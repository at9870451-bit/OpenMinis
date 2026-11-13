"""事件总线：插件与核心之间唯一的通信通道。

- 支持同步 / 异步处理函数
- 按 priority 升序执行（数值越小越先执行）
- 处理函数返回 STOP 即终止后续分发
"""

from __future__ import annotations

import inspect
from collections import defaultdict
from typing import Any, Callable

STOP = object()

Handler = Callable[[Any], Any]


class Subscription:
    """一次订阅的句柄，用于插件卸载时取消监听。"""

    def __init__(self, bus: "EventBus", key: str, entry: tuple) -> None:
        self._bus = bus
        self._key = key
        self._entry = entry

    def cancel(self) -> None:
        handlers = self._bus._handlers.get(self._key)
        if handlers and self._entry in handlers:
            handlers.remove(self._entry)


class EventBus:
    def __init__(self) -> None:
        self._handlers: dict[str, list[tuple[int, int, Handler]]] = defaultdict(list)
        self._seq = 0

    def on(self, event_type: str, handler: Handler, priority: int = 100) -> Subscription:
        """订阅事件。event_type 可为 "message" / "notice" / "request" 或 "*"。"""
        self._seq += 1
        entry = (priority, self._seq, handler)
        self._handlers[event_type].append(entry)
        self._handlers[event_type].sort(key=lambda e: (e[0], e[1]))
        return Subscription(self, event_type, entry)

    def clear(self) -> None:
        self._handlers.clear()

    async def emit(self, event_type: str, event: Any) -> bool:
        """分发事件。返回 True 表示被某个处理函数请求停止。"""
        handlers = list(self._handlers.get(event_type, []))
        if event_type != "*":
            handlers += list(self._handlers.get("*", []))
        handlers.sort(key=lambda e: (e[0], e[1]))

        for _priority, _seq, handler in handlers:
            result = handler(event)
            if inspect.isawaitable(result):
                result = await result
            if result is STOP:
                return True
        return False