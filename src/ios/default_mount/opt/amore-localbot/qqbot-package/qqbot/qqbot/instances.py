"""多实例管理：一个 exe 同时跑多个机器人，各自独立目录。

目录约定（默认实例保持向后兼容，仍是 exe 同目录）：

    <exe 目录>                      ← 默认实例（default）
    <exe 目录>/instances/<名字>     ← 其余实例，各自带 config/ 与 data/

面板「多实例」页通过本模块完成：列举 / 新建 / 启动 / 停止 / 删除 /
导出 zip / 导入 zip / 打开面板。每个实例的单实例锁是按 data 目录加的，
所以只要目录不同，多开就不会互斥。
"""

from __future__ import annotations

import json
import re
import secrets
import shutil
import socket
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .config import project_root
from .log import get_logger

log = get_logger("instances")

INSTANCES_DIRNAME = "instances"
EXPORT_DIRNAME = "exports"
DEFAULT_ID = "default"
DEFAULT_LABEL = "默认实例"

#: 实例名：首字符必须是字/数字/下划线（中文也算字），后面可带空格与短横线
_NAME_RE = re.compile(r"^\w[\w \-]{0,23}$", re.UNICODE)

#: 端口分配起点：默认实例占 6199/3001/3000/6099，新实例一律往后排
_PORT_START = {"webui": 6199, "ws": 3001, "api": 3000, "gateway": 6099}

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


# ---------- 路径与命名 ----------


def instances_root() -> Path:
    return project_root() / INSTANCES_DIRNAME


def root_of(name: str) -> Path:
    """实例名 -> 实例根目录；default / 空串 表示 exe 同目录。"""
    if is_default(name):
        return project_root()
    return instances_root() / name


def is_default(name: str) -> bool:
    return not name or name == DEFAULT_ID


def valid_name(name: str) -> bool:
    return bool(_NAME_RE.match((name or "").strip())) and ".." not in name


def label_of(root: Path) -> str:
    """从目录反推实例显示名。"""
    root = Path(root).resolve()
    if root.parent.name == INSTANCES_DIRNAME:
        return root.name
    return DEFAULT_LABEL


def id_of_root(root: Path) -> str:
    """从目录反推实例 id（供命令行 --instance 使用）。"""
    root = Path(root).resolve()
    if root.parent.name == INSTANCES_DIRNAME:
        return root.name
    return DEFAULT_ID


# ---------- 读取 ----------


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _config_of(name: str) -> dict[str, Any]:
    return _read_json(root_of(name) / "config" / "config.json")


def _ports_of(cfg: dict[str, Any]) -> dict[str, int]:
    proto = cfg.get("protocol") or {}
    webui = cfg.get("webui") or {}
    return {
        "webui": int(webui.get("port") or 0),
        "ws": urlparse(str(proto.get("onebot_ws_url") or "")).port or 0,
        "api": urlparse(str(proto.get("onebot_api_url") or "")).port or 0,
        "reverse": int(proto.get("onebot_reverse_port") or 0),
        "gateway": int(proto.get("gateway_webui_port") or 0),
    }


# ---------- 端口分配 ----------


def _port_alive(port: int, timeout: float = 0.35) -> bool:
    if not port:
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def _port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def used_ports() -> set[int]:
    """已被现有实例占用的端口（含正在运行但监听中的端口）。"""
    taken: set[int] = set()
    for item in list_instances(probe=False):
        for port in (item.get("ports") or {}).values():
            if port:
                taken.add(int(port))
    return taken


def _next_free(start: int, taken: set[int]) -> int:
    port = max(1, start)
    while port in taken or not _port_free(port):
        port += 1
        if port > 65535:
            raise RuntimeError("没有可用的空闲端口")
    taken.add(port)
    return port


def allocate_ports() -> dict[str, int]:
    """给新实例挑一组不与现有实例冲突、且当前空闲的端口。"""
    taken = used_ports()
    return {
        "webui": _next_free(_PORT_START["webui"] + 1, taken),
        "ws": _next_free(_PORT_START["ws"] + 1, taken),
        "api": _next_free(_PORT_START["api"] + 1, taken),
        "gateway": _next_free(_PORT_START["gateway"] + 1, taken),
    }


