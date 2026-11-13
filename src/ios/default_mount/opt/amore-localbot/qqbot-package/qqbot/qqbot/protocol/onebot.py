"""自研 OneBot 11 协议客户端。

这里的协议逻辑（连接、鉴权帧、事件解析、echo 请求应答关联、断线重连、
HTTP 回退）全部由我们自己实现，不依赖任何第三方机器人框架。

OneBot 11 约定的两种连接方向我们都支持：
  - 正向 WS（onebot_mode=forward）：本客户端主动连接协议实现方的 WS 服务端
  - 反向 WS（onebot_mode=reverse）：本程序起 WS 服务端，等协议实现方连入
  - HTTP：仅用于 API 调用回退
"""

from __future__ import annotations

import asyncio
import itertools
import json
from typing import Any

from ..log import get_logger
from .base import EventSink, ProtocolBackend

log = get_logger("protocol.onebot")


class OneBotBackend(ProtocolBackend):
    name = "onebot"

    def __init__(self, config, on_event: EventSink) -> None:
        super().__init__(config, on_event)
        self._ws: Any = None
        self._server: Any = None
        self._task: asyncio.Task | None = None
        self._pending: dict[str, asyncio.Future] = {}
        self._echo = itertools.count(1)
        self._tasks: set[asyncio.Task] = set()
        self.last_event_time: float = 0.0

    # ---------- 生命周期 ----------

    async def start(self) -> None:
        mode = (self.config.protocol.onebot_mode or "forward").lower()
        if mode == "reverse":
            self._task = asyncio.create_task(self._run_reverse())
        else:
            self._task = asyncio.create_task(self._run_forever())

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
        await self._close_server()
        await self._close_ws()
        for task in list(self._tasks):
            task.cancel()
        self._tasks.clear()

    def _spawn(self, coro) -> None:
        """把帧处理丢到独立任务里执行。

        关键：绝不能直接在接收循环里 await 处理逻辑，否则事件处理期间
        无法再收到任何帧，而 call_api 等待的应答正是通过该循环回来的，
        会造成必然的超时死锁。
        """
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _close_server(self) -> None:
        server, self._server = self._server, None
        if server is not None:
            server.close()
            try:
                await server.wait_closed()
            except Exception:  # noqa: BLE001
                pass

    async def _close_ws(self) -> None:
        ws, self._ws = self._ws, None
        self._connected = False
        if ws is not None:
            try:
                await ws.close()
            except Exception:  # noqa: BLE001
                pass

    def _headers(self) -> dict[str, str] | None:
        token = self.config.protocol.onebot_access_token
        return {"Authorization": f"Bearer {token}"} if token else None

    async def _connect(self, websockets: Any, url: str, headers: dict[str, str] | None):
        """兼容 websockets 新老版本的参数名差异。"""
        kwargs: dict[str, Any] = {"ping_interval": 30, "ping_timeout": 10}
        if headers:
            kwargs["additional_headers"] = headers
        try:
            return await websockets.connect(url, **kwargs)
        except TypeError:
            if headers:
                kwargs.pop("additional_headers", None)
                kwargs["extra_headers"] = headers
            return await websockets.connect(url, **kwargs)

    # ---------- 网关自动拉起 ----------

    async def _ensure_gateway(self) -> None:
        """委托给 GatewayController：探测 → 必要时弹框确认关 QQ → 拉起 → 等就绪。"""
        from ..gateway import GatewayController

        await GatewayController(self.config).ensure_ready(interactive=True)

    async def _run_forever(self) -> None:
        await self._ensure_gateway()
        try:
            import websockets
        except ImportError:
            log.error("缺少依赖 websockets，无法启用 OneBot 后端。请执行: pip install websockets")
            return

        url = self.config.protocol.onebot_ws_url
        interval = self.config.protocol.reconnect_interval

        while True:
            try:
                log.info("连接 OneBot WS: %s", url)
                ws = await self._connect(websockets, url, self._headers())
                self._ws = ws
                self._connected = True
                log.info("OneBot 连接成功")
                async for raw in ws:
                    self._spawn(self._handle_frame(raw))
            except asyncio.CancelledError:
                await self._close_ws()
                raise
            except Exception as exc:  # noqa: BLE001
                log.warning("OneBot 连接异常: %s，%ss 后重连", exc, interval)
                # 置控台开了智能通知时，第一时间给用户邮箱发一封异常邮件
                try:
                    from ..notify import notify_connection_error

                    await notify_connection_error(self.config, str(exc))
                except Exception as notify_exc:  # noqa: BLE001 - 通知失败不影响重连
                    log.warning("发送异常通知失败: %s", notify_exc)
            finally:
                self._connected = False
                self._ws = None
                self._fail_pending("连接已断开")
            await asyncio.sleep(interval)

    # ---------- 反向 WS 服务端模式 ----------

    async def _run_reverse(self) -> None:
        try:
            import websockets
        except ImportError:
            log.error("缺少依赖 websockets，无法启用 OneBot 后端。请执行: pip install websockets")
            return

        host = self.config.protocol.onebot_reverse_host
        port = self.config.protocol.onebot_reverse_port
        try:
            self._server = await websockets.serve(
                self._reverse_handler, host, port, ping_interval=30, ping_timeout=10
            )
        except OSError as exc:
            log.error("反向 WS 服务端启动失败（%s:%s 可能被占用）: %s", host, port, exc)
            return

        log.info("反向 WS 服务端已监听 ws://%s:%s，等待协议实现方连入", host, port)
        await asyncio.Future()  # 一直保持运行，直到被取消

    def _check_reverse_auth(self, ws: Any) -> bool:
        token = self.config.protocol.onebot_access_token
        if not token:
            return True
        request = getattr(ws, "request", None)
        headers = getattr(request, "headers", None)
        if headers is not None:
            auth = headers.get("Authorization") or headers.get("authorization") or ""
            if auth == f"Bearer {token}":
                return True
        path = getattr(request, "path", "") or ""
        query = path.split("?", 1)[1] if "?" in path else ""
        for pair in query.split("&"):
            if pair.startswith("access_token=") and pair.split("=", 1)[1] == token:
                return True
        return False

    async def _reverse_handler(self, ws: Any) -> None:
        if not self._check_reverse_auth(ws):
            log.warning("反向 WS 连接鉴权失败，已拒绝")
            await ws.close(code=1008, reason="unauthorized")
            return

        if self._ws is not None:
            log.info("已有连接，替换为最新连入的协议实现方")
            await self._close_ws()

        log.info("协议实现方已连入反向 WS")
        self._ws = ws
        self._connected = True
        try:
            async for raw in ws:
                self._spawn(self._handle_frame(raw))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("反向 WS 连接异常: %s", exc)
        finally:
            if self._ws is ws:
                self._ws = None
                self._connected = False
                self._fail_pending("连接已断开")
                try:
                    from ..notify import notify_connection_error

                    await notify_connection_error(self.config, "反向 WS 连接已断开")
                except Exception as notify_exc:  # noqa: BLE001 - 通知失败不影响服务
                    log.warning("发送异常通知失败: %s", notify_exc)

    # ---------- 事件与响应 ----------

    async def _handle_frame(self, raw: Any) -> None:
        if isinstance(raw, (bytes, bytearray)):
            try:
                raw = raw.decode("utf-8")
            except UnicodeDecodeError:
                return
        try:
            data = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            log.debug("收到非 JSON 帧，已忽略")
            return

        echo = data.get("echo")
        if echo is not None and ("retcode" in data or "status" in data):
            fut = self._pending.pop(str(echo), None)
            if fut and not fut.done():
                fut.set_result(data)
            return

        if data.get("post_type"):
            self.last_event_time = asyncio.get_running_loop().time()
            await self._emit(data)

    def _fail_pending(self, reason: str) -> None:
        for fut in list(self._pending.values()):
            if not fut.done():
                fut.set_exception(ConnectionError(reason))
        self._pending.clear()

    # ---------- API 调用 ----------

    async def call_api(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        if self._ws is not None and self._connected:
            try:
                return await self._call_ws(action, params)
            except Exception as exc:  # noqa: BLE001
                log.warning("WS 调用 %s 失败(%s: %s)，回退 HTTP", action, type(exc).__name__, exc)
        return await self._call_http(action, params)

    async def _call_ws(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        echo = str(next(self._echo))
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[echo] = fut
        try:
            await self._ws.send(json.dumps({"action": action, "params": params, "echo": echo}))
            return await asyncio.wait_for(fut, timeout=self.config.protocol.call_timeout)
        finally:
            self._pending.pop(echo, None)

    async def _call_http(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        try:
            import httpx
        except ImportError as exc:
            raise RuntimeError("缺少依赖 httpx，无法使用 HTTP 回退调用") from exc

        base = self.config.protocol.onebot_api_url.rstrip("/")
        url = f"{base}/{action}"
        async with httpx.AsyncClient(timeout=self.config.protocol.call_timeout) as client:
            resp = await client.post(url, json=params, headers=self._headers() or {})
            resp.raise_for_status()
            return resp.json()