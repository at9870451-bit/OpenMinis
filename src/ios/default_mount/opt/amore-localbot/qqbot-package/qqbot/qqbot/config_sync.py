"""配置与数据的导出 / 导入，用于不同端之间快速同步。

导出内容是「除 API Key 之外的全部用户数据」：配置、知识库、长期记忆、
表情包、插件配置与插件数据、界面背景。API Key 在导出时留空，导入时
自动沿用本机原有的 Key，避免换端后模型不可用。

导入不会在运行中直接替换 sqlite：先落到 data/.import-pending.zip，
下次启动（Config.load 之前）再一次性应用，保证数据库一致。
"""

from __future__ import annotations

import io
import json
import os
import shutil
import time
import zipfile
from pathlib import Path
from typing import Any

FORMAT = "qqbot-config"
PENDING_NAME = ".import-pending.zip"
FAILED_NAME = ".import-failed.zip"

#: 导出时清空的密钥字段
_SECRET_PATHS = (
    ("ai", "api_key"),
    ("ai", "vision", "api_key"),
    ("tts", "api_key"),
    ("image", "api_key"),
)

#: 不参与同步的 data 子项（日志/缓存/设备绑定/网关程序）
_SKIP_DATA = {"logs", "tts", "gateway", "updates", "qqbot.lock", "txgod.json"}

#: 导出时额外排除的用户数据：知识库、长期记忆按需求不跨端同步
_EXPORT_SKIP_DATA = _SKIP_DATA | {"knowledge", "memory"}

#: 导入时整目录替换的 data 子项（知识库/记忆库按需求不参与同步）
_REPLACE_DATA_DIRS = ("stickers", "plugins", "ui")

_ALLOWED_PREFIXES = ("config/", "data/", "plugins_ext/")
_MAX_IMPORT = 200 * 1024 * 1024


class ConfigSyncError(ValueError):
    """配置包不合法。"""


def _version() -> str:
    from . import __version__

    return __version__


def _scrub(config_data: dict[str, Any]) -> None:
    for path in _SECRET_PATHS:
        node: Any = config_data
        for key in path[:-1]:
            node = node.get(key) if isinstance(node, dict) else None
        if isinstance(node, dict):
            node[path[-1]] = ""


#: 跨端同步时保留目标端自己的部署参数。
#: 这些不是「用户内容」，而是本机怎么对外提供服务/怎么连网关；
#: 把电脑端的 127.0.0.1 带到服务器上会直接导致面板打不开。
_RUNTIME_FIELDS = {
    "webui": ("enabled", "host", "port", "access_password"),
    "protocol": (
        "backend", "onebot_mode", "onebot_ws_url", "onebot_api_url",
        "onebot_access_token", "onebot_reverse_host", "onebot_reverse_port",
        "onebot_gateway_launcher", "onebot_gateway_uin", "onebot_gateway_wait",
        "onebot_gateway_use_embedded", "gateway_webui_port",
        "gateway_multi_instance", "nt_uin", "nt_signer", "nt_signer_url",
        "nt_signer_token", "nt_server_host", "nt_server_port",
    ),
    "tray": ("enabled", "autostart", "start_minimized", "open_panel_on_start"),
}


def _restore_runtime(incoming: dict[str, Any], current: dict[str, Any]) -> None:
    """保留目标端的监听地址、端口、密码与网关连接参数。"""
    for section, keys in _RUNTIME_FIELDS.items():
        target = incoming.get(section)
        source = current.get(section)
        if not isinstance(target, dict) or not isinstance(source, dict):
            continue
        for key in keys:
            if key in source:
                target[key] = source[key]


def _restore_secrets(incoming: dict[str, Any], current: dict[str, Any]) -> None:
    """导入包里的 Key 是空的：沿用本机原值；同时保留设备绑定和部署参数。"""
    # AI 配置、知识库与记忆库不参与同步：整段沿用本机（旧包带了也不覆盖）
    for section in ("ai", "knowledge", "memory"):
        if isinstance(current.get(section), dict):
            incoming[section] = current[section]
    for path in _SECRET_PATHS:
        old: Any = current
        for key in path:
            old = old.get(key) if isinstance(old, dict) else None
        node: Any = incoming
        for key in path[:-1]:
            if not isinstance(node, dict):
                node = None
                break
            node = node.setdefault(key, {})
        if isinstance(node, dict) and not node.get(path[-1]) and old:
            node[path[-1]] = old
    incoming["txgod"] = current.get("txgod") or incoming.get("txgod") or {}
    _restore_runtime(incoming, current)


