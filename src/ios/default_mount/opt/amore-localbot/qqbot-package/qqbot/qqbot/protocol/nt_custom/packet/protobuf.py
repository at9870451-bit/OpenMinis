"""极简 protobuf 线格式编解码。

QQ NT 绝大多数载荷是 protobuf。这里只实现线格式（wire format）本身，
不依赖 .proto 文件：逆向阶段需要的是「能读写任意未知结构」，而不是
预先编译好的消息类。
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Any, Iterable

WIRE_VARINT = 0
WIRE_64BIT = 1
WIRE_LEN = 2
WIRE_32BIT = 5


def encode_varint(value: int) -> bytes:
    if value < 0:
        value &= (1 << 64) - 1
    out = bytearray()
    while True:
        chunk = value & 0x7F
        value >>= 7
        if value:
            out.append(chunk | 0x80)
        else:
            out.append(chunk)
            return bytes(out)


def decode_varint(data: bytes, pos: int = 0) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("varint 越界")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint 超过 64 位")


@dataclass
class Field:
    number: int
    wire_type: int
    value: Any

    @property
    def is_bytes(self) -> bool:
        return self.wire_type == WIRE_LEN


class Writer:
    """按字段号顺序拼装 protobuf 载荷。"""

    def __init__(self) -> None:
        self._buf = bytearray()

    def _tag(self, number: int, wire_type: int) -> None:
        self._buf += encode_varint((number << 3) | wire_type)

    def varint(self, number: int, value: int) -> "Writer":
        self._tag(number, WIRE_VARINT)
        self._buf += encode_varint(value)
        return self

    def boolean(self, number: int, value: bool) -> "Writer":
        return self.varint(number, 1 if value else 0)

    def raw(self, number: int, value: bytes) -> "Writer":
        self._tag(number, WIRE_LEN)
        self._buf += encode_varint(len(value))
        self._buf += value
        return self

    def string(self, number: int, value: str) -> "Writer":
        return self.raw(number, value.encode("utf-8"))

    def message(self, number: int, sub: "Writer") -> "Writer":
        return self.raw(number, sub.to_bytes())

    def fixed32(self, number: int, value: int) -> "Writer":
        self._tag(number, WIRE_32BIT)
        self._buf += struct.pack("<I", value)
        return self

    def fixed64(self, number: int, value: int) -> "Writer":
        self._tag(number, WIRE_64BIT)
        self._buf += struct.pack("<Q", value)
        return self

    def to_bytes(self) -> bytes:
        return bytes(self._buf)

    def __len__(self) -> int:
        return len(self._buf)


def parse(data: bytes) -> list[Field]:
    """解析任意 protobuf 载荷为字段列表（保留原始顺序）。"""
    fields: list[Field] = []
    pos = 0
    end = len(data)
    while pos < end:
        tag, pos = decode_varint(data, pos)
        number = tag >> 3
        wire_type = tag & 0x07
        if number == 0:
            raise ValueError("字段号 0 非法")

        if wire_type == WIRE_VARINT:
            value, pos = decode_varint(data, pos)
        elif wire_type == WIRE_64BIT:
            if pos + 8 > end:
                raise ValueError("fixed64 越界")
            value = struct.unpack_from("<Q", data, pos)[0]
            pos += 8
        elif wire_type == WIRE_LEN:
            size, pos = decode_varint(data, pos)
            if pos + size > end:
                raise ValueError("长度前缀越界")
            value = data[pos : pos + size]
            pos += size
        elif wire_type == WIRE_32BIT:
            if pos + 4 > end:
                raise ValueError("fixed32 越界")
            value = struct.unpack_from("<I", data, pos)[0]
            pos += 4
        else:
            raise ValueError(f"不支持的线类型 {wire_type}")
        fields.append(Field(number, wire_type, value))
    return fields


def to_dict(data: bytes) -> dict[int, list[Any]]:
    """把载荷还原成「字段号 -> 值列表」，便于人工查看抓包。"""
    result: dict[int, list[Any]] = {}
    for field in parse(data):
        result.setdefault(field.number, []).append(field.value)
    return result


def first(data: bytes, number: int, default: Any = None) -> Any:
    for field in parse(data):
        if field.number == number:
            return field.value
    return default


def describe(data: bytes, indent: int = 0) -> str:
    """把 protobuf 载荷渲染成可读树，嵌套消息会自动尝试递归解析。"""
    lines: list[str] = []
    pad = "  " * indent
    for field in parse(data):
        value = field.value
        if isinstance(value, (bytes, bytearray)) and value:
            nested: Iterable[Field] | None = None
            try:
                nested = parse(bytes(value))
            except ValueError:
                nested = None
            if nested and all(f.number > 0 for f in nested):
                lines.append(f"{pad}#{field.number} (message {len(value)}B):")
                lines.append(describe(bytes(value), indent + 1))
            else:
                try:
                    text = bytes(value).decode("utf-8")
                    if text.isprintable() and text:
                        lines.append(f'{pad}#{field.number} = "{text}"')
                        continue
                except UnicodeDecodeError:
                    pass
                lines.append(f"{pad}#{field.number} = hex:{bytes(value).hex()}")
        else:
            lines.append(f"{pad}#{field.number} = {value}")
    return "\n".join(lines)