"""文生图：把提示词发给图片模型，取回图片字节。

默认走 OpenAI 兼容的 ``/images/generations``：
    POST {base_url}{path}
    {"model": "...", "prompt": "...", "n": 1, "size": "1024x1024"}
响应支持 ``data[0].b64_json``（base64）与 ``data[0].url``（下载地址）两种。
"""

from __future__ import annotations

import base64
import hashlib
import re
from pathlib import Path
from typing import Any

import httpx

_RATIO_RE = re.compile(r"(1:1|4:3|3:4|16:9|9:16)")
_RES_RE = re.compile(r"(480P|720P|1080P|1K|2K)", re.IGNORECASE)

_RES_BASE = {"480P": 480, "720P": 720, "1080P": 1080, "1K": 1024, "2K": 2048}


def _align(value: float) -> int:
    """对齐到 8 的倍数，避免部分接口直接拒绝非对齐尺寸。"""
    return max(256, (int(round(value)) + 7) // 8 * 8)


def parse_size(text: str, default_ratio: str = "1:1", default_resolution: str = "480P") -> tuple[int, int]:
    """从一句话里解析比例与清晰度，返回 (宽, 高)。

    「9:16」「720P」「1K」这类写法可以混在任意位置；没写就用默认值。
    """
    ratio_match = _RATIO_RE.search(text or "")
    ratio = ratio_match.group(1) if ratio_match else (default_ratio or "1:1")
    res_match = _RES_RE.search(text or "")
    resolution = (res_match.group(1) if res_match else (default_resolution or "480P")).upper()
    base = _RES_BASE.get(resolution, 480)

    try:
        a_text, b_text = ratio.split(":", 1)
        a, b = int(a_text), int(b_text)
    except (ValueError, AttributeError):
        a, b = 1, 1

    if a <= b:  # 竖图或方图：短边为基准
        width = base
        height = base * b / a
    else:
        height = base
        width = base * a / b
    return _align(width), _align(height)


def _extension(content_type: str, url: str = "") -> str:
    ctype = (content_type or "").lower()
    if "png" in ctype:
        return "png"
    if "jpeg" in ctype or "jpg" in ctype:
        return "jpg"
    if "webp" in ctype:
        return "webp"
    suffix = Path(url.split("?", 1)[0]).suffix.lower().lstrip(".")
    return suffix if suffix in ("png", "jpg", "jpeg", "webp") else "png"


async def generate(
    image_cfg, ai_cfg, prompt: str, size_text: str = ""
) -> tuple[bytes, str, int, int]:
    """生成图片，返回 (图片字节, 扩展名, 宽, 高)。"""
    base_url = str(image_cfg.base_url or ai_cfg.base_url or "").rstrip("/")
    if "pollinations" in base_url.lower():
        # 免费生图（无需 Key）：GET https://image.pollinations.ai/prompt/{prompt}
        from urllib.parse import quote
        import random as _r
        width, height = parse_size(
            size_text or prompt, image_cfg.default_ratio, image_cfg.default_resolution
        )
        seed = _r.randint(0, 999999)
        url = (f"https://image.pollinations.ai/prompt/{quote(prompt[:500])}"
               f"?width={width}&height={height}&seed={seed}&nologo=true")
        timeout = float(getattr(image_cfg, "timeout", 120.0) or 120.0)
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            resp = await client.get(url)
            if resp.status_code >= 400:
                raise RuntimeError(f"pollinations HTTP {resp.status_code}")
            data = resp.content
        if not data:
            raise RuntimeError("pollinations 返回空")
        return data, "png", width, height
    api_key = str(image_cfg.api_key or ai_cfg.api_key or "")
    api_key = str(image_cfg.api_key or ai_cfg.api_key or "")
    model = str(image_cfg.model or "").strip()
    if not base_url:
        raise ValueError("未配置生图接口地址")
    if not model:
        raise ValueError("未配置生图模型")

    path = str(image_cfg.path or "/images/generations").strip()
    if not path.startswith("/"):
        path = "/" + path
    url = base_url if base_url.endswith(path) else base_url + path
    width, height = parse_size(
        size_text or prompt, image_cfg.default_ratio, image_cfg.default_resolution
    )

    body: dict[str, Any] = {
        "model": model,
        "prompt": prompt,
        "n": 1,
        "size": f"{width}x{height}",
    }
    # 扩展参数：step 只对硅基流动（SiliconFlow）生效，智谱等接口不接受会报错
    step = getattr(image_cfg, "step", 0) or 0
    if step and "siliconflow" in base_url.lower():
        body["step"] = int(step)
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}

    timeout = float(getattr(image_cfg, "timeout", 120.0) or 120.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        resp = await client.post(url, json=body, headers=headers)
        if resp.status_code >= 400:
            raise RuntimeError(f"图片接口 HTTP {resp.status_code}: {resp.text[:200]}")
        try:
            payload = resp.json()
        except ValueError as exc:
            raise RuntimeError("图片接口返回的不是 JSON") from exc

        items = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(items, list) or not items:
            message = payload.get("message") if isinstance(payload, dict) else ""
            raise RuntimeError(str(message or "图片接口没有返回图片"))
        item = items[0] if isinstance(items[0], dict) else {}

        b64 = item.get("b64_json") or item.get("b64") or item.get("image")
        if b64:
            try:
                return base64.b64decode(str(b64)), "png", width, height
            except (ValueError, TypeError) as exc:
                raise RuntimeError("图片接口返回的 base64 无效") from exc

        image_url = item.get("url") or item.get("image_url")
        if not image_url:
            raise RuntimeError("图片接口没有返回图片地址")
        image_resp = await client.get(str(image_url))
        image_resp.raise_for_status()
        ext = _extension(image_resp.headers.get("content-type", ""), str(image_url))
        return image_resp.content, ext, width, height


def save_image(directory: Path, data: bytes, ext: str) -> Path:
    """按内容哈希落盘，重复生成同样的图不会重复占空间。"""
    directory.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha1(data).hexdigest()[:16]
    path = directory / f"{digest}.{ext}"
    if not path.exists():
        path.write_bytes(data)
    return path
