"""core/rom_source.py: SLD parsing.

Uses a small synthetic SLD (a real excerpt's shape, not the actual
copyrighted ROM disassembly, which this environment may not have built --
see scripts/build_rom_source.py).
"""
from pathlib import Path

from zxspectrum.core.rom_source import load_rom_source

_SLD = """\
|SLD.data.version|1
rom.asm|1||0|-1|-1|Z|pages.size:16384,pages.count:4,slots.count:4,slots.adr:0,16384,32768,49152
rom.asm|11||0|-1|23552|D|KSTATE
rom.asm|11||0|-1|23552|L|,KSTATE,,+equ,+used
rom.asm|89||0|0|0|F|START
rom.asm|90||0|0|0|T|
rom.asm|91||0|0|1|T|
rom.asm|104||0|0|8|F|ERROR_1
rom.asm|105||0|0|8|T|
rom.asm|106||0|0|11|T|
"""


def _write_build(tmp_path: Path) -> Path:
    (tmp_path / "rom.asm").write_text("; fake asm\n", encoding="utf-8")
    (tmp_path / "rom.sld").write_text(_SLD, encoding="utf-8")
    return tmp_path


def test_load_rom_source_returns_none_when_build_output_is_missing(tmp_path):
    assert load_rom_source(tmp_path) is None


def test_load_rom_source_maps_instruction_lines_to_addresses(tmp_path):
    rom_source = load_rom_source(_write_build(tmp_path))
    assert rom_source is not None
    # Only T records (real instructions) contribute -- the D/L/Z records
    # for the KSTATE EQU and the device header must not leak in, since
    # their "address" field isn't a real code address.
    assert rom_source.line_to_addr == {90: 0, 91: 1, 105: 8, 106: 11}
    assert rom_source.addr_to_line == {0: 90, 1: 91, 8: 105, 11: 106}


def test_load_rom_source_collects_symbols_from_f_records(tmp_path):
    rom_source = load_rom_source(_write_build(tmp_path))
    assert rom_source.symbols == {"START": 0, "ERROR_1": 8}


def test_symbol_at_finds_nearest_label_at_or_before_address(tmp_path):
    rom_source = load_rom_source(_write_build(tmp_path))
    assert rom_source.symbol_at(0) == ("START", 0)
    assert rom_source.symbol_at(1) == ("START", 1)
    assert rom_source.symbol_at(8) == ("ERROR_1", 0)
    assert rom_source.symbol_at(11) == ("ERROR_1", 3)


def test_symbol_at_returns_none_before_the_first_known_label(tmp_path):
    sld = "rom.asm|89||0|0|100|F|FOO\n"
    (tmp_path / "rom.asm").write_text("; fake\n", encoding="utf-8")
    (tmp_path / "rom.sld").write_text(sld, encoding="utf-8")
    rom_source = load_rom_source(tmp_path)
    assert rom_source.symbol_at(50) is None
