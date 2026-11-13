"""封包层：protobuf 与 TCP 分帧。"""

from .framing import (
    FrameReader,
    LengthObfuscator,
    PlainLength,
    XorLength,
    decode_frames,
    encode_frame,
)
from .protobuf import Field, Writer, describe, first, parse, to_dict

__all__ = [
    "Writer",
    "Field",
    "parse",
    "to_dict",
    "first",
    "describe",
    "encode_frame",
    "decode_frames",
    "FrameReader",
    "LengthObfuscator",
    "PlainLength",
    "XorLength",
]