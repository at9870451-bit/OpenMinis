"""自主模式插件：被戳一戳 / 被 @ / 命中关键词 / 任意消息按概率，主动思考并回复。

与「AI 对话」插件的分工：
  - 显式触发前缀（config.ai.triggers，如 #ai）永远归 AI 对话插件处理，
    本插件遇到前缀开头的消息会直接放行，避免同一条消息被回复两次。
  - 私聊也归 AI 对话插件处理，本插件只负责群聊里的 @ / 关键词 / 戳一戳。
  - 本插件优先级高于 AI 对话插件，处理完会 STOP，确保不会重复回复。

随机接话规则：
  - 按概率抽中某条群消息后才会接；
  - 如果这条消息 @ 的是别人而不是机器人，直接放弃，不接；
  - 接了就直接说实际内容，不要旁白、不要解释自己有没有插嘴。

回复方式由 config.auto_mode.reply_mode 决定：
  quote=引用该条消息回复 / direct=直接回复（旧配置里的 mention 也按直接回复处理，不再 @ 人）
"""

from __future__ import annotations

import random
import time
from collections import deque
from typing import Any

from ...core.message import Message, at as at_seg, text as text_seg
from ..base import Plugin

#: 戳一戳在不同协议实现里的 notice_type / sub_type 组合
POKE_TYPES = {"poke"}

#: 短应答最多缓存多少条群消息（够用即可，避免长时间占用内存）
MAX_RECENT = 40




class _PokeCtx:
    """给 style_hooks 用的最小 ctx：只带 user_id / group_id / is_group。"""

    def __init__(self, group_id, user_id):
        self.group_id = group_id
        self.user_id = user_id
        self.is_group = bool(group_id)

