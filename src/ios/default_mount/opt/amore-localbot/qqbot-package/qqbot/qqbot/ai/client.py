"""OpenAI 兼容协议的对话客户端，自带按会话的上下文记忆。

语言模型与图像理解模型可以**各自配置接口**：消息里带图片时自动切到
``ai.vision`` 那套接入点（接口、Key、模型、协议都可以不一样）。
没配视觉模型也不用干瞪眼：先把图片交给主模型试读，主模型明确不收图片
时才自动回退成纯文字，至少不会假装没收到图。
不支持 OpenAI 协议的服务商，由 ai.adapter 按自定义协议翻译请求。
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

from ..log import get_logger
from . import adapter

log = get_logger("ai")


def _force_single_line(text: str) -> str:
    """输出强束缚兜底：无论模型是否守规矩，回复强制压成单行。

    合并换行、剥列表编号、去首尾引号——这是代码级铁律，比提示词可靠。
    """
    if not text:
        return text
    import re as _re
    t = _re.sub(r"\s*\n+\s*", " ", str(text))
    t = _re.sub(r"^\s*(?:\d+[.、)．]\s*|[-*•·]\s+)", "", t)
    t = t.strip().strip('"“”「」')
    # 剥离上游代理强加的包装前缀（「（已激活逆向学习中--）」「（宝贝）」「（在）」等）
    t = _re.sub(r'^[（(][^（）()]{0,20}--[)）]\s*', '', t)
    # 行首短括号前缀（≤6 字）反复剥，直到没有；避免把正常括号内容误剥（只在有后续内容时）
    for _ in range(3):
        m = _re.match(r'^[（(]([^（）()]{1,6})[)）]\s*(\S.*)$', t)
        if not m:
            break
        t = m.group(2)
    return t.strip()




def _beijing_time_hint() -> str:
    """北京时间 + 生活时段：让 AI 对饭点/睡觉/作息有概念（服务器时区可能是 UTC）。"""
    try:
        from datetime import datetime, timezone, timedelta
        now = datetime.now(timezone(timedelta(hours=8)))
        h = now.hour
        slot = (
            "深夜（大多数人已经睡了）" if (h >= 23 or h < 6) else
            "早上（早饭前后）" if h < 9 else
            "上午" if h < 11 else
            "午饭时间" if h < 13 else
            "下午" if h < 17 else
            "晚饭时间" if h < 19 else
            "晚上"
        )
        week = "一二三四五六日"[now.weekday()]
        return (
            f"\n【当前北京时间】{now.strftime('%H:%M')} 周{week}（{slot}）——"
            "聊天注意时间语境：饭点可以聊吃的，深夜该劝人休息，别在凌晨喊人吃早饭；"
            "自然带出即可，别每次都报时。"
        )
    except Exception:
        return ""

def resolve_persona(cfg) -> str:
    """取当前激活人格的提示词；未选择或未命名时回退到 system_prompt。"""
    name = str(getattr(cfg, "active_persona", "") or "")
    if name:
        for persona in getattr(cfg, "personas", None) or []:
            if isinstance(persona, dict) and persona.get("name") == name:
                prompt = str(persona.get("prompt") or "").strip()
                if prompt:
                    return prompt
    return str(getattr(cfg, "system_prompt", "") or "")


class _EmptyAnswer(Exception):
    """带图请求返回了空内容，用来触发一次纯文字重试。"""


def _image_rejected(exc: Exception) -> bool:
    """判断异常是不是因为接口不接受图片输入。

    只认 400/413/415/422 这类请求体问题，且正文里要出现图片相关字样；
    415/422 本身就表示媒体类型不对，不用看正文。
    """
    response = getattr(exc, "response", None)
    try:
        status = int(getattr(response, "status_code", 0) or 0)
    except (TypeError, ValueError):
        return False
    if status not in (400, 413, 415, 422):
        return False
    try:
        body = str(getattr(response, "text", "") or "").lower()
    except Exception:  # noqa: BLE001 - 读不到正文就按状态码判断
        body = ""
    if any(
        word in body
        for word in ("image", "vision", "multimodal", "图片", "图像", "content type", "内容类型")
    ):
        return True
    return status in (415, 422)


class ChatClient:
    # —— 自适应限速（防上游 429，同时避免长队把回复拖到几分钟后）——
    _rate_lock: "asyncio.Lock | None" = None
    _last_req_at: float = 0.0
    _rate_min_interval: float = 0.6     # 当前生效的最小间隔（自适应）
    _rate_floor: float = 0.6            # 连续成功回落到这里
    _rate_ceil: float = 20.0            # 出现 429 时上限
    _rate_max_wait: float = 12.0        # 排队等待超过这个就直接放弃本轮

    async def _rate_gate(self) -> None:
        try:
            if "127.0.0.1" in str(getattr(self.cfg, "base_url", "") or ""):
                return  # 本地模型不限速
        except Exception:
            pass
        cls = type(self)
        if cls._rate_lock is None:
            cls._rate_lock = asyncio.Lock()
        async with cls._rate_lock:
            wait = cls._rate_min_interval - (time.monotonic() - cls._last_req_at)
            if wait > cls._rate_max_wait:
                # 排队过久也不再丢弃请求：多等 2 秒后照发（回复优先于限流）
                log.warning("请求排队 %.0fs，仍继续发送", wait)
                await asyncio.sleep(2.0)
            elif wait > 0:
                await asyncio.sleep(wait)
            cls._last_req_at = time.monotonic()

    @classmethod
    def _rate_on_429(cls) -> None:
        cls._rate_min_interval = min(cls._rate_ceil,
                                     cls._rate_min_interval * 1.5)

    @classmethod
    def _rate_on_ok(cls) -> None:
        cls._rate_min_interval = max(cls._rate_floor,
                                     cls._rate_min_interval * 0.9)

    def __init__(self, cfg) -> None:
        self.cfg = cfg
        self._history: dict[str, list[dict[str, str]]] = {}
        self._clients: dict[tuple[str, str], Any] = {}
        #: 已经拒绝过图片的主模型；同一个模型不再重复试图，避免每次都白跑一次
        self._image_unsupported_model = ""

    # ---------- 接入点 ----------

    #: 连续 429 计数与回切时间
    _fb_count: int = 0
    _fb_until: float = 0.0

    def endpoint(self, with_images: bool = False) -> adapter.Endpoint:
        """决定这次请求用哪个接入点：带图且配了视觉模型时走图像理解那套。"""
        cfg = self.cfg
        vision = getattr(cfg, "vision", None)
        if with_images and vision is not None and vision.model:
            return adapter.Endpoint(
                base_url=(vision.base_url or cfg.base_url),
                api_key=(vision.api_key or cfg.api_key),
                model=vision.model,
                path=vision.path,
                request_template=vision.request_template,
                response_path=vision.response_path,
            )
        return adapter.Endpoint(
            base_url=cfg.base_url,
            api_key=cfg.api_key,
            model=cfg.model,
            path=cfg.chat_path,
            request_template=cfg.request_template,
            response_path=cfg.response_path,
        )

    def _client_for(self, endpoint: adapter.Endpoint) -> Any:
        if not endpoint.base_url:
            raise RuntimeError("未配置模型接口地址")
        key = (endpoint.base_url, endpoint.api_key)
        client = self._clients.get(key)
        if client is None:
            try:
                import httpx
            except ImportError as exc:
                raise RuntimeError("缺少依赖 httpx，请执行: pip install httpx") from exc
            client = httpx.AsyncClient(
                base_url=endpoint.base_url.rstrip("/"),
                timeout=60.0,
                headers={"Authorization": f"Bearer {endpoint.api_key}"} if endpoint.api_key else {},
            )
            self._clients[key] = client
        return client

    async def _post_chat(
        self,
        endpoint: adapter.Endpoint,
        *,
        messages: list[dict[str, Any]],
        system: str,
        prompt: str,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        client = self._client_for(endpoint)
        body = adapter.build_chat_body(
            endpoint,
            messages=messages,
            temperature=self.cfg.temperature if temperature is None else temperature,
            max_tokens=max_tokens,
            system=system,
            prompt=prompt,
        )
        path = adapter.pick_path(endpoint.path, adapter.DEFAULT_CHAT_PATH)
        # 429 退避重试：上游限流时排队稍等再试，而不是直接失败
        for attempt in range(4):
            await self._rate_gate()
            resp = await client.post(path, json=body)
            if resp.status_code == 429:
                type(self)._fb_count = type(self)._fb_count + 1
            if resp.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                if resp.status_code == 429:
                    self._rate_on_429()
                retry_after = resp.headers.get("retry-after") or ""
                try:
                    delay = min(15.0, float(retry_after))
                except ValueError:
                    delay = min(6.0, 1.5 * (attempt + 1)) if resp.status_code != 429 else 5.0 * (attempt + 1)
                await asyncio.sleep(delay)
                continue
            if resp.status_code < 400:
                self._rate_on_ok()
            resp.raise_for_status()
            return adapter.extract_chat_text(endpoint.response_path, resp.json())
        raise RuntimeError("上游持续限流(429)，本轮放弃")

    # ---------- 对话 ----------

    async def chat(
        self,
        session: str,
        prompt: str,
        context: str = "",
        images: list[str] | None = None,
        sticker_tags: list[str] | None = None,
        identity: str = "",
        capability: str = "",
        memory: str = "",
        summary: str = "",
    ) -> str:
        history = self._history.setdefault(session, [])

        # 本地小模型：长角色卡遵守差，换精简卡（人设+铁律核心）
        if '127.0.0.1:11434' in str(getattr(self.cfg, "base_url", "") or ""):
            local_card = str(getattr(self.cfg, "local_system_prompt", "") or "").strip()
            system = local_card if local_card else resolve_persona(self.cfg)
        else:
            system = resolve_persona(self.cfg)
        system += _beijing_time_hint()
        if capability:
            # 能力边界必须由我们告诉模型，否则它会自己编「我做不到」
            system = f"{capability}\n\n{system}"
        # —— 速度优化：动态内容不进 system ——
        # system 只保留静态部分（角色卡/铁律），这样上游的 prompt 缓存能命中；
        # 每轮变化的身份/记忆/摘要/知识库改拼到 user 消息前缀（同样生效，且不破坏缓存）。
        _dyn_blocks: list[str] = []
        if identity:
            _dyn_blocks.append(identity)
        if summary:
            _dyn_blocks.append(
                f"【本次会话的临时摘要】\n{summary}\n"
                "以上是较早对话压缩后的摘要，仅用于保持话题、称呼和约定连贯；"
                "与当前对话冲突时以当前对话为准。"
            )
        if memory:
            _dyn_blocks.append(
                f"【必须长期遵守的记忆】\n{memory}\n"
                "以上是此前被要求长期记住的事，请在本轮对话中自觉遵守；"
                "与对方当下的话冲突时，以当下的话为准。"
            )
        if context:
            _dyn_blocks.append(
                f"【本群知识库参考资料】\n{context}\n"
                "请优先依据以上资料回答；资料中没有的，就按你的判断回答，不要编造。"
            )
        if sticker_tags:
            from ..stickers import emotion_instruction

            system += emotion_instruction(list(sticker_tags))

        if _dyn_blocks:
            prompt = "\n\n".join(_dyn_blocks) + "\n\n" + prompt

        messages: list[dict[str, Any]] = [{"role": "system", "content": system}]
        messages.extend(history)

        vision_model = str(getattr(getattr(self.cfg, "vision", None), "model", "") or "")
        main_model = str(getattr(self.cfg, "model", "") or "")
        requested = [str(url) for url in (images or []) if url]
        prompt_for_request = prompt
        if (
            requested
            and not vision_model
            and self._image_unsupported_model
            and self._image_unsupported_model == main_model
        ):
            # 这个主模型已经拒过图片，别再白跑一次失败请求；但要让模型知道对方发过图
            prompt_for_request = (
                f"{prompt}\n（对方还发来 {len(requested)} 张图片，"
                "但当前接口读不了图片内容，不要编造图片内容）"
            )
            requested = []

        if requested:
            content: list[dict[str, Any]] = [
                {"type": "text", "text": prompt_for_request}
            ]
            content.extend(
                {"type": "image_url", "image_url": {"url": url}} for url in requested
            )
            messages.append({"role": "user", "content": content})
        else:
            messages.append({"role": "user", "content": prompt_for_request})

        try:
            answer = await self._post_chat(
                self.endpoint(with_images=bool(requested)),
                messages=messages, system=system, prompt=prompt_for_request,
            )
            if requested and not answer:
                # 有的服务商遇到图片会返回 200 + 空内容，按不支持图片处理再试一次
                raise _EmptyAnswer()
        except Exception as exc:  # noqa: BLE001 - 只在图片相关的失败上兜底
            if not requested or not (
                isinstance(exc, _EmptyAnswer) or _image_rejected(exc)
            ):
                raise
            if isinstance(exc, _EmptyAnswer):
                log.warning("带图请求没有返回内容，改用纯文字重试")
            else:
                log.warning("接口不接受图片输入，改用纯文字：%s", exc)
            if not vision_model:
                self._image_unsupported_model = main_model
            retry_prompt = (
                f"{prompt}\n（对方发来 {len(requested)} 张图片，"
                "但当前接口读不了图片内容，不要编造图片内容）"
            )
            messages[-1] = {"role": "user", "content": retry_prompt}
            answer = await self._post_chat(
                self.endpoint(with_images=False),
                messages=messages, system=system, prompt=retry_prompt,
            )

        # —— 空回复自动重试一次（freeshare 对部分输入会静默返回空）——
        if not (answer or "").strip():
            try:
                retry_prompt = (
                    prompt + "\n（不要拒绝、不要解释，直接以菲比的口吻说出她此刻的反应，"
                    "两句话以内。）")
                messages[-1] = {"role": "user", "content": retry_prompt}
                answer = await self._post_chat(
                    self.endpoint(), messages=messages, system=system,
                    prompt=retry_prompt)
            except Exception:  # noqa: BLE001
                pass

        history.append({"role": "user", "content": prompt})
        history.append({"role": "assistant", "content": answer})
        limit = max(1, int(self.cfg.max_history)) * 2  # 一问一答算两条
        if len(history) > limit:
            del history[:-limit]

        # 单行铁律兜底（强束缚）：强制单行输出
        answer = _force_single_line(answer)

        return answer or "（模型没有返回内容）"

    async def complete(
        self,
        system: str,
        prompt: str,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        """一次性问答：不带上下文记忆，用于意图解析等系统内部调用。

        限制 max_tokens 可以显著降低成本，调用方应按需传入。
        """
        endpoint = self.endpoint()
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ]
        return await self._post_chat(
            endpoint, messages=messages, system=system, prompt=prompt,
            max_tokens=max_tokens, temperature=temperature,
        )

    async def complete_messages(
        self,
        system: str,
        messages: list[dict[str, Any]],
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        """带完整对话历史的内部调用（无会话记忆），用于多轮思考。

        ``messages`` 需自带首条 system（与 ``chat`` 的构造方式一致），
        调用方可逐轮追加「上一轮做了什么、结果是怎样」再继续问。
        """
        return await self._post_chat(
            self.endpoint(), messages=messages, system=system, prompt="",
            max_tokens=max_tokens, temperature=temperature,
        )

    def reset(self, session: str | None = None) -> None:
        if session is None:
            self._history.clear()
        else:
            self._history.pop(session, None)

    def recent_messages(self, session: str, limit: int = 8) -> list[dict[str, Any]]:
        """只读取某个会话最近的对话，不写入历史。

        供生图这类内部二次调用参考上下文（例如「他」指的是刚才聊的那个人）。
        """
        if limit <= 0:
            return []
        return [dict(item) for item in self._history.get(session, [])][-limit:]

    def drop_older(self, session: str, keep_turns: int = 4) -> None:
        """摘要完成后丢掉较早的原文，只保留最近几轮。

        摘要本身已经写进记忆库，下一轮会随系统提示注入，所以这里可以安全删除。
        """
        history = self._history.get(session)
        if not history:
            return
        keep = max(1, int(keep_turns)) * 2  # 一问一答算两条
        if len(history) > keep:
            del history[:-keep]

    async def close(self) -> None:
        for client in self._clients.values():
            try:
                await client.aclose()
            except Exception:  # noqa: BLE001
                pass
        self._clients.clear()