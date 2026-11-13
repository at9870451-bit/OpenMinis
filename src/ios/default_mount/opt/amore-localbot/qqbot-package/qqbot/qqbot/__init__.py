"""自研 QQ 机器人框架。

架构分层：
    core      事件模型、事件总线、Bot 主控生命周期
    protocol  协议适配层（可插拔：mock / onebot / 自研 NT）
    plugins   插件系统与热加载
    ai        大模型接入
    webui     本地配置面板与 HTTP API
    tray      系统托盘与开机自启
"""

import os as _os
import sys as _sys

__version__ = "2.0.9"

#: 增量更新：run.py 启动时会把这几个环境变量指向 data/updates/<版本>/
_update_version = _os.environ.get("QQBOT_UPDATE_VERSION")
if _update_version:
    __version__ = _update_version

_update_dir = _os.environ.get("QQBOT_UPDATE_DIR")


def _install_update_finder(overlay: str) -> None:
    """让覆盖目录里的模块优先于 exe 内置的模块加载。

    PyInstaller 打包后，子模块由内置的冻结导入器解析；只把目录塞进 sys.path
    是不够的（子包不会去那里找）。所以在 meta_path 最前面挂一个只认 qqbot.*
    的查找器：覆盖目录里有同名 .pyc/.py 就用它，没有就退回内置模块。
    包的 __init__ 不覆盖，避免破坏 pkgutil 对内置插件的枚举。
    """
    import importlib.util
    from importlib.machinery import SourceFileLoader, SourcelessFileLoader
    from pathlib import Path

    base = Path(overlay)
    if not (base / "qqbot").is_dir():
        return
    for finder in _sys.meta_path:
        if getattr(finder, "_qqbot_overlay", False):
            return

    class _OverlayFinder:
        _qqbot_overlay = True

        def find_spec(self, fullname, path=None, target=None):
            if fullname != "qqbot" and not fullname.startswith("qqbot."):
                return None
            rel = Path(*fullname.split("."))
            for suffix, loader_cls in ((".pyc", SourcelessFileLoader), (".py", SourceFileLoader)):
                candidate = base / rel.with_suffix(suffix)
                if candidate.is_file() and candidate.stem != "__init__":
                    return importlib.util.spec_from_file_location(
                        fullname, str(candidate), loader=loader_cls(fullname, str(candidate))
                    )
            return None

    _sys.meta_path.insert(0, _OverlayFinder())


if _update_dir:
    _install_update_finder(_update_dir)
