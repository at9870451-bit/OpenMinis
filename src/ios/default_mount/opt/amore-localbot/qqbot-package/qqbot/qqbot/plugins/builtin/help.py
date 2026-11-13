"""指令菜单：自动汇总所有插件注册的指令。"""

from __future__ import annotations

from typing import Any

from ..base import Plugin


class HelpPlugin(Plugin):
    name = "help"
    display_name = "指令菜单"
    version = "0.1.0"
    description = "指令菜单"
    priority = 5

    async def on_load(self) -> None:
        self.add_command(
            "help", self._cmd_help, aliases=("菜单", "命令"), description="显示全部可用指令"
        )

    async def _cmd_help(self, ctx, args: str) -> Any:
        items = self.bot.plugins.all_commands()
        if not items:
            await ctx.reply("当前没有可用指令。")
            return

        lines = ["可用指令："]
        for item in items:
            names = " ".join("#" + name for name in [item["name"], *item["aliases"]])
            flag = " 〔管理员〕" if item["admin"] else ""
            desc = f" —— {item['description']}" if item["description"] else ""
            lines.append(f"{names}{flag}{desc}")
        await ctx.reply("\n".join(lines))