"""插件管理器：加载、卸载、事件分发与热加载。

插件来源有两处：
  - 内置插件：qqbot/plugins/builtin/*.py
  - 外部插件：config.paths.plugin_dir 下，支持两种形态（可热加载，用户自行扩展）
      * 单文件：xxx.py
      * 目录包：xxx/__init__.py（可带子模块、assets/ 与自带面板 panel.html）
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import inspect
import json
import pkgutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import TYPE_CHECKING, Any

from ..core.bus import STOP
from ..core.events import Event, MessageEvent, NoticeEvent, RequestEvent
from ..log import get_logger
from .base import Plugin

if TYPE_CHECKING:
    from ..core.bot import Bot
    from ..core.context import Context

log = get_logger("plugins")

BUILTIN_PACKAGE = "qqbot.plugins.builtin"
EXT_MODULE_PREFIX = "qqbot_ext_"

# 打包（PyInstaller）后 pkgutil 无法枚举包内模块，此处作为兜底清单。
# 新增内置插件时，请同时补充到本清单与 packaging/build.spec 的 hiddenimports。
FALLBACK_BUILTIN_MODULES = [
    "echo", "help", "group_admin", "ai_chat", "auto_chat", "admin_nl",
    "qq_social", "link_parser", "image_gen", "omni_action", "surf_bridge",
]

#: 跨插件通用的配置项中文标签。插件没单独声明时用这里的兜底，
#: 免得面板上直接显示英文键名。
COMMON_CONFIG_LABELS: dict[str, str] = {
    "enabled": "启用",
    "strict_admin": "严格管理员权限（只认「AI 配置」里的管理员）",
}


@dataclass
class PluginRecord:
    instance: Plugin
    source: str  # builtin | external
    path: str


@dataclass
class SourceRecord:
    module: ModuleType
    source: str
    path: str
    module_name: str
    mtime: float
    plugins: list[str] = field(default_factory=list)


class PluginManager:
    def __init__(self, bot: "Bot") -> None:
        self.bot = bot
        self.plugins: dict[str, PluginRecord] = {}
        self._sources: dict[str, SourceRecord] = {}
        self._watch_task: asyncio.Task | None = None
        # 分发器优先级最低，保证它先于插件自身的总线订阅执行
        self._sub = bot.bus.on("*", self._dispatch, priority=-1000)

    # ---------- 加载 ----------

    async def load_all(self) -> None:
        before = json.dumps(self.bot.config.custom, sort_keys=True, ensure_ascii=False)
        await self._load_builtins()
        await self._load_external()
        # 触发各插件默认配置合并，并回写到 config.json，让配置文件自解释
        for record in self.plugins.values():
            _ = record.instance.cfg
        after = json.dumps(self.bot.config.custom, sort_keys=True, ensure_ascii=False)
        if before != after:
            self.bot.config.save()
            log.info("已把插件默认配置写入 config.json")

    async def _load_builtins(self) -> None:
        try:
            from . import builtin as builtin_pkg
        except ImportError:
            log.warning("未找到内置插件包 qqbot.plugins.builtin")
            return
        base = Path(builtin_pkg.__file__).parent

        names: list[str] = []
        try:
            for info in pkgutil.iter_modules(builtin_pkg.__path__):
                if not info.name.startswith("_"):
                    names.append(info.name)
        except Exception:  # noqa: BLE001 - 冻结环境下枚举可能失败
            names = []
        if not names:
            names = list(FALLBACK_BUILTIN_MODULES)

        for name in names:
            module_name = f"{BUILTIN_PACKAGE}.{name}"
            try:
                module = importlib.import_module(module_name)
            except Exception as exc:  # noqa: BLE001
                log.error("导入内置插件 %s 失败: %s", name, exc)
                continue
            await self._register(module, "builtin", str(base / f"{name}.py"), module_name)

    async def _load_external(self) -> None:
        """扫描外部插件目录并加载。

        支持两种形态（导入接口上传的就是这两种）：
          - 单文件：``plugins_ext/xxx.py``
          - 目录包：``plugins_ext/xxx/__init__.py``（可带子模块、assets 与 panel.html）
        """
        directory = self.bot.config.paths.plugin_dir
        for entry in sorted(directory.iterdir(), key=lambda item: item.name):
            if entry.name.startswith(("_", ".")):
                continue
            if entry.is_file() and entry.suffix == ".py":
                target = entry
                module_name = f"{EXT_MODULE_PREFIX}{entry.stem}"
                importer = self._import_file
            elif entry.is_dir() and (entry / "__init__.py").is_file():
                target = entry / "__init__.py"
                module_name = f"{EXT_MODULE_PREFIX}{entry.name}"
                importer = self._import_package
            else:
                continue
            key = str(target)
            if key in self._sources:  # 已经加载过（重扫时跳过，避免重复注册）
                continue
            try:
                module = importer(target, module_name)
            except Exception as exc:  # noqa: BLE001
                log.error("加载外部插件 %s 失败: %s", entry.name, exc)
                continue
            await self._register(module, "external", key, module_name)

    async def rescan_external(self, force: str | None = None) -> list[str]:
        """重新扫描外部插件目录：加载**新增**的插件，热重载改动过的。

        导入接口落盘新插件后调用它，新插件当场就能用，不必重启。
        ``force`` 传刚被替换过的入口文件路径：文件系统时间戳精度可能不够，
        直接点名重载就不会漏。
        """
        await self._load_external()
        targets = self._detect_changes()
        if force and force in self._sources and force not in targets:
            targets.append(force)
        for path in targets:
            try:
                await self.reload(path)
            except Exception as exc:  # noqa: BLE001
                log.error("重载 %s 失败: %s", path, exc)
        return [name for name, record in self.plugins.items() if record.source == "external"]

    @staticmethod
    def _import_file(path: Path, module_name: str) -> ModuleType:
        sys.modules.pop(module_name, None)
        spec = importlib.util.spec_from_file_location(module_name, path)
        if spec is None or spec.loader is None:
            raise ImportError(f"无法从 {path} 创建模块")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module

    @staticmethod
    def _import_package(init_file: Path, module_name: str) -> ModuleType:
        """按目录包导入（``__init__.py`` + 同级子模块）。

        必须先清掉上一轮残留的同名模块（含子模块），否则热重载会拿旧代码，
        出现「改了文件却没生效」。
        """
        for key in [k for k in sys.modules if k == module_name or k.startswith(module_name + ".")]:
            sys.modules.pop(key, None)
        spec = importlib.util.spec_from_file_location(
            module_name, init_file, submodule_search_locations=[str(init_file.parent)]
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"无法从 {init_file} 创建包")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module

    @staticmethod
    def _is_package(path: str) -> bool:
        return Path(path).name == "__init__.py"

    async def _register(self, module: ModuleType, source: str, path: str, module_name: str) -> list[str]:
        disabled = set(self.bot.config.plugins.disabled or [])
        found: list[str] = []

        for _name, obj in inspect.getmembers(module, inspect.isclass):
            if not issubclass(obj, Plugin) or obj is Plugin:
                continue
            # 只注册本插件定义的类。目录包允许插件类写在包内子模块里，
            # 所以放行 "包名.子模块" 前缀，否则包内定义的插件会被静默跳过。
            if not (
                obj.__module__ == module.__name__
                or obj.__module__.startswith(module.__name__ + ".")
            ):
                continue
            if obj.name in disabled:
                log.info("插件 %s 已在配置中禁用，跳过", obj.name)
                continue
            if obj.name in self.plugins:
                log.warning("插件名重复：%s（%s），跳过", obj.name, path)
                continue
            try:
                instance = obj(self.bot)
            except Exception as exc:  # noqa: BLE001
                log.error("实例化插件 %s 失败: %s", obj.name, exc)
                continue
            self.plugins[obj.name] = PluginRecord(instance, source, path)
            found.append(obj.name)

        self._sources[path] = SourceRecord(
            module=module,
            source=source,
            path=path,
            module_name=module_name,
            mtime=self._source_mtime(path),
            plugins=found,
        )

        for name in found:
            plugin = self.plugins[name].instance
            try:
                await plugin.on_load()
            except Exception as exc:  # noqa: BLE001
                log.error("插件 %s on_load 失败: %s", name, exc)
            log.info("已加载插件 %s v%s（%s）", plugin.name, plugin.version, source)
        return found

    # ---------- 卸载与热加载 ----------

    async def _unload_plugin(self, name: str) -> None:
        record = self.plugins.pop(name, None)
        if record is None:
            return
        plugin = record.instance
        try:
            await plugin.on_unload()
        except Exception as exc:  # noqa: BLE001
            log.warning("插件 %s on_unload 异常: %s", name, exc)
        plugin.unload()
        log.info("已卸载插件 %s", name)

    async def reload(self, source_path: str | None = None) -> list[str]:
        """重载指定源文件的插件；为空则重载全部。返回被重载的插件名。"""
        targets = [source_path] if source_path else list(self._sources)
        reloaded: list[str] = []

        for path in targets:
            record = self._sources.get(path)
            if record is None:
                continue
            for name in record.plugins:
                await self._unload_plugin(name)

            try:
                if record.source == "builtin":
                    module = importlib.reload(record.module)
                elif self._is_package(path):
                    module = self._import_package(Path(path), record.module_name)
                else:
                    module = self._import_file(Path(path), record.module_name)
            except Exception as exc:  # noqa: BLE001
                log.error("重载 %s 失败: %s", path, exc)
                self._sources.pop(path, None)
                continue

            self._sources.pop(path, None)
            reloaded += await self._register(module, record.source, path, record.module_name)

        return reloaded

    async def reload_plugin(self, name: str) -> bool:
        record = self.plugins.get(name)
        if record is None:
            return False
        await self.reload(record.path)
        return True

    # ---------- 启用 / 禁用 ----------

    def disabled_plugins(self) -> list[str]:
        return list(self.bot.config.plugins.disabled or [])

    async def disable(self, name: str) -> bool:
        """卸载插件并写入禁用名单（重启后仍保持禁用）。"""
        record = self.plugins.get(name)
        if record is None:
            return False
        await self._unload_plugin(name)
        source = self._sources.get(record.path)
        if source is not None and name in source.plugins:
            source.plugins.remove(name)
        disabled = self.bot.config.plugins.disabled
        if name not in disabled:
            disabled.append(name)
        self.bot.config.save()
        log.info("插件 %s 已禁用并写入配置", name)
        return True

    async def enable(self, name: str) -> bool:
        """从禁用名单移除并重新加载。"""
        disabled = self.bot.config.plugins.disabled
        if name in disabled:
            disabled.remove(name)
        self.bot.config.save()
        await self.reload()
        return name in self.plugins

    # ---------- 详情与配置（供插件管理窗口使用） ----------

    def panel_dir(self, name: str) -> Path | None:
        """插件自带控制面板的目录；没有则返回 None。

        约定：**目录包**插件在包根放一个 ``panel.html`` 就等于自带面板，
        面板会优先展示它，并把包内 ``assets/`` 目录挂成静态资源。
        单文件插件没有目录可放，只能走通用设置页。
        """
        record = self.plugins.get(name)
        if record is None or not self._is_package(record.path):
            return None
        directory = Path(record.path).parent
        return directory if (directory / "panel.html").is_file() else None

    def detail(self, name: str) -> dict[str, Any] | None:
        """返回插件详情：基本信息 + 配置项 + 指令清单。

        ``config_schema`` 取自插件的 default_config（默认值），前端据此
        自动生成设置表单；``config`` 为当前生效值。
        """
        record = self.plugins.get(name)
        if record is None:
            return None
        plugin = record.instance
        schema = plugin.default_config or {}
        current = {}
        for key in schema:
            current[key] = plugin.cfg_get(key)
        return {
            "name": plugin.name,
            "display_name": plugin.display_name or plugin.name,
            "version": plugin.version,
            "description": plugin.description,
            "author": plugin.author,
            "priority": plugin.priority,
            "source": record.source,
            "path": record.path,
            "panel": self.panel_dir(name) is not None,
            "config_schema": schema,
            "config_labels": {**COMMON_CONFIG_LABELS, **plugin.config_labels},
            "config": current,
            "commands": [
                {
                    "name": c.name,
                    "aliases": list(c.aliases),
                    "admin": c.admin,
                    "description": c.description,
                }
                for c in plugin.commands()
            ],
        }

    def update_config(self, name: str, patch: dict[str, Any]) -> bool:
        """把插件管理窗口提交的配置合并进 config.custom.<name> 并落盘。"""
        record = self.plugins.get(name)
        if record is None:
            return False
        section = record.instance.cfg
        for key, value in patch.items():
            if key in (record.instance.default_config or {}):
                section[key] = value
        self.bot.config.save()
        log.info("插件 %s 配置已更新：%s", name, list(patch))
        return True

    # ---------- 指令查询（供帮助菜单使用） ----------

    def all_commands(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for record in self._ordered():
            plugin = record.instance
            for command in plugin.commands():
                out.append(
                    {
                        "plugin": plugin.name,
                        "name": command.name,
                        "aliases": list(command.aliases),
                        "admin": command.admin,
                        "description": command.description,
                    }
                )
        return out

    # ---------- 热加载监视 ----------

    def start_watching(self) -> None:
        if self._watch_task is None or self._watch_task.done():
            self._watch_task = asyncio.create_task(self._watch_loop())

    def stop_watching(self) -> None:
        if self._watch_task and not self._watch_task.done():
            self._watch_task.cancel()
        self._watch_task = None

    async def _watch_loop(self) -> None:
        interval = max(0.5, float(self.bot.config.plugins.watch_interval or 2.0))
        while True:
            await asyncio.sleep(interval)
            try:
                changed = self._detect_changes()
            except Exception as exc:  # noqa: BLE001
                log.warning("热加载检测异常: %s", exc)
                continue
            for path in changed:
                log.info("检测到插件文件变更，热重载：%s", Path(path).name)
                try:
                    await self.reload(path)
                except Exception as exc:  # noqa: BLE001
                    log.error("热重载 %s 失败: %s", path, exc)

    def _detect_changes(self) -> list[str]:
        changed: list[str] = []
        for path, record in list(self._sources.items()):
            if self._source_mtime(path) > record.mtime + 1e-6:
                changed.append(path)
        return changed

    @classmethod
    def _source_mtime(cls, path: str) -> float:
        """插件源的修改时间。

        目录包不能只看 ``__init__.py``：改了子模块却检测不到就白搭，
        所以取包内所有 .py 的最新时间。
        """
        if cls._is_package(path):
            latest = cls._mtime(path)
            for child in Path(path).parent.rglob("*.py"):
                latest = max(latest, cls._mtime(str(child)))
            return latest
        return cls._mtime(path)

    @staticmethod
    def _mtime(path: str) -> float:
        try:
            return Path(path).stat().st_mtime
        except OSError:
            return 0.0

    # ---------- 事件分发 ----------

    def _ordered(self) -> list[PluginRecord]:
        return sorted(self.plugins.values(), key=lambda r: r.instance.priority)

    async def _dispatch(self, event: Event) -> Any:
        if isinstance(event, MessageEvent):
            ctx: "Context" = self.bot.context(event)
            for record in self._ordered():
                if await self._call(record.instance, "handle_message", ctx) is STOP:
                    return STOP
            return None

        if isinstance(event, NoticeEvent):
            method = "on_notice"
        elif isinstance(event, RequestEvent):
            method = "on_request"
        else:
            method = "on_event"
        for record in self._ordered():
            if await self._call(record.instance, method, event) is STOP:
                return STOP
        return None

    async def _call(self, plugin: Plugin, method: str, arg: Any) -> Any:
        handler = getattr(plugin, method, None)
        if handler is None:
            return None
        try:
            result = handler(arg)
            if inspect.isawaitable(result):
                result = await result
            return result
        except Exception as exc:  # noqa: BLE001
            log.exception("插件 %s 执行 %s 异常: %s", plugin.name, method, exc)
            return None

    # ---------- 收尾与状态 ----------

    async def shutdown(self) -> None:
        self.stop_watching()
        self._sub.cancel()
        for name in list(self.plugins):
            await self._unload_plugin(name)
        self._sources.clear()

    def summary(self) -> list[dict[str, Any]]:
        return [
            {
                "name": record.instance.name,
                "display_name": record.instance.display_name or record.instance.name,
                "version": record.instance.version,
                "description": record.instance.description,
                "priority": record.instance.priority,
                "source": record.source,
            }
            for record in self._ordered()
        ]