"""群管理：违禁词拦截、入群欢迎、关键词回复，并提供管理指令。

自动行为配置位于 config.custom.group_admin：
    banned_words  违禁词列表，命中即撤回（群聊还会禁言）
    ban_seconds   禁言时长（秒），0 表示不禁言
    welcome       入群欢迎语，留空表示不欢迎
    keywords      关键词 -> 回复内容 的映射

管理员可在群内直接维护上述配置（改动即时写入 config.json）。
"""

from __future__ import annotations

from typing import Any

from ...core.message import at, text
from ..base import Plugin


class GroupAdminPlugin(Plugin):
    name = "group_admin"
    display_name = "群管理"
    version = "0.2.0"
    description = "群管理：违禁词、入群欢迎、关键词回复"
    priority = 20

    default_config: dict[str, Any] = {
        "banned_words": [],
        "ban_seconds": 60,
        "welcome": "",
        "keywords": {},
    }

    config_labels: dict[str, str] = {
        "banned_words": "违禁词（命中即撤回，群聊还会禁言）",
        "ban_seconds": "命中违禁词的禁言时长（秒，0 表示只撤回不禁言）",
        "welcome": "新人入群欢迎语（留空则关闭欢迎）",
        "keywords": "关键词自动回复（JSON，例如 {\"你好\":\"在的\"}）",
    }

    async def on_load(self) -> None:
        self.add_command(
            "add_banned", self._cmd_add_banned,
            aliases=("违禁词添加", "添加违禁词"), admin=True, description="添加违禁词：<词>",
        )
        self.add_command(
            "del_banned", self._cmd_del_banned,
            aliases=("违禁词删除", "删除违禁词"), admin=True, description="删除违禁词：<词>",
        )
        self.add_command(
            "list_banned", self._cmd_list_banned,
            aliases=("违禁词列表",), admin=True, description="查看违禁词列表",
        )
        self.add_command(
            "set_welcome", self._cmd_set_welcome,
            aliases=("设置欢迎语",), admin=True, description="设置入群欢迎语，留空则关闭",
        )
        self.add_command(
            "add_keyword", self._cmd_add_keyword,
            aliases=("关键词添加",), admin=True, description="添加关键词回复：<关键词> <回复内容>",
        )
        self.add_command(
            "del_keyword", self._cmd_del_keyword,
            aliases=("关键词删除",), admin=True, description="删除关键词回复：<关键词>",
        )
        self.add_command(
            "list_keyword", self._cmd_list_keyword,
            aliases=("关键词列表",), admin=True, description="查看全部关键词回复",
        )
        self.add_command("ban", self._cmd_ban, admin=True, description="禁言：@某人 [秒数]")

    # ---------- 自动行为 ----------

    async def on_notice(self, event) -> Any:
        if getattr(event, "notice_type", "") != "group_increase":
            return None
        welcome = self.cfg_get("welcome") or ""
        group_id = getattr(event, "group_id", None)
        if not welcome or not group_id:
            return None
        await self.bot.send_group_msg(group_id, [at(event.user_id), text(" " + welcome)])
        return self.stop()

    async def on_message(self, ctx) -> Any:
        content = ctx.text

        for word in self.cfg_get("banned_words") or []:
            if word and word in content:
                await self._punish(ctx)
                return self.stop()

        for key, response in (self.cfg_get("keywords") or {}).items():
            if key and key in content:
                await ctx.reply(response)
                return self.stop()

        return None

    async def _punish(self, ctx) -> None:
        if ctx.message_id is not None:
            try:
                await self.bot.delete_msg(ctx.message_id)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("撤回违禁消息失败: %s", exc)

        duration = int(self.cfg_get("ban_seconds", 60) or 0)
        if ctx.is_group and duration > 0:
            try:
                await self.bot.set_group_ban(ctx.group_id, ctx.user_id, duration)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("禁言失败: %s", exc)

        await ctx.reply("消息包含违禁词，已处理。", mention=ctx.is_group)

    # ---------- 违禁词管理 ----------

    async def _cmd_add_banned(self, ctx, args: str) -> Any:
        word = args.strip()
        if not word:
            await ctx.reply("用法：#违禁词添加 <词>")
            return
        words: list = self.cfg["banned_words"]
        if word in words:
            await ctx.reply("该词已在列表中。")
            return
        words.append(word)
        self.save_config()
        await ctx.reply(f"已添加违禁词「{word}」，当前共 {len(words)} 个。")

    async def _cmd_del_banned(self, ctx, args: str) -> Any:
        word = args.strip()
        words: list = self.cfg.get("banned_words") or []
        if word not in words:
            await ctx.reply("该词不在列表中。")
            return
        words.remove(word)
        self.save_config()
        await ctx.reply(f"已删除违禁词「{word}」。")

    async def _cmd_list_banned(self, ctx, args: str) -> Any:
        words = self.cfg.get("banned_words") or []
        await ctx.reply("违禁词：" + ("、".join(map(str, words)) if words else "（空）"))

    # ---------- 欢迎语 ----------

    async def _cmd_set_welcome(self, ctx, args: str) -> Any:
        value = args.strip()
        self.cfg["welcome"] = value
        self.save_config()
        await ctx.reply(f"入群欢迎语已设置为：{value}" if value else "已关闭入群欢迎。")

    # ---------- 关键词回复 ----------

    async def _cmd_add_keyword(self, ctx, args: str) -> Any:
        parts = args.split(None, 1)
        if len(parts) < 2:
            await ctx.reply("用法：#关键词添加 <关键词> <回复内容>")
            return
        key, response = parts[0], parts[1]
        self.cfg["keywords"][key] = response
        self.save_config()
        await ctx.reply(f"已设置关键词「{key}」的回复。")

    async def _cmd_del_keyword(self, ctx, args: str) -> Any:
        key = args.strip()
        keywords: dict = self.cfg.get("keywords") or {}
        if key not in keywords:
            await ctx.reply("该关键词不存在。")
            return
        keywords.pop(key)
        self.save_config()
        await ctx.reply(f"已删除关键词「{key}」。")

    async def _cmd_list_keyword(self, ctx, args: str) -> Any:
        keywords: dict = self.cfg.get("keywords") or {}
        if not keywords:
            await ctx.reply("暂无关键词回复。")
            return
        lines = [f"{key} —— {value}" for key, value in keywords.items()]
        await ctx.reply("关键词回复：\n" + "\n".join(lines))

    # ---------- 禁言 ----------

    async def _cmd_ban(self, ctx, args: str) -> Any:
        if not ctx.is_group:
            await ctx.reply("该指令仅群聊可用。")
            return
        targets = ctx.at_targets
        if not targets:
            await ctx.reply("请 @ 要禁言的成员，例如：#ban @某人 60")
            return
        raw = args.strip()
        duration = int(raw) if raw.isdigit() else int(self.cfg_get("ban_seconds", 60) or 60)
        for qq in targets:
            try:
                await self.bot.set_group_ban(ctx.group_id, qq, duration)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("禁言 %s 失败: %s", qq, exc)
        await ctx.reply(f"已禁言 {duration} 秒。")