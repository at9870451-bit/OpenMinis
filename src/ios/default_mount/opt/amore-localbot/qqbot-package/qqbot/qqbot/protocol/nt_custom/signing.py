"""签名服务抽象。

这是自研 NT 协议的**生死闸门**：QQ 的每个业务包都需要一段由原生库
（wrapper.node / QQNT.dll）计算的签名，纯 Python 无法自行算出。

对 QQ 9.9.33 原生库的导出表取证结论（见 re/pe.py）：
  - QQNT.dll          3385 个导出，全部是 V8/Node 运行时内部符号，无签名相关导出
  - wrapper.node      仅 66 个导出，关键的是
                      nt::wrapper::INTSessionShell::CreateNTSessionShell(std::string const&)
                      —— 签名能力藏在 C++ 虚接口后面，不是可直接调用的 C 导出
  - msf-win32-x64.node 27 个导出，均为 Node 内部符号

因此签名只能通过「让原生库来算」获得，可行路线两条：
  A. 复用 QQ 客户端进程（注入 / LiteLoader 插件）——最稳定，但等于回到 OneBot 路线
  B. 自己托管原生库：加载 QQNT.dll 的 Node 运行时 + wrapper.node，
     通过 CreateNTSessionShell 驱动协议——最贴近「自研」，但需逆向虚表与 JS 侧 API

本模块只定义统一接口，具体实现按所选路线替换即可。
"""

from __future__ import annotations

import hashlib
from abc import ABC, abstractmethod

from ...log import get_logger

log = get_logger("protocol.nt.sign")


class Signer(ABC):
    name: str = "base"

    @abstractmethod
    async def sign(self, cmd: str, body: bytes, *, seq: int = 0, service: str = "") -> bytes:
        """为指定命令的包体生成签名。"""

    async def close(self) -> None:
        """释放资源。"""


class MockSigner(Signer):
    """确定性假签名，仅用于驱动登录状态机自测，不可与真实服务器通信。"""

    name = "mock"

    async def sign(self, cmd: str, body: bytes, *, seq: int = 0, service: str = "") -> bytes:
        digest = hashlib.sha256(f"{service}|{cmd}|{seq}|".encode() + body).digest()
        return b"\x00MOCK\x00" + digest[:12]


class HttpSigner(Signer):
    """调用本地签名服务（标准做法：签名服务进程内加载原生库完成计算）。

    约定接口：
        POST {url}/sign   {"cmd": str, "seq": int, "service": str, "data": hex}
        -> {"value": hex, "token": str?}
    """

    name = "http"

    def __init__(self, url: str, token: str = "", timeout: float = 10.0) -> None:
        self.url = url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._client = None

    async def _ensure_client(self):
        if self._client is None:
            try:
                import httpx
            except ImportError as exc:
                raise RuntimeError("缺少依赖 httpx，请执行: pip install httpx") from exc
            headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
            self._client = httpx.AsyncClient(
                base_url=self.url, timeout=self.timeout, headers=headers
            )
        return self._client

    async def sign(self, cmd: str, body: bytes, *, seq: int = 0, service: str = "") -> bytes:
        client = await self._ensure_client()
        resp = await client.post(
            "/sign",
            json={"cmd": cmd, "seq": seq, "service": service, "data": body.hex()},
        )
        resp.raise_for_status()
        payload = resp.json()
        value = payload.get("value")
        if not value:
            raise RuntimeError(f"签名服务未返回 value: {payload}")
        return bytes.fromhex(value)

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None


def create_signer(kind: str, **kwargs) -> Signer:
    kind = (kind or "mock").lower()
    if kind == "mock":
        return MockSigner()
    if kind in ("http", "sign-server"):
        return HttpSigner(kwargs.get("url", ""), kwargs.get("token", ""))
    raise ValueError(f"未知的签名方案: {kind!r}（可选 mock / http）")