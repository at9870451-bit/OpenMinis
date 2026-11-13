"""程序入口：支持控制台、托盘两种运行模式。"""

from __future__ import annotations

import argparse
import asyncio
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

from . import __version__
from .config import Config, project_root
from .core.bot import Bot
from .log import get_logger, setup_logging
from .singleinstance import SingleInstance


def allow_child_foreground() -> None:
    """允许随后启动的子进程把窗口提到前台。

    Windows 有「前台锁」：新建进程的窗口默认拿不到前台焦点，于是内嵌面板 /
    插件窗口常常开在主窗口**后面**。父进程在 Popen 之前调用本函数（ASFW_ANY），
    就等于把这个权利临时授予子进程。
    """
    if sys.platform != "win32":
        return
    try:
        import ctypes

        ctypes.windll.user32.AllowSetForegroundWindow(-1)  # ASFW_ANY
    except Exception as exc:  # noqa: BLE001 - 授权失败不影响窗口打开，只是可能不置顶
        get_logger("main").debug("AllowSetForegroundWindow 失败: %s", exc)


def raise_window_by_title(title: str, tries: int = 25) -> None:
    """按标题找到窗口并把它提到最前（在 webview.start 的回调线程里执行）。

    两步走，因为这两件事在 Windows 上是分开的：
      1. **层级**：先 SetWindowPos(TOPMOST) 再立刻 SetWindowPos(NOTOPMOST)，
         这是经典的「闪到最前」手法，不需要前台权限，能让它压住主面板；
      2. **焦点**：前台锁会挡掉普通的 SetForegroundWindow，于是把自己的输入队列
         临时挂到当前前台线程上（AttachThreadInput），借它的权利把焦点抢过来，完事立刻摘掉。

    非 Windows 平台直接忽略（pywebview 在那边本来就会正确聚焦）。
    """
    if sys.platform != "win32":
        return
    import ctypes
    import time
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
    user32.FindWindowW.restype = wintypes.HWND
    user32.SetWindowPos.argtypes = [
        wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, ctypes.c_uint,
    ]
    user32.SetWindowPos.restype = wintypes.BOOL
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.SetForegroundWindow.restype = wintypes.BOOL
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.c_void_p]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
    kernel32.GetCurrentThreadId.restype = wintypes.DWORD

    SWP_NOSIZE, SWP_NOMOVE, SWP_SHOWWINDOW = 0x0001, 0x0002, 0x0040
    HWND_TOPMOST, HWND_NOTOPMOST = wintypes.HWND(-1), wintypes.HWND(-2)
    SW_RESTORE = 9
    flags = SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW

    # 窗口要等一会儿才创建出来，轮询几次
    for _ in range(max(1, tries)):
        hwnd = user32.FindWindowW(None, title)
        if not hwnd:
            time.sleep(0.12)
            continue

        user32.ShowWindow(hwnd, SW_RESTORE)
        user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags)
        user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags)
        user32.SetForegroundWindow(hwnd)
        if user32.GetForegroundWindow() == hwnd:
            return

        # 前台锁挡住了：临时借用当前前台线程的输入队列
        foreground = user32.GetForegroundWindow()
        fg_thread = user32.GetWindowThreadProcessId(foreground, None)
        self_thread = kernel32.GetCurrentThreadId()
        if fg_thread and fg_thread != self_thread:
            try:
                user32.AttachThreadInput(self_thread, fg_thread, True)
                user32.SetForegroundWindow(hwnd)
            finally:
                user32.AttachThreadInput(self_thread, fg_thread, False)
        return


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="qqbot", description="自研 QQ 机器人")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument(
        "--mode",
        choices=["console", "tray"],
        default=None,
        help="运行模式，默认按配置（tray.enabled）决定",
    )
    parser.add_argument("--backend", choices=["mock", "onebot", "nt"], default=None, help="覆盖协议后端")
    parser.add_argument("--no-webui", action="store_true", help="本次不启动 WebUI")
    parser.add_argument("--no-tray", action="store_true", help="强制以控制台模式运行")
    parser.add_argument("--panel", action="store_true", help="仅打开内嵌控制面板窗口")
    parser.add_argument(
        "--plugin-window", metavar="NAME", default=None,
        help="以无边框内嵌窗口打开指定插件的管理界面",
    )
    parser.add_argument(
        "--plugin-frameless", type=int, default=1,
        help="插件窗口是否自绘无边框（0 保留系统边框，插件自带面板时用）",
    )
    parser.add_argument(
        "--instance", metavar="NAME", default=None,
        help="多开：按名字加载 instances/<NAME> 下的独立配置与数据（缺省为 exe 同目录）",
    )
    return parser.parse_args(argv)


