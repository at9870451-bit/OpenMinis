"""公告与版本更新服务对接。

协议要求：
- 每次请求带签名 ``HMAC-SHA256(secret, code + device_id + timestamp + nonce)``，
  公告与版本检查不需要卡密，``code`` 传空串即可；
- 请求头固定四项：``X-App-Id`` / ``X-Timestamp`` / ``X-Nonce`` / ``X-Sign``；
- 服务端使用自签证书，按接入文档忽略证书校验；
- 服务端只接受 ±300 秒内的时间戳，首次请求前先用 ``/health`` 对一次表。

设备号取 Windows ``MachineGuid`` 做哈希，首次算好后固化到 ``data/txgod.json``，
避免系统信息变化导致设备号漂移。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .config import Config

DEFAULT_SERVER = "https://118.89.134.160:8999/api"
DEVICE_PREFIX = "AIXIFU-"
API_TIMEOUT = 10.0
CLOCK_SYNC_INTERVAL = 300.0
STATE_NAME = "txgod.json"

# 内置密钥做异或处理，避免可执行文件里出现明文
_SEED = [
    108, 107, 105, 111, 111, 99, 62, 57, 60, 104, 106, 98, 59, 62, 57, 107,
    56, 106, 106, 63, 109, 56, 107, 107, 108, 63, 63, 108, 99, 108, 108, 108,
    63, 109, 110, 111, 99, 111, 59, 111, 110, 62, 104, 62, 60, 98, 107, 111,
]


class TxgodError(Exception):
    """接口错误：code 为服务端错误码，0 表示网络 / 解析问题。"""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = int(code)
        self.message = str(message)


def _embedded_secret() -> str:
    return bytes(value ^ 0x5A for value in _SEED).decode("utf-8")


def _ssl_ctx() -> ssl.SSLContext:
    """自签证书：按文档忽略校验。"""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _machine_raw() -> str:
    """机器指纹原文：优先 MachineGuid，回退主机名 + 网卡 MAC。"""
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Cryptography",
            0,
            winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
        ) as key:
            value, _kind = winreg.QueryValueEx(key, "MachineGuid")
            if value:
                return str(value)
    except Exception:  # noqa: BLE001 - 读不到就走回退
        pass
    try:
        import socket

        return f"{socket.gethostname()}|{uuid.getnode():012X}"
    except Exception:  # noqa: BLE001
        return f"{uuid.getnode():012X}"


def compute_device_id() -> str:
    digest = hashlib.sha256(_machine_raw().encode("utf-8")).hexdigest()[:16].upper()
    return DEVICE_PREFIX + digest


def _version_tuple(text: Any) -> tuple:
    """'1.2.0' → (1, 2, 0)：只取每段里的数字，非法段记 0。"""
    parts = []
    for chunk in str(text or "").split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts) or (0,)


def evaluate_version(info: dict, current: str) -> tuple[bool, bool]:
    """把服务端返回归一成 (need_update, force_update)。

    服务端显式给了字段就照它执行；缺失时按 latest / min_version 自行判断。
    """
    data = info or {}
    latest = data.get("latest") or ""
    client = str(data.get("current") or current or "")
    min_version = data.get("min_version") or ""

    # 版本已经对上（或比服务端还新）时，服务端再怎么说需要更新都不采信。
    # 否则会出现「当前 1.1.8 / 最新 1.1.8 却强制更新」这种自相矛盾的弹窗。
    if latest and _version_tuple(latest) <= _version_tuple(client):
        return False, False

    need = data.get("need_update")
    if need is None:
        need = bool(latest) and _version_tuple(latest) > _version_tuple(client)

    force = data.get("force_update")
    if force is None:
        force = bool(min_version) and _version_tuple(client) < _version_tuple(min_version)

    return bool(need), bool(force)


def _parse_utc(text: Any) -> float:
    """服务端 UTC 时间串 → 时间戳；解析不了返回 0。"""
    if not text:
        return 0.0
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(str(text), fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return 0.0


class TxgodClient:
    """一个产品实例的公告 / 版本客户端（同步方法，调用方放线程里跑）。"""

    def __init__(self, config: Config):
        self.config = config
        section = config.txgod
        self.server = (section.server or DEFAULT_SERVER).rstrip("/")
        self.app_id = str(section.app_id or "").strip()
        self.secret = str(section.secret or "").strip() or _embedded_secret()
        self.device_id = self._load_device()
        self._clock_offset = 0.0
        self._clock_synced_at = 0.0

    # ---------- 本地状态 ----------

    @property
    def state_path(self) -> Path:
        return self.config.paths.data_dir / STATE_NAME

    def _load_device(self) -> str:
        device = ""
        try:
            state = json.loads(self.state_path.read_text("utf-8"))
            if isinstance(state, dict):
                device = str(state.get("device_id") or "")
        except (OSError, ValueError):
            pass
        if not device:
            device = str(self.config.txgod.device_id or "").strip() or compute_device_id()
        self._save_device(device)
        return device

    def _save_device(self, device: str) -> None:
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            self.state_path.write_text(
                json.dumps({"device_id": device}, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except OSError:
            pass
        if self.config.txgod.device_id != device:
            self.config.txgod.device_id = device
            try:
                self.config.save()
            except OSError:
                pass

    @property
    def skipped_version(self) -> str:
        return str(self.config.txgod.skipped_version or "")

    def remember_skip(self, version: str) -> None:
        self.config.txgod.skipped_version = str(version or "").strip()
        self.config.save()

    # ---------- 签名与请求 ----------

    def sync_clock(self) -> None:
        """用 ``/health`` 的 UTC 时间校正本机偏差，最多每 5 分钟一次。"""
        now = time.time()
        if now - self._clock_synced_at < CLOCK_SYNC_INTERVAL:
            return
        try:
            data = self._request("GET", "/health", sign=False)
        except TxgodError:
            return
        server_ts = _parse_utc(data.get("time"))
        if server_ts:
            self._clock_offset = server_ts - time.time()
            self._clock_synced_at = time.time()

    def _sign_headers(self) -> dict[str, str]:
        timestamp = str(int(time.time() + self._clock_offset))
        nonce = secrets.token_hex(8)
        message = f"{''}{self.device_id}{timestamp}{nonce}".encode("utf-8")
        signature = hmac.new(self.secret.encode("utf-8"), message, hashlib.sha256).hexdigest()
        return {
            "X-App-Id": self.app_id,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Sign": signature,
        }

    def _request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        query: dict | None = None,
        sign: bool = True,
    ) -> dict:
        url = self.server + path
        if query:
            url += "?" + urllib.parse.urlencode(query)

        body = None
        if payload is not None:
            # 不能带 BOM，否则服务端会当成缺少参数
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

        headers = {"Content-Type": "application/json"}
        if sign:
            headers.update(self._sign_headers())

        request = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=API_TIMEOUT, context=_ssl_ctx()) as response:
                raw = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            code, message = int(exc.code), f"服务返回 {exc.code}"
            try:
                error = (json.loads(raw) or {}).get("error") or {}
                code = int(error.get("code") or code)
                message = str(error.get("message") or message)
            except (ValueError, TypeError, AttributeError):
                pass
            raise TxgodError(code, message) from None
        except Exception as exc:  # noqa: BLE001 - 网络异常统一按连不上处理
            raise TxgodError(0, f"无法连接更新服务（{type(exc).__name__}）") from None

        try:
            data = json.loads(raw or "{}")
        except ValueError:
            raise TxgodError(0, "更新服务返回内容无法解析") from None
        if not isinstance(data, dict):
            raise TxgodError(0, "更新服务返回格式异常")
        return data

    # ---------- 业务接口 ----------

    def fetch_announcement(self) -> dict:
        """读取公告；返回空字典表示暂无公告。"""
        self.sync_clock()
        data = self._request("GET", "/announcement", query={"app_id": self.app_id})
        raw = data.get("announcement") or data.get("data") or {}
        if not isinstance(raw, dict) or not raw:
            return {}
        # 服务端可能按 app_id 下发专属公告；不匹配的不要展示
        raw_app = str(raw.get("app_id") or "")
        if raw_app and self.app_id and raw_app != self.app_id:
            return {}
        return {
            "title": str(raw.get("title") or ""),
            "content": str(raw.get("content") or ""),
            "updated_time": str(raw.get("updated_time") or raw.get("updatedTime") or ""),
        }

    def check_version(self, current: str) -> dict:
        """检查版本；返回统一字段供界面直接使用。"""
        self.sync_clock()
        data = self._request(
            "GET",
            "/version/check",
            query={"version": current, "app_id": self.app_id},
        )

        latest: str | None = None
        download_url = ""
        notes = ""
        raw_latest = data.get("latest")
        if isinstance(raw_latest, str):
            latest = raw_latest.strip() or None
        elif isinstance(raw_latest, dict):
            value = raw_latest.get("version")
            latest = str(value).strip() if value else None
            download_url = str(
                raw_latest.get("download_url") or raw_latest.get("downloadUrl") or ""
            ).strip()
            notes = str(raw_latest.get("changelog") or raw_latest.get("notes") or "").strip()

        if not download_url:
            download_url = str(data.get("download_url") or data.get("downloadUrl") or "").strip()
        if not notes:
            notes = str(data.get("changelog") or data.get("notes") or "").strip()
        if download_url and not download_url.lower().startswith(("http://", "https://")):
            download_url = "https://" + download_url.lstrip("/")

        # 服务端可能把 latest 返回成对象，先归一成版本号再比较
        normalized = dict(data)
        normalized["latest"] = latest or ""
        need, force = evaluate_version(normalized, current)
        return {
            "current": str(data.get("current") or current),
            "latest": latest,
            "need_update": need,
            "force_update": force,
            "download_url": download_url,
            "notes": notes,
            "min_version": str(data.get("min_version") or ""),
        }


__all__ = ["TxgodClient", "TxgodError", "compute_device_id", "evaluate_version"]
