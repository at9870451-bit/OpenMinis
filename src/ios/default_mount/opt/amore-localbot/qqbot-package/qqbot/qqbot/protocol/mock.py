"""Mock 协议后端：不依赖任何真实 QQ，用于框架开发与自测。

启动后会按脚本注入若干演示事件，并把机器人发出的消息打印出来，
从而让插件系统、WebUI、托盘等模块在没有真实协议的情况下也能跑通。
"""

from __future__ import annotations

import asyncio
from typing import Any

from ..log import get_logger
from .base import EventSink, ProtocolBackend

log = get_logger("protocol.mock")


class MockBackend(ProtocolBackend):
    name = "mock"

    def __init__(self, config, on_event: EventSink) -> None:
        super().__init__(config, on_event)
        self._task: asyncio.Task | None = None
        self.sent: list[dict[str, Any]] = []  # 记录机器人发出的内容，便于自测断言

    async def start(self) -> None:
        self._connected = True
        log.info("Mock 后端已启动（演示模式，不会连接真实 QQ）")
        self._task = asyncio.create_task(self._demo_feed())

    async def stop(self) -> None:
        self._connected = False
        if self._task and not self._task.done():
            self._task.cancel()

    async def _demo_feed(self) -> None:
        await asyncio.sleep(0.5)
        await self._emit(
            {
                "post_type": "meta_event",
                "meta_event_type": "lifecycle",
                "time": 0,
                "self_id": 10000,
            }
        )
        demo_messages = ["#echo 你好，世界", "普通的一条群消息", "#help"]
        for idx, content in enumerate(demo_messages, start=1):
            await asyncio.sleep(0.2)
            await self._emit(
                {
                    "post_type": "message",
                    "message_type": "group",
                    "sub_type": "normal",
                    "time": 0,
                    "self_id": 10000,
                    "message_id": 1000 + idx,
                    "user_id": 20000 + idx,
                    "group_id": 90001,
                    "raw_message": content,
                    "message": [{"type": "text", "data": {"text": content}}],
                    "sender": {"nickname": f"测试用户{idx}", "user_id": 20000 + idx},
                }
            )
        log.info("演示事件投递完毕，Mock 后端进入静默（可用 WebUI 手动投递）")

    async def inject_message(self, content: str, group_id: int = 90001, user_id: int = 20000) -> None:
        """供 WebUI / 测试调用：手动注入一条群消息。"""
        await self._emit(
            {
                "post_type": "message",
                "message_type": "group",
                "sub_type": "normal",
                "time": 0,
                "self_id": 10000,
                "message_id": 0,
                "user_id": user_id,
                "group_id": group_id,
                "raw_message": content,
                "message": [{"type": "text", "data": {"text": content}}],
                "sender": {"nickname": "手动注入", "user_id": user_id},
            }
        )

    async def call_api(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        record = {"action": action, "params": params}
        self.sent.append(record)
        log.info("[Mock 发送] %s -> %s", action, params)
        # 列表类查询返回真正的列表，避免面板把 message_id 当成群条目遍历
        if action in ("get_group_list", "get_friend_list", "get_group_member_list"):
            return {"status": "ok", "retcode": 0, "data": []}
        return {"status": "ok", "retcode": 0, "data": {"message_id": len(self.sent)}}