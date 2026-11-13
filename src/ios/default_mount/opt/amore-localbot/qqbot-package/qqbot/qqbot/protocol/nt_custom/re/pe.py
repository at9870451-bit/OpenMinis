"""PE 导出表解析（纯 Python，不依赖 IDA / dumpbin）。

用途：定位 QQ NT 原生库（QQNT.dll / wrapper.node / msf-*.node）中对外
暴露的函数，判断签名、加密等关键能力是否能被独立进程直接调用。
这是自研协议逆向阶段的第一手证据工具。
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

MAX_NAME_LEN = 512


@dataclass
class Section:
    name: str
    virtual_address: int
    virtual_size: int
    raw_pointer: int
    raw_size: int


@dataclass
class Export:
    name: str
    ordinal: int
    rva: int
    forwarder: str | None = None

    def __str__(self) -> str:
        suffix = f" -> {self.forwarder}" if self.forwarder else f" @0x{self.rva:X}"
        return f"[{self.ordinal:>5}] {self.name}{suffix}"


class PEFile:
    """只解析 PE 头、节表与导出目录，不会把整个文件读进内存。"""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._fh = open(self.path, "rb")
        self.machine = 0
        self.is_64bit = False
        self.sections: list[Section] = []
        self.export_rva = 0
        self.export_size = 0
        self.import_rva = 0
        self.import_size = 0
        self.function_count = 0
        self.name_count = 0
        self.export_base = 0
        self._addr_funcs = 0
        self.image_size = 0
        self.timestamp = 0
        self._parse_headers()

    # ---------- 基础 ----------

    def _read(self, offset: int, size: int) -> bytes:
        self._fh.seek(offset)
        return self._fh.read(size)

    def _parse_headers(self) -> None:
        dos = self._read(0, 64)
        if len(dos) < 64 or dos[:2] != b"MZ":
            raise ValueError(f"{self.path.name} 不是有效的 PE 文件（缺少 MZ 头）")

        e_lfanew = struct.unpack_from("<I", dos, 0x3C)[0]
        if self._read(e_lfanew, 4) != b"PE\x00\x00":
            raise ValueError(f"{self.path.name} PE 签名无效")

        coff = self._read(e_lfanew + 4, 20)
        self.machine = struct.unpack_from("<H", coff, 0)[0]
        self.timestamp = struct.unpack_from("<I", coff, 4)[0]
        num_sections = struct.unpack_from("<H", coff, 2)[0]
        size_opt = struct.unpack_from("<H", coff, 16)[0]

        opt = self._read(e_lfanew + 24, size_opt)
        self.is_64bit = struct.unpack_from("<H", opt, 0)[0] == 0x20B
        self.image_size = struct.unpack_from("<I", opt, 56)[0]  # SizeOfImage
        dd_off = 112 if self.is_64bit else 96  # 数据目录起始偏移
        self.export_rva, self.export_size = struct.unpack_from("<II", opt, dd_off)
        self.import_rva, self.import_size = struct.unpack_from("<II", opt, dd_off + 8)

        sec_off = e_lfanew + 24 + size_opt
        for i in range(num_sections):
            raw = self._read(sec_off + i * 40, 40)
            if len(raw) < 40:
                break
            name = raw[:8].rstrip(b"\x00").decode("latin-1", "replace")
            virtual_size, virtual_address = struct.unpack_from("<II", raw, 8)
            raw_size, raw_pointer = struct.unpack_from("<II", raw, 16)
            self.sections.append(
                Section(name, virtual_address, virtual_size, raw_pointer, raw_size)
            )

    def rva_to_offset(self, rva: int) -> int | None:
        for section in self.sections:
            span = max(section.virtual_size, section.raw_size)
            if section.virtual_address <= rva < section.virtual_address + span:
                return section.raw_pointer + (rva - section.virtual_address)
        return None

    # ---------- 导出 ----------

    def exports(self) -> list[Export]:
        if not self.export_rva:
            return []
        dir_off = self.rva_to_offset(self.export_rva)
        if dir_off is None:
            return []

        header = self._read(dir_off, 40)
        if len(header) < 40:
            return []
        (
            _chars,
            _stamp,
            _major,
            _minor,
            _name_rva,
            base,
            num_funcs,
            num_names,
            addr_funcs,
            addr_names,
            addr_ordinals,
        ) = struct.unpack_from("<IIHHIIIIIII", header, 0)

        self.function_count = num_funcs
        self.name_count = num_names
        self.export_base = base
        self._addr_funcs = addr_funcs

        names_off = self.rva_to_offset(addr_names)
        ords_off = self.rva_to_offset(addr_ordinals)
        funcs_off = self.rva_to_offset(addr_funcs)
        if names_off is None or ords_off is None or funcs_off is None:
            return []

        result: list[Export] = []
        for i in range(num_names):
            name_rva = struct.unpack_from("<I", self._read(names_off + i * 4, 4))[0]
            name_off = self.rva_to_offset(name_rva)
            if name_off is None:
                continue
            name = (
                self._read(name_off, MAX_NAME_LEN)
                .split(b"\x00", 1)[0]
                .decode("latin-1", "replace")
            )
            index = struct.unpack_from("<H", self._read(ords_off + i * 2, 2))[0]
            func_rva = struct.unpack_from("<I", self._read(funcs_off + index * 4, 4))[0]

            forwarder = None
            if self.export_rva <= func_rva < self.export_rva + self.export_size:
                fwd_off = self.rva_to_offset(func_rva)
                if fwd_off is not None:
                    forwarder = (
                        self._read(fwd_off, MAX_NAME_LEN)
                        .split(b"\x00", 1)[0]
                        .decode("latin-1", "replace")
                    )
            result.append(Export(name, base + index, func_rva, forwarder))
        return result

    def find(self, *keywords: str) -> list[Export]:
        lowered = [k.lower() for k in keywords]
        return [
            e for e in self.exports() if any(k in e.name.lower() for k in lowered)
        ]

    # ---------- 导入 ----------

    def _thunk_names(self, table_rva: int) -> list[str]:
        """读取一张导入名表（OriginalFirstThunk），返回符号名列表。"""
        ptr = 8 if self.is_64bit else 4
        offset = self.rva_to_offset(table_rva)
        if offset is None:
            return []
        names: list[str] = []
        slot = 0
        while slot < 4096:
            raw = self._read(offset + slot * ptr, ptr)
            if len(raw) < ptr:
                break
            value = int.from_bytes(raw, "little")
            if value == 0:
                break
            if value & (1 << (ptr * 8 - 1)):
                names.append(f"#{value & 0xFFFF}")
            else:
                hint_off = self.rva_to_offset(value)
                names.append(
                    "<无法定位>"
                    if hint_off is None
                    else self._read(hint_off + 2, 256)
                    .split(b"\x00", 1)[0]
                    .decode("latin-1", "replace")
                )
            slot += 1
        return names

    def import_thunks(self) -> dict[int, str]:
        """返回 {IAT 槽位的 RVA: 导入符号名}。

        用途：把反汇编里看到的 `call qword ptr [rip+disp32]` 目标地址
        （落在本模块 IAT 内）还原成具体符号名。
        """
        if not self.import_rva:
            return {}
        offset = self.rva_to_offset(self.import_rva)
        if offset is None:
            return {}
        ptr = 8 if self.is_64bit else 4
        result: dict[int, str] = {}
        index = 0
        while True:
            descriptor = self._read(offset + index * 20, 20)
            if len(descriptor) < 20:
                break
            original_thunk, _stamp, _fwd, _name, first_thunk = struct.unpack(
                "<IIIII", descriptor
            )
            if original_thunk == 0 and first_thunk == 0:
                break
            if first_thunk:
                for slot, symbol in enumerate(self._thunk_names(original_thunk or first_thunk)):
                    result[first_thunk + slot * ptr] = symbol
            index += 1
            if index > 512:
                break
        return result

    def imports(self) -> dict[str, list[str]]:
        """返回 {依赖的 DLL 名: [符号/序号]}。"""
        if not self.import_rva:
            return {}
        offset = self.rva_to_offset(self.import_rva)
        if offset is None:
            return {}

        ptr = 8 if self.is_64bit else 4
        result: dict[str, list[str]] = {}
        index = 0
        while True:
            descriptor = self._read(offset + index * 20, 20)
            if len(descriptor) < 20:
                break
            original_thunk, _stamp, _fwd, name_rva, _first_thunk = struct.unpack(
                "<IIIII", descriptor
            )
            if original_thunk == 0 and name_rva == 0:
                break  # 全零描述符表示结束

            name_off = self.rva_to_offset(name_rva)
            dll = ""
            if name_off is not None:
                dll = (
                    self._read(name_off, 256)
                    .split(b"\x00", 1)[0]
                    .decode("latin-1", "replace")
                )

            symbols: list[str] = []
            thunk_rva = original_thunk or _first_thunk
            thunk_off = self.rva_to_offset(thunk_rva) if thunk_rva else None
            if thunk_off is not None:
                slot = 0
                while slot < 4096:  # 防御性上限
                    raw = self._read(thunk_off + slot * ptr, ptr)
                    if len(raw) < ptr:
                        break
                    value = int.from_bytes(raw, "little")
                    if value == 0:
                        break
                    ordinal_flag = 1 << (ptr * 8 - 1)
                    if value & ordinal_flag:
                        symbols.append(f"#{value & 0xFFFF}")
                    else:
                        hint_off = self.rva_to_offset(value)
                        if hint_off is None:
                            symbols.append("<无法定位>")
                        else:
                            symbols.append(
                                self._read(hint_off + 2, 256)
                                .split(b"\x00", 1)[0]
                                .decode("latin-1", "replace")
                            )
                    slot += 1
            result[dll] = symbols
            index += 1
            if index > 512:
                break
        return result

    def is_node_addon(self) -> bool:
        """是否为标准 Node-API 插件（可被 Node 直接 require）。"""
        names = {e.name for e in self.exports()}
        return bool({"napi_register_module_v1", "node_module_register"} & names) or any(
            n.startswith("napi_") for n in names
        )

    def ordinal_only_exports(self) -> list[int]:
        """只按序号导出、没有名字的函数序号（Node 插件的初始化函数常在此）。"""
        self.exports()  # 确保已解析计数
        named = {e.ordinal - self.export_base for e in self.exports()}
        return [i for i in range(self.function_count) if i not in named]

    # ---------- 资源 ----------

    def summary(self) -> dict:
        return {
            "文件": self.path.name,
            "大小(MB)": round(self.path.stat().st_size / 1024 / 1024, 2),
            "架构": "x64" if self.is_64bit else "x86",
            "时间戳": self.timestamp,
            "节数": len(self.sections),
            "导出函数数": len(self.exports()),
        }

    def close(self) -> None:
        self._fh.close()

    def __enter__(self) -> "PEFile":
        return self

    def __exit__(self, *exc) -> None:
        self.close()