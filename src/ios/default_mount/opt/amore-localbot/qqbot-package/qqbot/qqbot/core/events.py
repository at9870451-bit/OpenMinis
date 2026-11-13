"""事件模型：把协议层的原始字典包装成结构化对象。"""

from __future__ import annotations

from typing import Any

from .message import Message


class Event:
    """所有事件的基类，保留原始数据以兼容协议扩展字段。"""

    kind = "event"

    def __init__(self, data: dict[str, Any]) -> None:
        self.raw = data
        self.post_type: str = data.get("post_type", "")
        self.time: int = int(data.get("time") or 0)
        self.self_id: int = int(data.get("self_id") or 0)

    def get(self, key: str, default: Any = None) -> Any:
        return self.raw.get(key, default)

    def __repr__(self) -> str:
        return f"<{type(self).__name__} post_type={self.post_type!r}>"


class MessageEvent(Event):
    """消息事件（群聊 / 私聊）。"""

    kind = "message"

    def __init__(self, data: dict[str, Any]) -> None:
        super().__init__(data)
        self.message_type: str = data.get("message_type", "")
        self.sub_type: str = data.get("sub_type", "")
        self.message_id = data.get("message_id")
        self.user_id = int(data.get("user_id") or 0)
        self.group_id = data.get("group_id")
        self.group_id = int(self.group_id) if self.group_id else None
        self.sender: dict[str, Any] = data.get("sender") or {}
        self.message = Message.from_raw(data.get("message"))
        self.raw_message: str = data.get("raw_message", "") or self.message.plain_text()

    @property
    def is_group(self) -> bool:
        return self.group_id is not None

    @property
    def is_private(self) -> bool:
        return self.group_id is None

    @property
    def text(self) -> str:
        return self.message.plain_text()

    @property
    def nickname(self) -> str:
        return str(self.sender.get("card") or self.sender.get("nickname") or self.user_id)

    @property
    def role(self) -> str:
        """群内身份：owner / admin / member（私聊为空）。"""
        return str(self.sender.get("role") or "")

    def __repr__(self) -> str:
        scope = f"group={self.group_id}" if self.is_group else f"user={self.user_id}"
        return f"<MessageEvent {scope} text={self.text!r}>"


class NoticeEvent(Event):
    """通知事件：群成员变动、戳一戳、撤回等。"""

    kind = "notice"

    def __init__(self, data: dict[str, Any]) -> None:
        super().__init__(data)
        self.notice_type: str = data.get("notice_type", "")
        self.group_id = data.get("group_id")
        self.user_id = data.get("user_id")


class RequestEvent(Event):
    """请求事件：加好友、加群。"""

    kind = "request"

    def __init__(self, data: dict[str, Any]) -> None:
        super().__init__(data)
        self.request_type: str = data.get("request_type", "")
        self.user_id = data.get("user_id")
        self.group_id = data.get("group_id")
        self.comment: str = data.get("comment", "")
        self.flag: str = data.get("flag", "")


class MetaEvent(Event):
    """元事件：连接生命周期、心跳。"""

    kind = "meta"

    def __init__(self, data: dict[str, Any]) -> None:
        super().__init__(data)
        self.meta_event_type: str = data.get("meta_event_type", "")


def parse_event(data: dict[str, Any]) -> Event:
    """根据 post_type 分派为具体事件类型。"""
    post_type = data.get("post_type")
    if post_type == "message":
        return MessageEvent(data)
    if post_type == "notice":
        return NoticeEvent(data)
    if post_type == "request":
        return RequestEvent(data)
    if post_type == "meta_event":
        return MetaEvent(data)
    return Event(data)