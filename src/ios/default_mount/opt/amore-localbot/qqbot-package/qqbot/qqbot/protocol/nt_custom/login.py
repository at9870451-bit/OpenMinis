"""登录流程编排。

**分层原则**：状态流转（连接 → 握手 → 认证 → 在线）是可确定实现的编排逻辑，
用 mock 签名 + 假传输即可完整验证；而每个包的**字段号与字节布局**必须靠真机
抓包逆向确认，全部集中在 Handshake 的常量区，并逐条标注。

当前状态：编排逻辑完整可跑；包布局为占位，pending_work 会明确列出还差什么。
"""

from __future__ import annotations

import asyncio
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum

from ...log import get_logger
from .crypto.ecdh import ECDHSession
from .packet.framing import FrameReader, encode_frame
from .packet.protobuf import Writer, first, parse
from .session import DeviceProfile, SessionState, SessionStore
from .signing import Signer

log = get_logger("protocol.nt.login")


class LoginState(str, Enum):
    IDLE = "idle"
    CONNECTING = "connecting"
    HANDSHAKE = "handshake"
    AUTHENTICATING = "authenticating"
    ONLINE = "online"
    FAILED = "failed"


@dataclass
class LoginResult:
    ok: bool
    state: LoginState
    uin: int = 0
    session_key: bytes = b""
    error: str = ""
    pending_work: list[str] = field(default_factory=list)


# ---------- 传输层 ----------


class Transport(ABC):
    @abstractmethod
    async def connect(self) -> None: ...

    @abstractmethod
    async def send(self, payload: bytes) -> None: ...

    @abstractmethod
    async def receive(self, timeout: float = 15.0) -> bytes: ...

    @abstractmethod
    async def close(self) -> None: ...


class TcpTransport(Transport):
    """真实 TCP 传输：自动分帧，屏蔽半包/粘包。"""

    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._frames = FrameReader()

    async def connect(self) -> None:
        log.info("连接 NT 服务器 %s:%s", self.host, self.port)
        self._reader, self._writer = await asyncio.open_connection(self.host, self.port)

    async def send(self, payload: bytes) -> None:
        if self._writer is None:
            raise RuntimeError("传输尚未连接")
        self._writer.write(encode_frame(payload))
        await self._writer.drain()

    async def receive(self, timeout: float = 15.0) -> bytes:
        if self._reader is None:
            raise RuntimeError("传输尚未连接")
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            frames = self._frames.feed(await asyncio.wait_for(
                self._reader.read(65536), timeout=max(0.1, deadline - asyncio.get_running_loop().time())
            ))
            if frames:
                return frames[0]
            if asyncio.get_running_loop().time() >= deadline:
                raise TimeoutError("等待服务器响应超时")

    async def close(self) -> None:
        if self._writer is not None:
            try:
                self._writer.close()
                await self._writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
        self._reader = None
        self._writer = None


# ---------- 包布局（需逆向确认） ----------


class Handshake:
    """NT 握手包的字段定义。

    !! 以下字段号全部是占位值，必须用真机抓包比对后修正 !!
    自研协议的全部不确定性都收敛在这里，其余代码不依赖具体字段号。
    """

    # 待逆向确认的包布局
    F_ECDH_PUBLIC_KEY = 1
    F_UIN = 2
    F_DEVICE_GUID = 3
    F_DEVICE_QIMEI = 4
    F_COMMAND = 5
    F_SIGNATURE = 6
    F_RETCODE = 1
    F_SESSION_KEY = 7
    F_SERVER_HOST = 8
    F_SERVER_PORT = 9

    CMD_HANDSHAKE = "trpc.qq_new_tech.status_svc.StatusService.Register"
    CMD_LOGIN = "trpc.login.ecdh.EcdhService.SsoNTLogin"

    PENDING = [
        "握手包字段号与嵌套结构（F_ECDH_PUBLIC_KEY 等）需抓包确认",
        "登录包 TLV 布局、加密方式（TEA 密钥来源）需抓包确认",
        "configsvr 拉取配置的接口地址与响应结构需抓包确认",
        "签名服务的输入拼接方式（cmd/seq/body/时间戳）需抓包比对",
        "风控/滑块验证码的触发条件与处理流程需实测",
    ]

    @staticmethod
    def build_handshake(pubkey: bytes, device: DeviceProfile, uin: int) -> bytes:
        return (
            Writer()
            .string(Handshake.F_COMMAND, Handshake.CMD_HANDSHAKE)
            .raw(Handshake.F_ECDH_PUBLIC_KEY, pubkey)
            .varint(Handshake.F_UIN, uin)
            .string(Handshake.F_DEVICE_GUID, device.guid)
            .string(Handshake.F_DEVICE_QIMEI, device.qimei36)
            .to_bytes()
        )

    @staticmethod
    def build_login(uin: int, session_key: bytes, device: DeviceProfile) -> bytes:
        return (
            Writer()
            .string(Handshake.F_COMMAND, Handshake.CMD_LOGIN)
            .varint(Handshake.F_UIN, uin)
            .string(Handshake.F_DEVICE_GUID, device.guid)
            .raw(Handshake.F_SESSION_KEY, session_key)
            .to_bytes()
        )

    @staticmethod
    def parse_retcode(payload: bytes) -> int:
        value = first(payload, Handshake.F_RETCODE, None)
        return int(value) if isinstance(value, int) else -1

    @staticmethod
    def parse_peer_key(payload: bytes) -> bytes:
        value = first(payload, Handshake.F_ECDH_PUBLIC_KEY, None)
        return bytes(value) if isinstance(value, (bytes, bytearray)) else b""

    @staticmethod
    def parse_response(payload: bytes) -> dict:
        return {f.number: f.value for f in parse(payload) if f.wire_type != 2 or f.value}


