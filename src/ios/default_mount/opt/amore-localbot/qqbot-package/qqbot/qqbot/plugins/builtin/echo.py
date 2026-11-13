"""回声与延迟测试。"""

from __future__ import annotations

from typing import Any

from ..base import Plugin


class EchoPlugin(Plugin):
    name = "echo"
    display_name = "回声测试"
    version = "0.2.0"
    description = "回声与延迟测试"
    priority = 10

    async def on_load(self) -> None:
        self.add_command("echo", self._cmd_echo, aliases=("复读",), description="复读后面的内容")
        self.add_command("ping", self._cmd_ping, description="延迟测试")

    async def _cmd_echo(self, ctx, args: str) -> Any:
        await ctx.reply(args or "（空）")

    async def _cmd_ping(self, ctx, args: str) -> Any:
        await ctx.reply("pong")