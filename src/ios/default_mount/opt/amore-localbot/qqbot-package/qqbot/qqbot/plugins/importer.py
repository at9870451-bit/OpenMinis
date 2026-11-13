"""自定义插件导入：上传 → 子进程自检 → 全部通过才落盘 → 热加载。

支持两种形态（和插件管理器能识别的形态一致）：
  - 单文件：``xxx.py``
  - 目录包：``xxx/__init__.py``（可带子模块、``assets/`` 与自带面板 ``panel.html``），
    打成 zip 上传

**安全边界（必须对用户说清楚）**：加载插件就是执行它里面的代码，所以
「导入时自动测试」只能挡住在子进程里**当场报错**的插件，挡不住蓄意作恶的
插件——后者完全可以等到 self_check 之后再动手。真正的护栏是：
测试跑在独立子进程里（超时杀掉，拖不垮主程序）、导入前要用户确认风险、
导入后把来源与哈希记进日志方便追溯。
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Any

from ..log import get_logger

log = get_logger("plugins.import")

#: 单个插件包最大体积。插件是代码不是素材，超过这个数基本可以判定传错了
MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
#: 解压后总大小上限，防 zip 炸弹
MAX_UNPACKED_BYTES = 128 * 1024 * 1024
#: 外层兜底超时（秒）。子进程内部每一步还有 15 秒超时，这里放得更宽；
#: 真正兜住「同步死循环」的是这一层——超时直接把子进程杀掉。
#: 60 > 15×3，所以正常情况下用户看到的是精确到步骤的报错，而不是笼统的超时。
TEST_TIMEOUT = 60.0
#: 压缩包里不参与「找入口」的目录/文件
_IGNORED_NAMES = {"__MACOSX", "__pycache__", ".DS_Store", ".git", ".idea", ".vscode"}


class PluginImportError(Exception):
    """导入失败。message 直接给用户看，steps 是自检过程明细。"""

    def __init__(self, message: str, *, steps: list[dict[str, Any]] | None = None) -> None:
        super().__init__(message)
        self.steps = steps or []


def _ignored(path: Path) -> bool:
    return path.name in _IGNORED_NAMES or path.name.startswith(".")


def _rmtree(path: Path) -> None:
    """删目录；Windows 上句柄释放有一点延迟，失败就多试几次。

    sqlite 文件尤其容易刚被关掉就还被系统占着一小会儿，一次 rmtree 常常删不掉。
    """
    if not path.exists():
        return
    for attempt in range(4):
        if path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                path.unlink()
            except OSError:
                pass
        if not path.exists():
            return
        time.sleep(0.25 * (attempt + 1))
    if path.exists():
        log.warning("临时目录未能完全删除：%s", path)


# ---------- 解压与定位入口 ----------


def _safe_extract(bundle: zipfile.ZipFile, target: Path) -> None:
    """解压并挡住 zip slip（``../`` 越界）与 zip 炸弹。"""
    base = target.resolve()
    total = 0
    for info in bundle.infolist():
        name = info.filename
        parts = Path(name.replace("\\", "/")).parts
        if name.startswith(("/", "\\")) or ".." in parts or (parts and ":" in parts[0]):
            raise PluginImportError(f"压缩包内含非法路径：{name}")
        dest = (base / name).resolve()
        if dest != base and base not in dest.parents:
            raise PluginImportError(f"压缩包内含越界路径：{name}")
        total += int(info.file_size or 0)
    if total > MAX_UNPACKED_BYTES:
        raise PluginImportError("压缩包解压后体积过大，已拒绝导入")
    bundle.extractall(base)


def _entry_in_dir(directory: Path) -> Path:
    if (directory / "__init__.py").is_file():
        return directory / "__init__.py"
    direct = [
        p for p in sorted(directory.iterdir())
        if p.is_file() and p.suffix == ".py" and not _ignored(p)
    ]
    if len(direct) == 1:
        return direct[0]
    subs = [
        p for p in sorted(directory.iterdir()) if p.is_dir() and not _ignored(p)
    ]
    if not direct and len(subs) == 1:  # 有人会把插件目录再套一层
        return _entry_in_dir(subs[0])
    raise PluginImportError(
        f"目录「{directory.name}」里没有 __init__.py，也找不到唯一的 .py 入口"
    )


def _find_entry(root: Path) -> Path:
    """在解压结果里找出插件入口：单个 .py，或含 __init__.py 的目录包。"""
    if (root / "__init__.py").is_file():
        return root / "__init__.py"
    items = [p for p in sorted(root.iterdir()) if not _ignored(p)]
    if not items:
        raise PluginImportError("压缩包是空的")
    if len(items) == 1:
        only = items[0]
        if only.is_file():
            if only.suffix != ".py":
                raise PluginImportError(
                    f"压缩包里是 {only.name}，只支持 .py 源码或含 __init__.py 的目录包"
                )
            return only
        return _entry_in_dir(only)
    dirs = [p for p in items if p.is_dir()]
    files = [p for p in items if p.is_file() and p.suffix == ".py"]
    if len(dirs) == 1 and not files:
        return _entry_in_dir(dirs[0])
    if len(files) == 1 and not dirs:
        return files[0]
    raise PluginImportError(
        "压缩包里必须只有一个插件：单个 .py，或一个含 __init__.py 的目录包"
    )


def _prepare(upload: Path, workdir: Path) -> Path:
    """把上传内容摊开，返回入口文件路径。"""
    if upload.suffix.lower() == ".py":
        return upload
    target = workdir / "unpacked"
    target.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(upload) as bundle:
            _safe_extract(bundle, target)
    except zipfile.BadZipFile as exc:
        raise PluginImportError(f"不是有效的 zip 文件：{exc}") from exc
    return _find_entry(target)


# ---------- 子进程自检 ----------


def _kill_tree(proc: subprocess.Popen) -> None:
    """连同 PyInstaller 单文件 exe 解出来的子进程一起杀掉。

    打包成 onefile 后，直接拉起的进程只是「引导进程」，真正的 Python 代码跑在
    它再起的一个子进程里。只杀直接子进程会留下一个还在死循环的孤儿进程，
    既占内存又可能占端口，所以这里按进程树杀。

    （顺带说明为什么不用 subprocess.run(capture_output=…)：它在超时后会
    kill 再 communicate，而孤儿子进程仍持有那对管道，communicate 会一直等
    EOF，反倒把父进程也拖住。所以输出一律重定向到文件，不接管道。）
    """
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                capture_output=True,
                timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            return
        except Exception as exc:  # noqa: BLE001 - 退回单进程 kill
            log.debug("taskkill 失败：%s", exc)
    else:
        try:
            import signal

            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            return
        except Exception as exc:  # noqa: BLE001
            log.debug("killpg 失败：%s", exc)
    try:
        proc.kill()
    except Exception as exc:  # noqa: BLE001
        log.debug("kill 失败：%s", exc)


def _run_selftest(entry: Path, workdir: Path, instance_id: str, timeout: float) -> dict[str, Any]:
    from ..instances import launch_command

    result_file = workdir / "selftest.json"
    stdout_file = workdir / "selftest.out"
    stderr_file = workdir / "selftest.err"
    sandbox = workdir / "sandbox"
    command = launch_command(
        instance_id,
        [
            "--plugin-test", str(entry),
            "--plugin-test-result", str(result_file),
            # 沙箱放在自己的工作目录里：子进程被强杀时它来不及自清，
            # 由这里统一删掉，不会在系统临时目录里越堆越多。
            "--plugin-test-sandbox", str(sandbox),
        ],
    )
    spawn_kwargs: dict[str, Any] = {"stdin": subprocess.DEVNULL}
    if os.name == "nt":
        spawn_kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    else:
        spawn_kwargs["start_new_session"] = True  # 便于整组杀掉

    try:
        with stdout_file.open("wb") as out, stderr_file.open("wb") as err:
            proc = subprocess.Popen(command, stdout=out, stderr=err, **spawn_kwargs)
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _kill_tree(proc)
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    log.warning("自检进程在超时处理后仍未退出：pid=%s", proc.pid)
                raise PluginImportError(
                    f"自检超时（超过 {timeout:.0f} 秒），已终止自检进程。"
                    "插件里可能有死循环、长时间阻塞或等待网络。",
                    steps=[{"name": "子进程自检", "ok": False, "detail": "超时被终止", "warn": False}],
                ) from None
    except OSError as exc:
        raise PluginImportError(f"无法启动自检进程：{exc}") from exc

    if result_file.is_file():
        try:
            report = json.loads(result_file.read_text("utf-8"))
        except (OSError, ValueError) as exc:
            raise PluginImportError(f"自检结果无法解析：{exc}") from exc
        if isinstance(report, dict):
            return report

    tail = ""
    try:
        tail = stderr_file.read_bytes()[-800:].decode("utf-8", "replace").strip()
    except OSError:
        pass
    detail = "自检进程没有留下结果，插件很可能在加载阶段就让进程退出了（例如 sys.exit、段错误）。"
    if tail:
        detail += f"\n进程输出：{tail}"
    raise PluginImportError(
        detail, steps=[{"name": "子进程自检", "ok": False, "detail": detail, "warn": False}]
    )


# ---------- 落盘 ----------


def _install(entry: Path, plugin_dir: Path) -> Path:
    """把通过自检的插件原子地放进插件目录，返回落盘路径。"""
    plugin_dir.mkdir(parents=True, exist_ok=True)
    if entry.name == "__init__.py":
        destination = plugin_dir / entry.parent.name
        staging = plugin_dir / f".{destination.name}.importing"
        _rmtree(staging)
        shutil.copytree(
            entry.parent, staging, ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
        )
    else:
        destination = plugin_dir / entry.name
        staging = plugin_dir / f".{destination.name}.importing"
        _rmtree(staging)
        shutil.copy2(entry, staging)

    backup = plugin_dir / f".{destination.name}.old"
    _rmtree(backup)
    if destination.exists():
        destination.replace(backup)
    try:
        shutil.move(str(staging), str(destination))
    except OSError as exc:
        if backup.exists():  # 失败就把旧版本放回去，别让用户两头空
            backup.replace(destination)
        raise PluginImportError(f"写入插件目录失败：{exc}") from exc
    _rmtree(backup)
    return destination


def _audit(audit_file: Path | None, record: dict[str, Any]) -> None:
    if audit_file is None:
        return
    try:
        audit_file.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(record, ensure_ascii=False)
        with audit_file.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError as exc:
        log.warning("写入插件导入审计日志失败: %s", exc)


def install_plugin(
    *,
    plugin_dir: Path,
    filename: str,
    data: bytes,
    confirm: bool,
    instance_id: str = "",
    actor: str = "面板",
    audit_file: Path | None = None,
    timeout: float = TEST_TIMEOUT,
) -> dict[str, Any]:
    """完整走一遍「校验 → 子进程自检 → 落盘」，失败抛 PluginImportError。"""
    if not confirm:
        raise PluginImportError("未确认风险提示，已取消导入")
    if not data:
        raise PluginImportError("上传内容为空")
    if len(data) > MAX_ARCHIVE_BYTES:
        raise PluginImportError(
            f"插件包过大（{len(data) / 1024 / 1024:.1f} MB），上限 "
            f"{MAX_ARCHIVE_BYTES // 1024 // 1024} MB"
        )
    suffix = Path(filename).suffix.lower()
    if suffix not in (".py", ".zip"):
        raise PluginImportError("只支持上传 .py 单文件插件或 .zip 目录包")

    digest = hashlib.sha256(data).hexdigest()
    workdir = Path(tempfile.mkdtemp(prefix="qqbot-plugin-import-"))
    try:
        upload = workdir / Path(filename).name
        upload.write_bytes(data)
        entry = _prepare(upload, workdir)

        report = _run_selftest(entry, workdir, instance_id, timeout)
        if not report.get("ok"):
            raise PluginImportError(
                str(report.get("error") or "自检未通过"),
                steps=list(report.get("steps") or []),
            )

        plugin = report.get("plugin") or {}
        destination = _install(entry, plugin_dir)
        installed = str(destination)
        entry_path = str(
            destination / "__init__.py" if destination.is_dir() else destination
        )

        record = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "actor": actor,
            "source": filename,
            "sha256": digest,
            "size": len(data),
            "plugin": plugin.get("name", ""),
            "version": plugin.get("version", ""),
            "installed_path": installed,
        }
        # 面板日志与审计日志都记一份：面板日志会滚动，审计日志长期留存
        log.info(
            "插件导入成功 name=%s v%s 来源=%s sha256=%s 导入者=%s",
            record["plugin"], record["version"], filename, digest, actor,
        )
        _audit(audit_file, record)

        return {
            "plugin": plugin,
            "steps": list(report.get("steps") or []),
            "warnings": list(report.get("warnings") or []),
            "sha256": digest,
            "size": len(data),
            "source": filename,
            "installed_path": installed,
            "installed_entry": entry_path,
        }
    finally:
        _rmtree(workdir)
