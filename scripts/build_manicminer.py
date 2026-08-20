"""Fetch and assemble SkoolKit's Manic Miner disassembly into a loadable
.sna + .sld pair for source-level debugging.

Pipeline: skoolkid/manicminer's .skool source -> skool2asm.py (readable
assembly with labels/comments) -> sjasmplus (assembles it, producing an SLD
file mapping every address to its source line, and the raw assembled
bytes). Unlike the ROM (scripts/build_rom_source.py), there's no reference
binary to verify byte-for-byte against -- the assembly succeeding with zero
errors is the correctness signal here. The raw bytes are placed into a 48K
RAM image at their assembled address and wrapped into a .sna snapshot
(PC set to the disassembly's entry point) via core/snapshot.py's
write_sna(), so it can be loaded directly with load_snapshot()/launch's
"snapshot" arg like any other .sna.

The skool source and everything built from it -- most importantly the game
code and data itself, which the disassembly necessarily reproduces in full
-- are genuinely copyrighted (1983 Bug-Byte Ltd / Software Projects for the
game; Richard Dymond for the disassembly's own annotations). Same treatment
as roms/48.rom and rom_disassembly/: fetched locally, gitignored, never
committed. See README.md.

Requires `skoolkit` (pip install skoolkit) and `sjasmplus` on PATH -- see
scripts/build_rom_source.py's docstring for where to get sjasmplus.

Usage:
    python scripts/build_manicminer.py [--update] [--sp SP]
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from zxspectrum.core.memory import RAM_SIZE
from zxspectrum.core.snapshot import write_sna
from zxspectrum.core.z80 import Registers
from scripts.build_rom_source import require_skool2asm, require_tool

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = PROJECT_ROOT / ".manicminer-disassembly-src"
OUT_DIR = PROJECT_ROOT / "game_disassembly" / "manicminer"

SKOOL_REPO = "https://github.com/skoolkid/manicminer.git"

# sjasmplus wants the undocumented IX/IY-half-register mnemonics in a
# specific case (IXH/IXL/IYH/IYL); skool2asm.py emits them as IXl/IXh/IYl/
# IYh, which sjasmplus doesn't recognize as-is. Case-normalize just those
# tokens rather than uppercasing the whole file (which would also mangle
# comment prose and string literals).
_CASE_FIXES = re.compile(r"\bI[XY][lh]\b")

# The disassembly's first ORG is its documented @start address (confirmed
# against the skool source: @start is placed immediately before the
# instruction at the lowest address in the file) -- the address execution
# should begin at when the snapshot is loaded.
_ORG_RE = re.compile(r"^\s*ORG\s+(\d+)", re.MULTILINE)


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def fetch_skool_source(update: bool) -> Path:
    skool_path = SRC_DIR / "sources" / "mm.skool"
    if SRC_DIR.exists():
        if update:
            _run(["git", "-C", str(SRC_DIR), "pull", "--ff-only"])
        else:
            print(f"Using existing clone at {SRC_DIR} (pass --update to refresh)")
    else:
        _run(["git", "clone", "--depth", "1", SKOOL_REPO, str(SRC_DIR)])
    if not skool_path.exists():
        sys.exit(f"error: expected {skool_path} after fetching -- repo layout may have changed")
    return skool_path


def build_asm(skool_path: Path, skool2asm_path: str) -> str:
    # See build_rom_source.py's build_asm() for why sys.executable+PYTHONIOENCODING
    # are needed here (skool2asm.py has no .exe wrapper on Windows, and the
    # skool source's comments contain non-ASCII characters).
    env = os.environ | {"PYTHONIOENCODING": "utf-8"}
    result = _run([sys.executable, skool2asm_path, str(skool_path)], capture_output=True, encoding="utf-8", env=env)
    text = _CASE_FIXES.sub(lambda m: m.group(0).upper(), result.stdout)
    return "    DEVICE ZXSPECTRUM48\n" + text


def assemble(asm_text: str) -> tuple[Path, int, bytes]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    asm_path = OUT_DIR / "mm.asm"
    asm_path.write_text(asm_text, encoding="utf-8")

    entry = int(_ORG_RE.search(asm_text).group(1))

    sld_path = OUT_DIR / "mm.sld"
    bin_path = OUT_DIR / "mm.bin"
    _run(
        ["sjasmplus", "mm.asm", f"--sld={sld_path.name}", "--fullpath", f"--raw={bin_path.name}"],
        cwd=OUT_DIR,
    )
    game_bytes = bin_path.read_bytes()
    bin_path.unlink()
    return asm_path, entry, game_bytes


def write_snapshot(entry: int, game_bytes: bytes, sp: int) -> Path:
    ram = bytearray(RAM_SIZE)
    offset = entry - 0x4000
    if not (0 <= offset and offset + len(game_bytes) <= RAM_SIZE):
        sys.exit(
            f"error: assembled code (0x{entry:04X}, {len(game_bytes)} bytes) doesn't fit in "
            f"the 48K RAM window (0x4000-0xFFFF) -- can't build a .sna from it."
        )
    ram[offset : offset + len(game_bytes)] = game_bytes

    regs = Registers(pc=entry, sp=sp, im=1)
    sna_path = OUT_DIR / "mm.sna"
    sna_path.write_bytes(write_sna(regs, bytes(ram), border=7))
    return sna_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="git pull the skool source before building")
    parser.add_argument(
        "--sp", type=lambda s: int(s, 0), default=0xFF00,
        help="stack pointer to start with (default 0xFF00 -- above the assembled code/data)",
    )
    args = parser.parse_args()

    skool2asm_path = require_skool2asm()
    require_tool(
        "sjasmplus",
        "See scripts/build_rom_source.py's error message for where to get sjasmplus.",
    )

    skool_path = fetch_skool_source(args.update)
    asm_text = build_asm(skool_path, skool2asm_path)
    asm_path, entry, game_bytes = assemble(asm_text)
    sna_path = write_snapshot(entry, game_bytes, args.sp)

    print(f"Entry point: 0x{entry:04X}")
    print(f"Wrote {asm_path}, {OUT_DIR / 'mm.sld'}, and {sna_path}")
    print("Load roms/48.rom first (write_sna doesn't touch it), then this .sna + .sld.")


if __name__ == "__main__":
    main()
