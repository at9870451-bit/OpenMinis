"""路线 B 探针：尝试用原生库自建 NT Session Shell。

原理
    wrapper.node 导出了静态工厂
        nt::wrapper::INTSessionShell::CreateNTSessionShell(std::string const&)
    但它没有 napi_register_module_v1，所以 Node 的 require 走不通
    （已实测：Module did not self-register）。本探针改为直接用
    LoadLibrary + GetProcAddress 调这个工厂，再读取返回对象的虚表。

为什么不用 C++ 编译器
    ctypes 就能完成 LoadLibrary / GetProcAddress / 原始 ABI 调用，而且对
    跨模块 STL 的 ABI 掌控更彻底：这里手工构造 MSVC 布局的 std::string
    （32 字节：16 字节 SSO 缓冲 + size + capacity），而不是依赖本进程的 std。

风险
    调用失败会让本进程崩溃（0xC0000005），因此**必须在子进程中运行**。
    输出逐行 flush 落盘，崩溃前的进度不会丢。

用法
    python -m qqbot.protocol.nt_custom.re.probe_shell "QQ" 结果文件.txt
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import IO

QQ_ROOT = Path(r"E:\EXE\Tencent")
MAX_VTABLE_SLOTS = 64


def find_version_dir() -> Path | None:
    base = QQ_ROOT / "versions"
    if not base.is_dir():
        return None
    candidates = sorted((d for d in base.iterdir() if d.is_dir()), reverse=True)
    return candidates[0] if candidates else None


class MSVCString(ctypes.Structure):
    """MSVC std::string 的内存布局（x64，32 字节）。"""

    _fields_ = [
        ("buf", ctypes.c_char * 16),  # SSO 缓冲 / 指针
        ("size", ctypes.c_size_t),
        ("capacity", ctypes.c_size_t),
    ]


def make_msvc_string(text: str) -> MSVCString:
    raw = text.encode("utf-8")
    if len(raw) > 15:
        raise ValueError("探针只支持 15 字节以内的短字符串")
    value = MSVCString()
    value.buf = raw + b"\x00" * (16 - len(raw))
    value.size = len(raw)
    value.capacity = 15
    return value


class Probe:
    def __init__(self, out: IO[str]) -> None:
        self.out = out

    def say(self, message: str) -> None:
        print(message, flush=True)
        self.out.write(message + "\n")
        self.out.flush()

    def analyse_calls(self, base: int, proc_addr: int, wrapper: Path) -> None:
        """扫描函数开头，把 call/jmp [rip+disp32] 目标还原成导入符号名。

        这能直接回答「工厂为什么崩」：若开头就调用 v8/napi 相关导入，
        说明它依赖 QQNT.dll 已初始化的 Node/V8 运行时。
        """
        from .pe import PEFile

        self.say("[2.5] 静态分析工厂函数的早期调用目标")
        try:
            code = ctypes.string_at(proc_addr, 384)
        except Exception as exc:  # noqa: BLE001
            self.say(f"    读取代码失败: {exc}")
            return

        with PEFile(wrapper) as pe:
            thunks = pe.import_thunks()
        self.say(f"    本模块 IAT 槽位共 {len(thunks)} 个")

        hits: list[tuple[int, str]] = []
        for index in range(len(code) - 6):
            if code[index] == 0xFF and code[index + 1] in (0x15, 0x25):
                disp = int.from_bytes(code[index + 2 : index + 6], "little", signed=True)
                target = proc_addr + index + 6 + disp
                symbol = thunks.get(target - base)
                if symbol:
                    kind = "call" if code[index + 1] == 0x15 else "jmp "
                    hits.append((index, f"{kind} -> {symbol}"))
            if len(hits) >= 25:
                break

        if not hits:
            self.say("    未发现指向导入表的早期调用（可能全是内部调用）")
            return
        for offset, text in hits:
            self.say(f"    +0x{offset:03X}  {text}")

    def check_runtime(self, version_dir: Path) -> None:
        """检查 QQNT.dll 提供的 Node/V8 运行时是否已初始化。

        wrapper.node 从 QQNT.dll 导入 99 个符号（含 v8::Isolate::GetCurrent
        和 napi_*）。若这里返回 NULL，说明没有 V8 环境，工厂内部的
        「取当前 isolate」之类操作必然解引用空指针 —— 与实测的
        "access violation reading 0x2" 吻合。
        """
        self.say("[2.6] 运行时体检：V8 isolate 是否已初始化")
        qqnt = version_dir / "QQNT.dll"
        if not qqnt.is_file():
            self.say(f"    找不到 {qqnt}")
            return
        try:
            node_lib = ctypes.WinDLL(str(qqnt))
        except OSError as exc:
            self.say(f"    加载 QQNT.dll 失败: {exc}")
            return

        symbol = "?GetCurrent@Isolate@v8@@SAPEAV12@XZ"
        try:
            get_current = getattr(node_lib, symbol)
        except AttributeError:
            self.say(f"    QQNT.dll 未导出 {symbol}")
            return

        prototype = ctypes.CFUNCTYPE(ctypes.c_void_p)
        isolate = prototype(ctypes.cast(get_current, ctypes.c_void_p).value)()
        self.say(f"    v8::Isolate::GetCurrent() -> {hex(isolate) if isolate else 'NULL'}")
        if not isolate:
            self.say("    => 进程内没有 V8 运行时，原生库缺少宿主环境")

    def run(self, candidate: str) -> int:
        version_dir = find_version_dir()
        if version_dir is None:
            self.say(f"未找到 QQ 版本目录 {QQ_ROOT / 'versions'}")
            return 1

        app_dir = version_dir / "resources" / "app"
        wrapper = app_dir / "wrapper.node"
        self.say(f"[0] QQ 版本目录: {version_dir}")
        if not wrapper.is_file():
            self.say(f"    找不到 {wrapper}")
            return 1

        # 1) 让 wrapper.node 的依赖（QQNT.dll 等）能被解析
        dll_dirs = [app_dir, version_dir, app_dir / "miniapp" / "msf"]
        handles = []
        for directory in dll_dirs:
            if directory.is_dir():
                try:
                    handles.append(os.add_dll_directory(str(directory)))
                    self.say(f"    已加入 DLL 搜索路径: {directory}")
                except OSError as exc:
                    self.say(f"    加入失败 {directory}: {exc}")

        # 2) 加载模块
        self.say(f"[1] 加载 {wrapper.name}（约 110MB，请稍候）…")
        try:
            lib = ctypes.WinDLL(str(wrapper))
        except OSError as exc:
            self.say(f"    加载失败: {exc}")
            return 2
        base = int(lib._handle)  # HMODULE 即加载基址
        self.say(f"    加载成功，模块基址 = 0x{base:X}")

        # 3) 解析工厂符号（名字从 PE 导出表动态取，避免硬编码出错）
        from .pe import PEFile

        with PEFile(wrapper) as pe:
            names = [e.name for e in pe.exports()]
            image_size = pe.image_size
        self.say(f"    模块 SizeOfImage = 0x{image_size:X}（0x{image_size/1024/1024:.1f} MB）")

        factory = next((n for n in names if "CreateNTSessionShell" in n), None)
        if factory is None:
            self.say("    导出表里找不到 CreateNTSessionShell")
            return 3
        self.say(f"[2] 工厂符号: {factory}")

        try:
            proc = getattr(lib, factory)
        except AttributeError as exc:
            self.say(f"    解析失败: {exc}")
            return 3
        proc_addr = ctypes.cast(proc, ctypes.c_void_p).value or 0
        self.say(f"    函数地址 = 0x{proc_addr:X}，RVA = 0x{proc_addr - base:X}")

        # 2.5) 静态分析：工厂函数最早调用了哪些导入符号
        self.analyse_calls(base, proc_addr, wrapper)

        # 2.6) 运行时体检：V8 isolate 是否存在
        self.check_runtime(version_dir)

        # 4) 调用工厂
        # MSVC 返回非平凡类型时用隐藏返回指针：RCX = &retval, RDX = &string
        self.say(f"[3] 调用工厂（参数 = {candidate!r}）")
        retval = (ctypes.c_void_p * 2)()  # shared_ptr：2 个指针
        argument = make_msvc_string(candidate)
        prototype = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)
        call = prototype(proc_addr)
        call(ctypes.byref(retval), ctypes.byref(argument))

        obj = retval[0]
        self.say(f"    返回对象指针 = {hex(obj) if obj else 'NULL'}")
        if not obj:
            self.say("    工厂返回空对象")
            return 4

        # 5) 读取虚表
        self.say("[4] 读取虚表")
        vtable = ctypes.cast(obj, ctypes.POINTER(ctypes.c_void_p))[0]
        self.say(f"    虚表地址 = 0x{vtable:X}，RVA = 0x{vtable - base:X}")

        with PEFile(wrapper) as pe:
            vtable_symbols = {
                e.name: e.rva
                for e in pe.exports()
                if e.name.startswith("??_7") and "Test" not in e.name
            }
        for name, rva in vtable_symbols.items():
            self.say(f"    导出虚表 {name} -> RVA 0x{rva:X}")

        slots = 0
        for index in range(MAX_VTABLE_SLOTS):
            entry = ctypes.cast(vtable + index * 8, ctypes.POINTER(ctypes.c_void_p))[0]
            if entry is None or not (base <= entry < base + image_size):
                break
            slots += 1
            self.say(f"    槽位[{index:>2}] RVA 0x{entry - base:X}")
        self.say(f"    共 {slots} 个虚函数槽位落在本模块内")

        self.say("[5] 结论：工厂可独立调用，对象可构造 -> 路线 B 成立")
        return 0


def main(argv: list[str]) -> int:
    candidate = argv[1] if len(argv) > 1 else "QQ"
    out_path = Path(argv[2]) if len(argv) > 2 else Path("probe_shell.log")
    with open(out_path, "w", encoding="utf-8") as out:
        return Probe(out).run(candidate)


if __name__ == "__main__":
    sys.exit(main(sys.argv))