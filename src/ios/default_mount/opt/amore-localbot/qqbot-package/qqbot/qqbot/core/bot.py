"""Bot 主控：编排协议后端、事件总线、插件系统，对外提供统一 API。"""

from __future__ import annotations

import asyncio
import json
import random
import time
from collections import deque
from typing import Any

from ..log import get_logger
from ..protocol import create_backend
from .bus import EventBus
from .context import Context
from .events import Event, MessageEvent, parse_event
from .message import MessageLike, normalize_message

log = get_logger("bot")

# 表情包尺寸缓存（file -> (w,h)），避免每次发送都读图
_STICKER_SIZE_CACHE = {}

#: 称呼后面要一并去掉的中英文标点与空白
CALL_SEPARATORS = "，,、:：;；!！?？.。~～ -—…\t\r\n　 "

#: 需要走发送节流的接口（其它接口如 get_msg / 群管理不受影响）
SEND_ACTIONS = {"send_msg", "send_group_msg", "send_private_msg"}


def _message_text(message: Any) -> str:
    """取出消息里的纯文字，用于「相同内容不重复发」判断（没有文字返回空串）。"""
    if isinstance(message, str):
        return message.strip()
    if isinstance(message, (list, tuple)):
        parts: list[str] = []
        for seg in message:
            if not isinstance(seg, dict) or str(seg.get("type")) != "text":
                continue
            data = seg.get("data") or {}
            parts.append(str(data.get("text") or ""))
        return "".join(parts).strip()
    return ""


def strip_call_word(text: str, words: list[str]) -> str | None:
    """若文本以某个称呼开头，返回去掉称呼与紧随标点后的内容；否则返回 None。

    单独抽出来是为了让「AI 对话」与「白话群管」对触发词的判定完全一致——
    否则一边认「小T」、另一边不认，消息就会石沉大海。
    """
    content = (text or "").strip()
    if not content:
        return None
    for word in sorted((w for w in words if w), key=len, reverse=True):
        if content.lower().startswith(word.lower()):
            return content[len(word):].lstrip(CALL_SEPARATORS)
    return None


