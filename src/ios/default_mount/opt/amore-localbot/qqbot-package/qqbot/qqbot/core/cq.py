"""CQ 码解析与生成。

OneBot 的 string 上报格式用 CQ 码表达消息段，例如：

    [CQ:at,qq=123456] 你好 [CQ:image,file=xxx.jpg]

本模块负责在 CQ 码字符串与消息段之间双向转换。
只有 array 格式才天然带段信息；string 格式必须解析，否则会丢失 @、图片等。
"""

from __future__ import annotations

import re
from typing import Any, Iterable

CQ_PATTERN = re.compile(r"\[CQ:([^,\]]+)((?:,[^\]]*)?)\]")

# 转义顺序不可调换：必须先处理 & 本身
_UNESCAPE = (("&amp;", "&"), ("&#91;", "["), ("&#93;", "]"), ("&#44;", ","))


def unescape(value: str) -> str:
    for src, dst in _UNESCAPE:
        value = value.replace(src, dst)
    return value


def escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("[", "&#91;")
        .replace("]", "&#93;")
        .replace(",", "&#44;")
    )


def parse_cq(text: str) -> list[dict[str, Any]]:
    """把 CQ 码字符串解析为消息段列表（不含 CQ 码时即为单个文本段）。"""
    segments: list[dict[str, Any]] = []
    if not text:
        return segments

    pos = 0
    for match in CQ_PATTERN.finditer(text):
        if match.start() > pos:
            plain = unescape(text[pos:match.start()])
            if plain:
                segments.append({"type": "text", "data": {"text": plain}})

        cq_type = match.group(1).strip()
        params: dict[str, str] = {}
        raw_params = match.group(2)
        if raw_params:
            for pair in raw_params.strip(",").split(","):
                if "=" in pair:
                    key, _, value = pair.partition("=")
                    key = key.strip()
                    if key:
                        params[key] = unescape(value)
        segments.append({"type": cq_type, "data": params})
        pos = match.end()

    tail = unescape(text[pos:])
    if tail:
        segments.append({"type": "text", "data": {"text": tail}})
    return segments


def segment_to_cq(segment: dict[str, Any]) -> str:
    seg_type = segment.get("type", "")
    data = segment.get("data") or {}
    if seg_type == "text":
        return escape(str(data.get("text", "")))
    inner = ",".join(f"{key}={escape(str(value))}" for key, value in data.items())
    return f"[CQ:{seg_type}{',' + inner if inner else ''}]"


def build_cq(segments: Iterable[dict[str, Any]]) -> str:
    return "".join(segment_to_cq(segment) for segment in segments)