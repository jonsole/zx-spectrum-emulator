"""Build a speed-patched Manic Miner snapshot (mm-fast.sna) alongside the
stock one.

Stock Manic Miner spends 172,022 T-states -- nearly 2.5 PAL frames -- on two
4096-byte LDIRs every pass through its main loop: one to restore the empty
cavern into the working buffer at 0x6000, another to blit that buffer to the
display file. Both run in full whether or not anything in a given character
row changed.

This build records, per character row, the range of columns actually drawn
into, and copies only those. Measured over the main loop, that takes an
iteration from ~250,000 T-states to ~150,000: about 1.65x.

Rows alone are not enough, and it is worth saying why, because it looks like
it should be: the guardians are spread down the cavern, so between four of
them, Willy, the portal, the items and the conveyor, 10-13 of the 16 rows are
dirty every frame. Tracking rows on their own measured at 1.0x -- the quarter
of the copying it skipped was given straight back as per-row loop overhead.
The columns are where the win is: a sprite is two columns of thirty-two.

The Z80 side lives in scripts/mm_fast_patch.asm; this script splices it into
the disassembly, rewires the call sites, and assembles the result.

Nothing in the image moves. The patch takes over 0x9D00-0x9FFF -- uncontended
RAM, so the copy loop pays no ULA wait states on opcode fetches -- which is
bought from two cold pieces of the title screen:

  MESSINTRO   its 256 bytes of scrolling text move to the printer buffer at
              0x5B00, which Manic Miner never touches, since it runs with
              interrupts disabled from startup.
  LOWERATTRS  its 512 bytes of attributes are only 18 runs long, so they are
              re-encoded here as run-length pairs and expanded at startup.
  TITLESCR2   the middle third of the title screen bitmap, 2048 bytes but only
              648 runs, re-encoded the same way for another ~750 bytes. That is
              what the IM 2 vector table is paid for with.

Every hook replaces one instruction with another of exactly the same length,
so every other address in the game is unchanged and the stock mm.sld still
describes it.

Two snapshots come out of this, so the two can be compared side by side:

  mm-fast.sna   free-running. Fastest, but the loop time varies with how much
                is on screen, so the game speeds up and slows down.
  mm-sync.sna   locked to the frame interrupt with IM 2 + HALT, for a steady
                cadence. It also shortens the in-game music note, whose only
                job was timing the loop -- HALT does that now.

Manic Miner runs with interrupts disabled from startup and cannot simply
enable them: in IM 1 the ROM's handler increments FRAMES at 0x5C78 and scans
the keyboard into the system variables, all of which sit inside the attribute
buffer the game keeps at 0x5C00-0x5DFF. Freeing that buffer is very likely why
the interrupts were turned off in the first place. So the locked build uses
IM 2 with a handler of its own, whose 257-byte vector table is what the
reclaimed TITLESCR2 space pays for.

Reads game_disassembly/manicminer/mm.asm, so run scripts/build_manicminer.py
at least once first. Requires sjasmplus (found on PATH, or in tools/).

Usage:
    python scripts/build_manicminer_fast.py [--sp SP]
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from zxspectrum.core.memory import RAM_SIZE
from zxspectrum.core.snapshot import write_sna
from zxspectrum.core.z80 import Registers

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = PROJECT_ROOT / "game_disassembly" / "manicminer"
PATCH_ASM = PROJECT_ROOT / "scripts" / "mm_fast_patch.asm"
NEWLINE = chr(10)

# MESSINTRO is exactly 256 bytes and page-aligned -- START_2 relies on that,
# setting only IXL to index into it -- so its replacement home must be
# page-aligned too. 0x5B00 is the ZX printer buffer: nothing in the
# disassembly references it, and Manic Miner disables interrupts at startup
# and never re-enables them, so no ROM code runs to touch it either.
MESSINTRO_ADDR = 0x9D00
MESSINTRO_LEN = 256
MESSINTRO_NEW_ADDR = 0x5B00

# LOWERATTRS, the title screen's attributes for the bottom two thirds, sits
# immediately after MESSINTRO and is only 18 runs long. Re-encoding it as
# run-length pairs frees most of its 512 bytes for the patch at no visual
# cost. Together the two slots give the patch 0x9D00-0x9FFF, and TITLESCR1
# stays put at 0xA000.
LOWERATTRS_ADDR = 0xA000 - 512
LOWERATTRS_LEN = 512

# TITLESCR2, the middle third of the title screen bitmap, is 648 runs -- 1297
# bytes encoded against 2048 stored -- which buys the ~750 bytes the IM 2
# vector table needs. TITLESCR1 stays literal: at 970 runs it barely
# compresses, and DRAWSHEET copies it directly for The Final Barrier.
TITLESCR2_ADDR = 0xA800
TITLESCR2_LEN = 2048


def find_sjasmplus() -> str:
    found = shutil.which("sjasmplus")
    if found:
        return found
    bundled = PROJECT_ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"
    if bundled.exists():
        return str(bundled)
    sys.exit(
        "error: sjasmplus not found on PATH or in tools/sjasmplus/. See "
        "scripts/build_rom_source.py's error message for where to get it."
    )


def _instruction(line: str) -> str:
    """The instruction field of an assembly line, without label or comment."""
    return line.split(";")[0].strip()


def replace_everywhere(lines: list[str], old: str, new: str, expected: int) -> None:
    """Rewrite every line whose instruction is exactly `old`, keeping comments."""
    hits = 0
    for i, line in enumerate(lines):
        if _instruction(line) == old:
            lines[i] = line.replace(old, new, 1)
            hits += 1
    if hits != expected:
        sys.exit(f"error: expected {expected} occurrences of {old!r}, found {hits}")


def replace_after_label(lines: list[str], label: str, old: str, new: str) -> None:
    """Rewrite the first `old` instruction at or after `label:`.

    Several of these instructions appear many times across the game; anchoring
    to the routine's label picks out the one that matters.
    """
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith(f"{label}:"))
    except StopIteration:
        sys.exit(f"error: label {label}: not found -- the disassembly has changed")
    for i in range(start, min(start + 40, len(lines))):
        if _instruction(lines[i]) == old:
            lines[i] = lines[i].replace(old, new, 1)
            return
    sys.exit(f"error: no {old!r} within 40 lines of {label}: -- the disassembly has changed")


def replace_block(lines: list[str], old: list[str], new: list[str]) -> None:
    """Replace one exact run of consecutive instructions, comments discarded."""
    hits = [
        i
        for i in range(len(lines) - len(old) + 1)
        if [_instruction(l) for l in lines[i : i + len(old)]] == old
    ]
    if len(hits) != 1:
        sys.exit(f"error: expected 1 occurrence of block {old}, found {len(hits)}")
    at = hits[0]
    lines[at : at + len(old)] = new


def rle(data: bytes) -> bytes:
    """Run-length encode as (count, value) pairs, terminated by a zero count."""
    out = bytearray()
    i = 0
    while i < len(data):
        run = 1
        while i + run < len(data) and data[i + run] == data[i] and run < 255:
            run += 1
        out += bytes([run, data[i]])
        i += run
    out.append(0)
    return bytes(out)


def _check_rle(encoded: bytes, original: bytes, what: str) -> None:
    """The title screen has to come out identical, so verify before baking."""
    decoded = bytearray()
    for i in range(0, len(encoded) - 1, 2):
        decoded += bytes([encoded[i + 1]]) * encoded[i]
    if bytes(decoded) != original:
        sys.exit(f"error: {what} run-length encoding does not round-trip")
    if any(encoded[i] == 0 for i in range(0, len(encoded) - 1, 2)):
        sys.exit(f"error: {what} encoding has a zero-length run, which terminates it")


def _defbs(data: bytes) -> str:
    return NEWLINE.join(
        "  DEFB " + ",".join(str(b) for b in data[i : i + 16])
        for i in range(0, len(data), 16)
    )


def _data_block(lines: list[str], label: str, keyword: str) -> tuple[int, int]:
    """The span of `keyword` data lines introduced by `label:`."""
    try:
        at = next(i for i, l in enumerate(lines) if l.startswith(f"{label}:"))
    except StopIteration:
        sys.exit(f"error: {label}: not found -- the disassembly has changed")
    end = at + 1
    while end < len(lines) and _instruction(lines[end]).startswith(keyword):
        end += 1
    if end == at + 1:
        sys.exit(f"error: no {keyword} data after {label}: -- the disassembly has changed")
    return at, end


def splice_patch(lines: list[str], lower_attrs: bytes, title2: bytes) -> list[str]:
    """Take over MESSINTRO's, LOWERATTRS' and TITLESCR2's slots."""
    region1, marker, region2 = PATCH_ASM.read_text(encoding="utf-8").partition("; @@REGION2@@")
    if not marker:
        sys.exit("error: mm_fast_patch.asm has no ; @@REGION2@@ marker")

    lower_rle, title2_rle = rle(lower_attrs), rle(title2)
    _check_rle(lower_rle, lower_attrs, "LOWERATTRS")
    _check_rle(title2_rle, title2, "TITLESCR2")
    region1 = region1.replace("; @@LOWERRLE@@", _defbs(lower_rle))
    region2 = region2.replace("; @@TITLE2RLE@@", _defbs(title2_rle))

    # Locate every block before touching any, then replace back to front so
    # the earlier indices stay valid.
    ti_at, ti_end = _data_block(lines, "TITLESCR2", "DEFB")
    lo_at, lo_end = _data_block(lines, "LOWERATTRS", "DEFB")
    mi_at, mi_end = _data_block(lines, "MESSINTRO", "DEFM")
    if not mi_end <= lo_at and lo_end <= ti_at:
        sys.exit("error: the three slots are no longer in the expected order")
    lines[ti_at:ti_end] = region2.split(NEWLINE)
    lines[lo_at:lo_end] = []
    lines[mi_at:mi_end] = region1.split(NEWLINE)

    # The EQU has to precede START_2's "LD IX,MESSINTRO", so put it at the top.
    org = next(i for i, l in enumerate(lines) if _instruction(l).startswith("ORG "))
    lines.insert(org + 1, f"MESSINTRO EQU {MESSINTRO_NEW_ADDR}")
    return lines


