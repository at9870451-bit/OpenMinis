"""插件导入自检：在独立子进程里试加载插件、跑 on_load 与插件自检用例。

为什么必须另起进程：加载插件就是执行它里面的代码。一句 ``while True``、
一次 ``sys.exit``、或者几十秒不返回的网络等待，都能把宿主进程拖死。
放进子进程里跑、超时直接杀掉，主程序毫发无损——这是「导入前自动测试」
能够成立的前提。

调用方（导入接口）通过 ``--plugin-test`` 拉起本模块，结果写成 JSON 到
``--plugin-test-result`` 指定的文件；不用 stdout 是因为打包成 exe 之后
没有控制台，stdout 是 None。
"""

from __future__ import annotations

import asyncio
import importlib.util
import inspect
import json
import os
import re
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any

#: 被测模块统一挂在这个名字下，避免和宿主里的模块重名
MODULE_NAME = "qqbot_plugin_under_test"
#: 单个步骤的默认超时（秒）。导入接口在外层还会再兜一层更长的超时。
#: 注意：它只挡得住 async 里的 await 不返回；插件若用同步阻塞（time.sleep、
#: 死循环）跑满，事件循环被卡住，只有外层「杀掉子进程」才救得回来。
DEFAULT_TIMEOUT = 15.0
_MAX_ERROR_CHARS = 1200
#: 插件标识必须能安全地当目录名与配置键用
_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,31}$")


def _clip(text: str) -> str:
    text = (text or "").strip()
    if len(text) <= _MAX_ERROR_CHARS:
        return text
    return text[:_MAX_ERROR_CHARS] + "\n…（报错过长，已截断）"


def _step(name: str, ok: bool, detail: str = "", warn: bool = False) -> dict[str, Any]:
    return {"name": name, "ok": ok, "detail": _clip(detail), "warn": warn}


def _failed(steps: list[dict[str, Any]], error: str, warnings: list[str],
            plugin: dict[str, Any]) -> dict[str, Any]:
    return {
        "ok": False,
        "error": _clip(error),
        "steps": steps,
        "warnings": warnings,
        "plugin": plugin,
    }


def ensure_std_streams() -> None:
    """打包成无控制台的 exe 时 stdout/stderr 是 None，任何 print/日志都会炸。

    自检进程只需要一个结果文件，所以把这两个流丢进 null 即可。
    """
    for name in ("stdout", "stderr"):
        if getattr(sys, name, None) is None:
            try:
                setattr(sys, name, open(os.devnull, "w", encoding="utf-8"))
            except OSError:
                pass


# ---------- 加载 ----------


