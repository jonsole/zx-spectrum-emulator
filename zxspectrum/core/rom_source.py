"""Parses sjasmplus SLD debug data for the commented ROM disassembly.

Built by scripts/build_rom_source.py (skool2asm.py -> sjasmplus --sld),
gitignored like the ROM itself since the disassembly is copyrighted.
Loading is optional: `load_rom_source()` returns None if the build output
doesn't exist, matching the existing optional-ROM pattern elsewhere in
core/ -- callers (dap.py) fall back to the addressless behavior they
already have.

SLD is sjasmplus's pipe-delimited format: one record per line,
    file|line|definition_file|definition_line|page|address|type|data
`type` is a single letter: T (an instruction -- address<->line, unnamed),
F (a global label: `data` is the name), D (an EQU'd constant or system-
variable address), L (display/scope flags for the preceding D/F record),
Z (device/page header). Only T and F are used here -- D's address field
is an EQU value, not necessarily a real code address, and L/Z carry no
address<->line information of their own.
"""
from __future__ import annotations

import bisect
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_DIR = Path(__file__).resolve().parent.parent.parent / "rom_disassembly"


@dataclass
class RomSource:
    asm_path: Path
    line_to_addr: dict[int, int]
    addr_to_line: dict[int, int]
    symbols: dict[str, int]
    _sorted_addrs: list[int] = field(init=False, repr=False)
    _sorted_names: list[str] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        pairs = sorted(self.symbols.items(), key=lambda kv: kv[1])
        self._sorted_addrs = [addr for _, addr in pairs]
        self._sorted_names = [name for name, _ in pairs]

    def symbol_at(self, addr: int) -> tuple[str, int] | None:
        """The nearest label at or before `addr`, with its offset -- e.g.
        (addr - 3) inside routine FOO returns ("FOO", 3). None if `addr`
        precedes every known label."""
        i = bisect.bisect_right(self._sorted_addrs, addr) - 1
        if i < 0:
            return None
        base = self._sorted_addrs[i]
        return self._sorted_names[i], addr - base


def _parse_sld(sld_text: str) -> tuple[dict[int, int], dict[int, int], dict[str, int]]:
    line_to_addr: dict[int, int] = {}
    addr_to_line: dict[int, int] = {}
    symbols: dict[str, int] = {}
    for raw_line in sld_text.splitlines():
        fields = raw_line.split("|")
        if len(fields) < 8:
            continue
        _file, line_s, _def_file, _def_line, _page, addr_s, rec_type, data = fields[:8]
        if rec_type == "T":
            try:
                line_no, addr = int(line_s), int(addr_s)
            except ValueError:
                continue
            # setdefault: keep the first mapping if a line/address ever
            # repeats -- shouldn't happen for real T records, but a
            # first-wins rule is a safer default than silently overwriting.
            line_to_addr.setdefault(line_no, addr)
            addr_to_line.setdefault(addr, line_no)
        elif rec_type == "F" and data:
            try:
                addr = int(addr_s)
            except ValueError:
                continue
            symbols[data] = addr
    return line_to_addr, addr_to_line, symbols


def load_rom_source(directory: Path | None = None) -> RomSource | None:
    directory = directory or DEFAULT_DIR
    asm_path = directory / "rom.asm"
    sld_path = directory / "rom.sld"
    if not asm_path.exists() or not sld_path.exists():
        return None
    line_to_addr, addr_to_line, symbols = _parse_sld(sld_path.read_text(encoding="utf-8"))
    return RomSource(asm_path=asm_path, line_to_addr=line_to_addr, addr_to_line=addr_to_line, symbols=symbols)


_cache: RomSource | None = None
_cache_key: tuple[float, float] | None = None


def get_rom_source(directory: Path | None = None) -> RomSource | None:
    """Cached wrapper around load_rom_source(), invalidated by rom.asm/
    rom.sld's mtimes. Shared by both front-ends (DAP and MCP) so a rebuild
    (e.g. picking up a skoolkid/rom update) while a long-running server
    process is up is still picked up automatically, without re-parsing the
    ~9000-record SLD file on every single request either front-end makes.
    """
    global _cache, _cache_key
    directory = directory or DEFAULT_DIR
    asm_path = directory / "rom.asm"
    sld_path = directory / "rom.sld"
    try:
        key = (asm_path.stat().st_mtime, sld_path.stat().st_mtime)
    except OSError:
        _cache = None
        _cache_key = None
        return None
    if key != _cache_key:
        _cache = load_rom_source(directory)
        _cache_key = key
    return _cache
