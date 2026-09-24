"""Assembles Knight Lore 128K on the Filmation engine: sjasmplus, from
knightlore128.s -> output/knightlore128.{z80,sld,lst}, beside this script.

This game began as a copy of ../knightlore/ (2026-09-24) and is where Knight
Lore grows into a 128K castle: Pentagram's art beside Knight Lore's, a bigger
map joined by a table of exits, and new scenery. README.md says how far it has
got. The 48K Knight Lore in ../knightlore/ is left as it is.

sjasmplus writes the RAM with the SAVEBIN at the bottom of knightlore128.s,
the SLD that maps addresses to source lines, and a listing. It runs here, so
the SLD names the game's sources relative to knightlore128.s, which is where
the debugger resolves them. This wraps the RAM as a version 3 .z80 that starts
at `start` -- sjasmplus has no .z80 output of its own.

sprite_data.s, font.s, specials_gen.s and room_data.s are generated rather than
hand-written -- see sprite_source.py, font_source.py, specials_source.py and
rooms_source.py -- and are regenerated here whenever their inputs or their
generators are newer, which is the one build step beyond calling the
assembler.

The sprites come from sprites.png with sprites.json, which are this game's own
and carried: edit the PNG, rebuild, and the game changes. graphics.json says
which sprite each graphic number draws, the pixel nudge that lines it up and
the box it occupies. The nudges came from a running Knight Lore (see
../knightlore/adj.py); new graphics get theirs by hand.

The font is Knight Lore's, and it is not carried: it is extracted from your own
copy of the game into ../knightlore/, and this build reads the sheet there
rather than keeping a second copy of it.

    python build.py                 the game
    python build.py --debug-room    with the room number printed top-left
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

# The game's sources, its data and the scripts that turn the data into
# source all live here, beside this script.
HERE = Path(__file__).resolve().parent
GAME = HERE
# Where Knight Lore's font is unpacked, from your own copy of the game.
KNIGHTLORE = HERE.parent / "knightlore"
REPO = HERE.parent.parent.parent
OUT_DIR = HERE / "output"

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

    ONE step, not two. sprites.png and sprites.json are the authoritative form
    of the graphics -- the sprites themselves, the name and group of each one,
    which sprite every graphic number draws and the pixel nudge that lines it
    up -- and nothing here regenerates them. They are made once, by
    sprite_sheet.py, out of what kl_extract.py pulled from the game; after that
    they are what you edit and what the build reads.

    That is the whole of why the flow is one way. sprite_sheet.py used to be
    run from here whenever the sheet was missing, which quietly made the atlas
    a CACHE of graphic_map.json -- and a cache nothing invalidated, so
    re-pointing a graphic changed a file the build had already stopped reading.
    """
    generator = GAME / "sprite_source.py"
    sheet = GAME / "sprites.png"
    atlas = GAME / "sprites.json"
    # The graphic table is an input too, and a change to it reaches further
    # than a change to the artwork: the nudges, the boxes and the GFX_* labels
    # all come out of it.
    table = GAME / "graphics.json"
    # ...and so is the code that reads the sheet and the game's facts about it:
    # the frame check and the pixel colours are sheet.py's, and what animates
    # and what keeps its blank rows are sprite_sheet.py's.
    code = [GAME.parent / "sheet.py", GAME / "sprite_sheet.py"]
    generated = [GAME / name for name in
                 ("sprite_data.s", "sprite_table.s", "graphics_gen.s",
                  "sprite_adj_gen.s")]

    if not sheet.is_file() or not atlas.is_file():
        sys.exit(f"{sheet.name} and {atlas.name} are the graphics this game is "
                 f"built from, and one of them is missing.\n"
                 f"They are made once, from your own copy of the game:\n"
                 f"    python kl_extract.py \"path/to/Knight Lore\"\n"
                 f"    python sprite_sheet.py\n"
                 f"After that they are yours to edit and nothing overwrites them.")

    newest_input = max(f.stat().st_mtime
                       for f in [generator, sheet, atlas, table] + code if f.is_file())
    if all(f.is_file() and f.stat().st_mtime >= newest_input for f in generated):
        return

    print(f"Regenerating the sprite sources from {atlas.name}")
    subprocess.run([sys.executable, str(generator)], cwd=GAME, check=True)