# ---------- 描述 ----------


def _describe(name: str, root: Path, cfg: dict[str, Any]) -> dict[str, Any]:
    ports = _ports_of(cfg)
    proto = cfg.get("protocol") or {}
    bot = cfg.get("bot") or {}
    return {
        "id": name,
        "label": str(bot.get("name") or (DEFAULT_LABEL if is_default(name) else name)),
        "default": is_default(name),
        "path": str(root),
        "backend": str(proto.get("backend") or "onebot"),
        "account": int(proto.get("onebot_gateway_uin") or 0),
        "ports": ports,
        "running": _port_alive(ports["webui"]),
        "initialized": (root / "config" / "config.json").is_file(),
    }


def describe(name: str) -> dict[str, Any]:
    root = root_of(name)
    return _describe(name, root, _config_of(name))


def other_running(current_root: Path) -> list[str]:
    """除当前实例外，还有哪些实例正在运行。

    多开时用来挡掉一个坑：本机只有一个 QQ 宿主机，第二个实例若去「接管 QQ」，
    会把正在跑的那个实例的 QQ 一起关掉。有别的实例在跑时就直接放弃接管。
    """
    me = id_of_root(current_root)
    return [
        item["label"]
        for item in list_instances()
        if item["id"] != me and item["running"]
    ]


def list_instances(probe: bool = True) -> list[dict[str, Any]]:
    """列举全部实例：默认实例 + instances/ 下的子目录。"""
    dirs: list[tuple[str, Path]] = [(DEFAULT_ID, project_root())]
    base = instances_root()
    if base.is_dir():
        for child in sorted(base.iterdir()):
            if child.is_dir() and valid_name(child.name):
                dirs.append((child.name, child))

    items: list[dict[str, Any]] = []
    for name, root in dirs:
        cfg = _read_json(root / "config" / "config.json")
        item = _describe(name, root, cfg)
        if not probe:
            item["running"] = False
        items.append(item)
    return items


# ---------- 新建 / 删除 ----------


def _write_config(root: Path, cfg: dict[str, Any]) -> None:
    path = root / "config" / "config.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")


def _patch_runtime(cfg: dict[str, Any], name: str, ports: dict[str, int]) -> None:
    """把实例名与端口写进配置（其余设置保持调用方给的原样）。"""
    bot = cfg.setdefault("bot", {})
    bot["name"] = name

    proto = cfg.setdefault("protocol", {})
    proto["onebot_ws_url"] = f"ws://127.0.0.1:{ports['ws']}"
    proto["onebot_api_url"] = f"http://127.0.0.1:{ports['api']}"
    proto["onebot_reverse_port"] = ports["ws"]
    proto["gateway_webui_port"] = ports["gateway"]
    # 每个实例都有自己的网关和自己的 QQ 进程：QQ 是 Electron 应用，给它一个独立的
    # user-data-dir 就能在同一台电脑上再起一个 QQ，于是多个实例可以同时在线、
    # 各登各的号，互不干扰，也不会把别的实例的 QQ 关掉。
    proto["onebot_gateway_use_embedded"] = True
    proto["gateway_multi_instance"] = True
    # 新实例是另一个账号，登录信息必须重新填写
    proto["onebot_gateway_uin"] = 0
    # 每个实例一套自己的 OneBot 令牌（网关按它校验连接），别共用也别留空
    proto["onebot_access_token"] = "qqbot-" + secrets.token_hex(6)

    cfg.setdefault("webui", {})["port"] = ports["webui"]


