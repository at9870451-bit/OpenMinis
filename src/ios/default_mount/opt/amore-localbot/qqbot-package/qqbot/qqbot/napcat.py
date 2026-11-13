"""NapCat WebUI 客户端：供控制面板「登录 QQ」页使用的后端代理。

设计要点（不改 NapCat 源码）：
    网关目录里的 config/webui.json 保存了 WebUI 的端口与 token，本模块读取后
    自行完成鉴权，把 Credential 缓存在**进程内存**里。前端永远拿不到 token，
    NapCat 升级也不会覆盖我们的改动。

鉴权链路（已实测）：
    hash = sha256(token + ".napcat")
    POST /api/auth/login  {"hash": hash, "totpCode": ""}  ->  data.Credential
    之后所有请求带 header  Authorization: Bearer <Credential>
"""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
from typing import Any

from .log import get_logger

log = get_logger("napcat")

#: NapCat WebUI 配置文件名（位于网关目录 config/ 下）
WEBUI_CONFIG = Path("config") / "webui.json"
#: 鉴权 hash 的固定盐
AUTH_SALT = ".napcat"
#: Bearer Credential 的请求头
AUTH_HEADER = "Authorization"


class NapCatError(RuntimeError):
    """NapCat WebUI 调用失败（未部署、未启动或鉴权异常）。"""


#: NapCat 鉴权失效时返回的是 HTTP 200 + ``{"code": -1, "message": "Unauthorized"}``，
#: 只看 401/403 会一直拿着过期 Credential 撞墙，面板就会显示成「已登录」。
_AUTH_KEYWORDS = (
    "unauthorized",
    "credential",
    "token",
    "鉴权",
    "登录失效",
    "登录已失效",
    "未登录",
)


def _auth_failed(data: Any) -> bool:
    """响应里是不是在说「Credential 失效」。"""
    if not isinstance(data, dict):
        return False
    code = data.get("code")
    if code in (-100, 401, 403):
        return True
    if code in (0, None):
        return False
    message = str(data.get("message") or "").lower()
    return any(word in message for word in _AUTH_KEYWORDS)


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def qrcode_svg(url: str) -> bytes:
    """把登录二维码内容渲染成 SVG（纯标准库实现，无 Pillow 依赖）。"""
    import qrcode
    import qrcode.image.svg

    factory = qrcode.image.svg.SvgPathImage
    image = qrcode.make(url, image_factory=factory, border=2)
    buffer = io.BytesIO()
    image.save(buffer)
    return buffer.getvalue()