def patch_asm(stock: str, lower_attrs: bytes, title2: bytes,
              frame_sync: bool) -> str:
    lines = stock.split("\n")

    # The two 4096-byte copies the whole exercise is about. The replacements
    # are shorter, and the leftover zero bytes are NOPs, so everything after
    # them stays exactly where it was.
    #
    # The restore is small enough to inline into the 11 bytes it replaces:
    # only the rows drawn into last frame still hold sprite pixels, so only
    # those need wiping back to the empty cavern. BC carries the two buffer
    # MSBs, 0x70 -> 0x60.
    replace_block(
        lines,
        ["LD HL,28672", "LD DE,24576", "LD BC,4096", "LDIR"],
        [
            "  CALL FASTRESTORE       ; restore only the cells drawn into last frame",
            "  DEFS 8                 ; (padding: was a 4096-byte LDIR)",
        ],
    )
    replace_block(
        lines,
        ["LD HL,24576", "LD DE,16384", "LD BC,4096", "LDIR"],
        [
            "  CALL FASTBLIT          ; blit only the rows that changed",
            "  DEFS 8                 ; (padding: was a 4096-byte LDIR)",
        ],
    )

    # Sprite drawing. Every one of these is a same-length swap.
    replace_everywhere(lines, "CALL DRWFIX", "CALL DRWFIXM", expected=15)
    replace_everywhere(lines, "CALL Z,CRUMBLE", "CALL Z,CRUMBHOOK", expected=2)
    replace_everywhere(lines, "CALL CHKSWITCH", "CALL SWHOOK", expected=2)
    replace_everywhere(lines, "CALL MVCONVEYOR", "CALL CONVHOOK", expected=1)
    replace_everywhere(lines, "CALL PRINTCHAR_0", "CALL ITEMHOOK", expected=1)
    replace_after_label(lines, "CHKPORTAL_0", "LD HL,(PORTALLOC2)", "CALL PORTHOOK")
    replace_after_label(lines, "DRAWWILLY", "LD A,(WILLY_Y)", "CALL WILLYHOOK")

    # Full-refresh points: entering a cavern, and dying part-way through a frame.
    replace_after_label(lines, "NEWSHT", "LD A,(SHEET)", "CALL NEWHOOK")
    replace_after_label(lines, "KILLWILLY_1", "JP LOOP_4", "JP KILLHOOK")

    # LOWERATTRS' data is now run-length encoded, so expand it rather than
    # copying it. DE already points at the destination, left there by the
    # preceding LDIR.
    # START copies TITLESCR1 and TITLESCR2 to the display file in one 4096-byte
    # LDIR. TITLESCR2 is encoded now, so that splits into a copy and an expand.
    replace_block(
        lines,
        ["LD HL,TITLESCR1", "LD DE,16384", "LD BC,4096", "LDIR"],
        [
            "  CALL TITLEFILL         ; copy the top third, expand the middle one",
            "  DEFS 8                 ; (padding: was a 4096-byte LDIR)",
        ],
    )

    # Wait for the frame interrupt immediately before the blit, so a pass starts
    # at a fixed point in the raster and the blit runs ahead of the beam.
    if frame_sync:
        replace_block(
            lines,
            ["CALL FASTBLIT", "DEFS 8"],
            [
                "  CALL SYNCWAIT          ; lock the loop to the frame interrupt",
                "  CALL FASTBLIT          ; blit only the cells that changed",
                "  DEFS 5                 ; (padding: was a 4096-byte LDIR)",
            ],
        )

    replace_block(
        lines,
        ["LD HL,LOWERATTRS", "LD BC,512", "LDIR"],
        [
            "  CALL LOWERFILL         ; expand the run-length encoded attributes",
            "  DEFS 5                 ; (padding: was a 512-byte LDIR)",
        ],
    )

    return NEWLINE.join(splice_patch(lines, lower_attrs, title2))