class AutoModePlugin(Plugin):
    name = "auto"
    display_name = "自主模式"
    version = "0.1.0"
    description = "自主模式：被戳/@/命中关键词时主动思考并回复"
    priority = 40  # 小于 AI 对话插件（50），先于它处理

    def __init__(self, bot) -> None:
        super().__init__(bot)
        #: 每个会话最近说过的话（短应答用），只存说话人、昵称和正文
        self._recent: dict[str, deque] = {}
        #: 触发后的持续状态：会话 -> {"user_id": 触发者, "left": 还能再接几条}
        self._follow: dict[str, dict[str, int]] = {}
        #: 每个群上一次主动接话的时间（束缚用）
        self._last_auto: dict[str, float] = {}
        #: 每个群本小时已经主动接话的次数
        self._hour_count: dict[str, dict[str, int]] = {}

    # ---------- 生命周期 ----------

    async def on_load(self) -> None:
        mode = self.bot.config.auto_mode
        if mode.enabled:
            self.log.info(
                "自主模式已启用（回复方式=%s，任意消息概率=%s，冷却=%ss，上限=%s/时，连聊尾=%s）",
                mode.reply_mode, mode.any_probability if mode.on_any else "关闭",
                getattr(mode, "cooldown_seconds", 45),
                getattr(mode, "hourly_limit", 12),
                getattr(mode, "short_reply_after", 0),
            )
        else:
            self.log.info("自主模式未启用（config.auto_mode.enabled=false）")

    async def on_unload(self) -> None:
        # 客户端由 Bot 共享持有，这里不关（否则会打断其它插件的会话）
        pass

    # ---------- 运行期开关 ----------

    @property
    def _active(self) -> bool:
        """运行期实时判断，面板改配置后无需重启即可生效。"""
        return bool(self.bot.config.auto_mode.enabled and self.bot.config.ai.enabled)

    def _get_client(self):
        """用 Bot 上共享的客户端：与 AI 对话 / 白话群管共用同一份上下文。"""
        return self.bot.chat_client()

    @staticmethod
    def _session(ctx) -> str:
        from ._ai_reply import session_key

        return session_key(ctx)

    # ---------- 触发判定 ----------

    def _has_trigger_prefix(self, text: str) -> bool:
        content = text.strip()
        return any(t and content.startswith(t) for t in (self.bot.config.ai.triggers or []))

    def _is_at_me(self, ctx) -> bool:
        if not self.bot.self_id:
            return False
        target = str(self.bot.self_id)
        for seg in ctx.message:
            if getattr(seg, "type", "") == "at" and str(seg.data.get("qq")) == target:
                return True
        return False

    def _keyword_list(self) -> list[str]:
        """关键词统一成列表。

        历史配置里 auto_mode.keywords 是「逗号分隔的字符串」，
        直接遍历会变成逐字匹配（「死」「有」「你」都成触发词），必须拆分；
        同时丢弃长度 <2 的碎片——单字关键词几乎必然误触发。
        """
        raw = self.bot.config.auto_mode.keywords or []
        if isinstance(raw, str):
            chunks = (raw.replace("，", ",").replace("、", ",")
                         .replace("；", ",").replace("|", ",")
                         .replace("\n", ","))
            items = chunks.split(",")
        else:
            items = [str(x) for x in raw]
        out: list[str] = []
        for item in items:
            word = item.strip()
            if len(word) >= 2 and word not in out:
                out.append(word)
        return out

    def _matched_keyword(self, text: str) -> bool:
        if not text:
            return False
        return any(k in text for k in self._keyword_list())

    def _hit_any(self) -> bool:
        """任意消息抽签：按配置概率决定要不要接这句话。"""
        mode = self.bot.config.auto_mode
        if not getattr(mode, "on_any", False):
            return False
        try:
            prob = float(getattr(mode, "any_probability", 0.0) or 0.0)
        except (TypeError, ValueError):
            prob = 0.0
        prob = max(0.0, min(1.0, prob))
        return prob >= 1.0 or (prob > 0 and random.random() < prob)

    def _always_chat(self, gid: str) -> bool:
        try:
            mode = self.bot.config.auto_mode
            lst = str(getattr(mode, "always_chat_groups", "") or "")
            return str(gid) in [x.strip() for x in lst.split(",") if x.strip()]
        except Exception:
            return False

    def _fam_mult(self, uid: int, gid: str = "") -> float:
        """好感系数：familiarity 0~100 → min~max 倍率；低于门槛返回 0。"""
        mode = self.bot.config.auto_mode
        try:
            lo = float(getattr(mode, "random_reply_min_mult", 0.5))
            hi = float(getattr(mode, "random_reply_max_mult", 1.6))
            floor = int(getattr(mode, "random_reply_min_fam", 15) or 0)
        except (TypeError, ValueError):
            lo, hi, floor = 0.5, 1.6, 15
        fam = 0
        try:
            pe = getattr(self.bot, "persona_engine", None)
            if pe is not None and getattr(pe, "_conn", None) is not None:
                from persona_engine import store as _store
                m = _store.get_member(pe._conn, uid)
                fam = int(float(m.get("familiarity", 0) or 0))
        except Exception:
            fam = 0
        if floor and fam < floor:
            # 「一直聊」白名单群不看好感：陌生群友也要有人搭腔
            if gid and self._always_chat(str(gid)):
                return 1.0
            return 0.0
        fam = max(0, min(100, fam))
        return lo + (hi - lo) * (fam / 100.0)

    def _restraint_ok(self, gid: str) -> bool:
        """主动接话的束缚闸：同群冷却 + 每小时上限（@ / 戳一戳不受限）。"""
        if self._always_chat(gid):
            return True  # 「一直聊」群：无冷却无上限
        mode = self.bot.config.auto_mode
        try:
            cd = max(0, int(getattr(mode, "cooldown_seconds", 45) or 0))
        except (TypeError, ValueError):
            cd = 45
        try:
            cap = max(0, int(getattr(mode, "hourly_limit", 12) or 0))
        except (TypeError, ValueError):
            cap = 12
        now = time.time()
        last = self._last_auto.get(gid, 0.0)
        if cd and (now - last) < cd:
            self.log.debug("自主模式冷却中：%s 还需 %.0fs", gid, cd - (now - last))
            return False
        hour = int(now // 3600)
        bucket = self._hour_count.get(gid) or {"hour": hour, "n": 0}
        if int(bucket.get("hour", hour)) != hour:
            bucket = {"hour": hour, "n": 0}
        if cap and int(bucket.get("n", 0)) >= cap:
            self.log.info("自主模式触发小时上限：%s 已达 %d 条", gid, cap)
            self._hour_count[gid] = bucket
            return False
        bucket["n"] = int(bucket.get("n", 0)) + 1
        self._hour_count[gid] = bucket
        self._last_auto[gid] = now
        return True

    # ---------- 短应答 ----------

    def _short_conf(self) -> tuple[bool, int, int, str]:
        """读取短应答配置，返回 (是否开启, 前几条, 后几条, 范围)。"""
        mode = self.bot.config.auto_mode
        enabled = bool(getattr(mode, "short_reply_enabled", False))
        before = max(0, min(20, int(getattr(mode, "short_reply_before", 0) or 0)))
        after = max(0, min(20, int(getattr(mode, "short_reply_after", 0) or 0)))
        scope = "all" if str(getattr(mode, "short_reply_scope", "trigger")).lower() == "all" else "trigger"
        return enabled, before, after, scope

    def _recent_of(self, session: str) -> deque:
        buffer = self._recent.get(session)
        if buffer is None:
            buffer = deque(maxlen=MAX_RECENT)
            self._recent[session] = buffer
        return buffer

    @staticmethod
    def _sender_name(ctx) -> str:
        sender = getattr(ctx.event, "sender", {}) or {}
        return str(
            sender.get("card") or sender.get("nickname") or getattr(ctx.event, "user_id", "") or ""
        )

    def _remember(self, session: str, ctx, content: str) -> None:
        self._recent_of(session).append(
            {
                "user_id": int(ctx.user_id or 0),
                "name": self._sender_name(ctx),
                "text": content,
            }
        )

    def _history_text(self, session: str, user_id: int) -> str:
        """触发前（或持续应答前）最近几条群消息，拼成一段给模型看的历史。"""
        enabled, before, _, scope = self._short_conf()
        if not enabled or before <= 0:
            return ""
        items = list(self._recent_of(session))
        if scope == "trigger":
            items = [item for item in items if item["user_id"] == int(user_id or 0)]
        items = items[-before:]
        if not items:
            return ""
        lines = [f"{item['name'] or item['user_id']}：{item['text']}" for item in items]
        return (
            "【最近的群聊记录（按时间顺序，供你理解上下文）】\n"
            + "\n".join(lines)
            + "\n以上只是背景，别复述这些记录，直接接对方现在说的话。"
        )

    def _follow_hit(self, session: str, user_id: int) -> bool:
        """这条消息是否落在「触发后继续应答」的窗口内。"""
        enabled, _, after, scope = self._short_conf()
        if not enabled or after <= 0:
            return False
        state = self._follow.get(session)
        if not state or int(state.get("left", 0)) <= 0:
            return False
        # 全体范围：不分人，任何人都算；触发者范围：只认触发者本人
        return scope == "all" or int(state.get("user_id", 0)) == int(user_id or 0)

    def _open_follow(self, session: str, user_id: int) -> None:
        enabled, _, after, _ = self._short_conf()
        if enabled and after > 0:
            self._follow[session] = {"user_id": int(user_id or 0), "left": after}
        else:
            self._follow.pop(session, None)

    def _consume_follow(self, session: str) -> None:
        state = self._follow.get(session)
        if not state:
            return
        state["left"] = max(0, int(state.get("left", 0)) - 1)
        if state["left"] <= 0:
            self._follow.pop(session, None)

    # ---------- 回复 ----------


    async def _reply_poke(self, event, answer: str) -> None:
        """戳一戳回复：回一句文字并 @ 戳他的人（群聊），明确回戳对象。"""
        user_id = int(event.get("user_id") or 0)
        group_id = event.get("group_id")
        if group_id:
            chain = Message()
            # 明确回戳对方：@ 戳他的人（绝不 @ 自己）
            if user_id and (not self.bot.self_id or user_id != int(self.bot.self_id)):
                chain.append(at_seg(user_id))
                chain.append(text_seg(" "))
            chain.append(text_seg(answer))
            await self.bot.send_group_msg(int(group_id), chain)
        elif user_id:
            await self.bot.send_private_msg(user_id, answer)

    # ---------- 事件处理 ----------

    async def on_notice(self, event) -> Any:
        if not self._active or not self.bot.config.auto_mode.on_poke:
            return None
        group_id = event.get("group_id")
        if group_id and self.bot.is_silenced(group_id):
            return None  # 闭嘴里，戳也不理
        sub_type = str(event.get("sub_type") or "")
        if event.notice_type not in POKE_TYPES and sub_type != "poke":
            return None

        # target_id 是被戳的对象；个别实现不带该字段，此时按“戳的是机器人”处理
        target = event.get("target_id")
        if target and self.bot.self_id and int(target) != self.bot.self_id:
            return None

        user_id = int(event.get("user_id") or 0)
        # 自己戳自己（AI 不会戳自己）：忽略，避免自问自答
        if self.bot.self_id and user_id == int(self.bot.self_id):
            return None
        group_id = event.get("group_id")
        session = f"group_{group_id}" if group_id else f"user_{user_id}"
        try:
            # 戳一戳没有正文，但长期记忆（如「跟我说话要叫哥哥」）同样要遵守
            client = self._get_client()
            memory = await self.bot.memory_context(group_id, user_id)
            summary = await self.bot.summary_context(session)
            # 与 _ai_reply.answer 同款：style_hooks（人格/成人层级/时间感）也要生效，
            # 否则戳一戳永远是素回复。钩子产出并进 memory，与记忆同权注入。
            try:
                for _hook in (getattr(self.bot, "style_hooks", None) or []):
                    _extra = await _hook(_PokeCtx(group_id, user_id),
                                         "（有人戳了戳你）")
                    if _extra:
                        memory = (memory + "\n\n" + _extra).strip() if memory else _extra
            except Exception:  # noqa: BLE001
                pass
            answer = await client.chat(
                session, "（有人戳了戳你，请自然地回应一句）",
                memory=memory, summary=summary,
            )
        except Exception as exc:  # noqa: BLE001
            self.log.error("自主模式（戳一戳）调用模型失败: %s", exc)
            return None
        await self._reply_poke(event, answer)
        try:
            from ._ai_reply import _spawn_summary
            _spawn_summary(self.bot, client, session)
        except Exception:  # noqa: BLE001
            await self.bot.update_summary(client, session)
        return self.stop()

    async def on_message(self, ctx) -> Any:
        if not self._active:
            return None
        if not ctx.is_group:
            return None  # 私聊交由 AI 对话插件处理
        # 被要求闭嘴期间不主动搭话
        if self.bot.is_silenced(ctx.group_id):
            return None
        # 置控台里关掉 AI 发言的群：不主动接话
        if not self.bot.group_ai_enabled(ctx.group_id):
            return None
        text = ctx.text.strip()
        from ._ai_reply import message_has_reply, message_has_visual

        visual = message_has_visual(ctx.message)
        if not text and not visual and not message_has_reply(ctx.message):
            return None
        # 自己发的消息不接（避免机器人和自己聊天）
        if self.bot.self_id and int(ctx.user_id or 0) == int(self.bot.self_id):
            return None

        mode = self.bot.config.auto_mode
        session = self._session(ctx)
        user_id = int(ctx.user_id or 0)
        # 只发图 / 只引用时正文为空，记录里也留个占位说明
        record_text = text or ("（图片）" if visual else "（引用了一条消息）")

        # 先取历史再记录本条：短应答要的正是「这条之前」的上下文
        history = self._history_text(session, user_id)
        self._remember(session, ctx, record_text)

        # 只发表情包/图片（无文字）：占位已记进上下文（AI 能感受气氛），但不接话、不对图回复
        if visual and not text:
            return None

        if text and self._has_trigger_prefix(text):
            return None  # 显式触发词交给 AI 对话插件

        # 这条消息在 @ 别人（包括 @全体成员）而不是机器人 → 不管抽签/关键词多活跃都不掺和
        has_at = any(getattr(seg, "type", "") == "at" for seg in ctx.message)
        if has_at and not self._is_at_me(ctx):
            return None

        by_at = bool(mode.on_at) and self._is_at_me(ctx)
        by_keyword = bool(text) and self._matched_keyword(text)
        # 随机接话按好感度抽签（base × 好感系数）
        try:
            _base = float(getattr(mode, "random_reply_base", 0.0) or 0.0)
        except (TypeError, ValueError):
            _base = 0.0
        if _base > 0 and mode.on_any:
            import random as _rnd
            _mult = self._fam_mult(user_id, str(ctx.group_id or 0))
            if self._always_chat(str(ctx.group_id or 0)):
                _mult *= 3.0
            by_any = _rnd.random() < min(0.95, _base * _mult)
        else:
            by_any = self._hit_any()
        triggered = by_at or by_keyword or by_any
        # 短应答：上一条触发后，接下来几条即使没有触发词也继续接话
        by_follow = (not triggered) and self._follow_hit(session, user_id)
        if not triggered and not by_follow:
            return None
        # 束缚力：非 @ 的主动接话必须过「同群冷却 + 每小时上限」
        if not by_at and not self._restraint_ok(str(ctx.group_id or 0)):
            return None

        # 随机接话/短应答（非 @/关键词触发）打标：mood_injection 会做授权检测
        try:
            setattr(ctx, "_auto_random", not (by_at or by_keyword))
        except Exception:  # noqa: BLE001
            pass
        if triggered:
            # 新的触发重置持续状态（触发后还能再接几条由配置决定）
            self._open_follow(session, user_id)
        else:
            self._consume_follow(session)

        try:
            from ._ai_reply import answer

            # 只发图 / 只引用时正文为空，给模型一句占位说明，图片由 answer 一并带上
            prompt = text or ("（对方发来一张图片，没有文字）" if visual else "（对方引用了一条消息，没有文字）")
            # 随机接话也直接把原话交给模型，让它说实际内容；
            # 不要再加「你只是旁观」这类提示，否则它会满嘴旁白。
            await answer(
                self.bot, self._get_client(), ctx, prompt, session,
                mode.reply_mode, history=history,
            )
        except Exception as exc:  # noqa: BLE001
            self.log.error("自主模式调用模型失败: %s", exc)
            return self.stop()
        return self.stop()