def _add_tree(bundle: zipfile.ZipFile, source: Path, prefix: str) -> int:
    if not source.exists():
        return 0
    count = 0
    if source.is_file():
        bundle.write(source, prefix)
        return 1
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        rel = path.relative_to(source).as_posix()
        bundle.write(path, f"{prefix}/{rel}")
        count += 1
    return count


def export_bundle(config) -> tuple[str, bytes]:
    """打包当前配置与数据，返回 (文件名, zip 内容)。"""
    root: Path = config.paths.root
    conf = config.to_dict()
    _scrub(conf)
    # txgod 是产品级凭据与设备绑定信息，不属于「用户配置」，跨端搬运会破坏授权
    conf.pop("txgod", None)
    # AI 配置、知识库与记忆库的开关也不随这次同步走
    for section in ("ai", "knowledge", "memory"):
        conf.pop(section, None)

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as bundle:
        bundle.writestr(
            "manifest.json",
            json.dumps(
                {
                    "format": FORMAT,
                    "version": _version(),
                    "exported_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "note": "不含 AI 配置、知识库与长期记忆；API Key 留空，导入时沿用目标端原有值",
                },
                ensure_ascii=False,
                indent=2,
            ),
        )
        bundle.writestr(
            "config/config.json",
            json.dumps(conf, ensure_ascii=False, indent=2),
        )
        _add_tree(bundle, root / "plugins_ext", "plugins_ext")
        data_dir: Path = config.paths.data_dir
        if data_dir.is_dir():
            for child in sorted(data_dir.iterdir()):
                if child.name in _EXPORT_SKIP_DATA or child.name.startswith(".import"):
                    continue
                _add_tree(bundle, child, f"data/{child.name}")

    filename = f"qqbot-config-{_version()}.zip"
    return filename, buffer.getvalue()


def export_to_file(config) -> dict[str, Any]:
    """导出并写到 <实例根>/exports/，返回真实路径（内嵌面板不方便走下载）。"""
    filename, payload = export_bundle(config)
    target = Path(config.paths.root) / "exports"
    target.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = target / f"{Path(filename).stem}-{stamp}.zip"
    path.write_bytes(payload)
    return {
        "path": str(path),
        "filename": path.name,
        "size": len(payload),
        "dir": str(target),
    }


def _safe_extract(bundle: zipfile.ZipFile, target: Path) -> None:
    base = target.resolve()
    for member in bundle.infolist():
        if member.is_dir():
            continue
        name = member.filename.replace("\\", "/")
        if name.startswith("/") or ":" in name:
            raise ConfigSyncError(f"压缩包里有非法路径：{member.filename}")
        if any(part == ".." for part in name.split("/")):
            raise ConfigSyncError(f"压缩包里有越界路径：{member.filename}")
        dest = (target / name).resolve()
        if dest != base and base not in dest.parents:
            raise ConfigSyncError(f"压缩包里有越界路径：{member.filename}")
    bundle.extractall(target)


def _check_names(bundle: zipfile.ZipFile) -> None:
    for member in bundle.infolist():
        name = member.filename.replace("\\", "/").rstrip("/")
        if name == "manifest.json":
            continue
        if not any(name == prefix.rstrip("/") or name.startswith(prefix) for prefix in _ALLOWED_PREFIXES):
            raise ConfigSyncError(f"配置包里不允许的文件：{member.filename}")
        parts = name.split("/")
        if parts[0] == "data" and len(parts) > 1 and parts[1] in _SKIP_DATA:
            raise ConfigSyncError(f"配置包里包含不该同步的数据：{member.filename}")