def assemble(name: str, text: str, sjasmplus: str) -> bytes:
    asm_path = OUT_DIR / f"{name}.asm"
    bin_path = OUT_DIR / f"{name}.bin"
    asm_path.write_text(text, encoding="utf-8")
    cmd = [sjasmplus, asm_path.name, f"--raw={bin_path.name}"]
    if name != "mm-stock-check":
        # A source map for the patched build, so the VS Code debug target can
        # step through the patch itself and not just the stock disassembly.
        cmd += [f"--sld={name}.sld", "--fullpath"]
    print(f"$ {' '.join(cmd)}")
    subprocess.run(cmd, cwd=OUT_DIR, check=True, text=True)
    data = bin_path.read_bytes()
    bin_path.unlink()
    if name == "mm-stock-check":
        asm_path.unlink()        # only assembled to compare sizes against
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sp", type=lambda s: int(s, 0), default=0xFF00,
        help="stack pointer to start with (default 0xFF00, matching build_manicminer.py)",
    )
    args = parser.parse_args()

    sjasmplus = find_sjasmplus()
    stock_asm_path = OUT_DIR / "mm.asm"
    if not stock_asm_path.exists():
        sys.exit(f"error: {stock_asm_path} not found -- run scripts/build_manicminer.py first")
    stock_asm = stock_asm_path.read_text(encoding="utf-8")

    entry = int(re.search(r"^\s*ORG\s+(\d+)", stock_asm, re.MULTILINE).group(1))
    stock_bytes = assemble("mm-stock-check", stock_asm, sjasmplus)
    lower_attrs = stock_bytes[
        LOWERATTRS_ADDR - entry : LOWERATTRS_ADDR - entry + LOWERATTRS_LEN
    ]
    title2 = stock_bytes[
        TITLESCR2_ADDR - entry : TITLESCR2_ADDR - entry + TITLESCR2_LEN
    ]

    for name, frame_sync in (("mm-fast", False), ("mm-sync", True)):
        fast_bytes = assemble(
            name, patch_asm(stock_asm, lower_attrs, title2, frame_sync), sjasmplus
        )
        # The whole approach depends on nothing shifting, so check that it didn't.
        if len(fast_bytes) != len(stock_bytes):
            sys.exit(
                f"error: patched image is {len(fast_bytes)} bytes against the stock "
                f"{len(stock_bytes)} -- something moved, and the game's hardcoded "
                f"addresses will be wrong."
            )
        changed = sum(a != b for a, b in zip(stock_bytes, fast_bytes))

        messintro = stock_bytes[
            MESSINTRO_ADDR - entry : MESSINTRO_ADDR - entry + MESSINTRO_LEN
        ]
        ram = bytearray(RAM_SIZE)
        ram[entry - 0x4000 : entry - 0x4000 + len(fast_bytes)] = fast_bytes
        ram[MESSINTRO_NEW_ADDR - 0x4000 : MESSINTRO_NEW_ADDR - 0x4000 + MESSINTRO_LEN] = messintro

        sna_path = OUT_DIR / f"{name}.sna"
        sna_path.write_bytes(
            write_sna(Registers(pc=entry, sp=args.sp, im=1), bytes(ram), border=7)
        )
        lock = "frame-locked" if frame_sync else "free-running"
        print(f"Wrote {sna_path} ({lock}); {changed} bytes differ from stock")

    print(f"Entry point: 0x{entry:04X}, image size unchanged at {len(stock_bytes)} bytes")
    print(f"MESSINTRO relocated 0x{MESSINTRO_ADDR:04X} -> 0x{MESSINTRO_NEW_ADDR:04X}; "
          f"LOWERATTRS re-encoded to {len(rle(lower_attrs))} bytes, "
          f"TITLESCR2 to {len(rle(title2))}")
    print("Load roms/48.rom first, then either .sna. The stock mm.sld still applies:")
    print("every address outside the patch is unchanged.")


if __name__ == "__main__":
    main()
