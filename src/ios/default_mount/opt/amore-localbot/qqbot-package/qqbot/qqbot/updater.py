"""增量更新：安装更新包、读取当前版本、重启进程。

更新包只包含改动过的文件（另带 manifest.json），安装后落在
``data/updates/<版本>/``，启动时由 run.py 交给 qqbot 包优先加载，
因此不必替换体积上百 MB 的 exe。Windows 支持把 zip 直接拖到 exe 上，
Linux 由 /root/gengxin/update.py 处理，Android 走 APK 覆盖安装。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path
from typing import Any

FORMAT = "qqbot-update"
WIN = "win"
LINUX = "linux"

#: 更新包里允许出现的路径前缀（防止覆盖 config/、data/ 等用户数据）
_ALLOWED_PREFIXES = ("qqbot/", "app/mobile/")

#: 单个更新包解压后的体积上限，挡住异常大包/zip 炸弹
_MAX_UNCOMPRESSED = 300 * 1024 * 1024

_VERSION_RE = re.compile(r"^[0-9A-Za-z._-]{1,32}$")


class UpdateError(RuntimeError):
    """更新包不合法或安装失败。"""


# ---------- 路径与版本 ----------


def updates_dir(root: Path) -> Path:
    return Path(root) / "data" / "updates"


def active_info(root: Path) -> dict[str, Any]:
    """读 data/updates/current.json；没有或损坏时返回空字典。"""
    try:
        data = json.loads((updates_dir(root) / "current.json").read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def active_dir(root: Path) -> Path | None:
    """当前生效的代码覆盖目录（未安装过更新时返回 None）。"""
    info = active_info(root)
    version = str(info.get("version") or "")
    if not _VERSION_RE.match(version):
        return None
    path = updates_dir(root) / version
    return path if (path / "qqbot").is_dir() else None


def active_version(root: Path) -> str:
    return str(active_info(root).get("version") or "")


def _version_key(version: str) -> tuple[int, ...]:
    parts = [int(x) for x in re.findall(r"\d+", str(version))[:4]]
    return tuple(parts) or (0,)


def _resource_base(root: Path) -> Path:
    """当前正在使用的静态资源根目录。

    装过一次更新后，静态页面与手机页面已经完整复制到覆盖目录里，
    下一次更新要以它为基线，否则会丢文件。
    """
    current = active_dir(root)
    if current is not None and (current / "qqbot" / "webui" / "static").is_dir():
        return current
    # 源码运行时 qqbot/updater.py 的上一级就是项目根；打包后是 _MEIPASS
    return Path(__file__).resolve().parents[1]


def _notify(title: str, text: str, error: bool = False) -> None:
    """无控制台的 exe 里也要让用户看到更新结果。"""
    if sys.platform == "win32":
        try:
            import ctypes

            flags = 0x10 if error else 0x40  # MB_ICONERROR / MB_ICONINFORMATION
            ctypes.windll.user32.MessageBoxW(None, text, title, flags)
            return
        except Exception:  # noqa: BLE001 - 弹窗失败时退回日志
            pass
    try:
        print(f"[{title}] {text}", flush=True)
    except Exception:  # noqa: BLE001 - 无 stdout 的窗口程序
        pass
    try:
        base = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parents[1]
        log_dir = base / "data" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "update.log").open("a", encoding="utf-8") as fp:
            fp.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{title}] {text}\n")
    except OSError:
        pass


# ---------- 安装 ----------


def _safe_rel(name: str) -> str:
    name = name.replace("\\", "/")
    if not name or name.startswith("/") or ":" in name:
        raise UpdateError(f"更新包里有非法路径：{name}")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise UpdateError(f"更新包里有非法路径：{name}")
    return name


def _allowed(name: str) -> bool:
    return any(name == prefix.rstrip("/") or name.startswith(prefix) for prefix in _ALLOWED_PREFIXES)


def _copy_resources(base: Path, staging: Path) -> None:
    for name in ("qqbot/webui/static", "app/mobile"):
        source = base / name
        if source.is_dir():
            shutil.copytree(source, staging / name, dirs_exist_ok=True)


def install_package(
    root: Path,
    package: Path,
    platform: str = WIN,
    force: bool = False,
) -> dict[str, Any]:
    """校验并安装一个增量更新包，返回新版本信息。

    安装过程先写暂存目录，全部校验通过后才整体替换，失败不会破坏现有版本。
    """
    root = Path(root)
    package = Path(package)
    if not package.is_file():
        raise UpdateError(f"更新包不存在：{package}")

    try:
        bundle = zipfile.ZipFile(package)
    except zipfile.BadZipFile as exc:
        raise UpdateError("这不是一个合法的 zip 更新包") from exc

    with bundle:
        if bundle.testzip() is not None:
            raise UpdateError("更新包已损坏，无法解压")
        try:
            manifest = json.loads(bundle.read("manifest.json").decode("utf-8"))
        except (KeyError, ValueError, OSError) as exc:
            raise UpdateError("更新包里缺少 manifest.json") from exc
        if not isinstance(manifest, dict) or manifest.get("format") != FORMAT:
            raise UpdateError("更新包格式不正确")
        if str(manifest.get("platform") or "") != platform:
            raise UpdateError(
                f"这是 {manifest.get('platform') or '未知平台'} 的更新包，不能装到 {platform}"
            )
        if platform == WIN:
            expected = str(manifest.get("python") or "")
            current_python = f"{sys.version_info.major}.{sys.version_info.minor}"
            if expected and expected != current_python:
                raise UpdateError(
                    f"更新包由 Python {expected} 构建，当前程序是 {current_python}，"
                    "请改用完整 exe 或重新生成更新包"
                )
        version = str(manifest.get("version") or "").strip()
        if not _VERSION_RE.match(version):
            raise UpdateError("更新包版本号不合法")

        current = active_version(root)
        if current and not force and _version_key(version) <= _version_key(current):
            raise UpdateError(f"当前已是 {current}，更新包版本 {version} 不比它新")

        declared = {
            _safe_rel(str(item.get("path") or "")): str(item.get("sha256") or "")
            for item in (manifest.get("files") or [])
            if isinstance(item, dict)
        }

        entries = [item for item in bundle.infolist() if not item.is_dir()]
        total = sum(item.file_size for item in entries)
        if total > _MAX_UNCOMPRESSED:
            raise UpdateError("更新包解压后体积超过上限")

        staging = updates_dir(root) / f".staging-{version}-{os.getpid()}"
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True)
        try:
            _copy_resources(_resource_base(root), staging)

            seen: set[str] = set()
            for item in entries:
                name = _safe_rel(item.filename)
                if name == "manifest.json":
                    continue
                if not _allowed(name):
                    raise UpdateError(f"更新包不允许写入：{name}")
                if name not in declared:
                    raise UpdateError(f"更新包里有清单外的文件：{name}")
                payload = bundle.read(item)
                if hashlib.sha256(payload).hexdigest() != declared[name]:
                    raise UpdateError(f"文件校验失败：{name}")
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
                seen.add(name)

            missing = set(declared) - seen
            if missing:
                raise UpdateError(f"更新包缺少文件：{sorted(missing)[0]}")

            # 源工程里删掉的文件（静态资源）同步删除，避免旧页面残留
            for name in manifest.get("deleted") or []:
                try:
                    rel = _safe_rel(str(name))
                except UpdateError:
                    continue
                if not _allowed(rel):
                    continue
                target = staging / rel
                if target.is_file():
                    target.unlink()

            final = updates_dir(root) / version
            shutil.rmtree(final, ignore_errors=True)
            os.replace(staging, final)
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            raise

        info = {
            "version": version,
            "platform": platform,
            "previous": current,
            "installed_at": time.time(),
            "files": len(seen),
        }
        _write_current(root, info)
        _prune(root, keep={version, current})
        return info


def _write_current(root: Path, info: dict[str, Any]) -> None:
    directory = updates_dir(root)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "current.json"
    temp = directory / ".current.json.tmp"
    temp.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp, target)


def _prune(root: Path, keep: set[str]) -> None:
    base = updates_dir(root)
    if not base.is_dir():
        return
    for child in base.iterdir():
        if child.is_dir() and child.name not in keep and not child.name.startswith("."):
            shutil.rmtree(child, ignore_errors=True)


# ---------- 重启 ----------


def wait_pid(pid: int, timeout: float = 30.0) -> None:
    """等旧进程退出（重启助手进程调用）。"""
    if pid <= 0:
        return
    deadline = time.time() + max(1.0, timeout)
    while time.time() < deadline:
        if sys.platform == "win32":
            import ctypes

            handle = ctypes.windll.kernel32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
            if not handle:
                return
            try:
                code = ctypes.windll.kernel32.WaitForSingleObject(handle, 200)
                if code == 0:  # WAIT_OBJECT_0
                    return
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        else:
            try:
                os.kill(pid, 0)
            except OSError:
                return
            time.sleep(0.2)
    _notify("更新", "等待旧进程退出超时，将继续启动新版本。")


def restart_process(config) -> str:
    """重启当前程序，返回实际采用的方式：spawn / service / manual。"""
    if os.environ.get("PROOT_LOADER") or os.environ.get("PROOT_TMP_DIR"):
        # 手机本地版由 Android 服务托管，进程内重启会把运行时弄丢
        return "manual"
    if os.environ.get("INVOCATION_ID"):
        # systemd 托管：退出即可，由 Restart=always 拉起
        threading.Thread(target=_exit_later, daemon=True).start()
        return "service"

    from .instances import id_of_root, launch_command

    root = Path(config.paths.root)
    command = launch_command(id_of_root(root), ["--restart-watch", str(os.getpid())])
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        subprocess.Popen(command, cwd=str(root), close_fds=True, creationflags=flags)
    except OSError as exc:
        _notify("重启失败", f"无法启动新进程：{exc}", True)
        return "manual"
    threading.Thread(target=_exit_later, daemon=True).start()
    return "spawn"


def _exit_later(delay: float = 1.0) -> None:
    time.sleep(delay)
    os._exit(0)


# ---------- 拖入 exe 的更新入口 ----------


def _local_base(root: Path) -> str:
    """读取本实例 WebUI 地址（优先 127.0.0.1；监听 0.0.0.0 时也走本机）。"""
    try:
        cfg = json.loads((Path(root) / "config" / "config.json").read_text("utf-8"))
    except (OSError, ValueError):
        return ""
    webui = cfg.get("webui") or {}
    if webui.get("enabled") is False:
        return ""
    port = int(webui.get("port") or 0)
    host = str(webui.get("host") or "").strip()
    if not port:
        return ""
    if not host or host in ("0.0.0.0", "::", "[::]"):
        host = "127.0.0.1"
    return f"http://{host}:{port}"


def _request_restart(root: Path) -> bool:
    """让正在运行的实例自行重启（同时校验访问密码）。"""
    base = _local_base(root)
    if not base:
        return False
    try:
        import urllib.request

        cookie = ""
        try:
            password = (
                json.loads((Path(root) / "config" / "config.json").read_text("utf-8"))
                .get("webui", {})
                .get("access_password", "")
            )
        except (OSError, ValueError):
            password = ""
        if password:
            req = urllib.request.Request(
                base + "/api/login",
                data=json.dumps({"password": password}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                cookie = resp.headers.get("Set-Cookie", "").split(";")[0]

        headers = {"Content-Type": "application/json"}
        if cookie:
            headers["Cookie"] = cookie
        req = urllib.request.Request(
            base + "/api/app/restart", data=b"{}", headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001 - 没跑起来/端口不通都按「未运行」处理
        return False


def _launch_normal(root: Path) -> bool:
    from .instances import id_of_root, launch_command

    command = launch_command(id_of_root(Path(root)))
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        subprocess.Popen(command, cwd=str(root), close_fds=True, creationflags=flags)
        return True
    except OSError:
        return False


def run_update_cli(package: Path, root: Path, force: bool = False) -> int:
    """Windows：把更新包拖到 exe 上时进入这里。"""
    root = Path(root)
    try:
        info = install_package(root, package, platform=WIN, force=force)
    except UpdateError as exc:
        _notify("更新失败", str(exc), True)
        return 1
    except Exception as exc:  # noqa: BLE001 - 任何意外都要给用户一个提示
        _notify("更新失败", f"{type(exc).__name__}: {exc}", True)
        return 1

    if _request_restart(root):
        _notify("更新完成", f"已更新到 {info['version']}，正在重启机器人…")
        return 0
    if _launch_normal(root):
        _notify("更新完成", f"已更新到 {info['version']}，正在启动机器人…")
    else:
        _notify("更新完成", f"已更新到 {info['version']}，请手动启动程序。")
    return 0
