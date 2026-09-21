"""Assembles Knight Lore on the Filmation engine: sjasmplus, from
knightlore.s -> output/knightlore.{z80,sld,lst}, both beside this script.

sjasmplus writes all 48K of RAM with the SAVEBIN at the bottom of
knightlore.s, the SLD that maps addresses to source lines, and a listing. It
runs here, in knightlore/, so the SLD names the game's sources relative to
knightlore.s, which is where the debugger resolves them. This wraps the RAM as a version 3
.z80 that starts at `start` -- sjasmplus has no .z80 output of its own, and its
48K .sna has to push PC into the bottom of the screen.

sprite_data.s, font.s and room_data.s are generated rather than hand-written
-- see sprite_source.py, font_source.py, and rooms.py with rooms_source.py --
and are regenerated here whenever their inputs or their generators are newer,
which is the one build step beyond calling the assembler.

The sprites and the font each come from a sheet -- sprites.png with
sprites.json, font.png with font.json -- which is where that artwork lives:
sprite_sheet.py and font_sheet.py unpack them out of sprite_data.bin and
font.bin, and this makes one the first time it finds none. It never remakes
one that is already there, because that is where your edits to the artwork
live -- run the unpacking script by hand to go back to the game's own.

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

# Knight Lore's sources, its data and the scripts that turn the data into
# source all live here, beside this script.
HERE = Path(__file__).resolve().parent
KNIGHTLORE = HERE
REPO = HERE.parent.parent.parent
OUT_DIR = HERE / "output"
# Where the build wrote before it moved in here.
OLD_OUT_DIR = HERE.parent / "output"

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
    """Regenerates the sprite sources when the sheet has moved on.

    Two steps: sprite_sheet.py unpacks sprite_data.bin into sprites.png and
    sprites.json if there is no sheet yet, and sprite_source.py turns that
    sheet into the three assembler files. Only the first run makes a sheet --
    an existing one is the artwork, edits and all, and is never overwritten.
    """
    packed = KNIGHTLORE / "sprite_data.bin"
    unpack = KNIGHTLORE / "sprite_sheet.py"
    generator = KNIGHTLORE / "sprite_source.py"
    sheet = KNIGHTLORE / "sprites.png"
    atlas = KNIGHTLORE / "sprites.json"
    harvest = KNIGHTLORE / "sprite_adj.s"
    generated = [KNIGHTLORE / name for name in
                 ("sprite_data.s", "sprite_table.s", "sprite_adj_gen.s")]

    if not sheet.is_file() or not atlas.is_file():
        if not packed.is_file():
            sys.exit(f"{packed.name} is missing -- run kl_extract.py against your "
                     "own copy of Knight Lore to produce it")
        print(f"Unpacking {packed.name} into {sheet.name} and {atlas.name}")
        subprocess.run([sys.executable, str(unpack)], cwd=KNIGHTLORE, check=True)

    newest_input = max(f.stat().st_mtime
                       for f in (generator, sheet, atlas, harvest))
    if all(f.is_file() and f.stat().st_mtime >= newest_input for f in generated):
        return

    print(f"Regenerating the sprite sources from {sheet.name}")
    subprocess.run([sys.executable, str(generator)], cwd=KNIGHTLORE, check=True)


def generate_font_data() -> None:
    """Regenerates font.s when the font sheet has moved on.

    The same two steps as the sprites: font_sheet.py unpacks font.bin into
    font.png and font.json if there is no sheet yet, and font_source.py turns
    that sheet into font.s. Only the first run makes a sheet -- an existing one
    is the artwork, edits and all, and is never overwritten.
    """
    packed = KNIGHTLORE / "font.bin"
    unpack = KNIGHTLORE / "font_sheet.py"
    generator = KNIGHTLORE / "font_source.py"
    sheet = KNIGHTLORE / "font.png"
    atlas = KNIGHTLORE / "font.json"
    generated = KNIGHTLORE / "font.s"

    if not sheet.is_file() or not atlas.is_file():
        if not packed.is_file():
            sys.exit(f"{packed.name} is missing -- run kl_extract.py against your "
                     "own copy of Knight Lore to produce it")
        print(f"Unpacking {packed.name} into {sheet.name} and {atlas.name}")
        subprocess.run([sys.executable, str(unpack)], cwd=KNIGHTLORE, check=True)

    newest_input = max(f.stat().st_mtime for f in (generator, sheet, atlas))
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {sheet.name}")
    subprocess.run([sys.executable, str(generator)], cwd=KNIGHTLORE, check=True)


def assemble(sjasmplus: str, defines: list[str]) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    # --fullpath so the SLD's records carry a file the debugger can match a
    # source path against; knightlore.s INCLUDEs some forty other files, and a line
    # number only means something paired with the file it came from.
    subprocess.run(
        [
            sjasmplus,
            "--sld=output/knightlore.sld",
            "--fullpath",
            "--lst=output/knightlore.lst",
            *[f"-D{name}" for name in defines],
            "knightlore.s",
        ],
        cwd=KNIGHTLORE,
        check=True,
    )
    ram = (OUT_DIR / "knightlore.bin").read_bytes()
    start = find_label(OUT_DIR / "knightlore.sld", "start")
    (OUT_DIR / "knightlore.z80").write_bytes(z80_snapshot(ram, start))
    # What the build wrote before it moved in here would be stale, and
    # loadable by mistake.
    for name in ("filmation", "knightlore"):
        for old in ("sna", "z80", "bin", "sld", "lst"):
            (OLD_OUT_DIR / f"{name}.{old}").unlink(missing_ok=True)
    print(f"Wrote {OUT_DIR / 'knightlore.z80'} (PC {start:04X}) and {OUT_DIR / 'knightlore.sld'}")


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
    """Regenerates room_data.s when its inputs have moved on, in two steps.

    rooms.py decodes room_data.bin into rooms.json, the readable form, and
    rooms_source.py turns rooms.json into room_data.s. Both write their files
    themselves rather than to stdout, because they are thousands of lines of
    named templates and commented room records rather than one table.

    The two steps are timed separately on purpose. rooms.json is the editable
    form -- by hand, or in the room designer -- so it is only re-decoded when
    room_data.bin or the decoder is newer than it, and an edit to the castle
    reaches the build without being overwritten by the game's own rooms.
    """
    decoder = KNIGHTLORE / "rooms.py"
    emitter = KNIGHTLORE / "rooms_source.py"
    packed = KNIGHTLORE / "room_data.bin"
    atlas = KNIGHTLORE / "rooms.json"
    generated = KNIGHTLORE / "room_data.s"

    if not packed.is_file():
        sys.exit(f"{packed.name} is missing -- run kl_extract.py against your "
                 "own copy of Knight Lore to produce it")

    # The sprite sheet is an input too: rooms.json names its graphics after the
    # sheet's own labels (examples/filmation/graphics.py), so a sheet that has
    # been regenerated or renamed leaves those names stale, and rooms_source.py
    # would stop on a name it could not place.
    inputs = [decoder.stat().st_mtime, packed.stat().st_mtime]
    # ...and the naming rule itself, which lives one directory up and is what
    # turns a graphic number into the name rooms.json carries.
    namer = KNIGHTLORE.parent / "graphics.py"
    if namer.is_file():
        inputs.append(namer.stat().st_mtime)
    sheet = KNIGHTLORE / "sprites.json"
    if sheet.is_file():
        inputs.append(sheet.stat().st_mtime)
    newest_input = max(inputs)
    if not atlas.is_file() or atlas.stat().st_mtime < newest_input:
        print(f"Regenerating {atlas.name} from {packed.name}")
        subprocess.run([sys.executable, str(decoder)], cwd=KNIGHTLORE, check=True)

    newest_input = max(emitter.stat().st_mtime, atlas.stat().st_mtime)
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {atlas.name}")
    subprocess.run([sys.executable, str(emitter)], cwd=KNIGHTLORE, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Assemble the Filmation engine.")
    parser.add_argument("--debug-room", action="store_true",
                        help="print the room number in the top-left corner (DEBUG_ROOM)")
    args = parser.parse_args()
    defines = ["DEBUG_ROOM"] if args.debug_room else []

    sjasmplus = find_sjasmplus()
    generate_sprite_data()
    generate_font_data()
    generate_room_data()
    assemble(sjasmplus, defines)


if __name__ == "__main__":
    main()
