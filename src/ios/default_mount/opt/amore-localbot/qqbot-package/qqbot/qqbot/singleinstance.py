"""单实例保护。

同一目录下只允许一个实例运行，避免多个进程抢占同一 WebUI 端口、
重复连接协议后端。使用文件锁实现，跨平台兼容。
"""

from __future__ import annotations

import os
from pathlib import Path

from .log import get_logger

log = get_logger("singleinstance")


class SingleInstance:
    def __init__(self, lock_file: Path) -> None:
        self.lock_file = lock_file
        self._fd: int | None = None

    def acquire(self) -> bool:
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._fd = os.open(self.lock_file, os.O_RDWR | os.O_CREAT, 0o644)
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(self._fd, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

            os.ftruncate(self._fd, 0)
            os.write(self._fd, str(os.getpid()).encode("ascii"))
            return True
        except OSError:
            self._close()
            return False

    def release(self) -> None:
        if self._fd is None:
            return
        try:
            if os.name == "nt":
                import msvcrt

                os.lseek(self._fd, 0, os.SEEK_SET)
                msvcrt.locking(self._fd, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._fd, fcntl.LOCK_UN)
        except OSError:
            pass
        finally:
            self._close()

    def _close(self) -> None:
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None