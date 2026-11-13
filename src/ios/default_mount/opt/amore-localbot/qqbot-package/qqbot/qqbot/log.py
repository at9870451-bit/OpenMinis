"""统一日志：同时输出到控制台与文件，可被 WebUI 读取。"""

from __future__ import annotations

import logging
import sys
from collections import deque
from logging.handlers import RotatingFileHandler
from pathlib import Path

_RING: deque[str] = deque(maxlen=500)


class _RingHandler(logging.Handler):
    """把日志留在内存环形缓冲里，供 WebUI 实时展示。"""

    def emit(self, record: logging.LogRecord) -> None:
        try:
            _RING.append(self.format(record))
        except Exception:  # noqa: BLE001 - 日志本身不能抛错
            pass


def recent_logs(limit: int = 200) -> list[str]:
    lines = list(_RING)
    return lines[-limit:]


def setup_logging(log_file: Path, level: str = "INFO") -> logging.Logger:
    root = logging.getLogger("qqbot")
    root.setLevel(level.upper())
    root.handlers.clear()

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s", datefmt="%H:%M:%S"
    )

    # 打包为无控制台窗口的 exe 时 sys.stdout 为 None，此时跳过控制台输出
    if sys.stdout is not None:
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        root.addHandler(console)

    log_file.parent.mkdir(parents=True, exist_ok=True)
    # 托盘程序长期运行，日志需要轮转，避免无限增长
    file_handler = RotatingFileHandler(
        log_file, maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    file_handler.setFormatter(fmt)
    root.addHandler(file_handler)

    ring = _RingHandler()
    ring.setFormatter(fmt)
    root.addHandler(ring)

    return root


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(f"qqbot.{name}")