"""插件基类。

插件只需继承 Plugin，然后：
  - 在 on_load 里用 add_command 注册指令（自动带权限校验与解析）
  - 或实现 on_message / on_notice / on_request 钩子自行处理

示例：

    class EchoPlugin(Plugin):
        name = "echo"

        async def on_load(self):
            self.add_command("echo", self._cmd_echo, description="复读内容")

        async def _cmd_echo(self, ctx, args):
            await ctx.reply(args or "（空）")
"""

from __future__ import annotations

import inspect
from copy import deepcopy
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Callable, Iterable

from ..core.bus import STOP, Subscription
from ..core.events import Event, MessageEvent, NoticeEvent, RequestEvent
from ..log import get_logger

if TYPE_CHECKING:
    from ..core.bot import Bot
    from ..core.context import Context

PREFIXES = ("#", "/", "！", "!")


@dataclass
class Command:
    name: str
    handler: Callable[..., Any]
    aliases: tuple[str, ...] = ()
    admin: bool = False
    description: str = ""

    def display_names(self) -> list[str]:
        return [self.name, *self.aliases]


class Plugin:
    #: 唯一标识，同时用于配置区分段（config.custom.<name>）与数据目录
    name: str = "plugin"
    #: 面板上显示的中文名；留空则回退到 name（name 是标识，不能随便改）
    display_name: str = ""
    version: str = "0.1.0"
    description: str = ""
    author: str = ""
    #: 越小越先处理消息
    priority: int = 100
    #: 插件默认配置，首次访问时合并进 config.custom.<name>
    default_config: dict[str, Any] = {}
    #: 配置项的中文标签：key -> 中文名。面板按它渲染设置表单，
    #: 否则用户看到的是一堆英文键名（strict_admin、max_size_mb 之类）。
    config_labels: dict[str, str] = {}

    def __init__(self, bot: "Bot") -> None:
        self.bot = bot
        self.log = get_logger(f"plugin.{self.name}")
        self._subs: list[Subscription] = []
        self._commands: dict[str, Command] = {}
        self._alias_map: dict[str, Command] = {}
        self.data_dir = bot.config.paths.plugin_data_dir / self.name
        self.data_dir.mkdir(parents=True, exist_ok=True)

    # ---------- 配置 ----------

    @property
    def cfg(self) -> dict[str, Any]:
        """该插件在配置文件 custom 区的配置段（自动补齐默认项）。"""
        section = self.bot.config.custom.setdefault(self.name, {})
        if not isinstance(section, dict):
            section = {}
            self.bot.config.custom[self.name] = section
        for key, value in self.default_config.items():
            # 必须深拷贝：否则默认的 list/dict 会被所有实例共享，指令修改后互相串味
            section.setdefault(key, deepcopy(value))
        return section

    def cfg_get(self, key: str, default: Any = None) -> Any:
        return self.cfg.get(key, default)

    def save_config(self) -> None:
        """配置被指令修改后调用，持久化到 config.json。"""
        self.bot.config.save()

    # ---------- 订阅总线 ----------

    def subscribe(self, event_type: str, handler, priority: int | None = None) -> Subscription:
        sub = self.bot.bus.on(
            event_type, handler, self.priority if priority is None else priority
        )
        self._subs.append(sub)
        return sub

    # ---------- 指令注册 ----------

    def add_command(
        self,
        name: str,
        handler: Callable[..., Any],
        *,
        aliases: Iterable[str] = (),
        admin: bool = False,
        description: str = "",
    ) -> Command:
        """注册指令。handler 签名为 (ctx, args) -> Any。"""
        command = Command(name, handler, tuple(aliases), admin, description)
        self._commands[name] = command
        for alias in aliases:
            self._alias_map[alias] = command
        return command

    def commands(self) -> list[Command]:
        return list(self._commands.values())

    # ---------- 生命周期钩子 ----------

    async def on_load(self) -> None:
        """插件被加载后调用，适合注册指令、建连接。"""

    async def on_unload(self) -> None:
        """插件被卸载/重载前调用，适合释放资源。"""

    def self_check(self) -> list[str]:
        """自检用例：返回问题清单，**空列表表示通过**。

        面板导入插件时会把这个插件放进**独立子进程**里，依次做三件事：
        「试加载模块」→「实例化并调用 on_load」→「调用本方法」。
        三步都通过才会真正安装；任何一步不通过都会把原因回给用户。

        默认什么都不检查。想让自己的配置问题在导入阶段就被拦下，覆盖它即可：

            def self_check(self):
                problems = []
                if not self.cfg_get("token"):
                    problems.append("缺少必填配置 token")
                return problems

        注意：这里只应该做**本地、快速、可重复**的检查，不要发起网络请求，
        否则导入会因为超时失败。抛出的异常同样会被当作失败原因上报。
        """
        return []

    # ---------- 事件钩子（返回 STOP 可终止后续插件） ----------

    async def on_message(self, ctx: "Context") -> Any:
        return None

    async def on_notice(self, event: NoticeEvent) -> Any:
        return None

    async def on_request(self, event: RequestEvent) -> Any:
        return None

    async def on_event(self, event: Event) -> Any:
        return None

    # ---------- 消息总入口（由 PluginManager 调用） ----------

    async def handle_message(self, ctx: "Context") -> Any:
        """先走指令分发，未命中再交给 on_message。"""
        if self._commands or self._alias_map:
            if await self._dispatch_command(ctx) is STOP:
                return STOP
        return await self.on_message(ctx)

    async def _dispatch_command(self, ctx: "Context") -> Any:
        # 指令只对配置里的管理员开放；其他成员一律只聊天
        if not ctx.is_admin:
            return None
        names = [*self._commands, *self._alias_map]
        parsed = self.parse_command(ctx.text, names)
        if parsed is None:
            return None
        name, args = parsed
        command = self._commands.get(name) or self._alias_map.get(name)
        if command is None:
            return None

        if command.admin and not ctx.is_admin:
            await self._safe_reply(ctx, "你没有执行该指令的权限。")
            return STOP

        try:
            result = command.handler(ctx, args)
            if inspect.isawaitable(result):
                await result
        except Exception as exc:  # noqa: BLE001
            self.log.exception("指令 %s 执行异常: %s", command.name, exc)
            await self._safe_reply(ctx, "指令执行出错，请查看日志。")
        return STOP

    async def _safe_reply(self, ctx: "Context", message: str) -> None:
        """回复失败时只记日志，避免把异常再次抛回分发链造成级联报错。"""
        try:
            await ctx.reply(message)
        except Exception as exc:  # noqa: BLE001
            self.log.warning("回复失败: %s", exc)

    # ---------- 工具 ----------

    @staticmethod
    def stop() -> object:
        return STOP

    @staticmethod
    def parse_command(
        text: str, commands: Iterable[str], prefixes: Iterable[str] = PREFIXES
    ) -> tuple[str, str] | None:
        """解析命令。

        若文本形如 `<前缀><命令> [参数]`，返回 (命令, 参数串)；
        不匹配返回 None。参数串在无参数时为空字符串。
        """
        t = text.strip()
        for prefix in prefixes:
            if not t.startswith(prefix):
                continue
            rest = t[len(prefix):].strip()
            for cmd in commands:
                if rest == cmd:
                    return cmd, ""
                if rest.startswith(cmd + " ") or rest.startswith(cmd + "\u3000"):
                    return cmd, rest[len(cmd):].strip()
        return None

    def unload(self) -> None:
        """取消本插件在总线上的全部订阅。"""
        for sub in self._subs:
            sub.cancel()
        self._subs.clear()

    def __repr__(self) -> str:
        return f"<Plugin {self.name} v{self.version}>"