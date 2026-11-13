"""TCP 封包编解码。

QQ 的 TCP 层用「起始标记 + 长度 + 载荷 + 结束标记」分帧：

    0x02 | length(2 字节) | payload | 0x03

长度字段在部分协议版本上会做一次轻量混淆（与密钥派生的 4 字节 dword 异或）。
本模块把混淆做成可插拔策略，默认不混淆——**具体采用哪种必须以真机抓包
校验**，不要假定当前默认值即可与官方服务互通。
"""

from __future__ import annotations

from dataclasses import dataclass

START_MARK = 0x02
END_MARK = 0x03
HEADER_SIZE = 3


class LengthObfuscator:
    """长度字段混淆策略基类。"""

    def encode(self, length: int) -> bytes:
        return length.to_bytes(2, "big")

    def decode(self, raw: bytes) -> int:
        return int.from_bytes(raw, "big")


class PlainLength(LengthObfuscator):
    """不做混淆（QQ 部分链路即为此形态）。"""


class XorLength(LengthObfuscator):
    """与 4 字节 dword 的低 2 字节异或（密钥相关链路）。"""

    def __init__(self, dword: int) -> None:
        self.dword = dword & 0xFFFFFFFF

    def encode(self, length: int) -> bytes:
        masked = length ^ (self.dword & 0xFFFF)
        return masked.to_bytes(2, "big")

    def decode(self, raw: bytes) -> int:
        return int.from_bytes(raw, "big") ^ (self.dword & 0xFFFF)


def encode_frame(payload: bytes, obfuscator: LengthObfuscator | None = None) -> bytes:
    obfuscator = obfuscator or PlainLength()
    if len(payload) > 0xFFFF:
        raise ValueError("单帧载荷超过 65535 字节")
    return bytes([START_MARK]) + obfuscator.encode(len(payload)) + payload + bytes([END_MARK])


@dataclass
class DecodeResult:
    frames: list[bytes]
    consumed: int


def decode_frames(
    buffer: bytes, obfuscator: LengthObfuscator | None = None
) -> DecodeResult:
    """从缓冲区里尽量多地取出完整帧。

    返回已解析的帧列表与已消费的字节数；剩余部分（半包）留在调用方缓存中，
    下次收到数据再续上。
    """
    obfuscator = obfuscator or PlainLength()
    frames: list[bytes] = []
    pos = 0
    total = len(buffer)

    while pos < total:
        # 找到起始标记（跳过前导噪声）
        if buffer[pos] != START_MARK:
            pos += 1
            continue
        if pos + HEADER_SIZE > total:
            break  # 头部还没收全
        length = obfuscator.decode(buffer[pos + 1 : pos + 3])
        end = pos + HEADER_SIZE + length
        if end + 1 > total:
            break  # 载荷或结束标记还没收全
        if buffer[end] != END_MARK:
            pos += 1  # 结束标记不匹配，说明是伪起始，继续找
            continue
        frames.append(bytes(buffer[pos + HEADER_SIZE : end]))
        pos = end + 1

    return DecodeResult(frames, pos)


class FrameReader:
    """带内部缓存的流式分帧器，直接喂 TCP 收到的分片。"""

    def __init__(self, obfuscator: LengthObfuscator | None = None) -> None:
        self._buffer = bytearray()
        self._obfuscator = obfuscator or PlainLength()

    def feed(self, chunk: bytes) -> list[bytes]:
        self._buffer += chunk
        result = decode_frames(bytes(self._buffer), self._obfuscator)
        del self._buffer[: result.consumed]
        return result.frames

    @property
    def pending(self) -> int:
        return len(self._buffer)