async def _serve(config: Config, log) -> None:
    """在当前事件循环内启动 Bot 与 WebUI，并持续运行。"""
    bot = Bot(config)
    await bot.start()

    server = None
    if config.webui.enabled:
        from .webui.app import start_webui

        server = await start_webui(bot)
        log.info("控制面板：http://%s:%s", config.webui.host, config.webui.port)

    log.info("运行中，按 Ctrl+C 退出")
    try:
        while True:
            await asyncio.sleep(3600)
    finally:
        if server is not None:
            server.should_exit = True
            await asyncio.sleep(0.8)  # 给 uvicorn 留出优雅退出时间
        await bot.stop()


def open_panel_window(config: Config, log) -> None:
    """在独立进程里拉起内嵌控制面板窗口。

    托盘与 GUI 窗口都要占用主线程，所以面板必须另起进程；这里统一收口，
    任何地方都不再弹系统浏览器。
    """
    from .instances import id_of_root, launch_command

    command = launch_command(id_of_root(config.paths.root), ["--panel"])
    allow_child_foreground()  # 先把「提到前台」的权利授给面板进程，否则它会开在主窗口后面
    try:
        subprocess.Popen(command, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except OSError as exc:
        log.warning("拉起内嵌面板窗口失败: %s", exc)


def run_panel(config: Config, log) -> int:
    """打开内嵌浏览器窗口展示控制面板。

    托盘与 GUI 窗口都需要占用主线程，因此面板以**独立进程**运行，
    由托盘菜单拉起，两边互不干扰。缺少 pywebview 时回退系统浏览器。
    """
    url = f"http://{config.webui.host}:{config.webui.port}"
    try:
        import webview
    except ImportError:
        log.warning("缺少依赖 pywebview，回退系统浏览器。请执行: pip install pywebview")
        import webbrowser

        webbrowser.open(url)
        return 0

    title = f"{config.bot.name} 控制面板"
    try:
        window = webview.create_window(
            title,
            url,
            width=1280,
            height=820,
            min_size=(880, 600),
            maximized=True,  # 全屏窗口化：占满屏幕，但保留窗口边框便于最小化/关闭
        )

        def _watch_server() -> None:
            """主程序退出后 WebUI 就没了；面板不能留在那里当空壳。"""
            import time
            import urllib.error
            import urllib.request

            misses = 0
            while True:
                time.sleep(2)
                try:
                    with urllib.request.urlopen(url + "/api/status", timeout=2) as resp:
                        if resp.status == 200:
                            misses = 0
                            continue
                except urllib.error.HTTPError as exc:
                    if exc.code in (401, 403):  # 需要登录也说明服务还在
                        misses = 0
                        continue
                except Exception:  # noqa: BLE001
                    pass
                misses += 1
                if misses >= 3:
                    try:
                        window.destroy()
                    except Exception:  # noqa: BLE001
                        pass
                    return

        import threading

        threading.Thread(target=_watch_server, daemon=True).start()
        webview.start(raise_window_by_title, [title])
    except Exception as exc:  # noqa: BLE001 - 内嵌窗口依赖 .NET / WebView2，失败时退回系统浏览器
        log.error("内嵌控制面板启动失败，改用系统浏览器：%s", exc)
        import webbrowser

        webbrowser.open(url)
    return 0


def run_plugin_window(config: Config, log, name: str, frameless: bool = True) -> int:
    """以无边框内嵌窗口打开插件管理界面。

    与面板一样以**独立进程**运行（托盘/GUI 都要占主线程）；页面通过
    ``js_api`` 提供的 close / minimize / move_by 实现自绘标题栏的窗口控制。
    """
    url = (
        f"http://{config.webui.host}:{config.webui.port}"
        f"/plugin-panel/{quote(name)}"
    )
    try:
        import webview
    except ImportError:
        log.warning("缺少依赖 pywebview，回退系统浏览器。请执行: pip install pywebview")
        import webbrowser

        webbrowser.open(url)
        return 0

    class WindowApi:
        """供无边框窗口自绘标题栏调用（拖动 / 最小化 / 关闭）。"""

        @staticmethod
        def _window():
            return webview.windows[0] if webview.windows else None

        def close(self) -> None:
            window = self._window()
            if window is not None:
                window.destroy()

        def minimize(self) -> None:
            window = self._window()
            if window is not None:
                window.minimize()

        def move_by(self, dx: int, dy: int) -> None:
            """按位移增量移动窗口，配合前端标题栏的鼠标事件实现拖动。"""
            window = self._window()
            if window is None:
                return
            try:
                x = window.x if window.x is not None else 0
                y = window.y if window.y is not None else 0
                window.move(int(x) + int(dx), int(y) + int(dy))
            except Exception:  # noqa: BLE001 - 个别平台不支持读取坐标
                pass

    # 标题带上实例名：多开时各实例的插件窗口标题不重名，置顶逻辑才不会认错窗口
    title = f"插件管理 · {name} · {config.bot.name}"
    try:
        webview.create_window(
            title,
            url,
            width=780,
            height=640,
            min_size=(560, 460),
            frameless=frameless,
            easy_drag=False,
            js_api=WindowApi(),
        )
        # 插件窗口是从面板里点开的子进程：不主动提到前台就会被主窗口压住
        webview.start(raise_window_by_title, [title])
    except Exception as exc:  # noqa: BLE001 - 内嵌窗口失败时退回系统浏览器
        log.error("插件窗口启动失败，改用系统浏览器：%s", exc)
        import webbrowser

        webbrowser.open(url)
    return 0


def run_console(config: Config, log) -> int:
    try:
        asyncio.run(_serve(config, log))
    except KeyboardInterrupt:
        log.info("收到退出信号，已停止")
    return 0


def _pop_option(raw: list[str], name: str) -> tuple[list[str], str | None]:
    """取出 ``--name VALUE`` / ``--name=VALUE``，从参数列表里移除。"""
    for index, item in enumerate(raw):
        if item == name:
            if index + 1 < len(raw):
                value = raw[index + 1]
                del raw[index:index + 2]
            else:
                value = None
                del raw[index]
            return raw, value
        if item.startswith(name + "="):
            value = item.split("=", 1)[1]
            del raw[index]
            return raw, value
    return raw, None


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)

    # 插件导入自检：由导入接口以子进程方式拉起，只做「试加载 + 跑自检」，
    # 必须在读配置、加实例锁之前返回，避免与正在运行的主程序抢端口和锁。
    raw, test_entry = _pop_option(raw, "--plugin-test")
    if test_entry:
        raw, test_result = _pop_option(raw, "--plugin-test-result")
        raw, test_sandbox = _pop_option(raw, "--plugin-test-sandbox")
        from .plugins.selftest import run_cli

        return run_cli(
            Path(test_entry),
            Path(test_result) if test_result else None,
            sandbox_root=Path(test_sandbox) if test_sandbox else None,
        )

    # 把更新包拖到 QQBot.exe 上时，Windows 会把 zip 路径作为第一个参数传进来；
    # 也支持显式 --update <包>。这一步要在读取配置、加实例锁之前完成。
    raw, package = _pop_option(raw, "--update")
    if package is None and raw and raw[0].lower().endswith(".zip"):
        package = raw.pop(0)
    if package:
        from .updater import run_update_cli

        return run_update_cli(Path(package), project_root())

    # 重启助手：等旧进程退出后再继续正常启动，避免端口/实例锁冲突
    raw, watch_pid = _pop_option(raw, "--restart-watch")
    if watch_pid:
        try:
            from .updater import wait_pid

            wait_pid(int(watch_pid))
        except ValueError:
            pass

    args = parse_args(raw)

    # 多开：--instance 指定时加载 instances/<名字> 下的独立配置与数据；
    # 不指定则仍用 exe 同目录（默认实例），保持既有行为不变。
    if args.instance:
        from .instances import instances_root

        root = instances_root() / args.instance
    else:
        root = None
    config = Config.load(root)

    if args.backend:
        config.protocol.backend = args.backend
    if args.no_webui:
        config.webui.enabled = False

    log = setup_logging(config.paths.log_file, config.bot.log_level).getChild("main")
    log.info("%s v%s 启动，根目录 %s", config.bot.name, __version__, config.paths.root)
    log.info("协议后端=%s，插件目录=%s", config.protocol.backend, config.paths.plugin_dir)

    if args.panel:
        return run_panel(config, log)
    if args.plugin_window:
        return run_plugin_window(
            config, log, args.plugin_window, frameless=bool(args.plugin_frameless)
        )

    mode = args.mode or ("tray" if config.tray.enabled and sys.platform == "win32" else "console")
    if args.no_tray:
        mode = "console"
    if mode == "tray" and sys.platform != "win32":
        log.warning("当前系统没有桌面托盘，已改为控制台模式；控制面板请用浏览器访问")
        mode = "console"

    # 单实例保护：避免多个进程抢占 WebUI 端口与协议连接
    lock = SingleInstance(config.paths.data_dir / "qqbot.lock")
    if not lock.acquire():
        log.error("%s 已在运行（同一目录下只允许一个实例）", config.bot.name)
        # 不弹浏览器，直接拉起内嵌面板窗口
        open_panel_window(config, log)
        return 2

    try:
        if mode == "tray":
            from .tray.app import run_tray

            return run_tray(config, log, args)
        return run_console(config, log)
    finally:
        lock.release()


if __name__ == "__main__":
    sys.exit(main())