"""消息段与消息链：统一出站消息的表达，屏蔽各协议差异。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Union

from .cq import build_cq, parse_cq


@dataclass
class Segment:
    """一个消息段，如 text / at / image / face / reply。"""

    type: str
    data: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {"type": self.type, "data": self.data}


def text(content: str) -> Segment:
    return Segment("text", {"text": content})


def at(qq: Union[int, str]) -> Segment:
    return Segment("at", {"qq": str(qq)})


def image(file: str) -> Segment:
    return Segment("image", {"file": file})


def face(id_: int) -> Segment:
    return Segment("face", {"id": str(id_)})


def reply(message_id: Union[int, str]) -> Segment:
    return Segment("reply", {"id": str(message_id)})


def record(file: str) -> Segment:
    return Segment("record", {"file": file})


class Message(list):
    """消息链。支持 list 的所有操作，便于插件自由拼接。"""

    def to_array(self) -> list[dict[str, Any]]:
        return [seg.to_dict() if isinstance(seg, Segment) else seg for seg in self]

    def to_cq(self) -> str:
        """转为 CQ 码字符串（部分仅支持 string 格式的后端需要）。"""
        return build_cq(seg.to_dict() if isinstance(seg, Segment) else seg for seg in self)

    def plain_text(self) -> str:
        parts = []
        for seg in self:
            if isinstance(seg, Segment) and seg.type == "text":
                parts.append(seg.data.get("text", ""))
        return "".join(parts)

    def __str__(self) -> str:  # 便于日志输出
        return self.plain_text()

    @classmethod
    def from_raw(cls, raw: Any) -> "Message":
        """把协议层给出的 message 字段归一化为 Message。

        OneBot 可能给字符串（CQ 码）或数组：
          - 字符串：按 CQ 码解析，避免丢失 @ / 图片等段
          - 数组：逐项转为 Segment
        """
        msg = cls()
        if raw is None:
            return msg
        if isinstance(raw, str):
            for item in parse_cq(raw):
                msg.append(Segment(item["type"], item.get("data") or {}))
            return msg
        if isinstance(raw, Segment):
            msg.append(raw)
            return msg
        if isinstance(raw, Iterable):
            for item in raw:
                if isinstance(item, Segment):
                    msg.append(item)
                elif isinstance(item, dict) and "type" in item:
                    msg.append(Segment(item["type"], item.get("data") or {}))
                elif isinstance(item, str):
                    msg.append(text(item))
            return msg
        return msg


MessageLike = Union[str, Segment, Message, list]


def normalize_message(message: MessageLike) -> Union[str, list[dict[str, Any]]]:
    """把各种入参转成协议可直接发送的形式。"""
    if isinstance(message, str):
        return message
    if isinstance(message, Segment):
        return [message.to_dict()]
    if isinstance(message, Message):
        return message.to_array()
    if isinstance(message, list):
        out: list[dict[str, Any]] = []
        for item in message:
            if isinstance(item, Segment):
                out.append(item.to_dict())
            elif isinstance(item, dict):
                out.append(item)
            elif isinstance(item, str):
                out.append(text(item).to_dict())
        return out
    return str(message)