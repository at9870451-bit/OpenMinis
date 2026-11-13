"""开机自启。

优先使用「任务计划程序」：可以设置登录后延迟，避免开机瞬间网络/桌面
尚未就绪导致启动失败；系统不支持时自动回退到注册表 Run 键。
两者不会同时存在，避免重复启动。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from ..log import get_logger

log = get_logger("tray.autostart")

TASK_NAME = "QQBot"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
REG_VALUE = "QQBot"
LOGON_DELAY = "0000:30"  # 登录后延迟 30 秒

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _command() -> str:
    """启动命令行，兼容源码运行与打包 exe。"""
    if getattr(sys, "frozen", False):
        return f'"{Path(sys.executable).resolve()}" --mode tray'

    python = Path(sys.executable)
    pythonw = python.with_name("pythonw.exe")  # 无控制台窗口
    exe = pythonw if pythonw.exists() else python
    root = Path(__file__).resolve().parents[2]
    return f'"{exe}" "{root / "run.py"}" --mode tray'


# ---------- 任务计划 ----------


def _task_exists() -> bool:
    try:
        return (
            subprocess.run(
                ["schtasks", "/query", "/tn", TASK_NAME],
                capture_output=True,
                creationflags=_NO_WINDOW,
            ).returncode
            == 0
        )
    except OSError:
        return False


def _create_task() -> bool:
    base = ["schtasks", "/create", "/tn", TASK_NAME, "/tr", _command(), "/sc", "onlogon"]
    try:
        result = subprocess.run(
            base + ["/delay", LOGON_DELAY, "/f"],
            capture_output=True,
            text=True,
            creationflags=_NO_WINDOW,
        )
        if result.returncode != 0:  # 老系统可能不支持 /delay
            result = subprocess.run(
                base + ["/f"], capture_output=True, text=True, creationflags=_NO_WINDOW
            )
    except OSError as exc:
        log.warning("调用 schtasks 失败: %s", exc)
        return False

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip()
        log.warning("任务计划创建失败: %s", message[:200])
        return False
    log.info("已通过任务计划设置开机自启（登录后延迟 30 秒）")
    return True


def _delete_task() -> bool:
    if not _task_exists():
        return True
    try:
        subprocess.run(
            ["schtasks", "/delete", "/tn", TASK_NAME, "/f"],
            capture_output=True,
            creationflags=_NO_WINDOW,
        )
        log.info("已移除任务计划自启")
        return True
    except OSError as exc:
        log.warning("移除任务计划失败: %s", exc)
        return False


# ---------- 注册表 Run（回退方案） ----------


def _registry_exists() -> bool:
    try:
        import winreg
    except ImportError:
        return False
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_READ) as key:
            value, _ = winreg.QueryValueEx(key, REG_VALUE)
            return bool(value)
    except OSError:
        return False


def _set_registry(enabled: bool) -> bool:
    try:
        import winreg
    except ImportError:
        log.warning("当前系统不支持注册表自启（仅 Windows）")
        return False
    try:
        with winreg.CreateKeyEx(
            winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE
        ) as key:
            if enabled:
                winreg.SetValueEx(key, REG_VALUE, 0, winreg.REG_SZ, _command())
                log.info("已通过注册表设置开机自启")
            else:
                try:
                    winreg.DeleteValue(key, REG_VALUE)
                except FileNotFoundError:
                    pass
        return True
    except OSError as exc:
        log.error("设置注册表自启失败: %s", exc)
        return False


# ---------- 对外接口 ----------


def is_enabled() -> bool:
    return _task_exists() or _registry_exists()


def ensure_autostart(enabled: bool) -> bool:
    if enabled:
        if _create_task():
            _set_registry(False)  # 二选一，避免双份启动
            return True
        log.info("回退到注册表 Run 键")
        return _set_registry(True)

    _delete_task()
    _set_registry(False)
    return True