def generate_font_data() -> None:
    """Regenerates font.s when Knight Lore's font sheet has moved on.

    The sheet is Knight Lore's own, unpacked in ../knightlore/ from the
    font.bin kl_extract.py lifts out of your copy of the game. This game reads
    it there, unpacking it first if Knight Lore's build has not, and writes
    its own font.s here with its own font_source.py.
    """
    packed = KNIGHTLORE / "font.bin"
    unpack = KNIGHTLORE / "font_sheet.py"
    generator = GAME / "font_source.py"
    sheet = KNIGHTLORE / "font.png"
    atlas = KNIGHTLORE / "font.json"
    generated = GAME / "font.s"

    if not sheet.is_file() or not atlas.is_file():
        if not packed.is_file():
            sys.exit(f"{packed} is missing -- run ../knightlore/kl_extract.py "
                     "against your own copy of Knight Lore to produce it")
        print(f"Unpacking {packed.name} into {sheet.name} and {atlas.name}")
        subprocess.run([sys.executable, str(unpack)], cwd=KNIGHTLORE, check=True)

    newest_input = max(f.stat().st_mtime for f in (generator, sheet, atlas))
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {sheet}")
    subprocess.run([sys.executable, str(generator), "--sheet", str(sheet),
                    "--json", str(atlas)], cwd=GAME, check=True)


def generate_specials() -> None:
    """Regenerates specials_gen.s when specials.json has moved on.

    One step rather than two: specials.json is carried, so there is no sheet to
    unpack first and no packed file to need. kl_extract.py writes the JSON from
    the game once; after that it is the editable form, and moving a collectable
    is an edit to it.
    """
    data = GAME / "specials.json"
    generator = GAME / "specials_source.py"
    generated = GAME / "specials_gen.s"

    if not data.is_file():
        sys.exit(f"{data.name} is missing -- run kl_extract.py against your "
                 "own copy of Knight Lore to produce it")

    newest_input = max(f.stat().st_mtime for f in (generator, data))
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {data.name}")
    subprocess.run([sys.executable, str(generator)], cwd=GAME, check=True)


def assemble(sjasmplus: str, defines: list[str]) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    # --fullpath so the SLD's records carry a file the debugger can match a
    # source path against; knightlore128.s INCLUDEs some forty other files, and a line
    # number only means something paired with the file it came from.
    subprocess.run(
        [
            sjasmplus,
            "--sld=output/knightlore128.sld",
            "--fullpath",
            "--lst=output/knightlore128.lst",
            *[f"-D{name}" for name in defines],
            "knightlore128.s",
        ],
        cwd=GAME,
        check=True,
    )
    ram = (OUT_DIR / "knightlore128.bin").read_bytes()
    start = find_label(OUT_DIR / "knightlore128.sld", "start")
    (OUT_DIR / "knightlore128.z80").write_bytes(z80_snapshot(ram, start))
    print(f"Wrote {OUT_DIR / 'knightlore128.z80'} (PC {start:04X}) and {OUT_DIR / 'knightlore128.sld'}")


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
    """Regenerates room_data.s when rooms.json has moved on.

    ONE step, like the sprites. rooms.json is the authoritative form of the
    castle: rooms.py decodes it out of the game ONCE, and after that it is what
    you edit -- by hand or in the room designer -- and what rooms_source.py
    assembles. Nothing here re-decodes it, so an edit cannot be overwritten by
    the original game's rooms.

    Going back to those is a deliberate act: run rooms.py by hand, which says
    plainly that it overwrites what is there.
    """
    emitter = GAME / "rooms_source.py"
    atlas = GAME / "rooms.json"
    generated = GAME / "room_data.s"

    if not atlas.is_file():
        sys.exit(f"{atlas.name} is the castle this game is built from, and it "
                 f"is missing.\nIt is made once, from your own copy of the "
                 f"game:\n    python kl_extract.py \"path/to/Knight Lore\"\n"
                 f"    python rooms.py")

    # The sheet is an input too: rooms.json names its graphics after the
    # sheet's own labels (examples/filmation/graphics.py), so a sheet that has
    # been renamed leaves those names stale and rooms_source.py would stop on
    # one it could not place.
    inputs = [emitter.stat().st_mtime, atlas.stat().st_mtime]
    # ...and the templates the rooms place, a file of their own, wherever
    # rooms.json says it is.
    named = (json.loads(atlas.read_text(encoding="utf-8")).get("meta") or {}).get("templates")
    templates = GAME / named if named else None
    if templates and templates.is_file():
        inputs.append(templates.stat().st_mtime)
    namer = GAME.parent / "graphics.py"
    if namer.is_file():
        inputs.append(namer.stat().st_mtime)
    sheet = GAME / "sprites.json"
    if sheet.is_file():
        inputs.append(sheet.stat().st_mtime)

    if generated.is_file() and generated.stat().st_mtime >= max(inputs):
        return

    print(f"Regenerating {generated.name} from {atlas.name}")
    subprocess.run([sys.executable, str(emitter)], cwd=GAME, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Assemble the Filmation engine.")
    parser.add_argument("--debug-room", action="store_true",
                        help="print the room number in the top-left corner (DEBUG_ROOM)")
    args = parser.parse_args()
    defines = ["DEBUG_ROOM"] if args.debug_room else []

    sjasmplus = find_sjasmplus()
    generate_sprite_data()
    generate_font_data()
    generate_specials()
    generate_room_data()
    assemble(sjasmplus, defines)


if __name__ == "__main__":
    main()