class Bot:
    def __init__(self, config, bus: EventBus | None = None) -> None:
        self.config = config
        self.bus = bus or EventBus()
        self.self_id: int = 0
        self.backend = create_backend(config, self._handle_raw_event)

        # 群聊知识库：检索全在本机完成，不消耗 token
        from ..knowledge import KnowledgeBase
        from ..memory import MemoryStore
        from ..stickers import StickerStore

        self.kb = KnowledgeBase(config)
        self.stickers = StickerStore(config)
        self.memory = MemoryStore(config)
        #: 临时摘要按会话串行生成，避免同一会话并发写覆盖
        self._summary_locks: dict[str, asyncio.Lock] = {}
        #: 群级「闭嘴」状态：group_id -> 解除时间戳（0 表示要人喊才醒）
        self._silence: dict[int, float] = {}
        #: 闭嘴来源：manual=管理员/面板设置，group=被群管理禁言（群解除时只清后者）
        self._silence_source: dict[int, str] = {}
        self._silence_file = config.paths.silence_file
        self._load_silence()  # 重启后接着上次的闭嘴状态，不会一重启就自动解除

        #: 发送节流状态：会话 -> 锁 / 上次发送时间 / 最近一小时发送时间 / 最近文字
        self._send_locks: dict[str, asyncio.Lock] = {}
        self._send_last: dict[str, float] = {}
        self._send_sent: dict[str, deque] = {}
        self._send_texts: dict[str, dict[str, float]] = {}

        # 延迟导入，插件模块只以 TYPE_CHECKING 引用 Bot，避免循环依赖
        from ..plugins.manager import PluginManager

        self.plugins = PluginManager(self)
        self._running = False
        self.started_at: float = 0.0

    # ---------- 群「闭嘴」状态的持久化 ----------

    def _load_silence(self) -> None:
        """启动时读回上次的闭嘴状态。

        不读回来的话，进程一重启，之前让它闭嘴的群就等于被自动解除了。
        已到期的直接丢弃；until 为 0（无限期闭嘴、等喊醒）必须原样保留。
        """
        try:
            data = json.loads(self._silence_file.read_text("utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if not isinstance(data, dict):
            return
        now = time.time()
        for key, value in data.items():
            try:
                gid, until = int(key), float(value)
            except (TypeError, ValueError):
                continue
            if until and until <= now:
                continue  # 已经到期了，不用恢复
            self._silence[gid] = until
            self._silence_source[gid] = "manual"
        if self._silence:
            log.info("已恢复 %d 个群的闭嘴状态", len(self._silence))

    def _save_silence(self) -> None:
        """把闭嘴状态落盘（原子替换），失败只记日志，不影响主流程。"""
        try:
            self._silence_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._silence_file.with_suffix(".tmp")
            tmp.write_text(
                json.dumps({str(g): u for g, u in self._silence.items()}, ensure_ascii=False),
                encoding="utf-8",
            )
            tmp.replace(self._silence_file)
        except OSError as exc:
            log.warning("保存闭嘴状态失败: %s", exc)

    # ---------- 生命周期 ----------

    async def start(self) -> None:
        if self._running:
            return
        await self.backend.start()
        if self.config.plugins.enabled:
            await self.plugins.load_all()
            if self.config.plugins.watch:
                self.plugins.start_watching()
        self._running = True
        self.started_at = time.time()
        log.info("Bot 已启动（后端=%s，插件=%d）", self.backend.name, len(self.plugins.plugins))

    async def stop(self) -> None:
        if not self._running:
            return
        await self.plugins.shutdown()
        await self.backend.stop()
        client = getattr(self, "_chat_client", None)
        if client is not None:
            await client.close()
            self._chat_client = None
            self._chat_client_key = None
        self._running = False
        log.info("Bot 已停止")

    # ---------- 共享对话客户端 ----------

    def chat_client(self):
        """全局共享的对话客户端（带按会话的上下文记忆）。

        AI 对话 / 自主模式 / 白话群管 原本各建一个实例，各自记一份历史，
        结果同一个群里的上下文被拆成好几段，模型看起来「每次都重置」。
        统一成一个实例后，只要会话键相同，上下文就是连续的。
        """
        from ..ai.client import ChatClient

        cfg = self.config.ai
        # 只按接口与 Key 判断是否需要重建：改模型名不该把对话历史清掉
        key = (cfg.base_url, cfg.api_key)
        client = getattr(self, "_chat_client", None)
        if client is None or getattr(self, "_chat_client_key", None) != key:
            self._chat_client = ChatClient(cfg)
            self._chat_client_key = key
        return self._chat_client

    # ---------- 事件入口 ----------

    async def _handle_raw_event(self, data: dict[str, Any]) -> None:
        event = parse_event(data)
        if event.self_id and not self.self_id:
            self.self_id = event.self_id
        await self.bus.emit(event.kind, event)

    def context(self, event: MessageEvent) -> Context:
        return Context(self, event)

    # ---------- 发送节流（安全模式） ----------

    @staticmethod
    def _send_scope(action: str, params: dict[str, Any]) -> str:
        """返回这条消息所属的会话键；不是发消息接口时返回空串。"""
        if action == "send_group_msg" or (
            action == "send_msg" and str(params.get("message_type")) == "group"
        ):
            group_id = params.get("group_id")
            return f"group_{group_id}" if group_id is not None else ""
        if action == "send_private_msg" or (
            action == "send_msg" and str(params.get("message_type")) == "private"
        ):
            user_id = params.get("user_id")
            return f"user_{user_id}" if user_id is not None else ""
        return ""

    async def _send_guard(self, action: str, params: dict[str, Any],
                          priority: bool = False) -> bool:
        """发消息前的节流：随机延迟、同会话冷却、每小时上限、重复内容去重。

        返回 False 表示这条消息被丢弃（只记日志），调用方按已发送处理即可。
        参数全部来自 config.safety，面板改完立即生效。
        """
        cfg = self.config.safety
        if not getattr(cfg, "enabled", False):
            return True
        scope = self._send_scope(action, params)
        if not scope:
            return True
        try:
            min_delay = max(0.0, float(cfg.min_delay or 0.0))
            max_delay = max(min_delay, float(cfg.max_delay or 0.0))
            cooldown = max(0.0, float(cfg.group_cooldown or 0.0))
            hourly = max(0, int(cfg.hourly_limit or 0))
            dedup = max(0.0, float(cfg.dedup_window or 0.0))
        except (TypeError, ValueError):
            return True

        text = _message_text(params.get("message"))
        now = time.monotonic()
        seen = self._send_texts.get(scope)
        if priority:
            dedup = 0.0  # 失败补偿/兜底回复：不参与去重，确保必达
        # 兜底特征句也豁免去重（保证失败补偿必达，不会因重复被吞）
        if text and dedup > 0 and text.startswith((
                "…你这一下把人家说愣住了", "唔…", "急什么呀…",
                "进来可以…", "水都流到大腿了…", "讨厌…")):
            dedup = 0.0
        if text and dedup > 0 and seen:
            last = seen.get(text)
            if last is not None and now - last < dedup:
                log.warning(
                    "发送节流：[%s] 在 %.0f 秒内发过相同内容，本条已跳过", scope, dedup
                )
                return False

        lock = self._send_locks.get(scope)
        if lock is None:
            lock = asyncio.Lock()
            self._send_locks[scope] = lock
        async with lock:
            now = time.monotonic()
            wait = max(0.0, self._send_last.get(scope, 0.0) + cooldown - now)
            wait += random.uniform(min_delay, max_delay)
            if wait > 0:
                await asyncio.sleep(wait)

            stamps = self._send_sent.get(scope)
            if stamps is None:
                stamps = deque()
                self._send_sent[scope] = stamps
            cutoff = time.monotonic() - 3600
            while stamps and stamps[0] < cutoff:
                stamps.popleft()
            if hourly and len(stamps) >= hourly:
                log.warning(
                    "发送节流：[%s] 一小时内已发 %d 条，达到上限 %d，本条已跳过",
                    scope, len(stamps), hourly,
                )
                return False
            stamps.append(time.monotonic())
            self._send_last[scope] = time.monotonic()

        if text and dedup > 0:
            seen = self._send_texts.setdefault(scope, {})
            seen[text] = time.monotonic()
            if len(seen) > 50:  # 只留最近的一批，避免长时间运行后越攒越多
                oldest = sorted(seen.items(), key=lambda item: item[1])[: len(seen) - 50]
                for key, _ in oldest:
                    seen.pop(key, None)
        return True

    # ---------- 通用 API 调用 ----------

    async def call_api(self, action: str, params: dict[str, Any] | None = None, **kwargs: Any) -> dict[str, Any]:
        merged: dict[str, Any] = {**(params or {}), **kwargs}
        priority = bool(merged.pop("_priority", False))
        if action in SEND_ACTIONS and not await self._send_guard(action, merged, priority=priority):
            return {"status": "skipped", "retcode": 0, "data": None, "message": "发送节流：已跳过"}
        return await self.backend.call_api(action, merged)

    async def send_group_msg(self, group_id: int, message: MessageLike, auto_escape: bool = False) -> dict[str, Any]:
        return await self.call_api(
            "send_group_msg",
            group_id=int(group_id),
            message=normalize_message(message),
            auto_escape=auto_escape,
        )

    async def send_private_msg(self, user_id: int, message: MessageLike) -> dict[str, Any]:
        return await self.call_api(
            "send_private_msg", user_id=int(user_id), message=normalize_message(message)
        )

    async def send_by_event(self, event: MessageEvent, message: MessageLike) -> dict[str, Any]:
        if event.is_group:
            return await self.send_group_msg(event.group_id, message)
        return await self.send_private_msg(event.user_id, message)

    def call_words(self) -> list[str]:
        """机器人的「名字」：AI 触发词 + 白话群管称呼，去重保序。

        两处配置合并使用，避免用户只在其中一处填了名字却触发不了。
        """
        merged: list[str] = []
        for word in list(self.config.ai.triggers or []) + list(
            self.config.admin_nl.call_names or []
        ):
            name = str(word or "").strip()
            if name and name not in merged:
                merged.append(name)
        return merged

    def silence_group(self, group_id: Any, seconds: float = 0, source: str = "manual") -> float:
        """让机器人在某个群闭嘴一段时间（0 表示一直闭嘴，直到有人喊它说话）。

        返回预计解除的时间戳（0 表示无限期）。只影响「闲聊」，管理员指令照常执行，
        否则被关掉之后连唤醒它都做不到。
        """
        gid = int(group_id)
        until = 0.0 if not seconds else time.time() + float(seconds)
        self._silence[gid] = until
        self._silence_source[gid] = "group" if source == "group" else "manual"
        self._save_silence()  # 落盘：重启之后仍然闭嘴，不会一重启就解除
        log.info("群 %s 已闭嘴（%s）", gid, "无限期" if not until else f"{int(seconds)} 秒")
        return until

    def silence_source(self, group_id: Any) -> str:
        """当前闭嘴是由谁触发的：manual / group；没闭嘴返回空串。"""
        gid = int(group_id)
        if gid not in self._silence:
            return ""
        return self._silence_source.get(gid, "manual")

    def wake_group(self, group_id: Any) -> None:
        """解除某个群的闭嘴状态。"""
        gid = int(group_id)
        if self._silence.pop(gid, None) is not None:
            self._silence_source.pop(gid, None)
            self._save_silence()
            log.info("群 %s 已恢复说话", gid)

    def silence_remaining(self, group_id: Any) -> float:
        """还剩多少秒；0 表示没被闭嘴，-1 表示无限期闭嘴。"""
        gid = int(group_id)
        if gid not in self._silence:
            return 0.0
        until = self._silence[gid]
        if not until:
            return -1.0
        left = until - time.time()
        if left <= 0:
            # 到点了就顺手清掉，并把文件里的过期记录一起抹掉（只在过期这一刻写一次）
            self._silence.pop(gid, None)
            self._silence_source.pop(gid, None)
            self._save_silence()
            log.info("群 %s 的闭嘴时间已到，自动恢复说话", gid)
            return 0.0
        return left

    def is_silenced(self, group_id: Any) -> bool:
        return self.silence_remaining(group_id) != 0.0

    def group_ai_enabled(self, group_id: Any) -> bool:
        """置控台里该群的 AI 发言开关；没有单独配置过的群默认开启。"""
        per_group = getattr(getattr(self.config, "console", None), "per_group", None) or {}
        item = per_group.get(str(group_id))
        if isinstance(item, dict):
            return item.get("enabled", True) is not False
        return True

    async def kb_context(self, group_id: Any, query: str) -> str:
        """按群检索知识库，返回可拼进系统提示的参考资料（无命中返回空串）。

        检索在独立线程执行，避免 SQLite 阻塞事件循环；任何异常都只记日志，
        绝不影响正常对话。
        """
        cfg = self.config.knowledge
        if not cfg.enabled or not group_id or not (query or "").strip():
            return ""
        try:
            return await asyncio.to_thread(
                self.kb.context_for, int(group_id), query, cfg.top_k, cfg.max_chars
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("知识库检索失败: %s", exc)
            return ""

    async def memory_context(self, group_id: Any, user_id: Any) -> str:
        """取出当前场景该遵守的长期记忆，返回可拼进系统提示的文本（没有则空串）。

        与知识库不同，记忆不做检索：命中作用域就直接注入，所以必须在存储层
        按字符预算截断，避免长期积累把 token 吃光。
        """
        cfg = self.config.memory
        if not cfg.enabled:
            return ""
        try:
            return await asyncio.to_thread(
                self.memory.context_for, group_id, user_id, cfg.max_chars
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("记忆库读取失败: %s", exc)
            return ""

    async def summary_context(self, session: str) -> str:
        """读取某个会话的临时摘要（L3），用于拼进系统提示。"""
        cfg = self.config.memory
        if not cfg.enabled or not cfg.summary_enabled:
            return ""
        if not str(session or "").strip():
            return ""
        try:
            return await asyncio.to_thread(self.memory.summary, session)
        except Exception as exc:  # noqa: BLE001
            log.warning("临时摘要读取失败: %s", exc)
            return ""

    async def update_summary(self, client, session: str) -> None:
        """把较早的对话压成滚动摘要，随后只保留最近几轮原文。

        摘要生成失败时保持原样，绝不丢历史；成功后才裁剪，避免上下文丢失。
        """
        cfg = self.config.memory
        if not cfg.enabled or not cfg.summary_enabled:
            return
        key = str(session or "").strip()
        if not key:
            return
        lock = self._summary_locks.setdefault(key, asyncio.Lock())
        if lock.locked():
            return
        async with lock:
            try:
                every = max(2, int(cfg.summary_every or 8))
                keep = max(1, int(cfg.summary_keep or 4))
                budget = max(120, int(cfg.summary_max_chars or 500))
            except (TypeError, ValueError):
                every, keep, budget = 8, 4, 500
            # 摘要必须赶在上下文被 max_history 裁掉之前生成
            try:
                max_turns = max(2, int(self.config.ai.max_history or 10))
            except (TypeError, ValueError):
                max_turns = 10
            every = min(every, max_turns)
            keep = min(keep, max(1, every - 1))
            history = client.recent_messages(key, 10000)
            if len(history) // 2 < every:
                return
            older = history[:-keep * 2]
            if len(older) < 2:
                return

            previous = await asyncio.to_thread(self.memory.summary, key)
            lines: list[str] = []
            for item in older:
                role = "对方" if item.get("role") == "user" else "我"
                content = str(item.get("content") or "").strip()
                if content:
                    lines.append(f"{role}：{content[:300]}")
            if not lines:
                return

            budget = max(120, budget)
            system = (
                "你是对话摘要器。把较早的对话压成简洁、可执行的中文摘要，"
                "只保留：人物关系与称呼、明确的约定和偏好、情绪与态度变化、"
                "未完成的事项、重要事实。不要编造，不要写分析过程。"
            )
            prompt = (
                f"已有摘要：\n{previous or '无'}\n\n"
                f"新增对话：\n" + "\n".join(lines) + "\n\n"
                f"请输出更新后的摘要：3-8 条短句，每条一行，不超过 {budget} 字。"
            )
            try:
                summary = await client.complete(
                    system, prompt, max_tokens=max(256, min(1024, budget))
                )
            except Exception as exc:  # noqa: BLE001
                log.warning("生成临时摘要失败: %s", exc)
                return
            summary = str(summary or "").strip()[:budget]
            if not summary:
                return
            try:
                await asyncio.to_thread(self.memory.set_summary, key, summary)
                client.drop_older(key, keep)
                log.info("已更新临时摘要 [%s] %s", key, summary[:40])
            except Exception as exc:  # noqa: BLE001
                log.warning("写入临时摘要失败: %s", exc)

    def sticker_segment(self, tag: str):
        """按情绪标签随机取一张表情包，返回 image 消息段；没有就返回 None。"""
        from .message import image as image_seg

        import random as _random
        candidates = [s for s in self.stickers.list() if tag in (s.get("tags") or [])]
        # 发送池：只发 gif 动图表情包（png / jpg 一律不发）
        def _excluded(s):
            f = str(s.get("file") or "").lower()
            if not f.endswith(".gif"):
                return True
            if f.endswith((".jpg", ".jpeg")):
                try:
                    if self.stickers.path_of(s).stat().st_size > 800 * 1024:
                        return True
                except OSError:
                    return True
            # 长宽比检测：手机截图/长条图不发，只发接近正方形的表情包（0.68~1.47）
            path = self.stickers.path_of(s)
            cached = _STICKER_SIZE_CACHE.get(str(s.get("file") or ""))
            if cached is None:
                try:
                    from PIL import Image
                    with Image.open(path) as im:
                        w, h = im.size
                    cached = (w, h)
                    _STICKER_SIZE_CACHE[str(s.get("file") or "")] = cached
                except Exception:
                    _STICKER_SIZE_CACHE[str(s.get("file") or "")] = cached = (0, 0)
            w, h = cached
            if w <= 0 or h <= 0:
                return True
            ratio = w / h
            return ratio < 0.68 or ratio > 1.47
        candidates = [s for s in candidates if not _excluded(s)]
        if not candidates:
            return None
        item = _random.choice(candidates)
        path = self.stickers.path_of(item)
        if not path.is_file():
            return None
        # QQ 跑在 Docker 容器里，file:// 宿主机路径容器读不到；改发 base64://（OneBot 标准）
        import base64 as _b64
        data = _b64.b64encode(path.read_bytes()).decode()
        return image_seg(f"base64://{data}")

    async def voice_segment(self, text: str):
        """把文本合成语音，返回 record 消息段；未启用或失败返回 None。

        速度优化：
          1. 文本级缓存（LRU 32）：AI 常说重复的短句，命中直接复用，零合成耗时
          2. wav → ogg/opus 转码：体积缩到 1/15（129KB → 8.5KB），base64 传输快得多
          3. 转码失败自动回退原始 wav，不影响发送
        """
        from .message import record as record_seg

        cfg = self.config.tts
        text = (text or "").strip()
        if not cfg.enabled or not text:
            return None

        import base64 as _b64
        cache = getattr(self, "_voice_cache", None)
        if cache is None:
            cache = self._voice_cache = {}
        key = f"{cfg.voice}|{text}"
        if key in cache:
            return record_seg("base64://" + cache[key])

        try:
            from ..ai.tts import synthesize

            data, fmt = await synthesize(cfg, self.config.ai, text)
            # wav → ogg（体积 1/15，QQ 直接可播）
            if fmt.lower().lstrip(".") in ("wav", "wave", "pcm"):
                try:
                    import asyncio as _aio
                    import tempfile as _tf
                    from pathlib import Path as _P

                    def _to_ogg(raw: bytes) -> bytes:
                        with _tf.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                            f.write(raw)
                            src = f.name
                        dst = src + ".ogg"
                        try:
                            import subprocess as _sp
                            _sp.run(
                                ["ffmpeg", "-y", "-loglevel", "error", "-i", src,
                                 "-c:a", "libopus", "-b:a", "16k",
                                 "-application", "voip",
                                 "-ar", "24000", "-ac", "1", dst],
                                check=True, timeout=15)
                            return _P(dst).read_bytes()
                        finally:
                            for pth in (src, dst):
                                try:
                                    _P(pth).unlink()
                                except OSError:
                                    pass

                    ogg = await _aio.to_thread(_to_ogg, data)
                    if ogg:
                        data, fmt = ogg, "ogg"
                except Exception as exc:  # noqa: BLE001
                    log.debug("语音转 ogg 失败，用原始格式: %s", exc)

            b64 = _b64.b64encode(data).decode()
            # LRU：最多 32 条
            if len(cache) >= 32:
                cache.pop(next(iter(cache)))
            cache[key] = b64
            return record_seg("base64://" + b64)
        except Exception as exc:  # noqa: BLE001
            log.warning("语音合成失败，回退文字: %s", exc)
            return None

    # ---------- 常用便捷方法 ----------

    async def delete_msg(self, message_id: Any) -> dict[str, Any]:
        return await self.call_api("delete_msg", message_id=message_id)

    async def get_group_list(self) -> dict[str, Any]:
        return await self.call_api("get_group_list")

    async def get_friend_list(self) -> dict[str, Any]:
        return await self.call_api("get_friend_list")

    async def set_group_ban(self, group_id: int, user_id: int, duration: int = 60) -> dict[str, Any]:
        return await self.call_api(
            "set_group_ban", group_id=int(group_id), user_id=int(user_id), duration=duration
        )

    # ---------- 状态 ----------

    @property
    def running(self) -> bool:
        return self._running

    @property
    def uptime(self) -> float:
        return time.time() - self.started_at if self.started_at else 0.0

    def status(self) -> dict[str, Any]:
        return {
            "running": self._running,
            "backend": self.backend.name,
            "connected": self.backend.connected,
            "self_id": self.self_id,
            "uptime": round(self.uptime, 1),
            "plugins": self.plugins.summary(),
        }


__all__ = ["Bot", "Event", "MessageEvent"]