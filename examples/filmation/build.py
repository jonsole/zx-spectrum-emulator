"""Assembles the Filmation engine: sjasmplus -> output/filmation.{sna,sld,lst}.

The .sna comes out of the SAVESNA directive at the bottom of filmation.s, so
one sjasmplus invocation produces everything the debugger needs -- the
snapshot to load, the SLD to map addresses to source lines, and a listing.

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
    print(f"Wrote {OUT_DIR / 'filmation.sna'} and {OUT_DIR / 'filmation.sld'}")


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
