"""模型仓库拉取与可用性探测。

设计目标是最小化 token 消耗：
  - 拉取列表走 ``GET /models``，**不消耗任何 token**；
  - 逐个探测走 ``POST /chat/completions`` 且 ``max_tokens=1``，
    单模型通常只消耗 2~3 个 token，用来真实判断模型能否对话。

判定规则（按要求）：任何超时、网络异常、非 2xx 响应一律视为**不可用**。
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

from ..log import get_logger
from . import adapter

log = get_logger("ai.probe")

#: 并发探测上限，避免一次打爆上游限流
DEFAULT_CONCURRENCY = 6
#: 探测用的极简提示词，token 消耗最小
PROBE_PROMPT = "hi"


def _headers(api_key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}"} if api_key else {}


async def fetch_models(
    base_url: str, api_key: str, timeout_ms: int = 5000, path: str = ""
) -> list[str]:
    """从模型列表接口拉取模型 id（不消耗 token）。

    兼容两种返回：``{"data": [{"id": ...}]}`` 与裸列表 ``[...]``。
    """
    import httpx

    if not base_url:
        raise ValueError("请先填写接口地址")
    timeout = httpx.Timeout(max(0.2, timeout_ms / 1000))
    target = base_url.rstrip("/") + adapter.pick_path(path, adapter.DEFAULT_MODELS_PATH)
    async with httpx.AsyncClient(timeout=timeout, headers=_headers(api_key)) as client:
        resp = await client.get(target)
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()

    items = data.get("data") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise RuntimeError("接口返回格式无法识别")

    models: list[str] = []
    for item in items:
        if isinstance(item, dict):
            name = item.get("id") or item.get("name") or item.get("model")
        else:
            name = item
        if name:
            models.append(str(name))
    return sorted(set(models))


async def probe_model(
    base_url: str,
    api_key: str,
    model: str,
    timeout_ms: int = 5000,
    path: str = "",
) -> dict[str, Any]:
    """对单个模型发一次最小请求，返回 {ok, latency_ms, error}。"""
    import httpx

    timeout = httpx.Timeout(max(0.2, timeout_ms / 1000))
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": PROBE_PROMPT}],
        "max_tokens": 1,
        "stream": False,
    }
    target = base_url.rstrip("/") + adapter.pick_path(path, adapter.DEFAULT_CHAT_PATH)
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(
            timeout=timeout, headers=_headers(api_key)
        ) as client:
            resp = await client.post(target, json=payload)
    except httpx.TimeoutException:
        return {"ok": False, "latency_ms": None, "error": f"超时（>{timeout_ms}ms）"}
    except httpx.HTTPError as exc:
        return {"ok": False, "latency_ms": None, "error": f"网络错误: {exc.__class__.__name__}"}

    latency = int((time.perf_counter() - started) * 1000)
    if resp.status_code >= 400:
        return {"ok": False, "latency_ms": latency, "error": f"HTTP {resp.status_code}: {resp.text[:160]}"}
    return {"ok": True, "latency_ms": latency, "error": ""}


async def probe_models(
    base_url: str,
    api_key: str,
    models: list[str],
    timeout_ms: int = 5000,
    concurrency: int = DEFAULT_CONCURRENCY,
    path: str = "",
) -> dict[str, dict[str, Any]]:
    """并发探测多个模型，返回 {model: 探测结果}。"""
    semaphore = asyncio.Semaphore(max(1, concurrency))
    results: dict[str, dict[str, Any]] = {}

    async def run(model: str) -> None:
        async with semaphore:
            results[model] = await probe_model(base_url, api_key, model, timeout_ms, path)

    await asyncio.gather(*(run(model) for model in models))
    available = sum(1 for r in results.values() if r.get("ok"))
    log.info("模型探测完成：可用 %d / 共 %d", available, len(results))
    return results