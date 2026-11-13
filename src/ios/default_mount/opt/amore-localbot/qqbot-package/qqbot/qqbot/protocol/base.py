"""协议后端抽象接口。

所有协议实现（Mock / OneBot11 / 自研 NT）都必须实现本接口，
上层框架只依赖 ProtocolBackend，不依赖任何具体协议细节。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Awaitable, Callable

from ..config import Config

EventSink = Callable[[dict[str, Any]], Awaitable[None]]


class ProtocolBackend(ABC):
    #: 后端标识，与配置里的 protocol.backend 对应
    name: str = "base"

    def __init__(self, config: Config, on_event: EventSink) -> None:
        self.config = config
        self._on_event = on_event
        self._connected = False

    @property
    def connected(self) -> bool:
        return self._connected

    @abstractmethod
    async def start(self) -> None:
        """建立连接并开始接收事件。"""

    @abstractmethod
    async def stop(self) -> None:
        """断开连接、释放资源。"""

    @abstractmethod
    async def call_api(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        """调用一个协议动作（如 send_group_msg），返回响应数据。"""

    async def _emit(self, data: dict[str, Any]) -> None:
        """把原始事件交给上层。"""
        await self._on_event(data)

    def __repr__(self) -> str:
        state = "connected" if self._connected else "disconnected"
        return f"<{type(self).__name__} {self.name} {state}>"