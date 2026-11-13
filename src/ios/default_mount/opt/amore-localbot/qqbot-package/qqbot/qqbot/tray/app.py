"""托盘应用：主线程跑托盘图标，后台线程跑 asyncio（Bot + WebUI）。

Windows 下 pystray 必须在主线程运行，因此事件循环放到守护线程，
托盘与事件循环之间通过 run_coroutine_threadsafe 通信。
"""

from __future__ import annotations

import asyncio
import threading

from ..config import Config
from ..core.bot import Bot
from ..gateway import GatewayController
from ..main import run_console
from .autostart import ensure_autostart, is_enabled
from .icon import make_icon_image


def run_tray(config: Config, log, args=None) -> int:
    try:
        import pystray
    except ImportError:
        log.warning("缺少依赖 pystray/Pillow，已回退控制台模式。请执行: pip install pystray pillow")
        return run_console(config, log)

    loop = asyncio.new_event_loop()
    state: dict[str, object] = {"ready": threading.Event()}

    async def bootstrap() -> None:
        bot = Bot(config)
        state["bot"] = bot
        await bot.start()

        if config.webui.enabled:
            from ..webui.app import start_webui

            state["server"] = await start_webui(bot)

        stop = asyncio.Event()
        state["stop"] = stop
        state["ready"].set()

        await stop.wait()
        server = state.get("server")
        if server is not None:
            server.should_exit = True
            await asyncio.sleep(0.8)  # 给 uvicorn 留出优雅退出时间
        await bot.stop()

    def run_loop() -> None:
        asyncio.set_event_loop(loop)
        loop.run_until_complete(bootstrap())

    threading.Thread(target=run_loop, name="qqbot-loop", daemon=True).start()

    ready: threading.Event = state["ready"]  # type: ignore[assignment]
    if not ready.wait(timeout=20) or state.get("bot") is None:
        log.error("后台服务启动超时，退出")
        return 1

    bot: Bot = state["bot"]  # type: ignore[assignment]

    def call(coro):
        return asyncio.run_coroutine_threadsafe(coro, loop)

    gateway = GatewayController(config)

    def show_gateway_status(icon, item) -> None:
        """查看网关（NapCat）状态。弹框放到独立线程，避免阻塞事件循环。"""

        def done(fut) -> None:
            try:
                running = fut.result() == "running"
            except Exception:  # noqa: BLE001
                running = False
            text = "运行中，机器人可以连接" if running else "未运行（右键菜单可重启网关）"
            threading.Thread(
                target=GatewayController.notify,
                args=(f"{config.bot.name} 网关状态", f"QQ 协议网关：{text}"),
                daemon=True,
            ).start()

        call(gateway.status()).add_done_callback(done)

    def restart_gateway(icon, item) -> None:
        call(gateway.restart()).add_done_callback(
            lambda fut: log.info("网关重启流程结束: %s", fut.result())
        )

    def open_panel(icon, item) -> None:
        """以内嵌窗口打开控制面板（独立进程）。

        统一走 main.open_panel_window，任何情况下都不再弹系统浏览器。
        """
        from ..main import open_panel_window

        open_panel_window(config, log)

    def reload_plugins(icon, item) -> None:
        fut = call(bot.plugins.reload())
        fut.add_done_callback(lambda f: log.info("已热重载 %d 个插件", len(f.result() or [])))

    def toggle_autostart(icon, item) -> None:
        ensure_autostart(not is_enabled())

    def quit_app(icon, item) -> None:
        stop = state.get("stop")
        if isinstance(stop, asyncio.Event):
            loop.call_soon_threadsafe(stop.set)
        icon.stop()

    menu = pystray.Menu(
        pystray.MenuItem("打开控制面板", open_panel, default=True),
        pystray.MenuItem("网关状态", show_gateway_status),
        pystray.MenuItem("重启网关", restart_gateway),
        pystray.MenuItem("热重载插件", reload_plugins),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("开机自启", toggle_autostart, checked=lambda item: is_enabled()),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("退出", quit_app),
    )

    # 多开时每个实例都要有自己的托盘图标：图标 id 带上实例名避免互相顶掉
    from ..instances import id_of_root

    icon_id = "qqbot-" + id_of_root(config.paths.root)
    icon = pystray.Icon(icon_id, make_icon_image(64), config.bot.name, menu)

    if config.tray.autostart and not is_enabled():
        ensure_autostart(True)

    log.info("托盘已启动（右键图标可打开控制面板 / 退出）")

    # 启动后自动以最大化内嵌窗口打开主界面（不再依赖手动点托盘）
    if config.webui.enabled and config.tray.open_panel_on_start:
        log.info("正在自动打开控制面板窗口")
        open_panel(None, None)

    icon.run()  # 阻塞主线程，直到退出被点击

    log.info("正在退出…")
    return 0