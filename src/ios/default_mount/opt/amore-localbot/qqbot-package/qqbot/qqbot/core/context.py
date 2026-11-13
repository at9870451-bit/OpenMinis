"""消息上下文：插件处理消息时的便捷封装。"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from .bus import STOP
from .events import MessageEvent
from .message import (
    Message,
    MessageLike,
    Segment,
    at as at_seg,
    reply as reply_seg,
    text as text_seg,
)

if TYPE_CHECKING:
    from .bot import Bot


class Context:
    """对一次消息事件的封装，提供 reply / send 等快捷方法。"""

    def __init__(self, bot: "Bot", event: MessageEvent) -> None:
        self.bot = bot
        self.event = event

    # 直接透传事件属性，插件里可写 ctx.text / ctx.group_id
    def __getattr__(self, item: str) -> Any:
        return getattr(self.event, item)

    @property
    def text(self) -> str:
        return self.event.text

    @property
    def is_group(self) -> bool:
        return self.event.is_group

    @property
    def is_admin(self) -> bool:
        """是否可执行管理指令：只认配置里的管理员，群主/群管理不算。"""
        admins = [int(a) for a in (self.bot.config.bot.admins or [])]
        return int(self.event.user_id or 0) in admins

    @property
    def at_targets(self) -> list[int]:
        """消息中被 @ 的 QQ 号列表。"""
        targets: list[int] = []
        for seg in self.event.message:
            if not isinstance(seg, Segment) or seg.type != "at":
                continue
            qq = str(seg.data.get("qq", ""))
            if qq.isdigit():
                targets.append(int(qq))
        return targets

    async def reply(self, message: MessageLike, mention: bool = False, quote: bool = False) -> dict[str, Any]:
        """回复当前会话。mention=True 时在群聊中 @ 发送者。"""
        chain = Message.from_raw(message)
        prefix = Message()
        if quote and self.event.message_id:
            prefix.append(reply_seg(self.event.message_id))
        if mention and self.event.is_group:
            prefix.append(at_seg(self.event.user_id))
            # 必须 append 一个「文本段」。早先这里误用了 Message.from_raw(" ")，
            # 会把一个 Message 列表塞进列表，导致 JSON 序列化直接失败（群里 @ 回复发不出去）。
            prefix.append(text_seg(" "))
        prefix.extend(chain)
        return await self.bot.send_by_event(self.event, prefix)

    async def send(self, message: MessageLike) -> dict[str, Any]:
        return await self.bot.send_by_event(self.event, message)

    @staticmethod
    def stop() -> object:
        """终止后续插件的分发（返回值供处理函数 return）。"""
        return STOP