# ---------- 状态机 ----------


class LoginMachine:
    def __init__(
        self,
        *,
        uin: int,
        transport: Transport,
        signer: Signer,
        device: DeviceProfile,
        store: SessionStore | None = None,
        timeout: float = 15.0,
    ) -> None:
        self.uin = uin
        self.transport = transport
        self.signer = signer
        self.device = device
        self.store = store
        self.timeout = timeout
        self.state = LoginState.IDLE
        self.session = ECDHSession()

    async def run(self) -> LoginResult:
        pending = list(Handshake.PENDING)
        try:
            self.state = LoginState.CONNECTING
            await self.transport.connect()

            self.state = LoginState.HANDSHAKE
            shared = await self._handshake()
            if not shared:
                return self._fail("握手失败：未取得会话密钥", pending)

            self.state = LoginState.AUTHENTICATING
            session_key = await self._authenticate(shared)
            if session_key is None:
                return self._fail("认证失败：服务器未返回会话票据", pending)

            self.state = LoginState.ONLINE
            log.info("登录流程完成（uin=%s）", self.uin)
            return LoginResult(
                ok=True, state=self.state, uin=self.uin,
                session_key=session_key, pending_work=pending,
            )
        except Exception as exc:  # noqa: BLE001
            return self._fail(f"{type(exc).__name__}: {exc}", pending)
        finally:
            if self.state != LoginState.ONLINE:
                await self.transport.close()

    async def _handshake(self) -> bytes | None:
        log.info("开始 ECDH 握手")
        await self.transport.send(
            Handshake.build_handshake(self.session.public_bytes(), self.device, self.uin)
        )
        response = await self.transport.receive(self.timeout)
        peer = Handshake.parse_peer_key(response)
        if not peer:
            log.warning("握手响应里没有对端公钥（字段号可能不对）")
            return None
        shared = self.session.derive_shared_key(peer)
        log.info("ECDH 协商完成，共享密钥 %d 字节", len(shared))
        return shared

    async def _authenticate(self, shared: bytes) -> bytes | None:
        log.info("发起登录认证")
        body = Handshake.build_login(self.uin, shared, self.device)
        signature = await self.signer.sign(
            Handshake.CMD_LOGIN, body, seq=1, service=Handshake.CMD_HANDSHAKE
        )
        # 签名与包体的拼接顺序属于待逆向确认项（见 Handshake.PENDING）
        packet = body + Writer().raw(Handshake.F_SIGNATURE, signature).to_bytes()
        await self.transport.send(packet)

        response = await self.transport.receive(self.timeout)
        retcode = Handshake.parse_retcode(response)
        if retcode != 0:
            log.warning("登录被拒绝，retcode=%s（字段号可能不对，或签名无效）", retcode)
            return None

        key = first(response, Handshake.F_SESSION_KEY, None)
        session_key = bytes(key) if isinstance(key, (bytes, bytearray)) else shared
        if self.store is not None:
            self.store.save(
                SessionState(uin=self.uin, session_key=session_key.hex())
            )
        log.info("已取得会话票据，长度 %d 字节", len(session_key))
        return session_key

    def _fail(self, error: str, pending: list[str]) -> LoginResult:
        self.state = LoginState.FAILED
        log.error("登录流程失败：%s", error)
        return LoginResult(
            ok=False, state=self.state, uin=self.uin, error=error, pending_work=pending
        )