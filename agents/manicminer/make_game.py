"""Builds agents/manicminer/game/mm.bin: Manic Miner's bytes from 23552 to the
end of memory, which is what the player's tools load (mm_game.h).

They come from Richard Dymond's SkoolKit disassembly of the game
(github.com/skoolkid/manicminer), assembled back to the original bytes by
SkoolKit's skool2bin.py. Needs git and SkoolKit (pip install skoolkit). The
game is copyrighted (1983 Bug-Byte / Software Projects): the clone and the
binary stay in game/, which is gitignored, and are never committed.

game-disassemblies' build_manicminer.py makes a .sna of the same game, which
the tools take too (--game <file>.sna); this needs no assembler.

Usage:
    python agents/manicminer/make_game.py [--update]
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GAME_DIR = HERE / "game"
SRC_DIR = GAME_DIR / "manicminer-src"
SKOOL_REPO = "https://github.com/skoolkid/manicminer.git"
RAW_START = 23552


def run(cmd: list[str]) -> None:
    print("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True)


def skool2bin() -> list[str]:
    exe = shutil.which("skool2bin.py") or shutil.which("skool2bin")
    if exe:
        # On Windows the .py has no launcher of its own.
        return [sys.executable, exe] if exe.endswith(".py") else [exe]
    sys.exit("error: skool2bin.py not found -- pip install skoolkit")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update", action="store_true", help="git pull the skool source first")
    args = parser.parse_args()

    GAME_DIR.mkdir(exist_ok=True)
    if not SRC_DIR.exists():
        run(["git", "clone", "--depth", "1", SKOOL_REPO, str(SRC_DIR)])
    elif args.update:
        run(["git", "-C", str(SRC_DIR), "pull", "--ff-only"])

    out = GAME_DIR / "mm.bin"
    run(skool2bin() + [str(SRC_DIR / "sources" / "mm.skool"), str(out)])
    data = out.read_bytes()
    if len(data) != 0x10000 - RAW_START:
        sys.exit(f"error: expected {0x10000 - RAW_START} bytes from {RAW_START}, got {len(data)}")
    print(f"Wrote {out}. The tools also need the 48K ROM at roms/48.rom.")


if __name__ == "__main__":
    main()
