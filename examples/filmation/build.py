"""Assembles the Filmation engine: sjasmplus -> output/filmation.{z80,sld,lst}.

sjasmplus writes all 48K of RAM with the SAVEBIN at the bottom of filmation.s,
the SLD that maps addresses to source lines, and a listing. This wraps the RAM
as a version 3 .z80 that starts at `start` -- sjasmplus has no .z80 output of
its own, and its 48K .sna has to push PC into the bottom of the screen.

sprite_data.s and room_data.s are generated rather than hand-written -- see
sprites.py and rooms.py -- and are regenerated here whenever their packed
inputs or their generators are newer, which is the one build step beyond
calling the assembler.

sprite_adj.s is generated too, but by adj.py from a RUNNING Knight Lore, so it
is committed and never rebuilt here.

Run it directly, or via the "filmation.build" VS Code task that
.vscode/launch.json's "ZX Spectrum: Filmation" configuration depends on.

    python build.py                 the game
    python build.py --debug-room    with the room number printed top-left
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT_DIR = HERE / "output"
# Knight Lore's data and the scripts that turn it into source live in knightlore/.
KNIGHTLORE = HERE / "knightlore"

# Where sjasmplus might be, best first: the copy this repo fetches for its own
# disassembly builds, then whatever is on PATH. Kept a search rather than a
# setting because every machine this has run on has had one of the two.
SJASMPLUS_CANDIDATES = [
    REPO / "tools" / "sjasmplus" / "sjasmplus.exe",
    REPO / ".venv-win" / "Scripts" / "sjasmplus.exe",
]

INSTALL_HELP = (
    "sjasmplus not found.\n"
    "Windows: download the prebuilt sjasmplus-<version>.win.zip from\n"
    "  https://github.com/z00m128/sjasmplus/releases and unzip it into\n"
    f"  {REPO / 'tools' / 'sjasmplus'} (or put sjasmplus.exe on PATH).\n"
    "Linux/macOS: no prebuilt release exists -- build from source:\n"
    "  git clone https://github.com/z00m128/sjasmplus.git\n"
    "  cd sjasmplus && git submodule update --init --recursive && make"
)


def find_sjasmplus() -> str:
    for candidate in SJASMPLUS_CANDIDATES:
        if candidate.is_file():
            return str(candidate)
    on_path = shutil.which("sjasmplus")
    if on_path is not None:
        return on_path
    sys.exit(INSTALL_HELP)


def generate_sprite_data() -> None:
    """Regenerates sprite_data.s when its inputs have moved on.

    sprites.py writes the table to stdout, so this captures it rather than
    letting it inherit one -- the original project's SCons build did the same
    thing with a shell redirect.
    """
    generator = KNIGHTLORE / "sprites.py"
    packed = KNIGHTLORE / "sprite_data.bin"
    generated = KNIGHTLORE / "sprite_data.s"
    table = KNIGHTLORE / "sprite_table.s"
    adjusted = KNIGHTLORE / "sprite_adj_gen.s"
    harvest = KNIGHTLORE / "sprite_adj.s"

    if not packed.is_file():
        sys.exit(f"{packed.name} is missing -- run kl_extract.py against your "
                 "own copy of Knight Lore to produce it")

    newest_input = max(generator.stat().st_mtime, packed.stat().st_mtime,
                       harvest.stat().st_mtime)
    if all(f.is_file() and f.stat().st_mtime >= newest_input
           for f in (generated, table, adjusted)):
        return

    # Three files: the two halves go to different places in the image -- see
    # the note at the top of sprites.py -- and the adjustments are the harvest
    # in sprite_adj.s with the trimmed rows folded in.
    for out, part in ((generated, "bitmaps"), (table, "table"), (adjusted, "adj")):
        print(f"Regenerating {out.name} from {packed.name}")
        result = subprocess.run(
            [sys.executable, str(generator), part],
            cwd=KNIGHTLORE,
            capture_output=True,
            encoding="utf-8",
            check=True,
        )
        out.write_text(result.stdout, encoding="utf-8")


def assemble(sjasmplus: str, defines: list[str]) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    # --fullpath so the SLD's records carry a file the debugger can match a
    # source path against; filmation.s INCLUDEs four other files, and a line
    # number only means something paired with the file it came from.
    subprocess.run(
        [
            sjasmplus,
            "--sld=output/filmation.sld",
            "--fullpath",
            "--lst=output/filmation.lst",
            *[f"-D{name}" for name in defines],
            "filmation.s",
        ],
        cwd=HERE,
        check=True,
    )
    ram = (OUT_DIR / "filmation.bin").read_bytes()
    start = find_label(OUT_DIR / "filmation.sld", "start")
    (OUT_DIR / "filmation.z80").write_bytes(z80_snapshot(ram, start))
    # A .sna left from before this build wrote .z80 would be stale.
    (OUT_DIR / "filmation.sna").unlink(missing_ok=True)
    print(f"Wrote {OUT_DIR / 'filmation.z80'} (PC {start:04X}) and {OUT_DIR / 'filmation.sld'}")


def find_label(sld: Path, name: str) -> int:
    """A label's address, from the SLD's label records."""
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[1] == name and parts[2] == "":
                return int(fields[5])
    sys.exit(f"no label {name} in {sld}")


# Version 3 .z80, 48K: a 30-byte header with PC zeroed, 54 more bytes, then
# the three RAM pages, each compressed -- page 8 is $4000, 4 is $8000 and 5 is
# $C000. The same layout cpp-core's save_z80 writes.
Z80_V3_EXTRA = 54
Z80_PAGES = ((8, 0x0000), (4, 0x4000), (5, 0x8000))  # page, offset into RAM


def z80_compress(data: bytes) -> bytes:
    """ED ED n b for a run of five or more, or of two or more EDs. A lone ED
    goes out literally along with the byte after it, so that no decoder can
    take the pair for a run marker."""
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        run = 1
        while i + run < len(data) and data[i + run] == b and run < 255:
            run += 1
        if run >= 5 or (b == 0xED and run >= 2):
            out += bytes((0xED, 0xED, run, b))
            i += run
        elif b == 0xED:
            out += data[i:i + 2]
            i += 2
        else:
            out.append(b)
            i += 1
    return bytes(out)


def z80_snapshot(ram: bytes, pc: int) -> bytes:
    """48K of RAM from $4000, as a machine about to run from `pc`.

    Everything else is what start sets for itself anyway: it disables
    interrupts and loads SP first thing, and blacks the border.
    """
    assert len(ram) == 0xC000, len(ram)
    header = bytearray(30 + 2 + Z80_V3_EXTRA)
    header[10] = 0x3F                  # I, as the ROM leaves it
    header[29] = 1                     # IM 1; IFF1 and IFF2 stay 0
    header[30:32] = Z80_V3_EXTRA.to_bytes(2, "little")
    header[32:34] = pc.to_bytes(2, "little")
    header[34] = 0                     # hardware: 48K
    header[61] = header[62] = 0xFF     # the ROM is paged in
    body = bytearray()
    for page, offset in Z80_PAGES:
        packed = z80_compress(ram[offset:offset + 0x4000])
        body += len(packed).to_bytes(2, "little") + bytes((page,)) + packed
    return bytes(header + body)


def generate_room_data() -> None:
    """Regenerates room_data.s when its inputs have moved on.

    rooms.py writes the file itself rather than to stdout, because it is
    thousands of lines of named templates and commented room records rather
    than one table.
    """
    generator = KNIGHTLORE / "rooms.py"
    packed = KNIGHTLORE / "room_data.bin"
    generated = KNIGHTLORE / "room_data.s"

    if not packed.is_file():
        sys.exit(f"{packed.name} is missing -- run kl_extract.py against your "
                 "own copy of Knight Lore to produce it")

    newest_input = max(generator.stat().st_mtime, packed.stat().st_mtime)
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {packed.name}")
    subprocess.run([sys.executable, str(generator)], cwd=KNIGHTLORE, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Assemble the Filmation engine.")
    parser.add_argument("--debug-room", action="store_true",
                        help="print the room number in the top-left corner (DEBUG_ROOM)")
    args = parser.parse_args()
    defines = ["DEBUG_ROOM"] if args.debug_room else []

    sjasmplus = find_sjasmplus()
    generate_sprite_data()
    generate_room_data()
    assemble(sjasmplus, defines)


if __name__ == "__main__":
    main()
