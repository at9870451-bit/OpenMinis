"""冲浪小窝 联动桥：在 QQ 里遥控「冲浪小窝」桌面版。

纯 HTTP 调用，不需要改动 QQBot 核心——本文件丢进 plugins_ext/ 即被加载。

两个方向：
  * 遥控（主动）：在 QQ 里下指令控制冲浪
        #开始冲浪        #停止冲浪        #冲浪状态        #冲浪档位 建议/回复/冲浪
  * 推送（被动）：后台轮询冲浪的事件，把「熔断告警」这类要紧的事私聊给管理员
        默认只推 alert 级（熔断、掉登录），避免刷屏；级别可在插件设置里调

用法：先让冲浪小窝开着控制台，然后在本插件的设置里填对「控制台地址」和
「联动令牌」（令牌要和冲浪小窝里的一致）。这些指令只对管理员生效。
"""

from __future__ import annotations

import asyncio
from typing import Any, Callable

import httpx

from ..base import Plugin

DEFAULT_URL = "http://127.0.0.1:6299"
TIMEOUT = 8.0
#: 单次最多取多少条事件，防止积压时一次性刷屏
EVENT_BATCH = 20

#: 用户口语 -> 引擎档位
MODE_ALIASES: dict[str, str] = {
    "建议": "suggest",
    "ai建议": "suggest",
    "suggest": "suggest",
    "1": "suggest",
    "回复": "reply",
    "自动回复": "reply",
    "reply": "reply",
    "2": "reply",
    "冲浪": "surf",
    "自主冲浪": "surf",
    "surf": "surf",
    "3": "surf",
}

#: 事件级别 -> 排序值。推送门槛取 ``push_level`` 的排序值。
LEVEL_ORDER: dict[str, int] = {"info": 0, "warn": 1, "alert": 2}
LEVEL_TAG: dict[str, str] = {"info": "·", "warn": "❗", "alert": "⚠️"}
PUSH_LEVELS: dict[str, str] = {
    "alert": "只推要紧的（熔断、掉登录）",
    "warn": "连停止、切节奏也推",
    "info": "全部都推（会比较吵）",
}