def stage_import(config, payload: bytes) -> dict[str, Any]:
    """校验导入包并放到待应用位置，下次启动时生效。"""
    if len(payload) > _MAX_IMPORT:
        raise ConfigSyncError("配置包超过 200MB，拒绝导入")
    try:
        bundle = zipfile.ZipFile(io.BytesIO(payload))
    except zipfile.BadZipFile as exc:
        raise ConfigSyncError("这不是一个合法的 zip 配置包") from exc

    with bundle:
        if bundle.testzip() is not None:
            raise ConfigSyncError("配置包已损坏，无法解压")
        _check_names(bundle)
        try:
            incoming = json.loads(bundle.read("config/config.json").decode("utf-8"))
        except (KeyError, ValueError, OSError) as exc:
            raise ConfigSyncError("配置包里缺少 config/config.json") from exc
        if not isinstance(incoming, dict):
            raise ConfigSyncError("配置文件格式不正确")
        for section in (
            "bot", "protocol", "webui", "ui", "tray", "txgod", "ai", "tts",
            "image", "sticker", "knowledge", "memory", "admin_nl", "auto_mode",
            "plugins", "custom",
        ):
            if section in incoming and not isinstance(incoming[section], dict):
                raise ConfigSyncError(f"配置文件里的 {section} 段格式不正确")

    data_dir: Path = config.paths.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    pending = data_dir / PENDING_NAME
    temp = data_dir / (PENDING_NAME + ".tmp")
    temp.write_bytes(payload)
    os.replace(temp, pending)

    return {
        "name": str((incoming.get("bot") or {}).get("name") or ""),
        "version": str(_version()),
        "pending": True,
    }


def _backup_config(paths) -> Path | None:
    """导入前留一份旧配置，出问题时可以从 bak 文件恢复。"""
    if not paths.config_file.is_file():
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = paths.config_file.with_name(f"config.json.bak-{stamp}")
    try:
        shutil.copy2(paths.config_file, backup)
    except OSError:
        return None
    for old in sorted(paths.config_file.parent.glob("config.json.bak-*"))[:-3]:
        try:
            old.unlink()
        except OSError:
            pass
    return backup


def _record_import(data_dir: Path, incoming: dict[str, Any], backup: Path | None) -> None:
    """留一条导入记录，排查“导入后打不开面板”时有据可查。"""
    try:
        webui = incoming.get("webui") or {}
        line = (
            f"{time.strftime('%Y-%m-%d %H:%M:%S')} 导入 "
            f"{((incoming.get('bot') or {}).get('name') or '')} "
            f"host={webui.get('host')} port={webui.get('port')} "
            f"backup={backup.name if backup else '无'}\n"
        )
        with (data_dir / "import.log").open("a", encoding="utf-8") as fp:
            fp.write(line)
    except OSError:
        pass


def apply_pending(paths) -> bool:
    """启动时应用待导入的配置包；成功返回 True。"""
    data_dir: Path = paths.data_dir
    pending = data_dir / PENDING_NAME
    if not pending.is_file():
        return False
    staging = data_dir / ".import-staging"
    shutil.rmtree(staging, ignore_errors=True)
    try:
        with zipfile.ZipFile(pending) as bundle:
            if bundle.testzip() is not None:
                raise ConfigSyncError("配置包已损坏")
            _check_names(bundle)
            staging.mkdir(parents=True, exist_ok=True)
            _safe_extract(bundle, staging)

        incoming = json.loads((staging / "config" / "config.json").read_text("utf-8"))
        if not isinstance(incoming, dict):
            raise ConfigSyncError("配置文件格式不正确")
        try:
            current = json.loads(paths.config_file.read_text("utf-8"))
        except (OSError, ValueError):
            current = {}
        if not isinstance(current, dict):
            current = {}
        _restore_secrets(incoming, current)

        paths.config_file.parent.mkdir(parents=True, exist_ok=True)
        backup = _backup_config(paths)
        paths.config_file.write_text(
            json.dumps(incoming, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        _record_import(data_dir, incoming, backup)

        for name in _REPLACE_DATA_DIRS:
            source = staging / "data" / name
            target = data_dir / name
            if not source.is_dir():
                continue
            shutil.rmtree(target, ignore_errors=True)
            shutil.move(str(source), str(target))

        silence = staging / "data" / "silence.json"
        if silence.is_file():
            shutil.copy2(silence, data_dir / "silence.json")

        ext = staging / "plugins_ext"
        if ext.is_dir():
            shutil.rmtree(paths.plugin_dir, ignore_errors=True)
            shutil.move(str(ext), str(paths.plugin_dir))

        return True
    except Exception:  # noqa: BLE001 - 坏包不能每次启动都重试
        failed = data_dir / FAILED_NAME
        try:
            os.replace(pending, failed)
        except OSError:
            pass
        return False
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        try:
            if pending.exists():
                pending.unlink()
        except OSError:
            pass
