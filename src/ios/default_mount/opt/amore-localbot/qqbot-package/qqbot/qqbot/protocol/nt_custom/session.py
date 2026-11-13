"""设备指纹与会话票据的生成、持久化。

设备指纹必须**跨登录保持一致**，否则会被风控判定为异常设备。
字段名参考公开实现的命名；具体取值策略（尤其是 qimei 的生成算法）需要
按真机环境对齐，故此处生成的是占位值，用 placeholder=True 明确标记。
"""

from __future__ import annotations

import json
import os
import secrets
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from ...log import get_logger

log = get_logger("protocol.nt.session")


def _random_hex(length: int) -> str:
    return "".join(secrets.choice("0123456789ABCDEF") for _ in range(length))


@dataclass
class DeviceProfile:
    """设备信息。占位字段需按真机环境替换，否则风控会拦。"""

    guid: str = ""
    qimei36: str = ""
    android_id: str = ""
    device_name: str = ""
    system_kernel: str = ""
    vendor_name: str = ""
    vendor_os: str = ""
    os_version: str = ""
    brand: str = ""
    model: str = ""
    boot_id: str = ""
    proc_version: str = ""
    mac_address: str = ""
    imei: str = ""
    created_at: float = 0.0
    placeholder: bool = True

    @classmethod
    def generate(cls) -> "DeviceProfile":
        return cls(
            guid=_random_hex(32).lower(),
            qimei36=_random_hex(36).lower(),
            android_id=_random_hex(16).lower(),
            device_name="PCQQ",
            system_kernel="Windows 10",
            vendor_name="Tencent",
            vendor_os="Windows",
            os_version="10.0",
            brand="Tencent",
            model="PCQQ",
            boot_id=str(uuid.uuid4()),
            proc_version="Windows 10 Pro",
            mac_address="02:00:%02X:%02X:%02X:%02X" % tuple(secrets.randbelow(256) for _ in range(4)),
            imei="86" + "".join(str(secrets.randbelow(10)) for _ in range(13)),
            created_at=time.time(),
        )

    @classmethod
    def load_or_create(cls, path: Path) -> "DeviceProfile":
        if path.exists():
            try:
                data = json.loads(path.read_text("utf-8"))
                profile = cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
                log.info("已加载设备指纹 %s（guid=%s…）", path.name, profile.guid[:8])
                return profile
            except (json.JSONDecodeError, OSError, TypeError) as exc:
                log.warning("设备文件损坏，将重新生成: %s", exc)
        profile = cls.generate()
        profile.save(path)
        log.info("已生成新设备指纹并保存到 %s", path)
        return profile

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=2), encoding="utf-8")


@dataclass
class SessionState:
    """登录后拿到的会话票据，用于免密重连与心跳。"""

    uin: int = 0
    session_key: str = ""      # hex
    service_ticket: str = ""
    cookie: dict[str, str] = field(default_factory=dict)
    server_host: str = ""
    server_port: int = 0
    updated_at: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class SessionStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> SessionState | None:
        if not self.path.exists():
            return None
        try:
            data = json.loads(self.path.read_text("utf-8"))
            return SessionState(**{k: v for k, v in data.items() if k in SessionState.__dataclass_fields__})
        except (json.JSONDecodeError, OSError, TypeError) as exc:
            log.warning("会话文件损坏，将忽略: %s", exc)
            return None

    def save(self, state: SessionState) -> None:
        state.updated_at = time.time()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(state.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def clear(self) -> None:
        if self.path.exists():
            try:
                os.remove(self.path)
            except OSError as exc:
                log.warning("删除会话文件失败: %s", exc)