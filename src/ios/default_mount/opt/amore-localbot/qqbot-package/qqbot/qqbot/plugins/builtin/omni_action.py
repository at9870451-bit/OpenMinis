"""全能动作：用户自定义触发条件，命中后由机器人执行指定动作。

条件支持：触发词、被戳一戳、被点赞、收到好友申请、收到加群申请。
动作支持：回复（AI 自由措辞）、戳回去、点赞、同意/拒绝申请。
规则由面板通过 ``qqbot.omni`` 读写，插件只负责匹配与执行。
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import Any

from ...omni import OmniStore, trigger_label
from ..base import Plugin


@dataclass
class Scene:
    """一次触发现场：动作需要知道对谁、在哪个群、哪条申请。"""

    source: str
    user_id: int = 0
    group_id: int | None = None
    nickname: str = ""
    text: str = ""
    message_id: Any = None
    flag: str = ""
    event: Any = None

    @property
    def where(self) -> str:
        return f"群 {self.group_id}" if self.group_id else "私聊"


class OmniActionPlugin(Plugin):
    name = "omni_action"
    display_name = "全能动作"
    version = "0.1.0"
    description = "自定义触发条件，命中后由 AI 执行戳一戳、点赞、回复或审批"
    priority = 15  # 早于自主模式 / 白话群管 / AI 对话，规则命中后由它接管

    async def on_load(self) -> None:
        self.store = OmniStore(self.bot.config.paths.data_dir)
        self._tasks: set[asyncio.Task] = set()
        rules = self.store.list()
        if rules:
            self.log.info("全能动作已加载 %d 条规则", len(rules))
        else:
            self.log.info("全能动作已就绪，尚无规则")

    async def on_unload(self) -> None:
        for task in list(getattr(self, "_tasks", ())):
            task.cancel()
        self._tasks.clear()

    # ---------- 匹配 ----------

    @staticmethod
    def _keyword_hit(trigger: dict[str, Any], text: str) -> bool:
        content = str(text or "")
        lowered = content.lower()
        mode = str(trigger.get("mode") or "contains")
        for word in trigger.get("keywords") or []:
            raw = str(word or "")
            if not raw:
                continue
            target = raw.lower()
            if mode == "startswith":
                if lowered.startswith(target):
                    return True
            elif mode == "exact":
                if lowered == target:
                    return True
            elif mode == "regex":
                try:
                    if re.search(raw, content):
                        return True
                except re.error:
                    continue
            elif target in lowered:
                return True
        return False

    @staticmethod
    def _scope_ok(trigger: dict[str, Any], is_group: bool) -> bool:
        scope = str(trigger.get("scope") or "all")
        return scope == "all" or (scope == "group") == is_group

    def _rules(self, kind: str) -> list[dict[str, Any]]:
        return [
            rule for rule in self.store.list()
            if rule.get("enabled", True) and (rule.get("trigger") or {}).get("type") == kind
        ]

    def _is_self(self, user_id: Any) -> bool:
        return bool(self.bot.self_id) and int(user_id or 0) == int(self.bot.self_id)

    # ---------- 事件 ----------

    async def on_message(self, ctx) -> Any:
        text = str(ctx.text or "").strip()
        if not text or self._is_self(ctx.user_id):
            return None
        if ctx.is_group and self.bot.is_silenced(ctx.group_id):
            return None
        for rule in self._rules("keyword"):
            trigger = rule.get("trigger") or {}
            if not self._scope_ok(trigger, ctx.is_group):
                continue
            if not self._keyword_hit(trigger, text):
                continue
            scene = Scene(
                source="message",
                user_id=int(ctx.user_id or 0),
                group_id=ctx.group_id,
                nickname=str(getattr(ctx, "nickname", "") or ctx.user_id),
                text=text,
                message_id=ctx.message_id,
                event=ctx.event,
            )
            self._start(rule, scene)
            return self.stop()
        return None

    async def on_notice(self, event) -> Any:
        notice_type = str(event.get("notice_type") or "")
        sub_type = str(event.get("sub_type") or "")

        if notice_type == "poke" or sub_type == "poke":
            target = event.get("target_id")
            if target and not self._is_self(target):
                return None
            user_id = int(event.get("user_id") or 0)
            if self._is_self(user_id):
                return None
            rules = self._rules("poke")
            group_id = int(event.get("group_id") or 0) or None
            if not rules:
                return None
            if group_id and self.bot.is_silenced(group_id):
                return None
            scene = Scene(source="poke", user_id=user_id, group_id=group_id,
                          nickname=str(user_id), event=event)
            self._start(rules[0], scene)
            return self.stop()

        if notice_type == "profile_like":
            target = event.get("target_id")
            if target and not self._is_self(target):
                return None
            user_id = int(event.get("operator_id") or event.get("user_id") or 0)
            if not user_id or self._is_self(user_id):
                return None
            rules = self._rules("profile_like")
            if not rules:
                return None
            scene = Scene(
                source="profile_like", user_id=user_id,
                nickname=str(event.get("operator_nick") or user_id), event=event,
            )
            self._start(rules[0], scene)
            return self.stop()
        return None

    async def on_request(self, event) -> Any:
        request_type = str(getattr(event, "request_type", "") or "")
        if request_type == "friend":
            rules = self._rules("friend_request")
            kind = "friend_request"
        elif request_type == "group":
            rules = self._rules("group_request")
            kind = "group_request"
        else:
            return None
        if not rules:
            return None
        user_id = int(event.get("user_id") or 0)
        if self._is_self(user_id):
            return None
        scene = Scene(
            source=kind, user_id=user_id,
            group_id=int(event.get("group_id") or 0) or None,
            nickname=str(user_id), flag=str(getattr(event, "flag", "") or ""),
            event=event,
        )
        self._start(rules[0], scene)
        return self.stop()

    # ---------- 执行 ----------

    def _start(self, rule: dict[str, Any], scene: Scene) -> None:
        self.log.info("命中规则「%s」（%s，%s）", rule.get("name"), trigger_label(rule.get("trigger") or {}), scene.where)
        task = asyncio.create_task(self._run(rule, scene))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _run(self, rule: dict[str, Any], scene: Scene) -> None:
        for action in rule.get("actions") or []:
            try:
                await self._do(action, rule, scene)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                self.log.error("规则「%s」动作 %s 失败: %s", rule.get("name"), action.get("type"), exc)

    async def _do(self, action: dict[str, Any], rule: dict[str, Any], scene: Scene) -> None:
        kind = str(action.get("type") or "")
        if kind == "reply":
            text = await self._reply_text(action, rule, scene)
            if text:
                await self._send(scene, text)
            return
        if kind == "poke":
            if scene.group_id:
                await self.bot.call_api("group_poke", group_id=int(scene.group_id), user_id=scene.user_id)
            elif scene.user_id:
                await self.bot.call_api("friend_poke", user_id=scene.user_id)
            return
        if kind == "like":
            times = int(action.get("times") or rule.get("like_times") or 10)
            await self.bot.call_api("send_like", user_id=scene.user_id, times=max(1, min(20, times)))
            return
        if kind in ("approve_friend", "reject_friend", "approve_group", "reject_group"):
            if not scene.flag:
                raise RuntimeError("申请编号缺失")
            approve = kind.startswith("approve")
            if kind.endswith("friend"):
                await self.bot.call_api("set_friend_add_request", flag=scene.flag, approve=approve)
            else:
                await self.bot.call_api("set_group_add_request", flag=scene.flag, approve=approve)

    async def _send(self, scene: Scene, text: str) -> None:
        content = str(text or "").strip()
        if not content:
            return
        if scene.group_id:
            await self.bot.send_group_msg(int(scene.group_id), content)
            return
        if not scene.user_id:
            return
        try:
            await self.bot.send_private_msg(int(scene.user_id), content)
        except Exception:
            # 刚同意好友申请时，QQ 那边建立关系要一点时间，稍等再发一次
            await asyncio.sleep(1.5)
            await self.bot.send_private_msg(int(scene.user_id), content)

    async def _reply_text(self, action: dict[str, Any], rule: dict[str, Any], scene: Scene) -> str:
        if str(action.get("mode") or "ai") == "fixed":
            return str(action.get("text") or "").strip()
        instruction = str(action.get("instruction") or action.get("text") or "").strip()
        fact = {
            "message": f"对方在{scene.where}说了触发词",
            "poke": "对方戳了戳你",
            "profile_like": "对方给你的名片点了赞",
            "friend_request": "对方申请加你为好友",
            "group_request": "对方申请加入群聊",
        }.get(scene.source, "触发条件已命中")
        if not getattr(self.bot.config.ai, "enabled", False):
            return instruction or "收到"
        try:
            from ...ai.client import resolve_persona

            persona = resolve_persona(self.bot.config.ai) or ""
        except Exception:  # noqa: BLE001
            persona = ""
        system = (
            f"{persona}\n\n"
            "你正在执行主人提前设定好的自动动作。"
            "请结合当前人格，直接说你要发出去的那句话，不要解释、不要旁白、不要提规则或系统。"
            f"动作要求：{instruction or '自然地回应一句'}。"
        )
        prompt = f"触发情况：{fact}。触发者：{scene.nickname}。"
        if scene.text:
            prompt += f"对方说的是：{scene.text[:200]}。"
        prompt += "请直接回复："
        try:
            text = await asyncio.wait_for(
                self.bot.chat_client().complete(system, prompt, temperature=0.8, max_tokens=120),
                timeout=25,
            )
        except Exception as exc:  # noqa: BLE001
            self.log.warning("动作回复生成失败，使用原要求: %s", exc)
            return instruction or "好"
        text = re.sub(r"\[CQ:at,[^\]]*\]", "", str(text or "")).strip().strip('"').strip()
        return text or instruction or "好"


__all__ = ["OmniActionPlugin"]