def create_instance(name: str, base_config: dict[str, Any] | None = None) -> dict[str, Any]:
    """新建一个实例。

    ``base_config`` 一般传当前实例的配置（面板里就是它自己），这样新实例
    直接继承 AI / 人格 / 管理员等设置，只需要改账号即可开工。
    """
    name = (name or "").strip()
    if not valid_name(name):
        raise ValueError("实例名只能包含中文、字母、数字、空格、下划线或短横线（1~24 个字符）")
    if is_default(name):
        raise ValueError("default 是默认实例的保留名，请换一个名字")

    root = root_of(name)
    if root.exists():
        raise ValueError(f"实例「{name}」已经存在")

    ports = allocate_ports()
    cfg = json.loads(json.dumps(base_config or {}))  # 深拷贝，避免污染调用方
    _patch_runtime(cfg, name, ports)

    root.mkdir(parents=True, exist_ok=True)
    (root / "data").mkdir(parents=True, exist_ok=True)
    _write_config(root, cfg)
    log.info("已新建实例 %s（root=%s，端口=%s）", name, root, ports)
    return _describe(name, root, cfg)


def delete_instance(name: str) -> None:
    import time

    if is_default(name):
        raise ValueError("默认实例不能删除")
    root = root_of(name)
    if not root.exists():
        raise ValueError(f"实例「{name}」不存在")

    # 正在运行的实例必须先停下来，否则目录被占用删不干净
    if describe(name)["running"]:
        if not stop_instance(name):
            raise ValueError(f"实例「{name}」正在运行，没能停下来，请先手动关掉它再删除")
        time.sleep(1.0)

    shutil.rmtree(root, ignore_errors=True)
    if root.exists():
        raise ValueError(f"实例「{name}」的目录还有文件被占用，删除未完成")
    log.info("已删除实例 %s（%s）", name, root)


# ---------- 启动 / 停止 ----------


def launch_command(name: str, extra: list[str] | None = None) -> list[str]:
    if getattr(sys, "frozen", False):
        command = [sys.executable]
    else:
        command = [sys.executable, str(project_root() / "run.py")]
    if not is_default(name):
        command += ["--instance", name]
    return command + list(extra or [])


def start_instance(name: str) -> dict[str, Any]:
    root = root_of(name)
    if not (root / "config" / "config.json").is_file():
        raise ValueError(f"实例「{name}」还没有配置，无法启动")
    if describe(name)["running"]:
        raise ValueError(f"实例「{name}」已经在运行")

    from .main import allow_child_foreground

    allow_child_foreground()
    try:
        subprocess.Popen(launch_command(name), close_fds=True)
    except OSError as exc:
        raise ValueError(f"启动实例失败: {exc}") from exc
    log.info("已启动实例 %s", name)
    return describe(name)


def _lock_pid(root: Path) -> int:
    """尽力读锁文件里的 pid（运行中该文件被独占，通常读不到）。"""
    try:
        return int((root / "data" / "qqbot.lock").read_text("utf-8").strip())
    except (OSError, ValueError):
        return 0


def _qqbot_processes() -> list[tuple[int, str]]:
    """列出本程序相关进程的 (pid, 命令行)。

    运行中的实例锁文件被独占，读不到 pid，所以停实例只能靠命令行来认人。
    Windows 用 PowerShell 的 CIM 查询，Linux 直接扫 /proc。
    """
    if sys.platform != "win32":
        return _posix_processes()

    # 先强制 UTF-8 输出：Windows PowerShell 5 默认按本地代码页（GBK）吐字节，
    # 直接按 utf-8 解码会炸，也会把中文实例名解成乱码导致认不出实例。
    script = (
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;"
        "Get-CimInstance Win32_Process -Filter \"Name='QQBot.exe'\" | "
        "ForEach-Object { \"$($_.ProcessId)|$($_.CommandLine)\" }"
    )
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            creationflags=_NO_WINDOW,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    if not out:
        return []

    items: list[tuple[int, str]] = []
    for line in out.splitlines():
        line = line.lstrip("\ufeff").strip()
        pid_text, sep, cmd = line.partition("|")
        if sep and pid_text.strip().isdigit():
            items.append((int(pid_text.strip()), cmd.strip()))
    return items


