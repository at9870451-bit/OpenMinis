"""QQ 协议网关（NapCat 等）的生命周期管理。

网关是注入进 QQ 进程的载荷，**天然无法与本程序同进程**，所以这里负责：
    探测 → 必要时弹框确认关闭已运行的 QQ → 拉起 → 等待就绪

目标：用户双击一个 exe 就能完成整套流程，不必手动先开 NapCat。
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from urllib.parse import urlparse

from .config import project_root, resource_root
from .log import get_logger

log = get_logger("gateway")

PAYLOAD_ARCHIVES = ("napcat.zip", "napcat-clean.zip")
PAYLOAD_STAMP = ".extracted"

# user32 MessageBoxW 的常量
MB_YESNO = 0x00000004
MB_ICONQUESTION = 0x00000020
MB_ICONINFORMATION = 0x00000040
IDYES = 6

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _detect_uin(gateway_dir: Path) -> int:
    """从网关目录里已存在的配置文件反推已登录的 QQ 号。

    干净分发的场景下用户还没登录过，配置里拿不到 uin；等用户扫码登录后，
    网关会写出 onebot11_<uin>.json，下次启动就能靠它自动补全网络配置。
    """
    for pattern in ("onebot11_*.json", "napcat_*.json"):
        for path in gateway_dir.glob(f"config/{pattern}"):
            digits = path.stem.rsplit("_", 1)[-1]
            if digits.isdigit():
                return int(digits)
    return 0


def write_onebot_config(config, gateway_dir: Path) -> None:
    """把本框架的 WS 服务端设置写进 NapCat 的 OneBot 配置。

    这样解压出来的网关才会开启 3001 端口供本程序连接。
    """
    uin = config.protocol.onebot_gateway_uin or _detect_uin(gateway_dir)
    if not uin:
        return
    path = gateway_dir / "config" / f"onebot11_{uin}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(onebot11_payload(config), ensure_ascii=False, indent=2), encoding="utf-8"
    )


def onebot_ws_entry(config, port: int | None = None) -> dict[str, Any]:
    """我们想要的 OneBot WebSocket 服务端条目（网关照它开端口给本程序连）。"""
    parsed = urlparse(config.protocol.onebot_ws_url)
    return {
        "name": config.bot.name,
        "enable": True,
        "host": "127.0.0.1",
        "port": port or parsed.port or 3001,
        "messagePostFormat": "array",
        "reportSelfMessage": False,
        "token": config.protocol.onebot_access_token,
        "enableForcePushEvent": True,
        "debug": False,
        "heartInterval": 30000,
    }


def onebot11_payload(config) -> dict[str, Any]:
    """一份完整的 OneBot 11 配置（写文件用）。"""
    return {
        "network": {
            "httpServers": [],
            "httpSseServers": [],
            "httpClients": [],
            "websocketServers": [onebot_ws_entry(config)],
            "websocketClients": [],
            "plugins": [],
        },
        "musicSignUrl": "",
        "enableLocalFile2Url": False,
        "parseMultMsg": False,
        "imageDownloadProxy": "",
        "timeout": {
            "baseTimeout": 10000,
            "uploadSpeedKBps": 256,
            "downloadSpeedKBps": 256,
            "maxTimeout": 1800000,
        },
    }


def apply_gateway_port(config, gateway_dir: Path) -> None:
    """把网关自带 WebUI 的端口改成实例配置里的值，避免多开时端口撞车。

    配置为 0 时不动（默认实例沿用载荷里的 6099）；token 一律保留，
    否则控制面板「登录 QQ」页会因为换掉 token 而连不上网关。
    """
    port = int(config.protocol.gateway_webui_port or 0)
    if port <= 0:
        return
    path = gateway_dir / "config" / "webui.json"
    if not path.is_file():
        return
    try:
        data = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(data, dict) or int(data.get("port") or 0) == port:
        return
    data["port"] = port
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    log.info("网关 WebUI 端口已调整为 %d（%s）", port, path)


def napcat_webui_port(config) -> int:
    """网关自带 WebUI 的端口（取自它自己的 webui.json），读不到返回 0。"""
    path = config.paths.data_dir / "gateway" / "config" / "webui.json"
    try:
        data = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0
    try:
        return int(data.get("port") or 0)
    except (TypeError, ValueError):
        return 0


def _qq_pids_by_name() -> list[int]:
    """按进程名列出所有 QQ 进程（老路子，不区分实例）。"""
    try:
        out = subprocess.run(
            ["tasklist", "/fi", "imagename eq QQ.exe", "/fo", "csv", "/nh"],
            capture_output=True,
            text=True,
            timeout=15,
            creationflags=_NO_WINDOW,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    pids: list[int] = []
    for line in out.splitlines():
        parts = [part.strip('"') for part in line.split('","')]
        if len(parts) >= 2 and parts[0].strip('"').lower() == "qq.exe":
            try:
                pids.append(int(parts[1]))
            except ValueError:
                continue
    return pids


def _qq_command_lines() -> list[tuple[int, str]]:
    """列出 QQ.exe 进程的 (pid, 命令行)——多开时靠命令行里的数据目录认人。"""
    if sys.platform != "win32":
        return []
    script = (
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;"
        "Get-CimInstance Win32_Process -Filter \"Name='QQ.exe'\" | "
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
    rows: list[tuple[int, str]] = []
    for line in (out or "").splitlines():
        pid_text, sep, cmd = line.lstrip("\ufeff").strip().partition("|")
        if sep and pid_text.isdigit():
            rows.append((int(pid_text), cmd.strip()))
    return rows


def _other_running_instances(config) -> list[str]:
    """除自己以外还在运行的实例名（判断失败时返回空，不影响主流程）。"""
    try:
        from .instances import other_running

        return other_running(config.paths.root)
    except Exception:  # noqa: BLE001
        return []


def _is_default_instance(config) -> bool:
    """当前进程跑的是不是默认实例（exe 同目录那一份）。"""
    try:
        from .instances import DEFAULT_ID, id_of_root

        return id_of_root(config.paths.root) == DEFAULT_ID
    except Exception:  # noqa: BLE001 - 判断失败时按默认实例处理，宁可不清理
        return True


def qq_profile(config) -> Path | None:
    """本实例用来跑独立 QQ 进程的数据目录；没开多开时返回 None。

    QQ 是 Electron 应用，单实例锁是按 user-data-dir 加的，所以给出一个独立目录
    就能在同一台电脑上再起一个 QQ，两个网关各挂各的 QQ、各登各的号。
    """
    if not getattr(config.protocol, "gateway_multi_instance", False):
        return None
    return config.paths.data_dir / "gateway" / "qq-profile"


def _qq_exe_from_registry() -> Path | None:
    """定位 QQ.exe。

    新版 QQ NT 是 64 位程序，可能注册在 ``SOFTWARE\\Microsoft\\Windows\\...``
    而不是旧的 ``WOW6432Node``；也有用户装到当前用户目录。这里把几种常见位置
    都查一遍，避免启动脚本只认一个注册表键导致「找不到 QQ」。
    """
    if sys.platform != "win32":
        return None
    try:
        import winreg
    except ImportError:
        return None

    keys = [
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QQ"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\QQ"),
        (winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Uninstall\QQ"),
        (winreg.HKEY_CURRENT_USER, r"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QQ"),
    ]
    for hive, subkey in keys:
        try:
            with winreg.OpenKey(hive, subkey) as key:
                values: dict[str, str] = {}
                for name in ("InstallLocation", "UninstallString", "DisplayIcon"):
                    try:
                        values[name] = str(winreg.QueryValueEx(key, name)[0]).strip()
                    except OSError:
                        pass
        except OSError:
            continue

        for name in ("InstallLocation", "UninstallString", "DisplayIcon"):
            raw = values.get(name, "").strip().strip('"')
            if not raw:
                continue
            # DisplayIcon 可能带 ",0" 之类的图标索引
            raw = raw.split(",", 1)[0].strip().strip('"')
            candidate = Path(raw)
            if candidate.suffix.lower() == ".exe":
                if candidate.name.lower() == "qq.exe" and candidate.is_file():
                    return candidate
                candidate = candidate.parent / "QQ.exe"
            else:
                candidate = candidate / "QQ.exe"
            if candidate.is_file():
                return candidate

    # 注册表没登记时，再按常见安装目录兜底
    for base in (
        os.environ.get("ProgramFiles"),
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("LOCALAPPDATA"),
    ):
        if not base:
            continue
        for rel in ("Tencent/QQNT/QQ.exe", "Tencent/QQ/QQ.exe", "Programs/Tencent/QQ/QQ.exe"):
            path = Path(base) / rel
            if path.is_file():
                return path
    return None


def write_local_launcher(config, gateway_dir: Path) -> Path | None:
    """生成普通实例的启动脚本，直接用检测到的 QQ 路径。

    载荷自带的 launcher-user.bat 只查 WOW6432Node 注册表，新版 64 位 QQ 经常
    查不到；这里改成先由程序定位 QQ.exe，再生成 bat，兼容性更好。
    """
    qq_exe = _qq_exe_from_registry()
    if qq_exe is None:
        return None

    bat = gateway_dir / "launcher-local-user.bat"
    content = (
        "@echo off\r\n"
        "setlocal DisableDelayedExpansion\r\n"
        "cd /d \"%~dp0\" || exit /b 1\r\n"
        "chcp 65001 >nul\r\n"
        "set \"NAPCAT_PATCH_PACKAGE=%cd%\\qqnt.json\"\r\n"
        "set \"NAPCAT_LOAD_PATH=%cd%\\loadNapCat.js\"\r\n"
        "set \"NAPCAT_INJECT_PATH=%cd%\\NapCatWinBootHook.dll\"\r\n"
        "set \"NAPCAT_LAUNCHER_PATH=%cd%\\NapCatWinBootMain.exe\"\r\n"
        "set \"NAPCAT_MAIN_PATH=%cd%\\napcat.mjs\"\r\n"
        f"set \"QQPath={qq_exe}\"\r\n"
        "\"%NAPCAT_LAUNCHER_PATH%\" \"%QQPath%\" \"%NAPCAT_INJECT_PATH%\" %*\r\n"
        "exit /b %ERRORLEVEL%\r\n"
    )
    bat.write_text(content, encoding="utf-8")
    return bat


def write_multi_launcher(config, gateway_dir: Path) -> Path | None:
    """生成多开用的启动脚本：让网关起一个带独立 QQ 数据目录的 QQ 进程。

    直接照抄载荷里 launcher-user.bat 的环境变量设置（注入器就靠这些变量找
    napcat.mjs），只把「传给 QQ 的额外参数」换成 ``--user-data-dir=<本实例目录>``。
    实测 NapCatWinBootMain.exe 会把这些参数原样拼到 QQ 的命令行上。
    """
    profile = qq_profile(config)
    if profile is None:
        return None
    qq_exe = _qq_exe_from_registry()
    if qq_exe is None:
        log.error("注册表里找不到 QQ 安装路径，无法多开网关")
        return None
    profile.mkdir(parents=True, exist_ok=True)

    # 已知账号时把 uin 一并交给注入器：它会把参数原样拼到 QQ 的命令行上
    # （``-q <uin>``），于是重启后网关能用这个账号自己的登录票据免密登回来，
    # 不用每次重启都重新扫码。
    uin = int(config.protocol.onebot_gateway_uin or 0)
    extra = f'"{uin}" ' if uin else ""
    extra += '"--user-data-dir=%~dp0qq-profile"'

    bat = gateway_dir / "launcher-multi-user.bat"
    content = (
        "@echo off\r\n"
        "setlocal DisableDelayedExpansion\r\n"
        "cd /d \"%~dp0\" || exit /b 1\r\n"
        "chcp 65001 >nul\r\n"
        "set \"NAPCAT_PATCH_PACKAGE=%cd%\\qqnt.json\"\r\n"
        "set \"NAPCAT_LOAD_PATH=%cd%\\loadNapCat.js\"\r\n"
        "set \"NAPCAT_INJECT_PATH=%cd%\\NapCatWinBootHook.dll\"\r\n"
        "set \"NAPCAT_LAUNCHER_PATH=%cd%\\NapCatWinBootMain.exe\"\r\n"
        "set \"NAPCAT_MAIN_PATH=%cd%\\napcat.mjs\"\r\n"
        f"\"%NAPCAT_LAUNCHER_PATH%\" \"{qq_exe}\" \"%NAPCAT_INJECT_PATH%\" {extra}\r\n"
        "exit /b %ERRORLEVEL%\r\n"
    )
    bat.write_text(content, encoding="utf-8")
    return bat


def clean_bundled_login(gateway_dir: Path) -> None:
    """清掉内嵌载荷夹带的登录态，让新实例必须自己扫码登录。

    自用版的载荷里带着主账号的免密票据（passkey.json）与账号配置，直接解压出来
    会让新实例「顺手」登成主账号。多开时每个实例要连的是不同账号，所以首次给
    新实例铺网关时，把这些账号相关的文件删掉，只保留程序与默认配置。
    """
    config_dir = gateway_dir / "config"
    if not config_dir.is_dir():
        return
    removed: list[str] = []
    for pattern in ("passkey.json", "napcat_*.json", "onebot11_*.json"):
        for path in config_dir.glob(pattern):
            try:
                path.unlink()
                removed.append(path.name)
            except OSError:
                pass
    if removed:
        log.info("已清空载荷带来的登录态（%s），该实例需要自己登录账号", "、".join(removed))


def payload_roots() -> list[Path]:
    """可能放着内嵌载荷的目录，按优先级排列。

    装过增量更新后 ``resource_root()`` 指向 data/updates/<版本>（只复制了页面，
    没有 napcat.zip），如果只在那儿找就会报「未找到内嵌网关载荷」，
    网关自然拉不起来。所以要继续往 exe 自身的资源目录和程序目录找。
    """
    roots: list[Path] = []
    candidates = [
        resource_root(),
        Path(sys._MEIPASS) if getattr(sys, "_MEIPASS", None) else None,
        project_root(),
        Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else None,
    ]
    for candidate in candidates:
        if candidate is None:
            continue
        try:
            path = Path(candidate).resolve()
        except OSError:
            continue
        if path.is_dir() and path not in roots:
            roots.append(path)
    return roots


def _find_payload() -> Path | None:
    """定位内嵌的网关载荷。

    同时兼容自用版（napcat.zip）与发布版（napcat-clean.zip），
    避免打包配置与代码常量脱节。
    """
    for root in payload_roots():
        for name in PAYLOAD_ARCHIVES:
            candidate = root / name
            if candidate.is_file():
                return candidate
    return None


def ensure_payload(config) -> Path | None:
    """首次运行时把内嵌的网关载荷解压到数据目录，实现单文件分发。

    同时尽量继承本机既有 NapCat 的配置（含登录态），避免解压后还要重新扫码。
    没有内嵌载荷时返回 None。
    """
    archive = _find_payload()
    if archive is None:
        log.warning(
            "未找到内嵌网关载荷（已查找 %s，文件名 %s）",
            "、".join(str(root) for root in payload_roots()),
            PAYLOAD_ARCHIVES,
        )
        return None

    target = config.paths.data_dir / "gateway"
    stamp = target / PAYLOAD_STAMP
    if not stamp.exists():
        target.mkdir(parents=True, exist_ok=True)
        # 导入实例时可能只带了 config/（登录态），程序文件是缺的；解压前先把它挪开，
        # 解压后再合并回来，这样既补齐程序文件又不会覆盖带回来的登录信息。
        preserved: Path | None = None
        imported_config = target / "config"
        if imported_config.is_dir() and any(imported_config.iterdir()):
            preserved = target.parent / ".gateway-config-restore"
            if preserved.exists():
                shutil.rmtree(preserved, ignore_errors=True)
            try:
                shutil.move(str(imported_config), str(preserved))
            except OSError as exc:
                log.warning("暂存网关配置失败: %s", exc)
                preserved = None

        log.info("首次运行：解压内嵌网关载荷到 %s（约 34MB）", target)
        try:
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(target)
        except (OSError, zipfile.BadZipFile) as exc:
            log.error("解压网关载荷失败: %s", exc)
            return None

        if preserved is not None:
            try:
                shutil.copytree(preserved, imported_config, dirs_exist_ok=True)
                log.info("已还原备份里的网关配置（保留免密登录）")
            except OSError as exc:
                log.warning("还原网关配置失败: %s", exc)
            finally:
                shutil.rmtree(preserved, ignore_errors=True)

        legacy = config.protocol.onebot_gateway_launcher
        legacy_config = Path(legacy).parent / "config" if legacy else None
        if legacy_config is not None and legacy_config.is_dir():
            try:
                shutil.copytree(legacy_config, target / "config", dirs_exist_ok=True)
                log.info("已继承既有 NapCat 配置（保留免密登录）")
            except OSError as exc:
                log.warning("继承既有配置失败: %s", exc)

        # 新实例（不是导入来的、也不是默认实例）：抹掉载荷里的账号登录态，
        # 否则会顺手登成主账号，多开就失去意义了。
        if preserved is None and not _is_default_instance(config):
            clean_bundled_login(target)

        stamp.write_text("ok", encoding="utf-8")

    apply_gateway_port(config, target)
    write_onebot_config(config, target)
    return target


class GatewayController:
    def __init__(self, config) -> None:
        self.config = config

    # ---------- 探测 ----------

    async def port_ready(self, timeout: float = 1.5) -> bool:
        """OneBot 端口是否已就绪（即网关已登录并开始服务）。"""
        parsed = urlparse(self.config.protocol.onebot_ws_url)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 3001
        try:
            _reader, writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), timeout=timeout
            )
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
            return True
        except (OSError, asyncio.TimeoutError):
            return False

    def qq_processes(self) -> list[int]:
        """属于「本实例」的 QQ 进程。

        多开模式下按独立数据目录认人（命令里带本实例 qq-profile 路径的都是它的
        QQ 进程）；没开多开时沿用老行为，按进程名统计全部 QQ 进程。
        """
        profile = qq_profile(self.config)
        if profile is None:
            return _qq_pids_by_name()
        key = str(profile).lower()
        return [pid for pid, cmd in _qq_command_lines() if key in cmd.lower()]

    async def webui_ready(self, timeout: float = 1.0) -> bool:
        """网关进程本身是否活着（它的 WebUI 端口感不感知）。

        OneBot 端口就绪要等「登录完成」，所以没登录时 port_ready 是 False，
        但网关其实已经在跑了——这时候绝不能把它当成「QQ 没被接管」去关掉。
        """
        port = napcat_webui_port(self.config)
        if port <= 0:
            return False
        try:
            _reader, writer = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", port), timeout=timeout
            )
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
            return True
        except (OSError, asyncio.TimeoutError):
            return False

    async def apply_onebot_config(self) -> bool:
        """让网关切切实实地开一个 OneBot WS 端口给本程序连。

        只改 config/onebot11_<uin>.json 是没用的——网关只在启动那一刻读它，
        之后改文件它不重读（新账号是登录后才生成这份配置的，所以永远落后一拍）。
        走网关自己的 ``/api/OB11Config/SetConfig`` 接口才会立即生效。
        推的时候只动我们这一条 WS 服务端配置，别把用户自己配的东西覆盖掉。
        """
        from .napcat import NapCatClient, NapCatError

        entry = onebot_ws_entry(self.config)
        try:
            client = NapCatClient(self.config)
            current = await client.get_ob11_config()
        except NapCatError as exc:
            # 这一步会被重连循环反复调用，失败只记 debug，免得刷屏（成功才记 INFO）
            log.debug("读取网关 OneBot 配置失败: %s", exc)
            return False

        if not isinstance(current, dict):
            current = {}
        network = current.get("network")
        if not isinstance(network, dict):
            network = {}
            current["network"] = network
        servers = network.get("websocketServers")
        if not isinstance(servers, list):
            servers = []
            network["websocketServers"] = servers

        for index, item in enumerate(servers):
            if isinstance(item, dict) and item.get("name") == entry["name"]:
                servers[index] = {**item, **entry}
                break
        else:
            servers.append(entry)

        try:
            ok = await client.set_ob11_config(current)
        except NapCatError as exc:
            log.debug("推送网关 OneBot 配置失败: %s", exc)
            return False
        if ok:
            log.info(
                "已让网关开启 OneBot 端口 %s（%s）",
                entry["port"], "等待登录" if not await self.port_ready() else "已就绪",
            )
        return ok

    async def status(self) -> str:
        return "running" if await self.port_ready() else "stopped"

    # ---------- 交互（ctypes 直接调 user32：零依赖，打包后仍可用） ----------

    @staticmethod
    def _message_box(text: str, title: str, flags: int) -> int:
        if sys.platform != "win32":
            return 0
        try:
            return int(ctypes.windll.user32.MessageBoxW(0, text, title, flags))
        except Exception as exc:  # noqa: BLE001
            log.warning("弹框失败: %s", exc)
            return 0

    @classmethod
    def confirm(cls, title: str, text: str) -> bool:
        return cls._message_box(text, title, MB_YESNO | MB_ICONQUESTION) == IDYES

    @classmethod
    def notify(cls, title: str, text: str) -> None:
        cls._message_box(text, title, MB_ICONINFORMATION)

    # ---------- 操作 ----------

    def stop_qq(self) -> int:
        """只关「本实例」的 QQ 进程，绝不动别的实例的 QQ。"""
        pids = self.qq_processes()
        if not pids:
            return 0
        killed = 0
        for pid in pids:
            result = subprocess.run(
                ["taskkill", "/f", "/pid", str(pid), "/t"],
                capture_output=True,
                creationflags=_NO_WINDOW,
            )
            if result.returncode == 0:
                killed += 1
        log.info("已关闭 %d 个属于本实例的 QQ 进程", killed)
        return killed

    def resolve_launcher(self) -> Path | None:
        """确定网关启动脚本：优先内嵌载荷（单文件分发），其次显式路径。"""
        if sys.platform == "win32" and self.config.protocol.onebot_gateway_use_embedded:
            payload = ensure_payload(self.config)
            if payload is not None:
                # 开了多开的实例：用生成的专用脚本，让它起一个带独立数据目录的 QQ
                multi = write_multi_launcher(self.config, payload)
                if multi is not None:
                    return multi
                # 普通实例也优先用程序自己生成的脚本，兼容 64 位 QQ 的注册表位置
                local = write_local_launcher(self.config, payload)
                if local is not None:
                    return local
                log.warning("未能定位 QQ.exe，将使用载荷自带的启动脚本（需要旧版注册表路径）")
                candidate = payload / "launcher-user.bat"
                if candidate.is_file():
                    return candidate
        explicit = self.config.protocol.onebot_gateway_launcher
        if explicit:
            path = Path(explicit)
            if path.is_file():
                return path
            log.error("网关启动脚本不存在: %s", explicit)
        return None

    def launch(self) -> bool:
        path = self.resolve_launcher()
        if path is None:
            log.warning("未找到可用的网关启动脚本（内嵌载荷与 onebot_gateway_launcher 均不可用）")
            return False

        command = f'"{path}"'
        uin = self.config.protocol.onebot_gateway_uin
        # 多开时登录态存在自己的 QQ 数据目录里，不需要再传账号做快速登录，
        # 传了反而会把「独立数据目录」那个参数挤掉。
        if uin and qq_profile(self.config) is None:
            command += f" {uin}"
        log.info("正在拉起网关: %s", command)
        try:
            subprocess.Popen(
                command,
                cwd=str(path.parent),
                shell=True,
                creationflags=_NO_WINDOW,
            )
            return True
        except OSError as exc:
            log.error("拉起网关失败: %s", exc)
            return False

    # ---------- 主流程 ----------

    async def ensure_ready(self, interactive: bool = True) -> bool:
        """确保网关可用。interactive=False 时不弹框，只返回能否继续。"""
        protocol = self.config.protocol
        if await asyncio.to_thread(self.resolve_launcher) is None:
            return await self.port_ready()

        if await self.port_ready():
            log.info("QQ 网关已在运行，无需拉起")
            return True
        # 网关进程活着，只是还没登录（比如正等着扫码）——等它登录就行，
        # 千万不能把它当成「QQ 没被接管」而弹框去关 QQ。
        if await self.webui_ready():
            log.info("网关已在运行（尚未登录或还没开出 OneBot 端口），等待登录即可")
            await self.apply_onebot_config()  # 顺带把 OneBot 端口配置推上去
            return True

        running = await asyncio.to_thread(self.qq_processes)
        if running:
            # 没开多开的实例和别的实例共用同一个 QQ 宿主：别的实例在跑时，
            # 不能为了本实例去关 QQ，否则会把那边一起打断（开了多开的实例有
            # 自己的 QQ 进程，天然不冲突，所以不需要这道护栏）。
            others = await asyncio.to_thread(_other_running_instances, self.config)
            if others and qq_profile(self.config) is None:
                log.warning(
                    "本机已有其它实例在运行（%s），放弃接管 QQ，以免打断它",
                    "、".join(others),
                )
                return False
            if not interactive:
                log.warning("检测到 QQ 正在运行但未被注入，需先关闭 QQ")
                return False
            approved = await asyncio.to_thread(
                self.confirm,
                f"{self.config.bot.name} 需要接管 QQ",
                f"检测到 QQ 正在运行（{len(running)} 个进程），但它没有被注入，\n"
                "必须先关闭 QQ 才能让机器人接管。\n\n是否现在关闭 QQ 并继续？",
            )
            if not approved:
                log.warning("用户取消了关闭 QQ，网关未启动")
                return False
            await asyncio.to_thread(self.stop_qq)
            await asyncio.sleep(3)

        if not self.launch():
            return False

        deadline = asyncio.get_running_loop().time() + protocol.onebot_gateway_wait
        while asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(2)
            if await self.port_ready():
                log.info("QQ 网关已就绪")
                return True
        log.warning("等待网关就绪超时（%.0fs）", protocol.onebot_gateway_wait)
        return False

    async def restart(self) -> bool:
        # 没开多开时和别的实例共用同一个 QQ 宿主：那绝不能去关 QQ，
        # 否则会把别的实例的网关一起打断。（开了多开的实例只关自己的 QQ）
        others = await asyncio.to_thread(_other_running_instances, self.config)
        if others and qq_profile(self.config) is None:
            log.warning(
                "本机已有其它实例在运行（%s），不重启网关，以免打断它", "、".join(others)
            )
            return False
        log.info("正在重启 QQ 网关")
        await asyncio.to_thread(self.stop_qq)
        await asyncio.sleep(3)
        return await self.ensure_ready(interactive=True)