"""协议层：统一出口。上层通过 create_backend 获取后端实例。"""

from __future__ import annotations

from ..config import Config
from .base import EventSink, ProtocolBackend

__all__ = ["ProtocolBackend", "EventSink", "create_backend"]


def create_backend(config: Config, on_event: EventSink) -> ProtocolBackend:
    """按配置创建协议后端。"""
    name = (config.protocol.backend or "mock").lower()

    if name == "mock":
        from .mock import MockBackend

        return MockBackend(config, on_event)
    if name == "onebot":
        from .onebot import OneBotBackend

        return OneBotBackend(config, on_event)
    if name == "nt":
        from .nt_custom import NTBackend

        return NTBackend(config, on_event)

    raise ValueError(f"未知的协议后端: {name!r}（可选 mock / onebot / nt）")