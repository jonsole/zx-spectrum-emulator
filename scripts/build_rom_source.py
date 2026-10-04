"""Fetch and assemble the commented ROM disassembly for source-level debugging.

Pipeline: skoolkid/rom's rom.skool -> SkoolKit's skool2asm (readable assembly
with labels/comments) -> sjasmplus (assembles it, producing an SLD file
mapping every address to its source line). The assembled binary is checked
against the 48K ROM's SHA-256 as a correctness check: if the disassembly
doesn't reproduce the real ROM exactly, the address mapping can't be trusted
for debugging, so this refuses to write output.

The skool source and everything built from it are genuinely copyrighted
(Amstrad / Dr Ian Logan & Dr Frank O'Hara / Richard Dymond) and published
with no licence to redistribute them, so nobody does: this is run where the
disassembly is used. In a checkout it writes rom_disassembly/ (gitignored);
the ROM example workspace carries this same file as scripts/build_rom_source.py
and its launch runs it first, so it writes the workspace's own
rom_disassembly/ on the user's machine. That is why it needs nothing of the
repository: no roms/48.rom (the ROM is checked by hash), no git (rom.skool is
one file, fetched at a pinned commit and checked by hash too) and nothing
imported from beside it.

What a run does when the disassembly is already there: nothing. A stamp file
beside the output records which skool source it was built from, so a launch
costs no more than reading it, and moving SKOOL_COMMIT on rebuilds it.

Requires SkoolKit (pip install skoolkit==10.1, the version CI checks it with)
and sjasmplus: the SJASMPLUS environment variable (the workspace's task sets
it from the extension, which fetches one), else tools/sjasmplus/
(scripts/fetch_sjasmplus.py puts one there), else the PATH.

Usage:
    python scripts/build_rom_source.py [--rebuild] [--force] [--out DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = PROJECT_ROOT / ".rom-disassembly-src"
OUT_DIR = PROJECT_ROOT / "rom_disassembly"

# The skoolkid/rom commit the disassembly is built from, and the SHA-256 of
# its sources/rom.skool. Pinned rather than following master so that what a
# user builds is what CI built and checked: an upstream edit changes nothing
# until this is moved. To move it, put the new commit and its file's hash
# here and run this with --rebuild; CI's own run proves it still reassembles
# the ROM.
SKOOL_COMMIT = "f2edfcc1e593994fb502dd74a372a054ff9ca17a"
SKOOL_SHA256 = "07c1eeeeb471016a4e2090110b5717b45f8310a806f61bd60986d22f1a3a2696"
SKOOL_URL = f"https://raw.githubusercontent.com/skoolkid/rom/{SKOOL_COMMIT}/sources/rom.skool"

# The 48K ROM's SHA-256: the same value as scripts/fetch_roms.py's, which
# package_release.py checks, repeated here so this file stands alone in the
# workspace.
ROM_48_SHA256 = "d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42"

STAMP_NAME = ".built-from"

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

# skool2asm run in a child interpreter, the way SkoolKit's own skool2asm.py
# script runs it. Importing the module rather than finding the script means
# it works however SkoolKit was installed -- a venv, a plain install, pip
# --user -- each of which puts the script somewhere different, and on Windows
# a bare .py script on PATH is not something subprocess can run anyway.
_SKOOL2ASM = (
    "import sys\n"
    "from skoolkit import skool2asm, error, SkoolKitError\n"
    "try:\n"
    "    skool2asm.main(sys.argv[1:])\n"
    "except SkoolKitError as e:\n"
    "    error(e.args[0])\n"
)


def _run(cmd: list[str], shown: str | None = None, **kwargs) -> subprocess.CompletedProcess:
    print(f"$ {shown or ' '.join(cmd)}")
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch_skool_source() -> Path:
    skool_path = SRC_DIR / "rom.skool"
    if skool_path.exists() and sha256(skool_path.read_bytes()) == SKOOL_SHA256:
        print(f"Using {skool_path} (skoolkid/rom {SKOOL_COMMIT[:7]})")
        return skool_path
    print(f"Fetching {SKOOL_URL}")
    try:
        with urllib.request.urlopen(SKOOL_URL, timeout=60) as response:
            data = response.read()
    except OSError as e:
        sys.exit(f"error: could not fetch the ROM disassembly's source: {e}")
    actual = sha256(data)
    if actual != SKOOL_SHA256:
        sys.exit(f"error: rom.skool has SHA-256 {actual}, expected {SKOOL_SHA256} -- not used")
    SRC_DIR.mkdir(exist_ok=True)
    skool_path.write_bytes(data)
    return skool_path


def find_sjasmplus() -> str:
    named = os.environ.get("SJASMPLUS")
    if named and Path(named).is_file():
        return named
    for name in ("sjasmplus.exe", "sjasmplus"):
        candidate = PROJECT_ROOT / "tools" / "sjasmplus" / name
        if candidate.is_file():
            return str(candidate)
    on_path = shutil.which("sjasmplus")
    if on_path:
        return on_path
    sys.exit(
        "error: sjasmplus not found.\n"
        "Windows: python scripts/fetch_sjasmplus.py fetches it into tools/sjasmplus/;\n"
        "  in the ROM example workspace the ZX Spectrum Debug extension fetches it.\n"
        "Linux/macOS: no prebuilt release exists -- build from source:\n"
        "  git clone https://github.com/z00m128/sjasmplus.git\n"
        "  cd sjasmplus && git submodule update --init --recursive && make\n"
        "  cp build/release/sjasmplus ~/.local/bin/  # or anywhere else on PATH"
    )


def require_skoolkit() -> None:
    try:
        import skoolkit  # noqa: F401 -- only asking whether it is installed
    except ImportError:
        sys.exit(f"error: SkoolKit is not installed for {sys.executable}.\n"
                 "Install it with: python -m pip install skoolkit==10.1")


def build_asm(skool_path: Path) -> str:
    # The skool source's comments contain non-ASCII characters (e.g. an
    # arrow glyph); on Windows the child interpreter's stdout otherwise
    # defaults to the console's codepage (cp1252), which can't encode them
    # and crashes skool2asm with a UnicodeEncodeError even though stdout is
    # going to a pipe, not a real console.
    env = os.environ | {"PYTHONIOENCODING": "utf-8"}
    result = _run([sys.executable, "-c", _SKOOL2ASM, str(skool_path)], f"skool2asm {skool_path}",
                  capture_output=True, encoding="utf-8", env=env)
    text = result.stdout
    for pattern, replacement in _KEYWORD_FIXES:
        text = pattern.sub(replacement, text)
    # Prepend DEVICE so it's part of the file from the start -- SLD line
    # numbers are 1:1 with whatever file is actually assembled, so if this
    # were added later by prepending to an already-built file, every
    # mapped line number would be off by however many lines got added.
    return "    DEVICE ZXSPECTRUM48\n" + text


def assemble(asm_text: str, out_dir: Path, sjasmplus: str, force: bool) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Gone until this build is verified, so a failure partway never leaves
    # the old stamp vouching for new files.
    (out_dir / STAMP_NAME).unlink(missing_ok=True)
    asm_path = out_dir / "rom.asm"
    asm_path.write_text(asm_text, encoding="utf-8")

    sld_path = out_dir / "rom.sld"
    bin_path = out_dir / "rom.bin"
    _run(
        [sjasmplus, "rom.asm", f"--sld={sld_path.name}", "--fullpath", f"--raw={bin_path.name}"],
        cwd=out_dir,
    )

    assembled = sha256(bin_path.read_bytes())
    bin_path.unlink(missing_ok=True)
    if assembled != ROM_48_SHA256:
        message = (
            "error: the assembled ROM is NOT the 48K ROM byte for byte\n"
            f"(SHA-256 {assembled}, expected {ROM_48_SHA256}).\n"
            "The address<->source-line mapping would be untrustworthy for debugging. "
            "A SkoolKit whose output differs from the one this was checked with "
            "(10.1) is the likeliest cause."
        )
        if not force:
            sld_path.unlink(missing_ok=True)
            asm_path.unlink(missing_ok=True)
            sys.exit(message + "\nRe-run with --force to keep the output anyway.")
        print(message + "\n--force given: keeping output, but treat the mapping with suspicion.")
        return
    print("Verified: the assembled ROM is byte for byte the 48K ROM.")
    # Written only for a verified build, so a forced one is redone next time.
    (out_dir / STAMP_NAME).write_text(SKOOL_SHA256 + "\n", encoding="utf-8")
    print(f"Wrote {asm_path} and {sld_path}")


def already_built(out_dir: Path) -> bool:
    stamp = out_dir / STAMP_NAME
    if not (out_dir / "rom.asm").is_file() or not (out_dir / "rom.sld").is_file() or not stamp.is_file():
        return False
    return stamp.read_text(encoding="utf-8").strip() == SKOOL_SHA256


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rebuild", action="store_true", help="build even if the output is up to date")
    parser.add_argument("--force", action="store_true", help="keep output even if it doesn't reassemble the 48K ROM")
    parser.add_argument("--out", type=Path, default=OUT_DIR, help=f"where to write (default: {OUT_DIR})")
    args = parser.parse_args()

    if not args.rebuild and already_built(args.out):
        print(f"The ROM disassembly in {args.out} is up to date.")
        return
    require_skoolkit()
    sjasmplus = find_sjasmplus()
    skool_path = fetch_skool_source()
    asm_text = build_asm(skool_path)
    assemble(asm_text, args.out, sjasmplus, args.force)


if __name__ == "__main__":
    main()
