"""WebUI：本地控制面板与 HTTP API。

仅监听 127.0.0.1（可在配置中修改），提供状态查看、配置修改、
插件管理与日志查看，并支持向 Mock 后端注入测试消息。
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
from copy import copy
from pathlib import Path
from typing import Any

from .. import __version__ as APP_VERSION
from ..config import Config
from ..log import get_logger, recent_logs
from ..omni import (
    ACTION_TYPES, MATCH_MODES, SCOPES, TRIGGER_HELP, TRIGGER_TYPES,
    OmniStore, action_summary, ai_plan, normalize_rule, trigger_label, validate_rule,
)
from ..txgod import TxgodClient, TxgodError

log = get_logger("webui")


def _log_task_failure(task: asyncio.Task) -> None:
    """后台任务异常时记日志。

    无控制台窗口的 exe 里 stderr 为 None，未处理的任务异常会被静默吞掉，
    所以必须显式落盘。
    """
    if task.cancelled():
        return
    exc = task.exception()
    if exc is not None:
        log.error("WebUI 服务异常退出: %s: %s", type(exc).__name__, exc)


def _apply_config(config: Config, data: dict[str, Any]) -> None:
    """把前端提交的字段合并进配置，只接受已知字段。

    遇到嵌套的配置对象（如 ai.vision）按字段合并，避免把 dataclass 整个替换成 dict。
    """
    from dataclasses import is_dataclass

    for section in (
        "bot", "protocol", "webui", "tray", "txgod", "ai", "tts", "image",
        "sticker", "knowledge", "memory", "admin_nl", "auto_mode", "safety", "console",
        "ui", "plugins",
    ):
        patch = data.get(section)
        if not isinstance(patch, dict):
            continue
        target = getattr(config, section)
        for key, value in patch.items():
            if not hasattr(target, key):
                continue
            current = getattr(target, key)
            if is_dataclass(current) and not isinstance(current, type) and isinstance(value, dict):
                for sub_key, sub_value in value.items():
                    if hasattr(current, sub_key):
                        setattr(current, sub_key, sub_value)
            else:
                setattr(target, key, value)
    custom = data.get("custom")
    if isinstance(custom, dict):
        config.custom = custom


_MEDIA_TYPES: dict[str, str] = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
    ".txt": "text/plain; charset=utf-8",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
}


def _guess_media_type(path: Path) -> str:
    """插件自带面板的静态资源类型（白名单之外一律按二进制流下发）。"""
    return _MEDIA_TYPES.get(path.suffix.lower(), "application/octet-stream")


def create_app(bot):
    from fastapi import Body, FastAPI, Request
    from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
    from fastapi.staticfiles import StaticFiles

    import base64
    import hashlib
    import hmac

    config: Config = bot.config
    app = FastAPI(title="QQBot 控制面板", version=APP_VERSION, docs_url="/api/docs", redoc_url=None)

    @app.middleware("http")
    async def _no_cache_pages(request: Request, call_next):
        """面板页面一律不缓存。

        增量更新会替换 index.html，但内嵌 WebView / 浏览器会缓存旧页面，
        就会出现「明明更新了却看不到新按钮」。页面类响应统一 no-store。
        """
        response = await call_next(request)
        path = request.url.path
        if (
            path in ("/", "/login", "/m", "/m/login", "/download")
            or path.startswith("/static/")
            or path.startswith("/plugin-panel/")
        ):
            response.headers["Cache-Control"] = "no-store"
        return response

    from .. import instances as inst
    from ..napcat import NapCatClient, NapCatError, qrcode_svg

    napcat = NapCatClient(config)
    current_id = inst.id_of_root(config.paths.root)
    txgod = TxgodClient(config)

    static_dir = config.paths.static_dir
    index_file = static_dir / "index.html"
    if static_dir.exists():
        app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

    # 手机端控制面板：与桌面面板共用同一套 API，只是页面单独一套
    mobile_dir = config.paths.mobile_dir
    if mobile_dir.exists():
        app.mount("/m/assets", StaticFiles(directory=str(mobile_dir)), name="mobile-assets")

    # 个性化背景图：文件落在 data/ui，页面通过 /ui-assets 读取
    ui_dir = config.paths.ui_dir
    ui_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/ui-assets", StaticFiles(directory=str(ui_dir)), name="ui-assets")

    # ---------- 访问密码（云端公网部署时必填） ----------
    auth_password = str(getattr(config.webui, "access_password", "") or "")
    session_cookie = "qqbot_session"
    session_token = (
        hmac.new(auth_password.encode("utf-8"), b"qqbot-panel-v1", hashlib.sha256).hexdigest()
        if auth_password
        else ""
    )

    @app.middleware("http")
    async def _auth_guard(request: Request, call_next):
        if not auth_password:
            return await call_next(request)
        path = request.url.path
        # 登录页与静态资源必须放行，否则登录页自己都加载不出来
        if (
            path in ("/login", "/api/login", "/logout", "/m/login", "/download")
            or path.startswith("/static/")
            or path.startswith("/m/assets/")
            or path.startswith("/download/")
        ):
            return await call_next(request)
        token = request.cookies.get(session_cookie, "")
        if token and hmac.compare_digest(token, session_token):
            return await call_next(request)
        if path.startswith("/api/"):
            return JSONResponse(
                {"ok": False, "error": "未登录或登录已过期", "auth": True}, status_code=401
            )
        if path == "/m" or path.startswith("/m/"):
            return RedirectResponse("/m/login", status_code=303)
        return RedirectResponse("/login", status_code=303)

    # ---------- 页面 ----------

    @app.get("/login", response_class=HTMLResponse)
    async def login_page() -> Any:
        if not auth_password:
            return RedirectResponse("/", status_code=303)
        login_file = static_dir / "login.html"
        if login_file.exists():
            return HTMLResponse(login_file.read_text("utf-8"))
        return HTMLResponse("<h1>QQBot</h1><p>缺少 static/login.html</p>")

    @app.post("/api/login")
    async def login_submit(payload: dict[str, Any] = Body(...)) -> Any:
        if not auth_password:
            return {"ok": True}
        entered = str(payload.get("password") or "")
        if not hmac.compare_digest(entered, auth_password):
            await asyncio.sleep(0.3)
            return JSONResponse({"ok": False, "error": "密码不正确"}, status_code=401)
        response = JSONResponse({"ok": True})
        response.set_cookie(
            session_cookie,
            session_token,
            max_age=30 * 24 * 3600,
            httponly=True,
            samesite="lax",
            path="/",
        )
        return response

    @app.get("/logout")
    async def logout(mobile: int = 0) -> Any:
        is_mobile = mobile == 1
        if auth_password:
            target = "/m/login" if is_mobile else "/login"
        else:
            target = "/m" if is_mobile else "/"
        response = RedirectResponse(target, status_code=303)
        response.delete_cookie(session_cookie, path="/")
        return response

    @app.get("/", response_class=HTMLResponse)
    async def index() -> HTMLResponse:
        if index_file.exists():
            return HTMLResponse(index_file.read_text("utf-8"))
        return HTMLResponse("<h1>QQBot</h1><p>未找到 static/index.html</p>")

    # ---------- 网页入口与安卓控制端下载 ----------

    download_dir = config.paths.root / "downloads"

    @app.get("/download", response_class=HTMLResponse)
    async def download_page() -> Any:
        page = static_dir / "download.html"
        if page.exists():
            return HTMLResponse(page.read_text("utf-8"))
        return HTMLResponse("<h1>QQBot</h1><p>未找到 static/download.html</p>")

    @app.get("/download/{filename}")
    async def download_file(filename: str) -> Any:
        safe = Path(filename).name
        path = download_dir / safe
        if not path.is_file():
            return JSONResponse({"ok": False, "error": "文件不存在"}, status_code=404)
        media = (
            "application/vnd.android.package-archive"
            if safe.lower().endswith(".apk")
            else "application/octet-stream"
        )
        return Response(
            content=path.read_bytes(),
            media_type=media,
            headers={"Content-Disposition": f'attachment; filename="{safe}"'},
        )

    # ---------- 手机端页面 ----------

    def _mobile_page(name: str) -> HTMLResponse:
        file = mobile_dir / name
        if file.exists():
            return HTMLResponse(file.read_text("utf-8"))
        return HTMLResponse(
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<h1>QQBot</h1><p>缺少 app/mobile 页面资源</p>"
        )

    @app.get("/m", response_class=HTMLResponse)
    async def mobile_index() -> Any:
        return _mobile_page("index.html")

    @app.get("/m/login", response_class=HTMLResponse)
    async def mobile_login_page() -> Any:
        if not auth_password:
            return RedirectResponse("/m", status_code=303)
        return _mobile_page("login.html")

    # ---------- 状态与配置 ----------

    @app.get("/api/status")
    async def get_status() -> dict[str, Any]:
        payload = bot.status()
        payload["version"] = APP_VERSION
        payload["auth"] = bool(auth_password)
        return payload

    @app.get("/api/config")
    async def get_config() -> dict[str, Any]:
        return config.to_dict()

    @app.put("/api/config")
    async def put_config(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        _apply_config(config, payload)
        config.save()
        return {"ok": True, "note": "协议与 WebUI 相关改动需重启后生效"}

    # ---------- 置控台 ----------

    def _console_state(gid: str) -> dict[str, Any]:
        """一个群的卡片状态：绿=可发言，红=被禁言/已关闭。"""
        entry = (config.console.per_group or {}).get(str(gid)) or {}
        enabled = not (isinstance(entry, dict) and entry.get("enabled") is False)
        try:
            remaining = float(bot.silence_remaining(gid))
            source = bot.silence_source(gid)
        except Exception:  # noqa: BLE001 - 状态读不到按未禁言处理
            remaining, source = 0.0, ""
        silenced = remaining != 0.0
        until = 0.0
        if remaining > 0:
            until = time.time() + remaining
        return {
            "group_id": str(gid),
            "enabled": enabled,
            "silenced": silenced,
            "permanent": silenced and remaining < 0,
            "until": until,
            "remaining": remaining if remaining > 0 else 0.0,
            "source": source,
            "can_speak": enabled and not silenced,
        }

    @app.get("/api/console/overview")
    async def console_overview() -> Any:
        """置控台总览：各群红绿状态（绿=允许发言，红=禁言中）。"""
        names: dict[str, str] = {}
        order: list[str] = []
        try:
            # QQ 未登录时 OneBot 调用会一直挂着，这里限时，避免卡住整个面板
            resp = await asyncio.wait_for(bot.get_group_list(), timeout=4)
            items = resp.get("data") if isinstance(resp, dict) else None
            if not isinstance(items, list):
                items = []
            for item in items:
                if not isinstance(item, dict):
                    continue
                gid = str(item.get("group_id") or "").strip()
                if not gid or gid in names:
                    continue
                names[gid] = str(item.get("group_name") or "")
                order.append(gid)
        except Exception as exc:  # noqa: BLE001 - 未连接时拿不到群列表
            log.warning("获取群列表失败: %s", exc)
        for gid in (config.console.per_group or {}):
            gid = str(gid)
            if gid and gid not in names:
                names[gid] = ""
                order.append(gid)
        groups = []
        for gid in order:
            item = _console_state(gid)
            item["group_name"] = names.get(gid, "")
            groups.append(item)
        return {
            "ok": True,
            "groups": groups,
            "per_group": config.console.per_group,
        }

    @app.post("/api/console/group")
    async def console_group_toggle(payload: dict[str, Any] = Body(...)) -> Any:
        """卡片点选：绿→红为永久禁言，红→绿为恢复发言。"""
        gid = str(payload.get("group_id") or "").strip()
        if not gid.isdigit():
            return JSONResponse({"ok": False, "error": "群号不正确"}, status_code=400)
        enabled = bool(payload.get("enabled", True))
        entry = (config.console.per_group or {}).get(gid)
        if not isinstance(entry, dict):
            entry = {}
        # 红绿只由闭嘴状态表达，per_group.enabled 统一保持开启
        entry["enabled"] = True
        config.console.per_group[gid] = entry
        if enabled:
            bot.wake_group(gid)
        else:
            bot.silence_group(gid, 0, source="manual")
        config.save()
        state = _console_state(gid)
        state["group_name"] = ""
        return {"ok": True, "state": state}

    @app.post("/api/notify/test")
    async def notify_test(payload: dict[str, Any] = Body(...)) -> Any:
        """置控台「测试通知」：用未保存的邮箱参数发一封测试邮件。"""
        from ..notify import send_mail

        email = str(payload.get("email") or "").strip()
        qq = str(payload.get("qq") or "").strip()
        auth_code = str(payload.get("auth_code") or "").strip()
        if not email or not qq or not auth_code:
            return JSONResponse(
                {"ok": False, "error": "请先填写收件邮箱、发件 QQ 号和授权码"},
                status_code=400,
            )
        body = (
            "QQ机器人异常通知\n\n"
            "这是一封测试邮件：如果你收到了它，说明置控台的智能通知已经配置正确，\n"
            "之后检测到 OneBot 连接异常时会第一时间通知你。\n"
        )
        ok, error = await send_mail(email, qq, auth_code, "QQ机器人异常通知", body)
        return {"ok": ok, "error": error}

    # ---------- 配置同步（跨端导出 / 导入） ----------

    @app.post("/api/config/export")
    async def config_export() -> dict[str, Any]:
        """导出到 exports/ 并返回路径：内嵌面板里不依赖浏览器下载。"""
        from ..config_sync import export_to_file

        info = await asyncio.to_thread(export_to_file, config)
        return {"ok": True, **info}

    @app.get("/api/config/export")
    async def config_export_download() -> Any:
        """浏览器/手机端直接下载配置包。"""
        from ..config_sync import export_bundle

        filename, payload = await asyncio.to_thread(export_bundle, config)
        return Response(
            payload,
            media_type="application/zip",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )

    @app.post("/api/config/import")
    async def config_import(payload: dict[str, Any] = Body(...)) -> Any:
        import base64
        import binascii

        from ..config_sync import ConfigSyncError, stage_import

        raw = str(payload.get("content") or "")
        if not raw:
            return JSONResponse({"ok": False, "error": "没有收到配置包"}, status_code=400)
        try:
            blob = base64.b64decode(raw, validate=True)
        except (binascii.Error, ValueError):
            return JSONResponse({"ok": False, "error": "配置包编码不正确"}, status_code=400)
        try:
            info = await asyncio.to_thread(stage_import, config, blob)
        except ConfigSyncError as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        return {"ok": True, **info, "restart_required": True}

    # ---------- 程序更新（Windows 增量包） ----------

    @app.post("/api/update/upload")
    async def update_upload(payload: dict[str, Any] = Body(...)) -> Any:
        import base64
        import binascii
        import tempfile

        from ..updater import UpdateError, install_package

        if sys.platform != "win32":
            return JSONResponse(
                {
                    "ok": False,
                    "error": "当前系统请使用 Linux 的 /root/gengxin/update.py，或安装新版 APK",
                },
                status_code=400,
            )
        raw = str(payload.get("content") or "")
        if not raw:
            return JSONResponse({"ok": False, "error": "没有收到更新包"}, status_code=400)
        try:
            blob = base64.b64decode(raw, validate=True)
        except (binascii.Error, ValueError):
            return JSONResponse({"ok": False, "error": "更新包编码不正确"}, status_code=400)

        handle, name = tempfile.mkstemp(prefix="qqbot-update-", suffix=".zip")
        os.close(handle)
        temp = Path(name)
        try:
            temp.write_bytes(blob)
            # 更新包始终装在 exe 根目录，所有实例共用一份代码覆盖层
            from ..config import project_root

            info = await asyncio.to_thread(install_package, project_root(), temp, "win")
        except UpdateError as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        except Exception as exc:  # noqa: BLE001
            return JSONResponse(
                {"ok": False, "error": f"{type(exc).__name__}: {exc}"}, status_code=500
            )
        finally:
            try:
                temp.unlink()
            except OSError:
                pass
        return {"ok": True, **info, "restart_required": True}

    @app.post("/api/app/restart")
    async def restart_app() -> dict[str, Any]:
        """重启本程序（更新 / 导入配置后由面板调用）。Android 本地版需手动重启。"""
        if os.environ.get("PROOT_LOADER") or os.environ.get("PROOT_TMP_DIR"):
            return {"ok": True, "mode": "manual", "manual": True}

        async def _restart() -> None:
            await asyncio.sleep(0.6)
            try:
                await bot.stop()
            except Exception:  # noqa: BLE001 - 退出前尽力优雅停止
                pass
            from ..updater import restart_process

            await asyncio.to_thread(restart_process, config)

        asyncio.create_task(_restart())
        return {"ok": True, "mode": "restarting", "manual": False}

    # ---------- 个性化背景 ----------

    ui_regions = {
        "sidebar": "sidebar_image",
        "header": "header_image",
        "content": "content_image",
    }
    ui_max_bytes = 12 * 1024 * 1024

    def _ui_images() -> dict[str, str]:
        images: dict[str, str] = {}
        for region, attr in ui_regions.items():
            name = str(getattr(config.ui, attr) or "")
            images[region] = f"/ui-assets/{name}" if name and (ui_dir / name).exists() else ""
        return images

    def _ui_payload() -> dict[str, Any]:
        return {
            "ok": True,
            "enabled": bool(config.ui.enabled),
            "opacity": int(config.ui.image_opacity),
            "blur": int(config.ui.image_blur),
            "scrim": int(config.ui.scrim),
            "images": _ui_images(),
        }

    def _clamp(value: Any, low: int, high: int, fallback: int) -> int:
        try:
            number = int(value)
        except (TypeError, ValueError):
            return fallback
        return max(low, min(high, number))

    def _image_kind(blob: bytes) -> str:
        # 只认文件头，不信任扩展名或前端传来的类型
        if blob.startswith(b"\xff\xd8\xff"):
            return "jpg"
        if blob.startswith(b"\x89PNG\r\n\x1a\n"):
            return "png"
        if blob[:6] in (b"GIF87a", b"GIF89a"):
            return "gif"
        return ""

    @app.get("/api/ui")
    async def ui_state() -> dict[str, Any]:
        return _ui_payload()

    @app.put("/api/ui")
    async def ui_update(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        if "enabled" in payload:
            config.ui.enabled = bool(payload.get("enabled"))
        config.ui.image_opacity = _clamp(
            payload.get("opacity"), 0, 100, config.ui.image_opacity
        )
        config.ui.image_blur = _clamp(payload.get("blur"), 0, 20, config.ui.image_blur)
        config.ui.scrim = _clamp(payload.get("scrim"), 0, 100, config.ui.scrim)
        config.save()
        return _ui_payload()

    @app.post("/api/ui/background")
    async def ui_background_upload(payload: dict[str, Any] = Body(...)) -> Any:
        import base64
        import binascii

        region = str(payload.get("region") or "")
        attr = ui_regions.get(region)
        if not attr:
            return JSONResponse({"ok": False, "error": "未知区域"}, status_code=400)
        raw = str(payload.get("data") or "")
        if "," in raw[:120]:  # 兼容 data:image/png;base64,xxxx
            raw = raw.split(",", 1)[1]
        try:
            blob = base64.b64decode(raw)
        except (binascii.Error, ValueError):
            return JSONResponse({"ok": False, "error": "图片数据不是合法的 base64"}, status_code=400)
        if len(blob) > ui_max_bytes:
            return JSONResponse({"ok": False, "error": "图片超过 12MB，压缩后再试"}, status_code=400)
        kind = _image_kind(blob)
        if not kind:
            return JSONResponse({"ok": False, "error": "只支持 JPG / PNG / GIF"}, status_code=400)
        # 文件名带内容哈希，换图后浏览器不会拿到旧缓存
        filename = f"{region}-{hashlib.sha1(blob).hexdigest()[:10]}.{kind}"
        (ui_dir / filename).write_bytes(blob)
        old = str(getattr(config.ui, attr) or "")
        setattr(config.ui, attr, filename)
        config.ui.enabled = True
        config.save()
        if old and old != filename:
            try:
                (ui_dir / old).unlink()
            except OSError:
                pass
        return _ui_payload()

    @app.delete("/api/ui/background/{region}")
    async def ui_background_clear(region: str) -> Any:
        attr = ui_regions.get(region)
        if not attr:
            return JSONResponse({"ok": False, "error": "未知区域"}, status_code=400)
        old = str(getattr(config.ui, attr) or "")
        setattr(config.ui, attr, "")
        config.save()
        if old:
            try:
                (ui_dir / old).unlink()
            except OSError:
                pass
        return _ui_payload()

    # ---------- 插件 ----------

    @app.get("/api/plugins")
    async def list_plugins() -> dict[str, Any]:
        return {
            "loaded": bot.plugins.summary(),
            "disabled": bot.plugins.disabled_plugins(),
        }

    @app.post("/api/plugins/reload")
    async def reload_all() -> dict[str, Any]:
        names = await bot.plugins.reload()
        return {"ok": True, "reloaded": names}

    @app.post("/api/plugins/{name}/reload")
    async def reload_one(name: str) -> dict[str, Any]:
        ok = await bot.plugins.reload_plugin(name)
        return {"ok": ok}

    @app.post("/api/plugins/{name}/toggle")
    async def toggle_plugin(name: str, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        enabled = bool(payload.get("enabled"))
        ok = await bot.plugins.enable(name) if enabled else await bot.plugins.disable(name)
        return {"ok": ok, "enabled": enabled}

    @app.get("/api/plugins/{name}/detail")
    async def plugin_detail(name: str) -> Any:
        """插件详情：基本信息 + 配置项 + 指令清单（供管理窗口渲染）。"""
        detail = bot.plugins.detail(name)
        if detail is None:
            return JSONResponse({"ok": False, "error": "插件不存在或已禁用"}, status_code=404)
        return {"ok": True, "detail": detail}

    @app.put("/api/plugins/{name}/config")
    async def plugin_config(name: str, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        patch = payload.get("config")
        ok = bot.plugins.update_config(name, patch if isinstance(patch, dict) else {})
        return {"ok": ok}

    @app.post("/api/plugins/{name}/open")
    async def open_plugin_window(name: str) -> Any:
        """为指定插件拉起一个无边框管理窗口（独立进程）。

        统一走 ``/plugin-panel/<name>``：插件自带 panel.html 就展示它，
        否则服务端会 303 回通用设置页。
        """
        if bot.plugins.detail(name) is None:
            return JSONResponse({"ok": False, "error": "插件不存在或已禁用"}, status_code=404)
        # 云端/浏览器环境没法由服务端弹窗，返回页面地址让前端新开标签页
        if sys.platform != "win32":
            from urllib.parse import quote

            return {"ok": True, "url": f"/plugin-panel/{quote(name)}"}
        # 关键：父进程先授权，子进程才能把新窗口提到前台；
        # 否则 Windows 前台锁会让插件窗口开在面板后面（用户点开却看不到）。
        from ..instances import id_of_root, launch_command
        from ..main import allow_child_foreground

        # 通用设置页自带自绘标题栏（含关闭按钮），配无边框窗口正好；
        # 插件自带面板没法保证有标题栏，给它保留系统边框，否则用户关不掉窗口。
        frameless = "0" if bot.plugins.panel_dir(name) is not None else "1"
        command = launch_command(
            id_of_root(config.paths.root),
            ["--plugin-window", name, "--plugin-frameless", frameless],
        )
        allow_child_foreground()
        try:
            subprocess.Popen(command, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError as exc:
            return JSONResponse({"ok": False, "error": f"拉起窗口失败: {exc}"}, status_code=500)
        return {"ok": True}

    # ---------- 插件市场（本地市场目录：data/plugin_market/*.zip + *.json） ----------

    @app.get("/api/plugins/market/list")
    async def market_list() -> dict[str, Any]:
        """列出市场可用插件及安装状态。"""
        market_dir = config.paths.data_dir / "plugin_market"
        items = []
        if market_dir.is_dir():
            for meta_file in sorted(market_dir.glob("*.json")):
                try:
                    meta = json.loads(meta_file.read_text("utf-8"))
                except Exception:  # noqa: BLE001
                    continue
                name = str(meta.get("name") or meta_file.stem)
                zip_file = market_dir / (name + ".zip")
                items.append({
                    "name": name,
                    "display": meta.get("display") or name,
                    "description": meta.get("description") or "",
                    "version": meta.get("version") or "1.0.0",
                    "zip_exists": zip_file.exists(),
                    "size": zip_file.stat().st_size if zip_file.exists() else 0,
                    "installed": name in bot.plugins.plugins,
                    "disabled": name in bot.plugins.disabled_plugins(),
                })
        return {"ok": True, "items": items}

    @app.post("/api/plugins/market/install")
    async def market_install(payload: dict[str, Any] = Body(...)) -> Any:
        """从市场安装插件：读取本地 zip → 子进程自检 → 通过才热加载。"""
        # 市场包来自服务器本地受控目录（data/plugin_market），
        # 不是任意上传代码，因此不适用「无密码公网禁止导入」的拦截。
        from ..instances import id_of_root
        from ..plugins.importer import PluginImportError, install_plugin

        name = str(payload.get("name") or "").strip()
        if not name:
            return JSONResponse({"ok": False, "error": "缺少插件名"}, status_code=400)
        market_dir = config.paths.data_dir / "plugin_market"
        zip_file = market_dir / (name + ".zip")
        if not zip_file.is_file():
            return JSONResponse({"ok": False, "error": "市场里没有该插件包"}, status_code=404)
        data = zip_file.read_bytes()
        try:
            report = await asyncio.to_thread(
                install_plugin,
                plugin_dir=config.paths.plugin_dir,
                filename=zip_file.name,
                data=data,
                confirm=True,
                instance_id=id_of_root(config.paths.root),
                actor="插件市场",
                audit_file=plugin_audit_file,
            )
        except PluginImportError as exc:
            log.warning("市场插件安装被拒绝（%s）：%s", name, str(exc).splitlines()[0])
            return JSONResponse(
                {"ok": False, "error": str(exc), "steps": exc.steps}, status_code=400
            )
        entry = str(report.get("installed_entry") or "")
        await bot.plugins.rescan_external(force=entry)
        loaded = [
            n for n, r in bot.plugins.plugins.items() if r.path == entry
        ]
        return {"ok": True, **report, "loaded": loaded}

    # ---------- 自定义插件导入（上传 → 子进程自检 → 通过才安装） ----------

    plugin_audit_file = config.paths.data_dir / "plugin_import.log"

    def _import_blocked_reason() -> str | None:
        """返回拒绝导入的原因；None 表示放行。

        已设访问密码时，本接口和其它 /api 一样要登录后才可达；没设密码却把
        面板挂在公网地址上则是「任何人可远程装任意代码」，必须直接拒掉。
        """
        if not auth_password and config.webui.host not in ("127.0.0.1", "localhost", "::1"):
            return (
                "面板没有设置访问密码，却监听在公网地址上，为安全起见已禁止导入插件。"
                "请先在「连接设置」里设置访问密码。"
            )
        return None

    @app.post("/api/plugins/import")
    async def import_plugin_endpoint(payload: dict[str, Any] = Body(...)) -> Any:
        """导入自定义插件。

        流程：解码上传内容 → 独立子进程里「试加载 + on_load + 插件自检」→
        全部通过才落盘并热加载；任一步失败都会把具体报错和每一步的结果回给前端，
        不写入任何文件。
        """
        reason = _import_blocked_reason()
        if reason:
            return JSONResponse({"ok": False, "error": reason}, status_code=403)

        filename = str(payload.get("filename") or "").strip()
        raw = str(payload.get("content") or "")
        if not filename or not raw:
            return JSONResponse({"ok": False, "error": "缺少文件名或文件内容"}, status_code=400)
        try:
            data = base64.b64decode(raw, validate=False)
        except Exception:  # noqa: BLE001
            return JSONResponse({"ok": False, "error": "上传内容不是合法的 base64"}, status_code=400)

        from ..instances import id_of_root
        from ..plugins.importer import PluginImportError, install_plugin

        try:
            report = await asyncio.to_thread(
                install_plugin,
                plugin_dir=config.paths.plugin_dir,
                filename=filename,
                data=data,
                confirm=bool(payload.get("confirm")),
                instance_id=id_of_root(config.paths.root),
                actor="面板",
                audit_file=plugin_audit_file,
            )
        except PluginImportError as exc:
            # 报错正文可能带整段 traceback（要展示给用户），日志里只留第一行
            log.warning("插件导入被拒绝（%s）：%s", filename, str(exc).splitlines()[0])
            return JSONResponse(
                {"ok": False, "error": str(exc), "steps": exc.steps}, status_code=400
            )

        entry = str(report.get("installed_entry") or "")
        await bot.plugins.rescan_external(force=entry)
        loaded = [
            name for name, record in bot.plugins.plugins.items() if record.path == entry
        ]
        return {"ok": True, **report, "loaded": loaded}

    # ---------- 插件自带控制面板 ----------

    @app.get("/plugin-panel/{name}", response_class=HTMLResponse)
    async def plugin_panel_page(name: str) -> Any:
        """展示插件自带面板；没有自带面板就回退到通用设置页。"""
        directory = bot.plugins.panel_dir(name)
        if directory is None:
            from urllib.parse import quote

            return RedirectResponse(f"/static/plugin.html?name={quote(name)}", status_code=303)
        page = directory / "panel.html"
        try:
            return HTMLResponse(page.read_text("utf-8"))
        except OSError as exc:
            return HTMLResponse(f"<h1>读取插件面板失败</h1><p>{exc}</p>", status_code=500)

    @app.get("/plugin-panel/{name}/assets/{asset:path}")
    async def plugin_panel_asset(name: str, asset: str) -> Any:
        """插件自带面板的静态资源（包内 ``assets/`` 目录）。"""
        directory = bot.plugins.panel_dir(name)
        if directory is None:
            return JSONResponse({"ok": False, "error": "插件没有自带面板"}, status_code=404)
        base = (directory / "assets").resolve()
        target = (base / asset).resolve()
        if target != base and base not in target.parents:
            return JSONResponse({"ok": False, "error": "非法资源路径"}, status_code=400)
        if not target.is_file():
            return JSONResponse({"ok": False, "error": "资源不存在"}, status_code=404)
        return Response(target.read_bytes(), media_type=_guess_media_type(target))

    # ---------- AI 模型仓库与探测 ----------

    def _ai_credentials(payload: dict[str, Any]) -> tuple[str, str, int]:
        base_url = str(payload.get("base_url") or config.ai.base_url or "")
        api_key = payload.get("api_key")
        if api_key is None:
            api_key = config.ai.api_key
        timeout = int(payload.get("probe_timeout") or config.ai.probe_timeout or 5000)
        return base_url, str(api_key or ""), max(200, timeout)

    def _ai_paths(payload: dict[str, Any]) -> tuple[str, str]:
        """自定义协议里的模型列表路径与对话路径。"""
        models_path = str(payload.get("models_path") or config.ai.models_path or "")
        chat_path = str(payload.get("chat_path") or config.ai.chat_path or "")
        return models_path, chat_path

    @app.post("/api/ai/models")
    async def ai_fetch_models(payload: dict[str, Any] = Body(...)) -> Any:
        """拉取模型仓库列表（默认 GET /models，不消耗 token）。"""
        from ..ai.probe import fetch_models

        base_url, api_key, timeout = _ai_credentials(payload)
        models_path, _ = _ai_paths(payload)
        try:
            models = await fetch_models(base_url, api_key, timeout, models_path)
        except Exception as exc:  # noqa: BLE001
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=502)

        now = time.time()
        for model in models:
            # 保留已有探测结果，仅把新模型登记为「待探测」
            config.ai.model_status.setdefault(
                model, {"ok": None, "latency_ms": None, "error": "", "ts": now}
            )
        config.save()
        return {"ok": True, "models": models, "status": config.ai.model_status}

    @app.post("/api/ai/register")
    async def ai_register(payload: dict[str, Any] = Body(...)) -> Any:
        """手动登记模型名。

        部分服务商（如火山方舟的部分接入点）不提供 /models 列表接口，
        允许用户自己把模型名加进待探测列表。
        """
        names = [str(m).strip() for m in (payload.get("models") or []) if str(m).strip()]
        if not names:
            return JSONResponse({"ok": False, "error": "请填写要添加的模型名"}, status_code=400)
        now = time.time()
        for model in names:
            config.ai.model_status.setdefault(
                model, {"ok": None, "latency_ms": None, "error": "", "ts": now}
            )
        config.save()
        return {"ok": True, "status": config.ai.model_status}

    @app.post("/api/ai/probe")
    async def ai_probe(payload: dict[str, Any] = Body(...)) -> Any:
        """逐个轻量探测模型（max_tokens=1）。scope=all 全量 / unavailable 仅不可用。"""
        from ..ai.probe import probe_models

        base_url, api_key, timeout = _ai_credentials(payload)
        _, chat_path = _ai_paths(payload)
        scope = str(payload.get("scope") or "all")
        models = [str(m) for m in (payload.get("models") or []) if m]
        if not models:
            status = config.ai.model_status or {}
            if scope == "unavailable":
                models = [m for m, v in status.items() if isinstance(v, dict) and v.get("ok") is False]
            else:
                models = list(status)
        if not models:
            return JSONResponse(
                {"ok": False, "error": "没有可探测的模型，请先拉取模型列表"},
                status_code=400,
            )

        results = await probe_models(base_url, api_key, models, timeout, path=chat_path)
        now = time.time()
        for model, result in results.items():
            config.ai.model_status[model] = {**result, "ts": now}
        config.save()
        return {"ok": True, "results": results, "status": config.ai.model_status}

    # ---------- 群聊知识库 ----------

    @app.get("/api/kb/overview")
    async def kb_overview() -> Any:
        """知识库总览：已建库的群 + 机器人所在群列表（供选择）。"""
        bot_groups: list[dict[str, Any]] = []
        try:
            # QQ 未登录时 OneBot 调用会一直挂着，这里限时，避免卡住整个面板
            resp = await asyncio.wait_for(bot.get_group_list(), timeout=4)
            items = resp.get("data") if isinstance(resp, dict) else None
            if not isinstance(items, list):
                items = []
            for item in items:
                if not isinstance(item, dict):
                    continue
                bot_groups.append(
                    {
                        "group_id": item.get("group_id"),
                        "group_name": item.get("group_name") or "",
                    }
                )
        except Exception as exc:  # noqa: BLE001 - 未连接时拿不到群列表
            log.warning("获取群列表失败: %s", exc)
        return {
            "ok": True,
            "groups": bot.kb.groups(),
            "bot_groups": bot_groups,
            "stats": bot.kb.stats(),
        }

    @app.get("/api/kb/docs")
    async def kb_list(group_id: int = 0) -> Any:
        return {"ok": True, "docs": bot.kb.list_docs(group_id)}

    @app.post("/api/kb/docs")
    async def kb_add(payload: dict[str, Any] = Body(...)) -> Any:
        group_id = int(payload.get("group_id") or 0)
        content = str(payload.get("content") or "").strip()
        if not group_id or not content:
            return JSONResponse({"ok": False, "error": "请填写群号与内容"}, status_code=400)
        doc_id = bot.kb.add(
            group_id, content, str(payload.get("title") or ""), str(payload.get("tags") or "")
        )
        return {"ok": True, "id": doc_id}

    @app.put("/api/kb/docs/{doc_id}")
    async def kb_update(doc_id: int, payload: dict[str, Any] = Body(...)) -> Any:
        ok = bot.kb.update(
            doc_id,
            str(payload.get("title") or ""),
            str(payload.get("content") or ""),
            str(payload.get("tags") or ""),
        )
        return {"ok": ok}

    @app.delete("/api/kb/docs/{doc_id}")
    async def kb_delete(doc_id: int) -> Any:
        return {"ok": bot.kb.delete(doc_id)}

    @app.delete("/api/kb/group/{group_id}")
    async def kb_clear_group(group_id: int) -> Any:
        return {"ok": True, "deleted": bot.kb.delete_group(group_id)}

    @app.post("/api/kb/import")
    async def kb_import(payload: dict[str, Any] = Body(...)) -> Any:
        """批量导入：把整篇文档按空行切块后入库。"""
        from ..knowledge import split_chunks

        group_id = int(payload.get("group_id") or 0)
        text = str(payload.get("text") or "")
        if not group_id or not text.strip():
            return JSONResponse({"ok": False, "error": "请填写群号与文档内容"}, status_code=400)
        chunks = split_chunks(text)
        if not chunks:
            return JSONResponse({"ok": False, "error": "没有可导入的内容"}, status_code=400)
        count = bot.kb.add_many(
            group_id,
            [{"title": title, "content": content} for title, content in chunks],
        )
        return {"ok": True, "count": count}

    @app.post("/api/kb/search")
    async def kb_search(payload: dict[str, Any] = Body(...)) -> Any:
        """检索测试：不调用模型，仅本地关键词检索（0 token）。"""
        group_id = int(payload.get("group_id") or 0)
        query = str(payload.get("query") or "")
        top_k = int(payload.get("top_k") or config.knowledge.top_k)
        hits = bot.kb.search(group_id, query, top_k) if query.strip() else []
        return {
            "ok": True,
            "hits": [
                {"id": doc.get("id"), "title": doc.get("title"), "content": doc.get("content"),
                 "score": round(score, 3)}
                for doc, score in hits
            ],
            "context": bot.kb.context_for(group_id, query, top_k, config.knowledge.max_chars)
            if query.strip()
            else "",
        }

    # ---------- 长期记忆库 ----------

    @app.get("/api/memory/overview")
    async def memory_overview() -> Any:
        """记忆库总览：已有的作用域清单 + 机器人所在群列表（供选择）。"""
        bot_groups: list[dict[str, Any]] = []
        try:
            # QQ 未登录时 OneBot 调用会一直挂着，这里限时，避免卡住整个面板
            resp = await asyncio.wait_for(bot.get_group_list(), timeout=4)
            items = resp.get("data") if isinstance(resp, dict) else None
            if not isinstance(items, list):
                items = []
            for item in items:
                if not isinstance(item, dict):
                    continue
                bot_groups.append(
                    {
                        "group_id": item.get("group_id"),
                        "group_name": item.get("group_name") or "",
                    }
                )
        except Exception as exc:  # noqa: BLE001 - 未连接时拿不到群列表
            log.warning("获取群列表失败: %s", exc)
        return {
            "ok": True,
            "groups": bot.memory.groups(),
            "users": bot.memory.users(),
            "bot_groups": bot_groups,
            "stats": bot.memory.stats(),
        }

    @app.get("/api/memory")
    async def memory_list(scope: str = "", group_id: int = 0, user_id: int = 0) -> Any:
        return {
            "ok": True,
            "memories": bot.memory.list(scope, group_id, user_id),
        }

    @app.post("/api/memory")
    async def memory_add(payload: dict[str, Any] = Body(...)) -> Any:
        try:
            mem_id = bot.memory.add(
                str(payload.get("content") or ""),
                str(payload.get("scope") or "group"),
                int(payload.get("group_id") or 0),
                int(payload.get("user_id") or 0),
                "panel",
            )
        except ValueError as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        return {"ok": True, "id": mem_id}

    @app.delete("/api/memory/scope")
    async def memory_clear_scope(scope: str = "", group_id: int = 0, user_id: int = 0) -> Any:
        """清空某个作用域；注意必须声明在 /api/memory/{mem_id} 之前，否则会被当成 id。"""
        return {
            "ok": True,
            "deleted": bot.memory.delete_scope(scope, group_id, user_id),
        }

    @app.put("/api/memory/{mem_id}")
    async def memory_update(mem_id: int, payload: dict[str, Any] = Body(...)) -> Any:
        scope = payload.get("scope")
        ok = bot.memory.update(
            mem_id,
            None if payload.get("content") is None else str(payload.get("content")),
            None if scope is None else str(scope),
            None if payload.get("group_id") is None else int(payload.get("group_id") or 0),
            None if payload.get("user_id") is None else int(payload.get("user_id") or 0),
        )
        if ok and payload.get("enabled") is not None:
            bot.memory.set_enabled(mem_id, bool(payload.get("enabled")))
        return {"ok": ok}

    @app.delete("/api/memory/{mem_id}")
    async def memory_delete(mem_id: int) -> Any:
        return {"ok": bot.memory.delete(mem_id)}

    @app.post("/api/memory/preview")
    async def memory_preview(payload: dict[str, Any] = Body(...)) -> Any:
        """预览某场景下会被注入系统提示的记忆文本（本地拼接，不调用模型）。"""
        return {
            "ok": True,
            "text": await bot.memory_context(
                int(payload.get("group_id") or 0), int(payload.get("user_id") or 0)
            ),
        }

    # ---------- 白话群管 ----------

    @app.get("/api/admin-nl")
    async def admin_nl_info() -> Any:
        """能力清单 + 每条能力的默认权限（前端权限表格用）。

        接口目录里的动作会带上中文名（label）与是否只读，面板据此优先显示中文，
        原始动作名只作为小标签保留，方便对照接口文档。
        """
        from ..ai.api_catalog import BY_NAME
        from ..plugins.builtin.admin_nl import (
            ACTIONS, ACTION_LABELS, ACTION_LEVELS, LEVEL_LABEL,
            action_pattern, action_usage,
        )

        custom = getattr(config.admin_nl, "custom_words", {}) or {}
        actions: list[dict[str, Any]] = []
        for key, text in ACTIONS.items():
            if key == "none":
                continue
            spec = BY_NAME.get(key)
            word = str(custom.get(key) or "").strip()
            actions.append({
                "action": key,
                "label": (spec.label if spec is not None else ACTION_LABELS.get(key, "")),
                "read_only": bool(spec.read_only) if spec is not None else False,
                "description": text,
                "default_level": ACTION_LEVELS.get(key, "admin"),
                # 面板上的「?」：正确说法 + 参数；自定义理解词决定「完整句式」
                "syntax": action_usage(key),
                "custom_word": word,
                "pattern": action_pattern(key, word),
                "params": (
                    [
                        {"name": name, "desc": desc, "required": name in spec.required}
                        for name, desc in spec.params.items()
                    ]
                    if spec is not None else []
                ),
            })
        return {
            "ok": True,
            "actions": actions,
            "levels": [{"value": v, "label": t} for v, t in LEVEL_LABEL.items()],
        }

    # ---------- 全能动作 ----------

    omni_store = OmniStore(config.paths.data_dir)

    def omni_view(rule: dict[str, Any]) -> dict[str, Any]:
        return {
            **rule,
            "trigger_label": trigger_label(rule.get("trigger") or {}),
            "summary": action_summary(rule.get("actions") or []),
        }

    @app.get("/api/omni")
    async def omni_overview() -> Any:
        rules = await asyncio.to_thread(omni_store.list)
        return {
            "ok": True,
            "rules": [omni_view(rule) for rule in rules],
            "triggers": [
                {"value": key, "label": label, "help": TRIGGER_HELP.get(key, "")}
                for key, label in TRIGGER_TYPES.items()
            ],
            "actions": [{"value": key, "label": label} for key, label in ACTION_TYPES.items()],
            "modes": [{"value": key, "label": label} for key, label in MATCH_MODES.items()],
            "scopes": [{"value": key, "label": label} for key, label in SCOPES.items()],
            "ai": bool(config.ai.enabled),
        }

    @app.post("/api/omni/parse")
    async def omni_parse(payload: dict[str, Any] = Body(...)) -> Any:
        """把一句话或表单里的白话动作交给模型整理成规则；save=true 时直接落盘。"""
        text = str(payload.get("text") or "").strip()
        action_text = str(payload.get("action_text") or "").strip()
        trigger = payload.get("trigger")
        if not isinstance(trigger, dict):
            trigger = None
        try:
            rule = await ai_plan(bot, text, trigger, action_text)
        except Exception as exc:  # noqa: BLE001
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        if payload.get("name"):
            rule["name"] = str(payload["name"]).strip()[:40] or rule["name"]
        rule["enabled"] = bool(payload.get("enabled", True))
        if payload.get("save"):
            try:
                await asyncio.to_thread(omni_store.upsert, rule)
            except OSError as exc:
                return JSONResponse({"ok": False, "error": f"保存失败：{exc}"}, status_code=500)
        return {"ok": True, "rule": omni_view(rule)}

    @app.post("/api/omni/rules")
    async def omni_create(payload: dict[str, Any] = Body(...)) -> Any:
        rule = normalize_rule(payload)
        problem = validate_rule(rule)
        if problem:
            return JSONResponse({"ok": False, "error": problem}, status_code=400)
        await asyncio.to_thread(omni_store.upsert, rule)
        return {"ok": True, "rule": omni_view(rule)}

    @app.put("/api/omni/rules/{rule_id}")
    async def omni_update(rule_id: str, payload: dict[str, Any] = Body(...)) -> Any:
        old = await asyncio.to_thread(omni_store.get, rule_id)
        if not old:
            return JSONResponse({"ok": False, "error": "规则不存在"}, status_code=404)
        rule = normalize_rule(payload, old)
        rule["id"] = rule_id
        problem = validate_rule(rule)
        if problem:
            return JSONResponse({"ok": False, "error": problem}, status_code=400)
        await asyncio.to_thread(omni_store.upsert, rule)
        return {"ok": True, "rule": omni_view(rule)}

    @app.delete("/api/omni/rules/{rule_id}")
    async def omni_delete(rule_id: str) -> Any:
        removed = await asyncio.to_thread(omni_store.delete, rule_id)
        return {"ok": removed, "error": "" if removed else "规则不存在"}

    # ---------- 语音合成试听 ----------

    @app.get("/api/tts/voices")
    async def tts_voices() -> Any:
        """内置的豆包语音合成 2.0 官方音色清单（省得去控制台翻 ID）。"""
        from ..ai.voices import CONSOLE_URL, list_voices

        return {"ok": True, "voices": list_voices(), "console_url": CONSOLE_URL}

    @app.post("/api/tts/voices/probe")
    async def tts_probe_voices(payload: dict[str, Any] = Body(...)) -> Any:
        """依次试几个候选音色，返回真正能出声的那些。

        音色必须与资源（如 seed-tts-2.0）匹配，挨个试比自己猜快得多。
        """
        import asyncio as _asyncio

        from ..ai.tts import synthesize
        from ..ai.voices import candidate_ids

        preview = copy(config.tts)
        for key, value in (payload or {}).items():
            if hasattr(preview, key) and value not in (None, ""):
                setattr(preview, key, value)

        limit = max(1, min(int(payload.get("limit") or 8), 20))
        candidates = candidate_ids()[:limit]
        working: list[str] = []
        errors: list[dict[str, str]] = []

        for voice in candidates:
            probe = copy(preview)
            probe.voice = voice
            try:
                await synthesize(probe, config.ai, "你好")
            except Exception as exc:  # noqa: BLE001
                errors.append({"voice": voice, "error": str(exc)[:120]})
                await _asyncio.sleep(0.1)
                continue
            working.append(voice)
            if len(working) >= 3:
                break

        return {"ok": True, "working": working, "tried": len(working) + len(errors),
                "errors": errors[:5]}

    @app.post("/api/tts/preview")
    async def tts_preview(payload: dict[str, Any] = Body(...)) -> Any:
        """按当前音色配置合成一段示例语音，供试听确认。"""
        from ..ai.tts import synthesize

        preview = copy(config.tts)
        for key, value in (payload or {}).items():
            if hasattr(preview, key) and value not in (None, ""):
                setattr(preview, key, value)
        text = str(payload.get("text") or preview.sample_text or "").strip()
        if not text:
            return JSONResponse({"ok": False, "error": "试听文本不能为空"}, status_code=400)

        try:
            data, fmt = await synthesize(preview, config.ai, text)
        except Exception as exc:  # noqa: BLE001
            message = str(exc)
            if "404" in message:
                message += (
                    "（这个接口地址下没有 /audio/speech，说明该服务商可能不支持"
                    " OpenAI 兼容的语音合成，请换成支持的服务商或单独的 TTS 接口地址）"
                )
            return JSONResponse({"ok": False, "error": message}, status_code=502)

        media = {
            "mp3": "audio/mpeg", "wav": "audio/wav", "opus": "audio/opus",
            "aac": "audio/aac", "flac": "audio/flac",
        }.get(fmt.lower(), "application/octet-stream")
        return Response(content=data, media_type=media, headers={"Cache-Control": "no-store"})

    # ---------- 表情包 ----------

    @app.get("/api/stickers")
    async def sticker_list() -> Any:
        return {
            "ok": True,
            "stickers": [
                {"id": i["id"], "name": i.get("name", ""), "tags": i.get("tags") or [],
                 "size": i.get("size", 0)}
                for i in bot.stickers.list()
            ],
            "stats": bot.stickers.stats(),
        }

    @app.get("/api/stickers/{sticker_id}/raw")
    async def sticker_raw(sticker_id: str) -> Any:
        """把表情包原图回给面板做预览。"""
        item = next((i for i in bot.stickers.list() if i["id"] == sticker_id), None)
        if item is None:
            return JSONResponse({"ok": False, "error": "表情包不存在"}, status_code=404)
        path = bot.stickers.path_of(item)
        import mimetypes

        media = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        return Response(content=path.read_bytes(), media_type=media)

    @app.post("/api/stickers")
    async def sticker_add(payload: dict[str, Any] = Body(...)) -> Any:
        """导入表情包：图片以 base64 提交，避免额外依赖 multipart。"""
        import base64
        import binascii

        raw = str(payload.get("data") or "")
        if "," in raw[:80]:  # 兼容 data:image/png;base64,xxxx 形式
            raw = raw.split(",", 1)[1]
        try:
            blob = base64.b64decode(raw)
        except (binascii.Error, ValueError):
            return JSONResponse({"ok": False, "error": "图片数据不是合法的 base64"}, status_code=400)
        try:
            item = bot.stickers.add(str(payload.get("name") or ""), blob, payload.get("tags"))
        except ValueError as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        return {"ok": True, "sticker": {"id": item["id"], "name": item["name"], "tags": item["tags"]}}

    @app.put("/api/stickers/{sticker_id}")
    async def sticker_update(sticker_id: str, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        ok = bot.stickers.update_tags(sticker_id, payload.get("tags"))
        return {"ok": ok}

    @app.delete("/api/stickers/{sticker_id}")
    async def sticker_delete(sticker_id: str) -> dict[str, Any]:
        return {"ok": bot.stickers.delete(sticker_id)}

    # ---------- 开机自启 ----------

    @app.get("/api/autostart")
    async def get_autostart() -> dict[str, Any]:
        if sys.platform != "win32":
            return {"enabled": True, "managed": "systemd"}
        from ..tray.autostart import is_enabled

        return {"enabled": is_enabled()}

    @app.post("/api/autostart")
    async def set_autostart(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        if sys.platform != "win32":
            return {
                "ok": True,
                "enabled": True,
                "managed": "systemd",
                "note": "Linux 由 systemd 管理开机自启",
            }
        from ..tray.autostart import ensure_autostart

        enabled = bool(payload.get("enabled"))
        ok = ensure_autostart(enabled)
        config.tray.autostart = enabled
        config.save()
        return {"ok": ok, "enabled": enabled}

    # ---------- 日志 ----------

    @app.get("/api/logs")
    async def get_logs(limit: int = 200) -> dict[str, Any]:
        return {"lines": recent_logs(limit)}

    # ---------- QQ 登录（NapCat WebUI 代理） ----------

    def _conflicting_instances() -> list[str]:
        """除自己以外还在运行的实例名（用来解释「网关为什么起不来」）。"""
        try:
            from ..instances import other_running

            return other_running(config.paths.root)
        except Exception:  # noqa: BLE001
            return []

    def _qq_error(exc: NapCatError) -> JSONResponse:
        """把网关连不上的真实原因讲清楚，并给出下一步该做什么。

        多开时最常见的原因就是：另一个实例正占着 QQ，本实例的网关起不来。
        只回一句「无法连接网关」用户会一头雾水，所以这里把该怎么做一并说明。
        """
        from ..gateway import qq_profile, _qq_exe_from_registry

        qq_exe = _qq_exe_from_registry() if sys.platform == "win32" else None
        others = _conflicting_instances()
        if sys.platform == "win32" and qq_exe is None:
            message = (
                "没有检测到腾讯 QQ。安装包本身已经内置 NapCat，不需要另外安装 NapCat；"
                "请先安装 Windows 版 QQ（QQ NT），装好后点「重启网关」，再回到这里扫码。"
            )
        elif others and qq_profile(config) is None:
            message = (
                f"本机已有另一个机器人在运行（{'、'.join(others)}），它正占着 QQ。"
                "要跟它同时在线，请到本实例的「连接设置」里打开「多开网关」"
                "（会给本实例单独起一个 QQ，就能各登各的号）；"
                "或者先退出那个机器人（托盘图标右键 → 退出），本实例再接管 QQ。"
            )
        else:
            message = f"QQ 网关还没起来：{exc}"
        return JSONResponse({"ok": False, "error": message}, status_code=503)

    @app.get("/api/qq/status")
    async def qq_status() -> Any:
        """登录状态 + 已登录账号信息（已登录时）。"""
        try:
            status = await napcat.check_login_status()
        except NapCatError as exc:
            return _qq_error(exc)
        info: dict[str, Any] = {}
        if status.get("isLogin"):
            try:
                info = await napcat.login_info()
            except NapCatError:
                info = {}
        return {"ok": True, "status": status, "info": info}

    @app.get("/api/qq/qrcode.svg")
    async def qq_qrcode(refresh: bool = False) -> Any:
        """二维码 SVG。已登录时返回 204，前端据此切到「已登录」态。"""
        try:
            status = await napcat.check_login_status()
        except NapCatError as exc:
            return _qq_error(exc)
        if status.get("isLogin"):
            return Response(status_code=204)

        try:
            url = await napcat.refresh_qrcode() if refresh else await napcat.get_qrcode()
        except NapCatError as exc:
            return _qq_error(exc)
        if not url:
            # 部分 NapCat 版本 GetQQLoginQrcode 返回空，但状态接口里已经带二维码内容
            url = str(status.get("qrcodeurl") or "")
        if not url:
            # 注意：这里绝不能返回 204。前端把 204 当成「已登录」，
            # 而鉴权失败/网关重启时同样拿不到二维码，于是就会误报「已登录」。
            return JSONResponse(
                {
                    "ok": False,
                    "error": "暂时拿不到登录二维码，网关可能正在重启或鉴权失败，请稍后重试",
                },
                status_code=503,
            )
        svg = await asyncio.to_thread(qrcode_svg, url)
        return Response(content=svg, media_type="image/svg+xml", headers={"Cache-Control": "no-store"})

    @app.get("/api/qq/accounts")
    async def qq_accounts() -> Any:
        """免密登录账号列表。"""
        try:
            accounts = await napcat.quick_login_list()
        except NapCatError as exc:
            return _qq_error(exc)
        return {"ok": True, "accounts": accounts}

    @app.post("/api/qq/quicklogin")
    async def qq_quicklogin(payload: dict[str, Any] = Body(...)) -> Any:
        """使用免密账号一键登录。"""
        uin = str(payload.get("uin") or "").strip()
        if not uin:
            return JSONResponse({"ok": False, "error": "缺少 uin"}, status_code=400)
        try:
            ok = await napcat.set_quick_login(uin)
        except NapCatError as exc:
            return _qq_error(exc)
        if not ok:
            return JSONResponse(
                {"ok": False, "error": "免密登录失败，可点「修复免密登录」后重试"},
                status_code=400,
            )
        return {"ok": True}

    @app.post("/api/qq/passwordlogin")
    async def qq_passwordlogin(payload: dict[str, Any] = Body(...)) -> Any:
        """账号密码登录（交给 NapCat 的 PasswordLogin 接口）。"""
        import hashlib

        uin = str(payload.get("uin") or "").strip()
        password = str(payload.get("password") or "")
        password_md5 = str(payload.get("passwordMd5") or "").strip().lower()
        if not uin.isdigit():
            return JSONResponse({"ok": False, "error": "请填写正确的 QQ 号"}, status_code=400)
        if not password_md5:
            if not password:
                return JSONResponse({"ok": False, "error": "请填写密码"}, status_code=400)
            password_md5 = hashlib.md5(password.encode("utf-8")).hexdigest()
        try:
            data = await napcat.password_login(uin, password_md5)
        except NapCatError as exc:
            return _qq_error(exc)
        if data.get("code") != 0:
            message = str(data.get("message") or "")
            if "QQ Is Logined" in message:
                message = "已经登录了，不用再登一次"
            elif "uin is empty" in message or "passwordMd5 is empty" in message:
                message = "账号或密码没填完整"
            return JSONResponse(
                {"ok": False, "error": message or "账号密码登录失败"},
                status_code=400,
            )
        # 把 MD5 回给前端，勾了「记住账号密码」时下次可凭它直接登录
        return {
            "ok": True,
            "data": data.get("data") or {},
            "uin": uin,
            "passwordMd5": password_md5,
        }

    @app.post("/api/qq/repair")
    async def qq_repair(payload: dict[str, Any] | None = Body(None)) -> Any:
        """修复免密登录：重启网关后，带上 uin 的话再自动重试一次。"""
        from ..gateway import GatewayController

        uin = str((payload or {}).get("uin") or "").strip()
        try:
            ok = await napcat.restart()
        except NapCatError as exc:
            log.warning("NapCat 重启失败：%s", exc)
            ok = False
        if not ok:
            ok = await GatewayController(config).restart()
        retried = False
        if ok and uin:
            # 网关重启后需要一点时间才接受登录请求
            await asyncio.sleep(3)
            try:
                retried = await napcat.set_quick_login(uin)
            except NapCatError as exc:
                log.warning("免密登录重试失败：%s", exc)
                retried = False
        return {"ok": bool(ok), "retried": retried, "uin": uin}

    @app.post("/api/qq/restart")
    async def qq_restart() -> Any:
        """重启网关。

        - OneBot 端口没起来（常见于「刚换了账号」）：必须让网关**完整**重启一遍，
          它才会重新读进配置、开出 OneBot 端口。这一步在后台跑，不阻塞请求。
        - 端口正常：只是让 NapCat 自己重启一下。
        """
        from ..gateway import GatewayController

        gateway = GatewayController(config)

        async def full_restart() -> None:
            try:
                ok = await gateway.restart()
                log.info("完整重启网关结束：%s", "成功" if ok else "未成功")
            except Exception as exc:  # noqa: BLE001
                log.warning("完整重启网关失败: %s", exc)

        if not await gateway.port_ready():
            others = _conflicting_instances()
            from ..gateway import qq_profile

            if others and qq_profile(config) is None:
                return JSONResponse(
                    {
                        "ok": False,
                        "error": (
                            f"本机已有另一个机器人在运行（{'、'.join(others)}），它正占着 QQ。"
                            "请先退出它（托盘图标右键 → 退出）再重试；"
                            "想跟它同时在线，请到「连接设置」打开「多开网关」。"
                        ),
                    },
                    status_code=409,
                )
            asyncio.create_task(full_restart())
            return {
                "ok": True,
                "note": "正在完整重启网关（约十几秒），登录页会自动刷新；"
                "本实例的 QQ 会一起重启，登录态保存在它自己的数据目录里",
            }

        try:
            ok = await napcat.restart()
        except NapCatError:
            ok = False
        if ok:
            return {"ok": True}

        others = _conflicting_instances()
        if others:
            return JSONResponse(
                {
                    "ok": False,
                    "error": (
                        f"本机已有另一个机器人在运行（{'、'.join(others)}），它正占着 QQ。"
                        "请先退出它（托盘图标右键 → 退出）再重试；"
                        "想跟它同时在线，请到「连接设置」打开「多开网关」。"
                    ),
                },
                status_code=409,
            )

        from ..gateway import GatewayController

        gateway = GatewayController(config)

        async def bring_up() -> None:
            try:
                ready = await gateway.ensure_ready(interactive=False)
                log.info("拉起网关结束：%s", "已就绪" if ready else "未就绪")
            except Exception as exc:  # noqa: BLE001
                log.warning("拉起网关失败: %s", exc)

        asyncio.create_task(bring_up())
        return {"ok": True, "note": "正在拉起网关，十几秒后登录页会自动刷新；若仍连不上请先关闭 QQ"}

    # ---------- 多实例（多开） ----------

    def _instance_error(exc: ValueError) -> JSONResponse:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    @app.get("/api/instances")
    async def instances_list() -> Any:
        """列出所有实例：默认实例 + instances/ 下的独立实例。"""
        return {
            "ok": True,
            "current": current_id,
            "exports_dir": str(inst.exports_dir()),
            "instances": inst.list_instances(),
        }

    @app.post("/api/instances")
    async def instances_create(payload: dict[str, Any] = Body(...)) -> Any:
        """新建实例：继承当前实例的设置（AI / 人格 / 管理员等），端口自动错开。"""
        name = str(payload.get("name") or "").strip()
        try:
            item = inst.create_instance(name, base_config=config.to_dict())
        except ValueError as exc:
            return _instance_error(exc)
        return {"ok": True, "instance": item}

    @app.post("/api/instances/import")
    async def instances_import(payload: dict[str, Any] = Body(...)) -> Any:
        """导入备份 zip（base64），还原成新实例并自动重分配端口。"""
        import base64
        import binascii

        raw = str(payload.get("data") or "")
        if "," in raw[:80]:  # 兼容 data:application/zip;base64,xxxx
            raw = raw.split(",", 1)[1]
        try:
            blob = base64.b64decode(raw)
        except (binascii.Error, ValueError):
            return JSONResponse({"ok": False, "error": "备份数据不是合法的 base64"}, status_code=400)
        try:
            item = inst.import_zip(blob, str(payload.get("name") or "").strip())
        except ValueError as exc:
            return _instance_error(exc)
        return {"ok": True, "instance": item}

    @app.post("/api/instances/{name}/export")
    async def instances_export(name: str) -> Any:
        """导出实例的配置与数据，直接写成 zip 落到 exe 目录的 exports/ 里。

        不用浏览器下载：面板是内嵌窗口，下载容易「点了没反应、不知道存哪」，
        这里改成后端落盘并回传真实路径，面板再把路径显示出来。
        """
        try:
            info = await asyncio.to_thread(inst.export_to_file, name)
        except ValueError as exc:
            return _instance_error(exc)
        return {"ok": True, **info}

    @app.post("/api/reveal")
    async def reveal_backup(payload: dict[str, Any] = Body(...)) -> Any:
        """在资源管理器里定位备份文件/目录（仅限 exports 目录内）。"""
        try:
            path = await asyncio.to_thread(inst.reveal_path, str(payload.get("path") or ""))
        except (ValueError, OSError) as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        return {"ok": True, "path": path}

    @app.post("/api/instances/{name}/start")
    async def instances_start(name: str) -> Any:
        """以独立进程拉起该实例（自带托盘与面板窗口）。"""
        try:
            item = await asyncio.to_thread(inst.start_instance, name)
        except ValueError as exc:
            return _instance_error(exc)
        return {"ok": True, "instance": item}

    @app.post("/api/instances/{name}/stop")
    async def instances_stop(name: str) -> Any:
        if name == current_id:
            return JSONResponse(
                {"ok": False, "error": "这是你正在使用的实例，请直接关闭它的窗口"},
                status_code=400,
            )
        stopped = await asyncio.to_thread(inst.stop_instance, name)
        if not stopped:
            return JSONResponse({"ok": False, "error": "未找到该实例的进程（可能已经停止）"}, status_code=404)
        return {"ok": True}

    @app.post("/api/instances/{name}/panel")
    async def instances_panel(name: str, request: Request) -> Any:
        """打开指定实例的控制面板窗口（独立进程）。"""
        if sys.platform != "win32":
            info = inst.describe(name)
            port = (info.get("ports") or {}).get("webui") or config.webui.port
            host = request.url.hostname or "127.0.0.1"
            return {"ok": True, "url": f"{request.url.scheme}://{host}:{port}/"}
        try:
            inst.open_panel(name)
        except (OSError, ValueError) as exc:
            return JSONResponse({"ok": False, "error": f"拉起面板失败: {exc}"}, status_code=500)
        return {"ok": True}

    @app.delete("/api/instances/{name}")
    async def instances_delete(name: str) -> Any:
        if name == current_id:
            return JSONResponse(
                {"ok": False, "error": "不能删除正在使用的实例"}, status_code=400
            )
        try:
            await asyncio.to_thread(inst.delete_instance, name)
        except ValueError as exc:
            return _instance_error(exc)
        return {"ok": True}

    # ---------- 测试 ----------

    @app.post("/api/test/message")
    async def inject_message(payload: dict[str, Any] = Body(...)) -> Any:
        inject = getattr(bot.backend, "inject_message", None)
        if inject is None:
            return JSONResponse(
                {"ok": False, "error": "当前协议后端不支持模拟投递（仅 Mock 支持）"},
                status_code=400,
            )
        await inject(
            str(payload.get("text", "")),
            group_id=int(payload.get("group_id") or 90001),
            user_id=int(payload.get("user_id") or 20000),
        )
        return {"ok": True}

    # ---------- 公告与版本 ----------

    @app.get("/api/txgod/announcement")
    async def txgod_announcement() -> dict[str, Any]:
        try:
            data = await asyncio.to_thread(txgod.fetch_announcement)
        except TxgodError as exc:
            return {"ok": False, "error": exc.message, "code": exc.code}
        except Exception as exc:  # noqa: BLE001 - 不让面板因网络问题报 500
            return {"ok": False, "error": f"{type(exc).__name__}: {exc}", "code": 0}
        return {"ok": True, "data": data}

    @app.get("/api/txgod/version")
    async def txgod_version(current: str = APP_VERSION) -> dict[str, Any]:
        try:
            data = await asyncio.to_thread(txgod.check_version, str(current or APP_VERSION))
        except TxgodError as exc:
            return {"ok": False, "error": exc.message, "code": exc.code}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"{type(exc).__name__}: {exc}", "code": 0}
        data["skipped_version"] = txgod.skipped_version
        return {"ok": True, "data": data}

    @app.post("/api/txgod/skip")
    async def txgod_skip(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        version = str(payload.get("version") or "").strip()
        if version:
            await asyncio.to_thread(txgod.remember_skip, version)
        return {"ok": True}

    @app.post("/api/app/open-url")
    async def open_external(payload: dict[str, Any] = Body(...)) -> Any:
        url = str(payload.get("url") or "").strip()
        if not url.lower().startswith(("http://", "https://")):
            return JSONResponse({"ok": False, "error": "只允许打开 http(s) 链接"}, status_code=400)
        # 云端/浏览器环境没有本地桌面，交回前端新开标签页
        if sys.platform != "win32":
            return {"ok": True, "url": url, "external": True}
        try:
            if sys.platform == "win32":
                # 无控制台窗口时 webbrowser 可能找不到默认浏览器，直接交给系统
                os.startfile(url)  # type: ignore[attr-defined]
            else:
                import webbrowser

                webbrowser.open(url)
        except Exception as exc:  # noqa: BLE001
            return JSONResponse({"ok": False, "error": f"打开链接失败: {exc}"}, status_code=500)
        return {"ok": True}

    @app.post("/api/app/quit")
    async def quit_app() -> dict[str, Any]:
        """强制更新时由界面调用：先尽量优雅停止，再彻底退进程。"""

        async def _exit() -> None:
            await asyncio.sleep(0.6)
            try:
                await bot.stop()
            except Exception:  # noqa: BLE001
                pass
            os._exit(0)

        asyncio.create_task(_exit())
        return {"ok": True}

    return app


async def start_webui(bot):
    """在同一事件循环内启动 uvicorn，返回 Server 对象（可用于停止）。"""
    try:
        import uvicorn
    except ImportError:
        log.warning("缺少依赖 uvicorn/fastapi，WebUI 未启动。请执行: pip install fastapi uvicorn")
        return None

    try:
        app = create_app(bot)
    except ImportError:
        log.warning("缺少依赖 fastapi，WebUI 未启动。请执行: pip install fastapi uvicorn")
        return None

    cfg = uvicorn.Config(
        app,
        host=bot.config.webui.host,
        port=bot.config.webui.port,
        log_level="warning",
        log_config=None,  # 复用框架已配置的日志，避免无控制台窗口时写入失败
    )
    server = uvicorn.Server(cfg)
    # 托盘模式下事件循环运行在后台线程，而 uvicorn 在 Windows 上会退回
    # signal.signal() 注册处理器，该方法要求主线程，非主线程会抛 ValueError
    # 导致 serve() 直接失败。这里禁用信号注册（退出由调用方控制）。
    server.install_signal_handlers = lambda: None

    task = asyncio.create_task(server.serve())
    task.add_done_callback(_log_task_failure)
    return server