class NapCatClient:
    """NapCat WebUI 的异步客户端（读 token → 换 Credential → 调接口）。"""

    def __init__(self, config) -> None:
        self._gateway_dir: Path = config.paths.data_dir / "gateway"
        self._credential: str | None = None
        self._endpoint: tuple[str, str] | None = None  # (base_url, token)

    # ---------- 端点发现 ----------

    def _load_endpoint(self) -> tuple[str, str]:
        """读取 webui.json，返回 (base_url, token)。"""
        path = self._gateway_dir / WEBUI_CONFIG
        if not path.is_file():
            raise NapCatError(
                "NapCat WebUI 未开启（QQ 已在线，聊天/语音/画图均不受影响）。"
                "此页面仅用于重新扫码登录；如需扫码请使用 App 的扫码登录页。"
            )
        try:
            data = json.loads(path.read_text("utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise NapCatError(f"读取 {path} 失败: {exc}") from exc

        port = int(data.get("port") or 6099)
        token = str(data.get("token") or "")
        # host 常为 "::"（监听全部），客户端一律走回环地址，避免 IPv6 解析问题
        return f"http://127.0.0.1:{port}", token

    def _base_url(self) -> str:
        if self._endpoint is None:
            self._endpoint = self._load_endpoint()
        return self._endpoint[0]

    # ---------- 鉴权 ----------

    async def _login(self) -> str:
        """用 token 换 Credential。"""
        if self._endpoint is None:
            self._endpoint = self._load_endpoint()
        base_url, token = self._endpoint
        payload = {"hash": _sha256(token + AUTH_SALT), "totpCode": ""}
        import httpx

        try:
            async with httpx.AsyncClient(base_url=base_url, timeout=15.0) as client:
                resp = await client.post("/api/auth/login", json=payload)
                data = resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            self._endpoint = None  # 端口可能变了，下次重新读配置
            raise NapCatError(f"连接 NapCat WebUI 失败（{base_url}）: {exc}") from exc

        if data.get("code") != 0:
            raise NapCatError(f"NapCat 鉴权失败: {data.get('message') or data}")
        credential = (data.get("data") or {}).get("Credential")
        if not credential:
            raise NapCatError("NapCat 未返回 Credential")
        self._credential = credential
        log.info("NapCat WebUI 鉴权成功，已缓存 Credential")
        return credential

    async def _call(self, path: str, payload: dict[str, Any] | None = None) -> Any:
        """调用接口，Credential 失效时自动重登并重试一次。"""
        import httpx

        if self._credential is None:
            await self._login()

        for attempt in (1, 2):
            headers = {AUTH_HEADER: f"Bearer {self._credential}"}
            try:
                async with httpx.AsyncClient(
                    base_url=self._base_url(), timeout=20.0
                ) as client:
                    resp = await client.post(path, json=payload or {}, headers=headers)
            except httpx.HTTPError as exc:
                detail = str(exc) or exc.__class__.__name__
                raise NapCatError(f"请求 {path} 失败: {detail}") from exc

            if resp.status_code in (401, 403):
                if attempt == 1:
                    log.info("NapCat Credential 已失效（HTTP %s），重新鉴权", resp.status_code)
                    await self._relogin()
                    continue
                raise NapCatError("NapCat 鉴权被拒绝，请确认 webui.json 中的 token")

            try:
                data = resp.json()
            except ValueError as exc:
                raise NapCatError(
                    f"NapCat 返回了非 JSON 内容（HTTP {resp.status_code}）"
                ) from exc

            # 关键：鉴权失败时 NapCat 返回的是 HTTP 200 + code=-1/Unauthorized，
            # 不能只盯 401/403，否则过期凭证会一直被带进每个接口。
            if _auth_failed(data):
                if attempt == 1:
                    log.info(
                        "NapCat Credential 已失效（%s），重新鉴权后重试",
                        data.get("message") or data.get("code"),
                    )
                    await self._relogin()
                    continue
                raise NapCatError(
                    f"NapCat 鉴权失败: {data.get('message') or data.get('code')}"
                )
            return data

        raise NapCatError("NapCat 调用失败：鉴权重试后仍未成功")

    async def _relogin(self) -> None:
        """丢掉旧 Credential 并重新读取 webui.json 再鉴权。

        NapCat 重启后 token 也可能一起换掉，所以不能只换 Credential、
        继续用缓存下来的旧接口地址与 token。
        """
        self._credential = None
        self._endpoint = None
        await self._login()

    @staticmethod
    def _unwrap(data: Any, action: str) -> dict[str, Any]:
        """确认 code=0 后返回 data 对象；鉴权失败/业务失败一律抛错。"""
        if not isinstance(data, dict):
            raise NapCatError(f"{action}返回格式异常")
        code = data.get("code")
        if code != 0:
            raise NapCatError(f"{action}失败: {data.get('message') or code}")
        payload = data.get("data")
        return payload if isinstance(payload, dict) else {}

    # ---------- 登录相关接口 ----------

    async def check_login_status(self) -> dict[str, Any]:
        """当前登录状态：isLogin / loginPhase / qrcodeurl / coreReady 等。

        鉴权失败时直接抛错，不能悄悄返回空对象——那样面板会把「读不到」
        当成「没登录」，二维码却又是空的。
        """
        data = await self._call("/api/QQLogin/CheckLoginStatus")
        return self._unwrap(data, "读取登录状态")

    async def get_qrcode(self) -> str:
        """获取登录二维码内容（URL 字符串）。"""
        data = await self._call("/api/QQLogin/GetQQLoginQrcode")
        payload = self._unwrap(data, "获取二维码")
        return str(payload.get("qrcodeurl") or "")

    async def refresh_qrcode(self) -> str:
        data = await self._call("/api/QQLogin/RefreshQRcode")
        payload = self._unwrap(data, "刷新二维码")
        return str(payload.get("qrcodeurl") or "")

    async def quick_login_list(self) -> list[dict[str, Any]]:
        """免密登录账号列表（含 uin / uid / 昵称 / 头像）。"""
        data = await self._call("/api/QQLogin/GetQuickLoginListNew")
        items = data.get("data") if isinstance(data, dict) else None
        return items if isinstance(items, list) else []

    async def set_quick_login(self, uin: str) -> bool:
        """使用免密登录指定 QQ。"""
        data = await self._call("/api/QQLogin/SetQuickLoginQQ", {"uin": str(uin)})
        return data.get("code") == 0

    async def password_login(self, uin: str, password_md5: str) -> dict[str, Any]:
        """账号密码登录。

        返回网关原始响应：成功时 ``code=0``；需要验证码 / 新设备验证时
        同样是 ``code=0``，但 ``data`` 里带 ``needCaptcha`` / ``needNewDevice``。
        """
        return await self._call(
            "/api/QQLogin/PasswordLogin",
            {"uin": str(uin), "passwordMd5": str(password_md5)},
        )

    async def login_info(self) -> dict[str, Any]:
        """已登录账号信息：uin / nick / online。"""
        data = await self._call("/api/QQLogin/GetQQLoginInfo")
        return self._unwrap(data, "读取登录账号")

    async def restart(self) -> bool:
        """重启 NapCat（不结束 QQ 宿主进程）。"""
        data = await self._call("/api/QQLogin/RestartNapCat")
        return data.get("code") == 0

    # ---------- OneBot 11 配置（在线修改，改文件网关不会重读） ----------

    async def get_ob11_config(self) -> dict[str, Any]:
        """读取网关当前的 OneBot 11 配置。"""
        data = await self._call("/api/OB11Config/GetConfig")
        return self._unwrap(data, "读取 OneBot 配置")

    async def set_ob11_config(self, config: dict[str, Any]) -> bool:
        """在线写入 OneBot 11 配置，立即生效。

        注意接口要求把配置对象序列化成字符串放进 ``config`` 字段，
        直接传对象网关是不认的。
        """
        data = await self._call(
            "/api/OB11Config/SetConfig",
            {"config": json.dumps(config, ensure_ascii=False)},
        )
        return data.get("code") == 0

    async def realtime_logs(self) -> list[str]:
        """NapCat 实时日志（登录流程排查用）。"""
        data = await self._call("/api/Log/GetLogRealTime")
        items = data.get("data") if isinstance(data, dict) else None
        return items if isinstance(items, list) else []