def _posix_processes() -> list[tuple[int, str]]:
    """Linux /proc 扫描：命令行里带本项目 run.py 的 Python 进程。"""
    base = str(project_root().resolve())
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return []
    items: list[tuple[int, str]] = []
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "cmdline").read_bytes()
        except OSError:
            continue
        if not raw:
            continue
        command = raw.replace(b"\x00", b" ").decode("utf-8", "replace").strip()
        if "run.py" in command and base in command:
            items.append((int(entry.name), command))
    return items


def stop_instance(name: str) -> bool:
    """结束实例进程。

    认人方式：命令行里带 ``--instance <名字>`` 的就是该实例（默认实例则是
    命令行不带 --instance 的那些）。锁文件读不到时这就是唯一可靠的依据。
    """
    needle = f"--instance {name}"
    default = is_default(name)

    def belongs(command: str) -> bool:
        return ("--instance" not in command) if default else (needle in command)

    targets = [pid for pid, command in _qqbot_processes() if belongs(command)]
    if not targets:
        # 拿不到命令行（PowerShell 不可用等）时，退回锁文件里的 pid
        pid = _lock_pid(root_of(name))
        if pid:
            targets = [pid]

    killed = False
    if sys.platform != "win32":
        import os
        import signal
        import time

        for pid in targets:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                continue
            for _ in range(10):
                time.sleep(0.15)
                try:
                    os.kill(pid, 0)
                except OSError:
                    break
            else:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            killed = True
    else:
        for pid in targets:
            result = subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True,
                creationflags=_NO_WINDOW,
            )
            if result.returncode == 0:
                killed = True
    if killed:
        log.info("已停止实例 %s（pid=%s）", name, targets)
    return killed


def open_panel(name: str) -> None:
    from .main import allow_child_foreground

    allow_child_foreground()
    subprocess.Popen(
        launch_command(name, ["--panel"]),
        close_fds=True,
        creationflags=_NO_WINDOW,
    )


# ---------- 导出 / 导入 zip ----------


#: 只备份实例自己的目录；默认实例的根目录就是 exe 目录，里面还躺着 exe、instances/
#: 等不属于「配置与数据」的东西，一律不打包。
_KEEP_TOP = {"config", "data", "plugins_ext"}
#: 纯缓存/日志，可重建，不进备份
_SKIP_DATA = {"logs", "tts"}


def _keep_in_export(rel: Path) -> bool:
    """导出时保留哪些文件（rel 是相对实例根目录的路径）。"""
    parts = rel.parts
    if not parts or parts[0] not in _KEEP_TOP:
        return False
    if any(part == "__pycache__" for part in parts):
        return False
    if rel.name == "qqbot.lock":
        return False
    if parts[0] == "data" and len(parts) > 1 and parts[1] in _SKIP_DATA:
        return False
    if parts[0] == "data" and len(parts) >= 2 and parts[1] == "gateway":
        # 网关：只备份 config/（登录态、WebUI token、OneBot 配置），
        # 程序文件（node_modules 等上百 MB）下次启动会从内嵌载荷自动重解压
        return len(parts) >= 3 and parts[2] == "config"
    return True


def export_zip(name: str) -> tuple[str, bytes]:
    """把实例的配置与数据打包成内存里的 zip，返回 (文件名, 内容)。"""
    import io

    root = root_of(name)
    if not root.exists():
        raise ValueError(f"实例「{name}」不存在")

    buffer = io.BytesIO()
    kept = 0
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root)
            if not _keep_in_export(rel):
                continue
            bundle.write(path, rel.as_posix())
            kept += 1
    payload = buffer.getvalue()
    label = describe(name)["label"]
    log.info("已导出实例 %s：%d 个文件，%.1f KB", name, kept, len(payload) / 1024)
    return f"qqbot-{label}-备份.zip", payload


def exports_dir() -> Path:
    """备份的统一落脚点：exe 目录下的 exports/（所有实例共用，方便找）。"""
    return project_root() / EXPORT_DIRNAME


