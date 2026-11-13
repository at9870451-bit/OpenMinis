"""AI 对话插件：群聊 / 私聊接入大模型。

触发方式：
  - 私聊：直接发消息即可
  - 群聊：消息以 config.ai.triggers 中的任一前缀开头（如 #ai），或 @机器人
"""

from __future__ import annotations

import asyncio
from typing import Any

from ...core.message import Segment
from ..base import Plugin


class AIChatPlugin(Plugin):
    name = "ai"
    display_name = "AI 对话"
    version = "0.2.0"
    description = "接入大模型的群聊/私聊对话"
    priority = 50

    def __init__(self, bot) -> None:
        super().__init__(bot)

    async def on_load(self) -> None:
        self.add_command(
            "ai_reset", self._cmd_reset,
            aliases=("ai清空", "重置对话", "清理上下文", "忘掉记忆", "重置"),
            description="清空当前会话的 AI 上下文",
        )
        if self.bot.config.ai.enabled:
            self.log.info("AI 对话已启用，模型=%s", self.bot.config.ai.model)
        else:
            self.log.info("AI 对话未启用（config.ai.enabled=false）")

    def _get_client(self):
        """用 Bot 上共享的客户端：三个插件共用同一份上下文历史。"""
        return self.bot.chat_client()

    @staticmethod
    def _session(ctx) -> str:
        from ._ai_reply import session_key

        return session_key(ctx)

    async def _cmd_reset(self, ctx, args: str) -> Any:
        if not self.bot.config.ai.enabled:
            await ctx.reply("AI 对话未启用。")
            return
        session = self._session(ctx)
        self._get_client().reset(session)
        # 临时摘要也要一起清掉，否则下一轮又会从摘要里「想起」刚才聊的内容
        try:
            await asyncio.to_thread(self.bot.memory.clear_summary, session)
        except Exception as exc:  # noqa: BLE001 - 摘要清不掉不影响主流程
            self.log.warning("清理临时摘要失败: %s", exc)
        await ctx.reply("已清空本会话的 AI 上下文。")

    async def on_unload(self) -> None:
        # 客户端由 Bot 共享持有，插件卸载时不能关掉它，否则会连带打断其它插件的会话
        pass

    def _is_at_me(self, ctx) -> bool:
        if not self.bot.self_id:
            return False
        target = str(self.bot.self_id)
        for seg in ctx.message:
            if isinstance(seg, Segment) and seg.type == "at" and str(seg.data.get("qq")) == target:
                return True
        return False

    def _extract_prompt(self, ctx) -> str | None:
        """判断这条消息是否在跟机器人说话，并取出真正的问题。

        称呼判定与「白话群管」共用 bot.call_words()，并把称呼后面的中文标点
        一并去掉——否则「小T，你好」会变成「，你好」，甚至被判成空内容。
        """
        from ...core.bot import strip_call_word
        from ._ai_reply import message_has_reply, message_has_visual

        content = ctx.text.strip()
        stripped = strip_call_word(content, self.bot.call_words()) if content else None
        if stripped is not None:
            return stripped
        if content and (ctx.is_private or self._is_at_me(ctx)):
            return content
        # 只发图 / 只引用不写字时正文是空的；以前这里直接返回 None，
        # 模型连「对方发了张图」都不知道，所以补一句占位再去取图。
        if ctx.is_private or self._is_at_me(ctx):
            if message_has_visual(ctx.message):
                return "（对方发来一张图片，没有文字）"
            if message_has_reply(ctx.message):
                return "（对方引用了一条消息，没有文字）"
        return None

    async def on_message(self, ctx) -> Any:
        if not self.bot.config.ai.enabled:
            return None
        # 被要求闭嘴期间不闲聊（管理员指令仍由白话群管处理）
        if ctx.is_group and self.bot.is_silenced(ctx.group_id):
            return None
        # 置控台里关掉 AI 发言的群：不接话（管理指令不受影响）
        if ctx.is_group and not self.bot.group_ai_enabled(ctx.group_id):
            return None

        prompt = self._extract_prompt(ctx)
        if prompt is None:
            return None
        if not prompt:
            await ctx.reply("你想问点什么？")
            return self.stop()

        from ._ai_reply import answer

        try:
            mode = str(getattr(self.bot.config.ai, "reply_mode", "direct") or "direct")
            await answer(
                self.bot, self._get_client(), ctx, prompt, self._session(ctx), mode
            )
        except Exception as exc:  # noqa: BLE001
            # 上游 429/5xx 抖动：静默跳过，不发机器话（下一句她会照常回）
            self.log.warning("本轮调用失败，静默跳过: %s", type(exc).__name__)
        return self.stop()