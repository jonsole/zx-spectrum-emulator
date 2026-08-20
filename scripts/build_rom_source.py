"""Fetch and assemble the commented ROM disassembly for source-level debugging.

Pipeline: skoolkid/rom's .skool source -> skool2asm.py (readable assembly
with labels/comments) -> sjasmplus (assembles it, producing an SLD file
mapping every address to its source line). The assembled binary is
compared byte-for-byte against roms/48.rom as a correctness check: if the
disassembly doesn't reproduce the real ROM exactly, the address mapping
can't be trusted for debugging, so this refuses to write output.

The skool source and everything built from it are genuinely copyrighted
(Amstrad / Dr Ian Logan & Dr Frank O'Hara / Richard Dymond) -- same
treatment as roms/48.rom itself: fetched locally, gitignored, never
committed. See README.md.

Requires `skoolkit` (pip install skoolkit) and `sjasmplus` on PATH --
https://github.com/z00m128/sjasmplus (no Linux prebuilt release exists;
build from source: clone, `git submodule update --init --recursive`, `make`).

Usage:
    python scripts/build_rom_source.py [--update] [--force]
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = PROJECT_ROOT / ".rom-disassembly-src"
OUT_DIR = PROJECT_ROOT / "rom_disassembly"
REAL_ROM = PROJECT_ROOT / "roms" / "48.rom"

SKOOL_REPO = "https://github.com/skoolkid/rom.git"

# sjasmplus reserves some words (like ABS) as operator keywords, which can
# collide with a skool-generated label/operand of the same name. Only
# apply the substitution to actual code tokens (a label definition, or an
# operand right after an instruction that takes one), not to the label's
# many appearances inside comment prose -- comments aren't parsed by the
# assembler, so leaving those alone is both correct and easier to review.
# If a future skoolkid/rom update introduces a *different* collision,
# sjasmplus will fail loudly with a clear "Unrecognized instruction" or
# "collides with operator keyword" error naming the exact line -- add
# another targeted substitution here rather than guessing preemptively.
_KEYWORD_FIXES = [
    (re.compile(r"^abs:", re.MULTILINE), "absval:"),
    (re.compile(r"\b(DEFW|CALL|JP|JR|DJNZ)\s+abs\b"), r"\1 absval"),
]


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def fetch_skool_source(update: bool) -> Path:
    skool_path = SRC_DIR / "sources" / "rom.skool"
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


def require_tool(name: str, install_hint: str) -> str:
    path = shutil.which(name)
    if not path:
        sys.exit(f"error: '{name}' not found on PATH.\n{install_hint}")
    return path


def require_skool2asm() -> str:
    # pip installs skool2asm.py as a plain .py console script alongside
    # the interpreter that installed it (Scripts/ on Windows, bin/ on
    # POSIX) -- resolving it there is deterministic. shutil.which can't be
    # used for this: on Windows it only matches PATHEXT extensions
    # (.EXE/.BAT/...), so a bare .py script on PATH is invisible to it
    # even though `python skool2asm.py` runs it fine.
    candidate = Path(sys.executable).parent / "skool2asm.py"
    if not candidate.exists():
        sys.exit(f"error: skool2asm.py not found at {candidate}.\nInstall with: pip install skoolkit")
    return str(candidate)


def build_asm(skool_path: Path, skool2asm_path: str) -> str:
    # skoolkit installs skool2asm.py as a plain .py file with no .exe
    # wrapper -- on Windows that isn't directly runnable via PATH lookup
    # (no shebang/file association through subprocess), so it must always
    # be invoked as `<this venv's python> <script path>`, which also works
    # fine on POSIX.
    # The skool source's comments contain non-ASCII characters (e.g. an
    # arrow glyph); on Windows the child interpreter's stdout otherwise
    # defaults to the console's codepage (cp1252), which can't encode them
    # and crashes skool2asm.py with a UnicodeEncodeError even though
    # stdout is going to a pipe, not a real console.
    env = os.environ | {"PYTHONIOENCODING": "utf-8"}
    result = _run([sys.executable, skool2asm_path, str(skool_path)], capture_output=True, encoding="utf-8", env=env)
    text = result.stdout
    for pattern, replacement in _KEYWORD_FIXES:
        text = pattern.sub(replacement, text)
    # Prepend DEVICE so it's part of the file from the start -- SLD line
    # numbers are 1:1 with whatever file is actually assembled, so if this
    # were added later by prepending to an already-built file, every
    # mapped line number would be off by however many lines got added.
    return "    DEVICE ZXSPECTRUM48\n" + text


def assemble(asm_text: str, force: bool) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    asm_path = OUT_DIR / "rom.asm"
    asm_path.write_text(asm_text, encoding="utf-8")

    sld_path = OUT_DIR / "rom.sld"
    bin_path = OUT_DIR / "rom.bin"
    _run(
        ["sjasmplus", "rom.asm", f"--sld={sld_path.name}", "--fullpath", f"--raw={bin_path.name}"],
        cwd=OUT_DIR,
    )

    if not REAL_ROM.exists():
        print(f"note: {REAL_ROM} not found -- skipping byte-for-byte verification against it.")
    else:
        assembled = bin_path.read_bytes()
        real = REAL_ROM.read_bytes()
        if assembled != real:
            bin_path.unlink(missing_ok=True)
            message = (
                "error: assembled ROM does NOT match roms/48.rom byte-for-byte.\n"
                "The address<->source-line mapping would be untrustworthy for debugging "
                "(this usually means roms/48.rom is a different revision than what "
                "skoolkid/rom's disassembly targets)."
            )
            if not force:
                sld_path.unlink(missing_ok=True)
                asm_path.unlink(missing_ok=True)
                sys.exit(message + "\nRe-run with --force to keep the output anyway.")
            print(message + "\n--force given: keeping output, but treat the mapping with suspicion.")
        else:
            print("Verified: assembled ROM is byte-for-byte identical to roms/48.rom.")

    bin_path.unlink(missing_ok=True)
    print(f"Wrote {asm_path} and {sld_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="git pull the skool source before building")
    parser.add_argument("--force", action="store_true", help="keep output even if it doesn't match roms/48.rom")
    args = parser.parse_args()

    skool2asm_path = require_skool2asm()
    require_tool(
        "sjasmplus",
        "Windows: download the prebuilt sjasmplus-<version>.win.zip from\n"
        "  https://github.com/z00m128/sjasmplus/releases and put sjasmplus.exe\n"
        "  somewhere on PATH.\n"
        "Linux/macOS: no prebuilt release exists -- build from source:\n"
        "  git clone https://github.com/z00m128/sjasmplus.git\n"
        "  cd sjasmplus && git submodule update --init --recursive && make\n"
        "  cp build/release/sjasmplus ~/.local/bin/  # or anywhere else on PATH",
    )

    skool_path = fetch_skool_source(args.update)
    asm_text = build_asm(skool_path, skool2asm_path)
    assemble(asm_text, args.force)


if __name__ == "__main__":
    main()