def export_to_file(name: str) -> dict[str, Any]:
    """导出备份并直接写成文件，返回它的路径与大小。

    面板是内嵌的浏览器窗口，用「下载」方式给 zip 很容易点了没反应、也不知道
    存到哪去了；所以这里由后端把文件写到 exports/ 目录，再把真实路径回给面板。
    """
    import time

    filename, blob = export_zip(name)
    target = exports_dir()
    target.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = target / f"{Path(filename).stem}-{stamp}.zip"
    path.write_bytes(blob)
    log.info("备份已写入 %s（%.1f KB）", path, len(blob) / 1024)
    return {"path": str(path), "filename": path.name, "size": len(blob), "dir": str(target)}


def reveal_path(path: str = "") -> str:
    """在资源管理器里定位备份文件/目录；只允许打开 exports 目录里的东西。"""
    base = exports_dir().resolve()
    target = Path(path).resolve() if path else base
    if target != base and base not in target.parents:
        raise ValueError("只能打开备份目录（exports）里的文件")
    if not target.exists():
        raise ValueError(f"路径不存在：{target}")
    if sys.platform != "win32":
        return str(target)
    if target.is_dir():
        subprocess.Popen(["explorer", str(target)])
    else:
        subprocess.Popen(["explorer", f"/select,{target}"])
    return str(target)


def _safe_extract(bundle: zipfile.ZipFile, target: Path) -> None:
    """解压并挡住 zip-slip（条目路径不得跳出目标目录）。"""
    base = target.resolve()
    for member in bundle.infolist():
        dest = (target / member.filename).resolve()
        if not str(dest).startswith(str(base)):
            raise ValueError(f"压缩包里有越界的路径：{member.filename}")
    bundle.extractall(target)


def import_zip(payload: bytes, name: str = "") -> dict[str, Any]:
    """把备份 zip 还原成一个新实例（端口重新分配，网关程序下次启动自动补全）。"""
    import io

    name = (name or "").strip()
    try:
        bundle = zipfile.ZipFile(io.BytesIO(payload))
    except zipfile.BadZipFile as exc:
        raise ValueError("这不是一个合法的 zip 备份文件") from exc

    if bundle.testzip() is not None:
        raise ValueError("压缩包已损坏，无法解压")

    inner = _read_json_from_zip(bundle)
    if not name:
        raw = str(((inner.get("bot") or {}).get("name") or "")).strip()
        name = raw if valid_name(raw) else "备份实例"
    if not valid_name(name):
        raise ValueError("实例名只能包含中文、字母、数字、空格、下划线或短横线（1~24 个字符）")
    if is_default(name):
        raise ValueError("default 是默认实例的保留名，请换一个名字")

    root = root_of(name)
    if root.exists() and any(root.iterdir()):
        raise ValueError(f"实例「{name}」已经存在，请换一个名字")

    root.mkdir(parents=True, exist_ok=True)
    _safe_extract(bundle, root)

    ports = allocate_ports()
    cfg = _read_json(root / "config" / "config.json")
    _patch_runtime(cfg, name, ports)
    _write_config(root, cfg)

    # 让网关程序文件在下次启动时从内嵌载荷补齐（只保留带回来的 config/ 登录态）
    (root / "data" / "gateway").mkdir(parents=True, exist_ok=True)
    stamp = root / "data" / "gateway" / ".extracted"
    if stamp.exists():
        stamp.unlink()

    _apply_gateway_port(root, ports["gateway"])
    log.info("已导入实例 %s（%s，端口=%s）", name, root, ports)
    return _describe(name, root, cfg)


def _read_json_from_zip(bundle: zipfile.ZipFile) -> dict[str, Any]:
    for member in bundle.namelist():
        if member.replace("\\", "/").endswith("config/config.json"):
            try:
                data = json.loads(bundle.read(member).decode("utf-8"))
            except (ValueError, OSError):
                return {}
            return data if isinstance(data, dict) else {}
    return {}


def _apply_gateway_port(root: Path, port: int) -> None:
    """把实例的网关 WebUI 端口写进随包带回来的 webui.json（保留 token）。"""
    path = root / "data" / "gateway" / "config" / "webui.json"
    data = _read_json(path)
    if not data:
        return
    data["port"] = int(port)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
