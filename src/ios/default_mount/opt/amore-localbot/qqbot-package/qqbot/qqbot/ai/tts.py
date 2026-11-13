"""语音合成：把文本转成语音，用于「偶尔的语音回复」。

默认走 OpenAI 兼容的 ``POST /audio/speech``；服务商不兼容时由 ai.adapter
按自定义协议翻译（请求路径 / 请求头 / 请求体模板 / 响应模式）。

响应模式（tts.response_mode）：
    auto    默认，自动判断（先看 Content-Type，再试单个 JSON，最后按分块流解析）
    binary  接口直接返回音频字节
    b64     单个 JSON，用 response_path 指向 base64 音频（默认 data）
    stream  HTTP 分块流，每块是一个 JSON，把每块的 data 字段拼起来
            —— 火山/豆包的「单向流式语音合成」就是这种
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import uuid
from pathlib import Path

from ..log import get_logger
from . import adapter

log = get_logger("ai.tts")

_DEFAULT_AUDIO_FIELD = "data"


def resolve_endpoint(tts_cfg, ai_cfg) -> adapter.Endpoint:
    """语音接入点：tts 段留空时回落到主 AI 配置。"""
    return adapter.Endpoint(
        base_url=(tts_cfg.base_url or ai_cfg.base_url or "").rstrip("/"),
        api_key=tts_cfg.api_key or ai_cfg.api_key or "",
        model=tts_cfg.model,
        path=tts_cfg.speech_path,
        request_template=tts_cfg.request_template,
        response_path=tts_cfg.response_path,
    )


def _b64(value: object) -> bytes:
    try:
        return base64.b64decode(str(value))
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError("响应里的音频不是合法的 base64") from exc


def _read_stream(text: str, field: str) -> bytes:
    """解析 HTTP 分块流：每行一个 JSON，逐块取出 base64 音频拼起来。

    顺带把上游的错误码带出来——「音色和资源不匹配」这类提示全靠它。
    """
    audio = b""
    error = ""
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if not isinstance(item, dict):
            continue
        code = item.get("code")
        if code not in (0, None):
            error = error or str(item.get("message") or f"code={code}")
            continue
        value = adapter.dig(item, field) if field else item.get(_DEFAULT_AUDIO_FIELD)
        if isinstance(value, str) and value:
            audio += _b64(value)
    if not audio and error:
        raise RuntimeError(error)
    if not audio:
        raise RuntimeError("语音接口没有返回音频内容")
    return audio


async def _read_audio(resp, response_path: str, mode: str) -> bytes:
    """按配置从响应里取出音频字节。"""
    spec = str(response_path or "").strip()
    field = spec[4:] if spec.startswith("b64:") else (spec or _DEFAULT_AUDIO_FIELD)
    mode = (mode or "auto").lower()
    ctype = resp.headers.get("content-type", "")

    if mode == "binary":
        return resp.content

    if mode == "stream":
        return _read_stream(resp.text, field)

    if mode == "b64":
        try:
            data = resp.json()
        except ValueError as exc:
            raise RuntimeError("配置了 b64 响应模式，但接口返回的不是 JSON") from exc
        value = adapter.dig(data, field)
        if not value:
            raise RuntimeError(f"响应里没有找到 {field}")
        return _b64(value)

    # ---- auto ----
    if spec.startswith("url:"):
        import httpx

        data = resp.json()
        url = adapter.dig(data, spec[4:])
        if not url or not str(url).startswith("http"):
            raise RuntimeError(f"响应里没有找到音频地址 {spec[4:]}")
        async with httpx.AsyncClient(timeout=60.0) as client:
            audio = await client.get(str(url))
            audio.raise_for_status()
            return audio.content

    if "json" not in ctype and "text" not in ctype:
        return resp.content  # 直接就是音频

    text = resp.text
    try:
        data = json.loads(text)
    except ValueError:
        return _read_stream(text, field)  # 多行 JSON = 分块流

    if isinstance(data, dict):
        value = adapter.dig(data, field)
        if isinstance(value, str) and value:
            return _b64(value)
        error = data.get("message")
        if error:
            raise RuntimeError(str(error))
    return _read_stream(text, field)


async def synthesize(tts_cfg, ai_cfg, text: str) -> tuple[bytes, str]:
    """合成语音，返回 (音频字节, 扩展名)。失败会抛异常，由调用方兜底回文字。"""
    import httpx

    endpoint = resolve_endpoint(tts_cfg, ai_cfg)
    if not endpoint.base_url:
        raise ValueError("未配置语音接口地址")
    if not endpoint.model:
        raise ValueError("未配置语音模型名")

    fmt = (tts_cfg.response_format or "mp3").lstrip(".")
    values = {
        "model": endpoint.model,
        "text": text,
        "input": text,
        "voice": tts_cfg.voice,
        "format": fmt,
        "instructions": tts_cfg.instructions,
        "api_key": endpoint.api_key,
        "request_id": str(uuid.uuid4()),
    }
    body = adapter.build_speech_body(
        endpoint, text=text, voice=tts_cfg.voice, fmt=fmt,
        instructions=tts_cfg.instructions, values=values,
    )

    # 有自定义请求头时完全由用户掌控（火山要的就是 X-Api-Key 这类头）；
    # 没有才自动加 Authorization Bearer。
    headers: dict[str, str] = {}
    custom = str(getattr(tts_cfg, "headers", "") or "").strip()
    if custom:
        headers.update(adapter.render_headers(custom, values))
    elif endpoint.api_key:
        headers["Authorization"] = f"Bearer {endpoint.api_key}"
    headers.setdefault("Content-Type", "application/json")

    path = adapter.pick_path(endpoint.path, adapter.DEFAULT_SPEECH_PATH)
    base = endpoint.base_url.rstrip("/")
    # 用户常把完整接口地址直接填进「接口地址」，这时不要再拼一遍请求路径
    url = base if path and base.endswith(path) else base + path

    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(url, json=body, headers=headers)
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = await _read_audio(
            resp, tts_cfg.response_path, getattr(tts_cfg, "response_mode", "auto")
        )

    if not data:
        raise RuntimeError("语音接口返回了空内容")
    return data, fmt


def save_audio(tts_dir: Path, data: bytes, fmt: str) -> Path:
    """把合成结果落到本地文件，供 OneBot 用 file:// 发送；同名内容自动复用。"""
    tts_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha1(data).hexdigest()[:16]
    path = tts_dir / f"{digest}.{fmt}"
    if not path.exists():
        path.write_bytes(data)
    return path