class SurfBridgePlugin(Plugin):
    name = "surf_bridge"
    display_name = "冲浪小窝联动"
    version = "0.2.0"
    description = "在 QQ 里遥控冲浪小窝，并把熔断告警推送到 QQ"
    priority = 40  # 先于 AI 对话（50），免得指令被聊天逻辑吃掉

    config_labels: dict[str, str] = {
        "enabled": "启用本插件",
        "strict_admin": "严格管理员权限（只认「AI 配置」里的管理员，群主/群管理不算）",
        "surf_url": "冲浪小窝控制台地址",
        "token": "联动令牌（与冲浪小窝里的设置保持一致）",
        "push_enabled": "把冲浪的告警推送到 QQ",
        "push_level": "推送级别：alert 只要紧的 / warn 加停止与切节奏 / info 全部",
        "push_interval": "轮询间隔（秒），越小越及时但越费资源",
        "push_targets": "推送给谁（填 QQ 号，留空＝所有管理员）",
    }

    default_config: dict[str, Any] = {
        "enabled": True,
        "strict_admin": True,
        "surf_url": DEFAULT_URL,
        "token": "",
        # ---- 推送 ----
        "push_enabled": True,
        "push_level": "alert",
        "push_interval": 10,
        "push_targets": [],
    }

    def __init__(self, bot) -> None:
        super().__init__(bot)
        self._task: asyncio.Task | None = None
        #: 事件游标。None 表示还没对齐，首次轮询只对齐游标、不补推历史事件。
        self._cursor: int | None = None

    async def on_load(self) -> None:
        self.add_command(
            "surf_start", self._cmd_start,
            aliases=("开始冲浪", "冲浪开始"), admin=True,
            description="让冲浪小窝开始冲浪",
        )
        self.add_command(
            "surf_stop", self._cmd_stop,
            aliases=("停止冲浪", "冲浪停止"), admin=True,
            description="让冲浪小窝停止冲浪",
        )
        self.add_command(
            "surf_status", self._cmd_status,
            aliases=("冲浪状态",), admin=True,
            description="查看冲浪小窝当前状态",
        )
        self.add_command(
            "surf_mode", self._cmd_mode,
            aliases=("冲浪档位", "切换冲浪档位"), admin=True,
            description="切换冲浪档位：建议 / 回复 / 冲浪",
        )
        self.log.info("冲浪小窝联动已加载（地址=%s）", self._base())
        if self.cfg_get("strict_admin", True) is not False and not (
            self.bot.config.bot.admins or []
        ):
            self.log.warning("严格管理员已开启，但「AI 配置」里还没填管理员，指令会无人可用")

        if self._active and self.cfg_get("push_enabled", True):
            self._task = asyncio.create_task(self._poll_loop())
            self.log.info(
                "冲浪告警推送已开启（间隔 %ss，级别 %s）",
                self._interval(),
                self.cfg_get("push_level", "alert"),
            )

    async def on_unload(self) -> None:
        """热重载/禁用时把轮询任务收干净。

        插件基类的 ``unload()`` 只取消总线订阅，不会管我们自己 create 的 task；
        不在这里 cancel，每次热重载都会攒下一个僵尸轮询。
        """
        task, self._task = self._task, None
        if task is None or task.done():
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception as exc:  # noqa: BLE001 - 收尾阶段不该再抛
            self.log.debug("停止推送任务时忽略异常：%s", exc)
        self.log.info("冲浪告警推送已停止")

    # ---------- 权限 ----------

    @property
    def _active(self) -> bool:
        return bool(self.cfg_get("enabled", True))

    def _allowed(self, ctx) -> bool:
        """默认只认「AI 配置」里的管理员：这是账号级动作（能让程序去发评论）。"""
        if not self._active:
            return False
        if self.cfg_get("strict_admin", True) is not False:
            uid = int(getattr(ctx.event, "user_id", 0) or 0)
            return uid in [int(a) for a in (self.bot.config.bot.admins or [])]
        return bool(ctx.is_admin)

    async def handle_message(self, ctx) -> Any:
        """没权限的人完全不入场：既不执行，也不回「没权限」，免得群里刷屏。"""
        if not self._allowed(ctx):
            return None
        return await super().handle_message(ctx)

    # ---------- HTTP ----------

    def _base(self) -> str:
        return str(self.cfg_get("surf_url", DEFAULT_URL) or DEFAULT_URL).rstrip("/")

    def _headers(self) -> dict[str, str]:
        return {"X-Surf-Token": str(self.cfg_get("token", "") or "")}

    async def _call(self, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
        """调冲浪小窝的接口。失败时统一抛 RuntimeError，消息可直接发给用户。"""
        url = self._base() + path
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                response = await client.request(
                    method, url, headers=self._headers(), **kwargs
                )
        except httpx.HTTPError as exc:
            self.log.debug("连不上冲浪小窝（%s）：%s", url, exc)
            raise RuntimeError(
                "连不上冲浪小窝，确认它正在运行、地址和联动令牌没填错。"
            ) from None

        try:
            data = response.json()
        except ValueError:
            data = {}
        if not isinstance(data, dict):
            data = {}

        if response.status_code == 401:
            raise RuntimeError("联动令牌不对，请让两边的令牌保持一致。")
        if data.get("ok") is False:
            raise RuntimeError(str(data.get("error") or "冲浪小窝拒绝了这次操作。"))
        if response.status_code >= 400:
            raise RuntimeError(f"冲浪小窝返回了错误（{response.status_code}）。")
        return data

    async def _say(self, ctx, action: Callable[..., Any]) -> None:
        """跑一次 HTTP 调用，失败时统一回一句人话。"""
        try:
            data = await action()
        except Exception as exc:  # noqa: BLE001 - 一律转成给用户看的提示
            self.log.warning("冲浪联动失败：%s", exc)
            await ctx.reply(str(exc) if isinstance(exc, RuntimeError) else "操作失败，请稍后再试。")
            return
        await ctx.reply(self._describe(data))

    # ---------- 指令 ----------

    @staticmethod
    def _describe(data: dict[str, Any]) -> str:
        engine = data.get("engine") or {}
        head = f"{data.get('name') or '冲浪小窝'} {data.get('version') or ''}".strip()
        parts = [
            f"状态：{engine.get('state') or '未知'}",
            f"档位：{engine.get('mode_label') or '未知'}",
            f"节奏：{engine.get('tempo_label') or '未知'}",
        ]
        breaker = engine.get("breaker") or {}
        if breaker:
            parts.append(f"⚠️ 已熔断：{breaker.get('reason') or '触发风控保护'}")
        return f"{head}｜" + "｜".join(parts)

    async def _cmd_start(self, ctx, args: str) -> Any:
        await self._say(ctx, lambda: self._call("POST", "/api/engine/start"))

    async def _cmd_stop(self, ctx, args: str) -> Any:
        await self._say(ctx, lambda: self._call("POST", "/api/engine/stop"))

    async def _cmd_status(self, ctx, args: str) -> Any:
        await self._say(ctx, lambda: self._call("GET", "/api/peer/ping"))

    async def _cmd_mode(self, ctx, args: str) -> Any:
        raw = str(args or "").strip()
        if not raw:
            await ctx.reply("用法：#冲浪档位 建议 / 回复 / 冲浪")
            return
        mode = MODE_ALIASES.get(raw.lower().replace(" ", ""))
        if not mode:
            await ctx.reply("没听懂这个档位，可以选：建议 / 回复 / 冲浪。")
            return
        await self._say(
            ctx, lambda: self._call("PUT", "/api/engine/mode", json={"mode": mode})
        )

    # ---------- 事件推送 ----------

    def _interval(self) -> float:
        try:
            return max(3.0, float(self.cfg_get("push_interval", 10) or 10))
        except (TypeError, ValueError):
            return 10.0

    def _wanted(self, level: str) -> bool:
        threshold = LEVEL_ORDER.get(str(self.cfg_get("push_level", "alert") or "alert"), 2)
        return LEVEL_ORDER.get(str(level or "info"), 0) >= threshold

    @staticmethod
    def _format_event(item: dict[str, Any]) -> str:
        level = str(item.get("level") or "info")
        return f"{LEVEL_TAG.get(level, '·')} 冲浪小窝：{item.get('text') or ''}"

    def _targets(self) -> list[int]:
        raw = self.cfg_get("push_targets") or []
        targets: list[int] = []
        for value in raw if isinstance(raw, (list, tuple)) else [raw]:
            try:
                uid = int(str(value).strip())
            except (TypeError, ValueError):
                continue
            if uid and uid not in targets:
                targets.append(uid)
        if targets:
            return targets
        return [int(a) for a in (self.bot.config.bot.admins or [])]

    async def _broadcast(self, message: str) -> None:
        targets = self._targets()
        if not targets:
            self.log.debug("没有推送目标，跳过：%s", message)
            return
        for uid in targets:
            try:
                await self.bot.send_private_msg(uid, message)
            except Exception as exc:  # noqa: BLE001 - 单个目标失败不影响其余
                self.log.warning("推送冲浪事件给 %s 失败：%s", uid, exc)

    async def _poll_loop(self) -> None:
        while True:
            await asyncio.sleep(self._interval())
            try:
                await self._poll_once()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - 冲浪没开着是常态，不要刷屏
                self.log.debug("轮询冲浪事件失败：%s", exc)

    async def _poll_once(self) -> None:
        if self._cursor is None:
            # 首次只对齐游标：否则 QQBot 一重启就会把陈年事件全推一遍
            data = await self._call("GET", "/api/events?since=0&limit=1")
            self._cursor = int(data.get("latest") or 0)
            self.log.info("冲浪事件游标已对齐到 %s，之后的新事件会推送到 QQ", self._cursor)
            return

        data = await self._call(
            "GET", f"/api/events?since={self._cursor}&limit={EVENT_BATCH}"
        )
        self._cursor = int(data.get("cursor") or self._cursor)
        if data.get("truncated"):
            await self._broadcast("⚠️ 冲浪小窝事件积压太多，中间有遗漏，建议看一眼控制台。")
        for item in data.get("items") or []:
            if isinstance(item, dict) and self._wanted(str(item.get("level") or "")):
                await self._broadcast(self._format_event(item))