def _load_module(entry: Path):
    if entry.name == "__init__.py":  # 目录包
        for key in [k for k in sys.modules if k == MODULE_NAME or k.startswith(MODULE_NAME + ".")]:
            sys.modules.pop(key, None)
        spec = importlib.util.spec_from_file_location(
            MODULE_NAME, entry, submodule_search_locations=[str(entry.parent)]
        )
    else:  # 单文件
        sys.modules.pop(MODULE_NAME, None)
        spec = importlib.util.spec_from_file_location(MODULE_NAME, entry)
    if spec is None or spec.loader is None:
        raise ImportError(f"无法创建模块：{entry}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


def _plugin_classes(module) -> list[type]:
    from qqbot.plugins.base import Plugin

    found: list[type] = []
    for _name, obj in inspect.getmembers(module, inspect.isclass):
        if not issubclass(obj, Plugin) or obj is Plugin:
            continue
        if not (
            obj.__module__ == module.__name__
            or obj.__module__.startswith(module.__name__ + ".")
        ):
            continue
        found.append(obj)
    return found


def _reserved_names() -> set[str]:
    """内置插件占用的标识。

    外部插件重名会被管理器静默跳过（内置先加载），与其装完发现没生效，
    不如在自检阶段直接拦下并说明原因。
    """
    from qqbot.plugins.manager import FALLBACK_BUILTIN_MODULES

    return set(FALLBACK_BUILTIN_MODULES)


def _make_bot(root: Path):
    """造一个只用来装插件的 Bot：mock 后端、不加载插件、不连网。

    插件在 on_load 里通常只注册指令、读配置、建目录，用真实 Bot 对象能保证
    它拿到的接口和运行时完全一致（换成假对象就容易「测过了跑起来报错」）。
    """
    from qqbot.config import Config

    config = Config.load(root)
    config.protocol.backend = "mock"
    config.plugins.enabled = False
    config.webui.enabled = False
    config.tray.enabled = False

    from qqbot.core.bot import Bot

    return Bot(config)


#: 自检用的一次性根目录前缀（放在系统临时目录里）
SANDBOX_PREFIX = "qqbot-plugin-test-"


def _prune_sandboxes(keep: Path | None = None, max_age: float = 3600.0) -> None:
    """清理以前自检留下的沙箱目录。

    自检要一个「像样的」根目录给 Config/Bot 用（config/、data/ 一堆子目录），
    用完本该立刻删掉；但万一某个进程崩了没删成，也不能让垃圾在临时目录里
    一直堆下去——这里顺手清掉一小时以前的。
    """
    import shutil
    import time

    try:
        base = Path(tempfile.gettempdir())
        now = time.time()
        for item in base.glob(SANDBOX_PREFIX + "*"):
            if keep is not None and item == keep:
                continue
            try:
                if now - item.stat().st_mtime < max_age:
                    continue
            except OSError:
                continue
            shutil.rmtree(item, ignore_errors=True)
    except Exception as exc:  # noqa: BLE001 - 清理失败不影响自检
        print(f"清理旧沙箱失败: {exc}", file=sys.stderr)


def _drop_sandbox(root: Path) -> None:
    """删掉自检沙箱。

    sqlite3 的 Connection 是用 ``with conn:`` 提交、并不会 close，句柄要等对象
    被回收才释放；它内部有循环引用，光靠引用计数不一定立刻回收，所以在删之前
    先催一次 gc——否则 Windows 上 rmtree 会因为「文件被占用」删不掉。
    """
    import gc
    import shutil

    gc.collect()
    shutil.rmtree(root, ignore_errors=True)


# ---------- 执行 ----------


async def _exercise(plugin, timeout: float) -> list[dict[str, Any]]:
    """依次跑 on_load 与插件自检用例。"""
    steps: list[dict[str, Any]] = []

    try:
        await asyncio.wait_for(plugin.on_load(), timeout=timeout)
    except asyncio.TimeoutError:
        steps.append(_step("调用 on_load()", False, f"超过 {timeout:.0f} 秒没有返回，疑似死循环或阻塞"))
        return steps
    except Exception as exc:  # noqa: BLE001
        steps.append(
            _step("调用 on_load()", False, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
        )
        return steps
    steps.append(_step("调用 on_load()", True, "插件初始化完成"))

    checker = getattr(plugin, "self_check", None)
    if not callable(checker):
        steps.append(
            _step("运行插件自检", True, "该插件未提供 self_check()，本次跳过自检用例", warn=True)
        )
        return steps

    try:
        result = checker()
        if inspect.isawaitable(result):
            result = await asyncio.wait_for(result, timeout=timeout)
    except asyncio.TimeoutError:
        steps.append(_step("运行插件自检", False, f"self_check() 超过 {timeout:.0f} 秒没有返回"))
        return steps
    except Exception as exc:  # noqa: BLE001
        steps.append(
            _step(
                "运行插件自检",
                False,
                f"self_check() 抛出异常 {type(exc).__name__}: {exc}\n{traceback.format_exc()}",
            )
        )
        return steps

    if result is None:
        result = []
    if isinstance(result, (str, bytes)):
        result = [result]
    try:
        problems = [str(item).strip() for item in result if str(item).strip()]
    except TypeError:
        steps.append(_step("运行插件自检", False, "self_check() 应返回字符串列表（问题清单）"))
        return steps

    if problems:
        steps.append(_step("运行插件自检", False, "自检未通过：\n- " + "\n- ".join(problems)))
    else:
        steps.append(_step("运行插件自检", True, "自检用例全部通过"))
    return steps


def run(entry: Path, timeout: float = DEFAULT_TIMEOUT,
        sandbox_root: Path | None = None) -> dict[str, Any]:
    """对单个插件入口文件做完整自检，返回可直接交给前端的报告。

    ``sandbox_root`` 由导入接口传入，放在它自己的临时工作目录里。这样做是为了
    「子进程被杀掉时也能收尸」：插件里一句同步死循环就能让子进程被强杀，强杀的
    进程没机会清理自己的沙箱，交给父进程统一删才不会有残留。
    """
    steps: list[dict[str, Any]] = []
    warnings: list[str] = []
    plugin: dict[str, Any] = {}

    if not entry.is_file():
        steps.append(_step("读取插件", False, f"找不到文件：{entry}"))
        return _failed(steps, "插件文件不存在", warnings, plugin)

    try:
        module = _load_module(entry)
    except Exception as exc:  # noqa: BLE001
        steps.append(
            _step("导入模块", False, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
        )
        return _failed(steps, f"导入模块失败：{type(exc).__name__}: {exc}", warnings, plugin)
    steps.append(_step("导入模块", True, "模块已成功导入"))

    classes = _plugin_classes(module)
    if not classes:
        steps.append(
            _step("识别插件类", False, "模块里没有继承 Plugin 的插件类，请检查是否忘了继承 Plugin")
        )
        return _failed(steps, "没有找到插件类", warnings, plugin)
    if len(classes) > 1:
        warnings.append(
            f"检测到 {len(classes)} 个插件类，只测试了 {classes[0].__name__}（其余会一并安装）"
        )
    steps.append(_step("识别插件类", True, f"{classes[0].__name__}"))

    # 沙箱目录给 Config/Bot 当「根目录」用，用完一定要删掉，
    # 否则每导入一次插件就在系统临时目录里留下一份 config/data。
    owned = sandbox_root is None
    if owned:
        _prune_sandboxes()
        sandbox = Path(tempfile.mkdtemp(prefix=SANDBOX_PREFIX))
    else:
        sandbox = Path(sandbox_root)
        sandbox.mkdir(parents=True, exist_ok=True)
    try:
        return _check_instance(classes, steps, warnings, sandbox, timeout)
    finally:
        if owned:  # 父进程给的沙箱由父进程统一删，强杀场景才收得干净
            _drop_sandbox(sandbox)


def _check_instance(
    classes: list[type],
    steps: list[dict[str, Any]],
    warnings: list[str],
    sandbox: Path,
    timeout: float,
) -> dict[str, Any]:
    """实例化插件并跑 on_load / self_check，返回最终报告。"""
    plugin: dict[str, Any] = {}
    try:
        bot = _make_bot(sandbox)
        instance = classes[0](bot)
    except Exception as exc:  # noqa: BLE001
        steps.append(
            _step("实例化插件", False, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
        )
        return _failed(steps, f"实例化插件失败：{type(exc).__name__}: {exc}", warnings, plugin)
    plugin = {
        "name": instance.name,
        "display_name": instance.display_name or instance.name,
        "version": instance.version,
        "description": instance.description,
        "author": instance.author,
    }

    if not _NAME_PATTERN.match(str(instance.name or "")):
        steps.append(
            _step(
                "校验插件标识",
                False,
                f"name={instance.name!r} 不合法：只能是字母、数字、下划线，字母或下划线开头，最长 32 位",
            )
        )
        return _failed(steps, "插件标识 name 不合法", warnings, plugin)
    if str(instance.name) in _reserved_names():
        steps.append(
            _step("校验插件标识", False, f"标识「{instance.name}」已被内置插件占用，请换一个 name")
        )
        return _failed(steps, "插件标识与内置插件重名", warnings, plugin)
    steps.append(_step("实例化插件", True, f"{instance.name} v{instance.version}"))
    steps.append(_step("校验插件标识", True, instance.name))

    try:
        steps += asyncio.run(_exercise(instance, timeout))
    except Exception as exc:  # noqa: BLE001 - 事件循环都挂了，兜底收尾
        steps.append(
            _step("运行插件自检", False, f"自检过程异常：{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
        )

    if all(step["ok"] for step in steps):
        return {"ok": True, "error": "", "steps": steps, "warnings": warnings, "plugin": plugin}
    first_bad = next(step for step in steps if not step["ok"])
    return _failed(
        steps,
        f"{first_bad['name']}失败：{first_bad['detail']}",
        warnings,
        plugin,
    )


def run_cli(entry: Path, result_path: Path | None, timeout: float = DEFAULT_TIMEOUT,
            sandbox_root: Path | None = None) -> int:
    """子进程入口：跑自检并把 JSON 结果写盘。返回 0 通过 / 1 未通过。"""
    ensure_std_streams()
    try:
        report = run(entry, timeout=timeout, sandbox_root=sandbox_root)
    except Exception as exc:  # noqa: BLE001 - 无论如何都要留下一份结果
        report = {
            "ok": False,
            "error": f"自检进程异常：{type(exc).__name__}: {exc}",
            "steps": [],
            "warnings": [],
            "plugin": {},
        }
    payload = json.dumps(report, ensure_ascii=False)
    if result_path is not None:
        try:
            result_path.parent.mkdir(parents=True, exist_ok=True)
            result_path.write_text(payload, encoding="utf-8")
        except OSError:
            pass
    else:
        try:
            sys.stdout.write(payload)
        except Exception:  # noqa: BLE001 - 无控制台环境
            pass
    return 0 if report.get("ok") else 1


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="qqbot-plugin-test", description="插件导入自检")
    parser.add_argument("entry", help="插件入口文件（xxx.py 或 目录包/__init__.py）")
    parser.add_argument("--result", default=None, help="结果 JSON 落盘路径")
    parser.add_argument(
        "--sandbox", default=None,
        help="自检沙箱目录（由导入接口指定，便于它在子进程被强杀后统一清理）",
    )
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="单步超时（秒）")
    args = parser.parse_args(argv)
    return run_cli(
        Path(args.entry),
        Path(args.result) if args.result else None,
        timeout=args.timeout,
        sandbox_root=Path(args.sandbox) if args.sandbox else None,
    )


if __name__ == "__main__":
    sys.exit(main())
