"""Fetch and assemble the Fairlight disassembly into a loadable .sna + .sld
pair for source-level debugging.

Pipeline: VilleKrumlinde/FairlightZ80's fairlight.asm (a hand-annotated
disassembly reconstructed from a 48K snapshot) -> sjasmplus (assembles it,
producing an SLD file mapping every address to its source line, plus the raw
assembled bytes) -> .sna.

Unlike Manic Miner (scripts/build_manicminer.py), there's no skool2asm step:
the upstream repo ships assembler source directly, already carrying its own
`ORG 0x4000`. It also assembles to the *whole* 48K RAM image (0x4000-0xFFFF,
exactly 49152 bytes -- screen, sysvars, buffers and all, since it was
reconstructed from a snapshot rather than from a tape image), so the .sna's
RAM is the raw output verbatim rather than a code blob dropped into a blank
image.

The disassembly and everything built from it -- most importantly the game
code and data itself, which the disassembly necessarily reproduces in full --
are copyrighted (1985 The Edge / Bo Jangeborg for the game; the repo's author
for the disassembly's own annotations). Same treatment as roms/48.rom,
rom_disassembly/ and the Manic Miner build: fetched locally, gitignored,
never committed. See README.md.

Requires sjasmplus -- found in tools/sjasmplus/ (where the other examples'
builds put it) or on PATH.

Usage:
    python scripts/build_fairlight.py [--update] [--entry ADDR] [--sp ADDR]
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from zxspectrum.core.memory import RAM_SIZE
from zxspectrum.core.snapshot import write_sna
from zxspectrum.core.z80 import Registers

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = PROJECT_ROOT / ".fairlight-disassembly-src"
OUT_DIR = PROJECT_ROOT / "game_disassembly" / "fairlight"
VENDORED_SJASMPLUS = PROJECT_ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"

ASM_REPO = "https://github.com/VilleKrumlinde/FairlightZ80.git"

# 0xF065 (RTN_Title_Screen_Loop) is the game's entry point: it's the one
# routine in the snapshot nothing else jumps to or calls, it only ever
# tail-jumps back to itself, and 0xF065 == 61541 decimal -- the RANDOMIZE USR
# target a short BASIC loader (not part of the snapshot) would have used. It
# runs the title screen / reset / room 1 / GAME OVER attract cycle. See the
# upstream repo's analysis/game_text.md.
DEFAULT_ENTRY = 0xF065

# The game never sets SP itself -- every `ld sp` in it is a fast-fill trick
# that saves and restores the incoming value -- so the stack has to be
# supplied the way the original loader did. The upstream analysis records that
# the captured snapshot's header SP pointed at the word 0xE554; that word
# occurs exactly once in the whole 48K image, at 0x6390, which pins the
# original SP to 0x6390. .sna stores PC pushed at SP-2, so handing write_sna()
# 0x6392 reproduces the original header SP exactly, with our entry PC sitting
# in the same two bytes the original resume address did.
DEFAULT_SP = 0x6392

# The game holds its state-block base address in IY permanently, and assumes
# it is already loaded on entry: RTN_Title_Screen_Loop's very first
# instruction stores the room number through (iy+0x34). RTN_Room_Dispatch
# reloads `ld iy,Sub_FF80` every iteration, which is what makes 0xFF80 the
# value -- but that reload happens too late to help the entry path. Leaving IY
# at 0 sends that store to 0x0034 (ROM, silently discarded), so RTN_Enter_Room
# looks up a garbage room and never returns, and the screen stays black: the
# attribute wash RTN_Draw_Room lays down before drawing is 0x00 (black ink on
# black paper), and the room's real attribute byte is only painted by the
# routine at 0xF0FB, which runs after RTN_Enter_Room returns.
DEFAULT_IY = 0xFF80

# sjasmplus only emits SLD line info for code assembled into a DEVICE, and
# fairlight.asm (written for a plain --raw assembly) declares none. Prepending
# the directive is what turns the source into something source-level
# debuggable; it doesn't change a single output byte -- verified by diffing
# --raw output with and without it.
DEVICE_LINE = "    DEVICE ZXSPECTRUM48\n"


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def require_sjasmplus() -> str:
    if VENDORED_SJASMPLUS.exists():
        return str(VENDORED_SJASMPLUS)
    path = shutil.which("sjasmplus")
    if not path:
        sys.exit(
            f"error: sjasmplus not found at {VENDORED_SJASMPLUS} or on PATH.\n"
            "Download a build from https://github.com/z00m128/sjasmplus/releases and put "
            f"it in {VENDORED_SJASMPLUS.parent} (that directory is gitignored)."
        )
    return path


def fetch_asm_source(update: bool) -> Path:
    asm_path = SRC_DIR / "fairlight.asm"
    if SRC_DIR.exists():
        if update:
            _run(["git", "-C", str(SRC_DIR), "pull", "--ff-only"])
        else:
            print(f"Using existing clone at {SRC_DIR} (pass --update to refresh)")
    else:
        _run(["git", "clone", "--depth", "1", ASM_REPO, str(SRC_DIR)])
    if not asm_path.exists():
        sys.exit(f"error: expected {asm_path} after fetching -- repo layout may have changed")
    return asm_path


def assemble(src_asm: Path, sjasmplus: str) -> tuple[Path, bytes]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # The DEVICE line has to be part of the .asm that ships next to the .sld,
    # not a temporary prefix: the SLD maps addresses to line numbers in this
    # file, and assembling a one-line-longer copy would put every one of them
    # off by one.
    asm_path = OUT_DIR / "fairlight.asm"
    asm_path.write_text(DEVICE_LINE + src_asm.read_text(encoding="utf-8"), encoding="utf-8")

    bin_path = OUT_DIR / "fairlight.bin"
    _run(
        [sjasmplus, asm_path.name, "--sld=fairlight.sld", "--fullpath", f"--raw={bin_path.name}"],
        cwd=OUT_DIR,
    )
    ram = bin_path.read_bytes()
    bin_path.unlink()
    if len(ram) != RAM_SIZE:
        sys.exit(
            f"error: assembled {len(ram)} bytes, expected exactly {RAM_SIZE} "
            f"(0x4000-0xFFFF) -- the disassembly no longer covers the full 48K image."
        )
    return asm_path, ram


def write_snapshot(ram: bytes, entry: int, sp: int, iy: int) -> Path:
    regs = Registers(pc=entry, sp=sp, iy=iy, im=1, iff1=True, iff2=True)
    sna_path = OUT_DIR / "fairlight.sna"
    sna_path.write_bytes(write_sna(regs, ram, border=0))
    return sna_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="git pull the disassembly before building")
    parser.add_argument(
        "--entry", type=lambda s: int(s, 0), default=DEFAULT_ENTRY,
        help=f"address to start executing at (default 0x{DEFAULT_ENTRY:04X}, the title screen loop)",
    )
    parser.add_argument(
        "--sp", type=lambda s: int(s, 0), default=DEFAULT_SP,
        help=f"stack pointer to start with (default 0x{DEFAULT_SP:04X} -- the original snapshot's)",
    )
    parser.add_argument(
        "--iy", type=lambda s: int(s, 0), default=DEFAULT_IY,
        help=f"IY to start with (default 0x{DEFAULT_IY:04X}, the game-state block -- see DEFAULT_IY)",
    )
    args = parser.parse_args()

    sjasmplus = require_sjasmplus()
    src_asm = fetch_asm_source(args.update)
    asm_path, ram = assemble(src_asm, sjasmplus)
    sna_path = write_snapshot(ram, args.entry, args.sp, args.iy)

    print(f"Entry point: 0x{args.entry:04X}, SP: 0x{args.sp:04X}, IY: 0x{args.iy:04X}")
    print(f"Wrote {asm_path}, {OUT_DIR / 'fairlight.sld'}, and {sna_path}")
    print("Load roms/48.rom first (write_sna doesn't touch it), then this .sna + .sld.")


if __name__ == "__main__":
    main()
