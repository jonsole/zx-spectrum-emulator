"""Assembles the Filmation engine: sjasmplus -> output/filmation.{sna,sld,lst}.

The .sna comes out of the SAVESNA directive at the bottom of filmation.s, so
one sjasmplus invocation produces everything the debugger needs -- the
snapshot to load, the SLD to map addresses to source lines, and a listing.

sprite_data.s is generated rather than hand-written (see sprites.py); it is
regenerated here whenever sprite_data.bin or the generator is newer than it,
which is the one build step beyond calling the assembler.

Run it directly, or via the "filmation.build" VS Code task that
.vscode/launch.json's "ZX Spectrum: Filmation" configuration depends on.
"""

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
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
    """Regenerates sprite_data.s when its inputs have moved on.

    sprites.py writes the table to stdout, so this captures it rather than
    letting it inherit one -- the original project's SCons build did the same
    thing with a shell redirect.
    """
    generator = HERE / "sprites.py"
    packed = HERE / "sprite_data.bin"
    generated = HERE / "sprite_data.s"

    if not packed.is_file():
        # sprite_data.bin is the committed one and sprite_data.s is not, so
        # this only happens if the packed file has been deleted. Carry on if
        # a generated copy is lying around; otherwise sjasmplus will say so.
        print(f"note: {packed.name} not present -- using whatever {generated.name} is here.")
        return

    newest_input = max(generator.stat().st_mtime, packed.stat().st_mtime)
    if generated.is_file() and generated.stat().st_mtime >= newest_input:
        return

    print(f"Regenerating {generated.name} from {packed.name}")
    result = subprocess.run(
        [sys.executable, str(generator)],
        cwd=HERE,
        capture_output=True,
        encoding="utf-8",
        check=True,
    )
    generated.write_text(result.stdout, encoding="utf-8")


def assemble(sjasmplus: str) -> None:
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
            "filmation.s",
        ],
        cwd=HERE,
        check=True,
    )
    print(f"Wrote {OUT_DIR / 'filmation.sna'} and {OUT_DIR / 'filmation.sld'}")


def main() -> None:
    sjasmplus = find_sjasmplus()
    generate_sprite_data()
    assemble(sjasmplus)


if __name__ == "__main__":
    main()
