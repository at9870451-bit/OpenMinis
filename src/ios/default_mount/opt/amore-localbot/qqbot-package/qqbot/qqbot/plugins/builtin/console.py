"""置控台：内置插件入口。

按群 AI 发言开关、人物绑定与连接异常邮件通知的配置都在 config.console，
实际生效点分别在 Bot.group_ai_enabled / _ai_reply 提示词 / notify 模块；
这里作为插件列表里的统一入口，并提供一条管理员查询指令。
"""

from __future__ import annotations

from typing import Any

from ..base import Plugin


class ConsolePlugin(Plugin):
    name = "console"
    display_name = "置控台"
    version = "1.0.0"
    description = "按群开关 AI 发言、人物名字绑定、连接异常邮件通知"
    priority = 40

    async def on_load(self) -> None:
        self.add_command(
            "console",
            self._cmd_status,
            aliases=("置控台", "发言状态"),
            admin=True,
            description="查看置控台的群发言开关、绑定数量与通知状态",
        )

    async def on_notice(self, event) -> Any:
        """被群管理禁言/解禁时同步置控台的红绿状态。"""
        notice_type = str(getattr(event, "notice_type", "") or event.get("notice_type") or "")
        if notice_type != "group_ban":
            return None
        group_id = getattr(event, "group_id", None) or event.get("group_id")
        if not group_id:
            return None
        try:
            uid = int(getattr(event, "user_id", None) or event.get("user_id") or 0)
            self_id = int(self.bot.self_id or 0)
        except (TypeError, ValueError):
            return None
        if not self_id or uid != self_id:
            return None
        try:
            duration = int(event.get("duration") or 0)
        except (TypeError, ValueError):
            duration = 0
        if duration > 0:
            self.bot.silence_group(group_id, duration, source="group")
        elif self.bot.silence_source(group_id) == "group":
            # 群管理解除禁言：只清掉「被群禁言」造成的红色，
            # 不碰管理员在置控台/指令里设置的永久闭嘴
            self.bot.wake_group(group_id)
        return None

    async def _cmd_status(self, ctx, args: str) -> Any:
        cfg = self.bot.config.console
        lines = ["【置控台状态】"]
        if ctx.is_group:
            on = self.bot.group_ai_enabled(ctx.group_id)
            lines.append(f"本群 AI 发言：{'已开启' if on else '已关闭'}")
        lines.append(f"人物绑定：{len(cfg.bindings or [])} 个")
        if cfg.notify_enabled:
            target = cfg.notify_email or "（未填邮箱）"
            lines.append(f"异常邮件通知：已开启 → {target}")
        else:
            lines.append("异常邮件通知：未开启")
        await ctx.reply("\n".join(lines))
        return self.stop()
