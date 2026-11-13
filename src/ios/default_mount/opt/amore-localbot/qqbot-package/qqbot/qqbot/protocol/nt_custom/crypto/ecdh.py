"""secp256k1 椭圆曲线与 ECDH。

QQ NT 登录握手用 ECDH 协商会话密钥。曲线运算（点加、倍点、标量乘）是
公开数学，可以用标准测试向量严格校验；QQ 在共享密钥之上叠加的 KDF 属于
实现细节，见 derive_shared_key 的说明。
"""

from __future__ import annotations

import secrets

# secp256k1 曲线参数
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
A = 0
B = 7
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

Point = tuple[int, int] | None
G: Point = (GX, GY)


def inverse(value: int, modulus: int = P) -> int:
    return pow(value % modulus, -1, modulus)


def is_on_curve(point: Point) -> bool:
    if point is None:
        return True
    x, y = point
    return (y * y - x * x * x - B) % P == 0


def add(p1: Point, p2: Point) -> Point:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2

    if x1 == x2 and (y1 + y2) % P == 0:
        return None  # 互为逆元，结果为无穷远点
    if p1 == p2:
        slope = (3 * x1 * x1 + A) * inverse(2 * y1) % P
    else:
        slope = (y2 - y1) * inverse(x2 - x1) % P

    x3 = (slope * slope - x1 - x2) % P
    y3 = (slope * (x1 - x3) - y1) % P
    return x3, y3


def double(point: Point) -> Point:
    return add(point, point)


def multiply(scalar: int, point: Point = G) -> Point:
    """标量乘（double-and-add）。"""
    scalar %= N
    if scalar == 0 or point is None:
        return None
    result: Point = None
    addend: Point = point
    while scalar:
        if scalar & 1:
            result = add(result, addend)
        addend = double(addend)
        scalar >>= 1
    return result


def generate_keypair() -> tuple[int, Point]:
    private = secrets.randbelow(N - 1) + 1
    return private, multiply(private)


def serialize_public(point: Point, compressed: bool = False) -> bytes:
    if point is None:
        raise ValueError("无穷远点无法序列化")
    x, y = point
    if compressed:
        return bytes([0x02 + (y & 1)]) + x.to_bytes(32, "big")
    return b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")


def deserialize_public(data: bytes) -> Point:
    if not data:
        raise ValueError("空公钥")
    if data[0] == 0x04:
        if len(data) != 65:
            raise ValueError("非压缩公钥长度必须是 65 字节")
        return int.from_bytes(data[1:33], "big"), int.from_bytes(data[33:65], "big")
    if data[0] in (0x02, 0x03):
        if len(data) != 33:
            raise ValueError("压缩公钥长度必须是 33 字节")
        x = int.from_bytes(data[1:33], "big")
        y = pow((x * x * x + B) % P, (P + 1) // 4, P)
        if (y & 1) != (data[0] & 1):
            y = P - y
        return x, y
    raise ValueError(f"不支持的公钥前缀 0x{data[0]:02X}")


class ECDHSession:
    """一次 ECDH 协商的自有密钥对。"""

    def __init__(self, private: int | None = None) -> None:
        if private is None:
            private, public = generate_keypair()
        else:
            public = multiply(private)
        self.private = private
        self.public = public

    def public_bytes(self, compressed: bool = False) -> bytes:
        return serialize_public(self.public, compressed)

    def derive_shared_key(self, peer_public: bytes | Point, size: int = 16) -> bytes:
        """计算共享密钥。

        返回共享点的 X 坐标截取。QQ 会在其上再做一次 KDF / 密钥派生，
        这一步依赖具体服务约定，需要真机抓包确认，故此处只暴露原始结果。
        """
        peer = (
            deserialize_public(peer_public)
            if isinstance(peer_public, (bytes, bytearray))
            else peer_public
        )
        shared = multiply(self.private, peer)
        if shared is None:
            raise ValueError("协商结果为无穷远点，对端公钥非法")
        return shared[0].to_bytes(32, "big")[:size]