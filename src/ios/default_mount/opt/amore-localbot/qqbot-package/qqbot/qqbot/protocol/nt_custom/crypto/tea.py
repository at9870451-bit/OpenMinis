"""QQ TEA 分组密码。

QQ 使用的是 TEA 变体：**16 轮**（标准 TEA 是 32 轮），delta 与标准一致。
分组 8 字节、密钥 16 字节，均为大端 32 位字。

本模块只实现「分组密码」这一层——它的算术是公开且确定的，可以用标准
TEA 测试向量校验。QQ 特有的「随机头 + 填充长度」封装（Crypt 层）布局
各家实现略有出入，见 Crypt 的说明，需以真机抓包为准。
"""

from __future__ import annotations

import os
import struct

DELTA = 0x9E3779B9
MASK = 0xFFFFFFFF
QQ_ROUNDS = 16
STD_ROUNDS = 32


def _key_words(key: bytes) -> tuple[int, int, int, int]:
    if len(key) != 16:
        raise ValueError(f"TEA 密钥必须是 16 字节，当前 {len(key)} 字节")
    return struct.unpack(">4I", key)


def _encrypt_rounds(v0: int, v1: int, key: bytes, rounds: int) -> tuple[int, int]:
    k0, k1, k2, k3 = _key_words(key)
    total = 0
    for _ in range(rounds):
        total = (total + DELTA) & MASK
        v0 = (v0 + ((((v1 << 4) & MASK) + k0) ^ (v1 + total) ^ ((v1 >> 5) + k1))) & MASK
        v1 = (v1 + ((((v0 << 4) & MASK) + k2) ^ (v0 + total) ^ ((v0 >> 5) + k3))) & MASK
    return v0, v1


def _decrypt_rounds(v0: int, v1: int, key: bytes, rounds: int) -> tuple[int, int]:
    k0, k1, k2, k3 = _key_words(key)
    total = (DELTA * rounds) & MASK
    for _ in range(rounds):
        v1 = (v1 - ((((v0 << 4) & MASK) + k2) ^ (v0 + total) ^ ((v0 >> 5) + k3))) & MASK
        v0 = (v0 - ((((v1 << 4) & MASK) + k0) ^ (v1 + total) ^ ((v1 >> 5) + k1))) & MASK
        total = (total - DELTA) & MASK
    return v0, v1


def encrypt_block(v0: int, v1: int, key: bytes, rounds: int = QQ_ROUNDS) -> tuple[int, int]:
    return _encrypt_rounds(v0, v1, key, rounds)


def decrypt_block(v0: int, v1: int, key: bytes, rounds: int = QQ_ROUNDS) -> tuple[int, int]:
    return _decrypt_rounds(v0, v1, key, rounds)


def encrypt(data: bytes, key: bytes, rounds: int = QQ_ROUNDS) -> bytes:
    """对 8 字节整数倍的数据做 TEA 加密。"""
    if len(data) % 8:
        raise ValueError("TEA 加密要求数据长度为 8 的整数倍")
    out = bytearray()
    for i in range(0, len(data), 8):
        v0, v1 = struct.unpack_from(">2I", data, i)
        e0, e1 = _encrypt_rounds(v0, v1, key, rounds)
        out += struct.pack(">2I", e0, e1)
    return bytes(out)


def decrypt(data: bytes, key: bytes, rounds: int = QQ_ROUNDS) -> bytes:
    if len(data) % 8:
        raise ValueError("TEA 解密要求数据长度为 8 的整数倍")
    out = bytearray()
    for i in range(0, len(data), 8):
        v0, v1 = struct.unpack_from(">2I", data, i)
        d0, d1 = _decrypt_rounds(v0, v1, key, rounds)
        out += struct.pack(">2I", d0, d1)
    return bytes(out)


class Crypt:
    """QQ 的「带填充 TEA」封装。

    输出的前 8 字节是加密后的随机头；解密后前 3 字节是随机数、第 4 字节是
填充长度（3 字节头部 + 尾部填充）。明文总长 = 头部 + 数据 + 填充，并向上
对齐到 8 字节。

注意：QQ 不同版本/不同服务对头部布局与填充算法存在差异，这里的实现对
外暴露为可替换策略（header_size / block），接入真机时必须用抓包样本做一次
校验。未校验前不要假定它能与官方服务互通。
"""

HEADER_SIZE = 4  # 3 字节随机 + 1 字节填充长度
BLOCK = 8


class Crypt:
    def __init__(self, key: bytes, *, header_size: int = HEADER_SIZE, block: int = BLOCK) -> None:
        if len(key) != 16:
            raise ValueError("Crypt 密钥必须是 16 字节")
        self.key = key
        self.header_size = header_size
        self.block = block

    def encrypt(self, data: bytes) -> bytes:
        fill = (self.block - (len(data) + self.header_size) % self.block) % self.block
        body = bytearray()
        body += os.urandom(self.header_size - 1)
        body.append(fill + self.header_size - 1)  # 头部也算填充量
        body += data
        body += os.urandom(fill) if fill else b""
        return encrypt(bytes(body), self.key)

    def decrypt(self, data: bytes) -> bytes:
        plain = decrypt(data, self.key)
        if len(plain) < self.header_size:
            return b""
        padding = plain[self.header_size - 1]
        body = plain[self.header_size :]
        trim = padding - (self.header_size - 1)
        if trim <= 0:
            return bytes(body)
        return bytes(body[: len(body) - trim] if trim else body)