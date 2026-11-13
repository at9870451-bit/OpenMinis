"""连接异常邮件通知：OneBot 断开时第一时间提醒用户。

使用 QQ 邮箱 SMTP（smtp.qq.com:465，SSL），发件账号与授权码都由用户在置控台填写。
同一进程内做冷却，避免断线重连时每 5 秒发一封把邮箱塞满。
"""

from __future__ import annotations

import asyncio
import smtplib
import ssl
import time
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr

from .log import get_logger

log = get_logger("notify")

#: 上一次成功发信的时间戳（进程内冷却）
_last_sent = 0.0

SMTP_HOST = "smtp.qq.com"
SMTP_PORT = 465


def _send_sync(email: str, qq: str, auth_code: str, subject: str, body: str) -> None:
    """同步发信，放到线程里执行，避免阻塞事件循环。"""
    sender = f"{qq}@qq.com"
    message = MIMEText(body, "plain", "utf-8")
    message["Subject"] = Header(subject, "utf-8")
    message["From"] = formataddr((str(Header("QQ机器人", "utf-8")), sender))
    message["To"] = email
    with smtplib.SMTP_SSL(
        SMTP_HOST, SMTP_PORT, context=ssl.create_default_context(), timeout=15
    ) as smtp:
        smtp.login(sender, auth_code)
        smtp.sendmail(sender, [email], message.as_string())


async def send_mail(
    email: str,
    qq: str,
    auth_code: str,
    subject: str = "QQ机器人异常通知",
    body: str = "",
) -> tuple[bool, str]:
    """发一封邮件，返回 (是否成功, 错误信息)。"""
    if not email or not qq or not auth_code:
        return False, "邮箱、发件 QQ 号或授权码未填写"
    try:
        await asyncio.to_thread(_send_sync, email, qq, auth_code, subject, body)
        return True, ""
    except Exception as exc:  # noqa: BLE001 - 网络/SMTP 错误都只记日志
        log.warning("发送通知邮件失败: %s", exc)
        return False, str(exc)


async def notify_connection_error(config, reason: str = "") -> bool:
    """OneBot 连接异常时调用；未启用、信息不全或还在冷却期都直接跳过。"""
    global _last_sent

    cfg = getattr(config, "console", None)
    if cfg is None or not cfg.notify_enabled:
        return False
    email = str(cfg.notify_email or "").strip()
    qq = str(cfg.notify_qq or "").strip()
    auth_code = str(cfg.notify_auth_code or "").strip()
    if not email or not qq or not auth_code:
        return False

    now = time.time()
    cooldown = max(60, int(cfg.notify_cooldown or 1800))
    if _last_sent and now - _last_sent < cooldown:
        log.info("连接异常通知仍在冷却期，跳过本次发信")
        return False

    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    body = (
        "QQ机器人异常通知\n\n"
        f"时间：{stamp}\n"
        "检测到 OneBot 连接异常，机器人可能已离线，请检查协议端（如 NapCat）是否在线。\n"
    )
    if reason:
        body += f"异常信息：{reason}\n"
    body += "\n本邮件由 QQBot 自动发送，同一问题在冷却时间内不会重复提醒。\n"

    ok, error = await send_mail(email, qq, auth_code, "QQ机器人异常通知", body)
    if ok:
        _last_sent = now
        log.info("已发送连接异常通知邮件到 %s", email)
    else:
        log.warning("连接异常通知邮件未发出: %s", error)
    return ok
