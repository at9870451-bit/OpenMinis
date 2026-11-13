"""接入点适配：把「接口地址 + 自定义协议」翻译成真正的 HTTP 请求。

默认按 OpenAI 兼容协议走；服务商不兼容时可用三样东西改写，不需要改代码：

  - ``path``             请求路径，默认 /chat/completions、/models、/audio/speech
  - ``request_template`` 请求体模板，JSON 字符串，用 ``${占位符}`` 取值
  - ``response_path``    从响应里取内容的路径，如 ``choices.0.message.content``

占位符会被替换成**合法的 JSON 片段**（字符串自动加引号并转义），因此模板本身
仍是一段合法的 JSON。举例（火山方舟风格的路径改写）：

    {"model": ${model}, "messages": ${messages}, "temperature": ${temperature}}

语音接口若返回 JSON + base64 音频，可把 ``response_path`` 写成 ``b64:data.audio``；
若返回的是音频 URL，写成 ``url:data.url``。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from ..log import get_logger

log = get_logger("ai.adapter")

_PLACEHOLDER_RE = re.compile(r"\$\{(\w+)\}")

DEFAULT_CHAT_PATH = "/chat/completions"
DEFAULT_MODELS_PATH = "/models"
DEFAULT_SPEECH_PATH = "/audio/speech"


@dataclass
class Endpoint:
    """一次请求实际使用的接入点（把「留空复用主接口」解析完的结果）。"""

    base_url: str
    api_key: str
    model: str
    path: str = ""
    request_template: str = ""
    response_path: str = ""


def pick_path(configured: str, default: str) -> str:
    path = str(configured or "").strip()
    if not path:
        return default
    return path if path.startswith("/") else "/" + path


def render_request(template: str, values: dict[str, Any]) -> Any:
    """按模板拼请求体。

    占位符分两种写法，按所处位置自动判断：
      - 在字符串里（"${text}"）：只替换内容，保留模板自带的引号；
      - 在字符串外（${messages}）：替换成完整的 JSON 片段。
    这样火山那种 ``"text": "${text}"`` 与 AI 那种 ``"messages": ${messages}`` 都能用。
    """

    out: list[str] = []
    in_string = False
    index = 0
    length = len(template)
    while index < length:
        char = template[index]
        if char == "\\" and in_string:
            out.append(template[index : index + 2])
            index += 2
            continue
        if char == '"':
            in_string = not in_string
            out.append(char)
            index += 1
            continue
        if char == "$":
            match = _PLACEHOLDER_RE.match(template, index)
            if match:
                key = match.group(1)
                if key not in values:
                    raise ValueError(f"模板里的 ${{{key}}} 不是可用占位符")
                value = values[key]
                if in_string:
                    # 字符串上下文：只放内容，避免把模板里的引号顶掉
                    out.append(json.dumps(str(value), ensure_ascii=False)[1:-1])
                else:
                    out.append(json.dumps(value, ensure_ascii=False))
                index = match.end()
                continue
        out.append(char)
        index += 1

    rendered = "".join(out)
    try:
        return json.loads(rendered)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"请求体模板不是合法 JSON（{exc.msg}）。注意模板要整体包在 {{}} 里，"
            "占位符写成 ${model} 这种形式。"
        ) from exc


def render_headers(template: str, values: dict[str, Any]) -> dict[str, str]:
    """按模板拼自定义请求头。

    与请求体不同，这里把占位符替换成**纯字符串**（不带引号），
    所以模板要写成 ``{"X-Api-Key": "${api_key}"}`` 这种带引号的形式。
    """

    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in values:
            raise ValueError(f"请求头里的 ${{{key}}} 不是可用占位符")
        return str(values[key])

    rendered = _PLACEHOLDER_RE.sub(replace, template)
    try:
        data = json.loads(rendered)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"自定义请求头不是合法 JSON（{exc.msg}）。"
            '示例：{"X-Api-Key": "${api_key}"}'
        ) from exc
    if not isinstance(data, dict):
        raise ValueError("自定义请求头必须是一个 JSON 对象")
    return {str(k): str(v) for k, v in data.items()}


def dig(data: Any, path: str) -> Any:
    """按 ``a.0.b`` 这样的路径在响应里取值，取不到返回 None。"""
    current = data
    for part in str(path or "").split("."):
        if part == "":
            continue
        if isinstance(current, list):
            if not part.lstrip("-").isdigit():
                return None
            index = int(part)
            if not -len(current) <= index < len(current):
                return None
            current = current[index]
        elif isinstance(current, dict):
            current = current.get(part)
        else:
            return None
        if current is None:
            return None
    return current


def extract_chat_text(response_path: str, data: Any) -> str:
    """从响应里取正文：有自定义路径优先，否则按 OpenAI 的 choices[0].message.content。"""
    if response_path:
        value = dig(data, response_path)
        return str(value if value is not None else "").strip()
    choices = (data or {}).get("choices") or [{}]
    message = choices[0].get("message") or {}
    return str(message.get("content") or "").strip()


def build_chat_body(
    endpoint: Endpoint,
    *,
    messages: list[dict[str, Any]],
    temperature: float,
    max_tokens: int | None = None,
    system: str = "",
    prompt: str = "",
) -> dict[str, Any]:
    """拼请求体：有模板用模板，否则用标准 OpenAI 结构。"""
    if endpoint.request_template:
        values: dict[str, Any] = {
            "model": endpoint.model,
            "messages": messages,
            "temperature": temperature,
            "system": system,
            "prompt": prompt,
        }
        if max_tokens:
            values["max_tokens"] = max_tokens
        return render_request(endpoint.request_template, values)

    body: dict[str, Any] = {
        "model": endpoint.model,
        "messages": messages,
        "temperature": temperature,
    }
    if max_tokens:
        body["max_tokens"] = int(max_tokens)
    return body


def build_speech_body(
    endpoint: Endpoint,
    *,
    text: str,
    voice: str,
    fmt: str,
    instructions: str = "",
    values: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """拼语音请求体：有模板用模板，否则用标准 OpenAI 结构。"""
    if endpoint.request_template:
        payload = dict(values or {})
        payload.update({
            "model": endpoint.model,
            "text": text,
            "input": text,
            "voice": voice,
            "format": fmt,
            "instructions": instructions,
        })
        return render_request(endpoint.request_template, payload)
    body: dict[str, Any] = {
        "model": endpoint.model,
        "input": text,
        "voice": voice or "alloy",
        "response_format": fmt,
    }
    if instructions:
        body["instructions"] = instructions
    return body