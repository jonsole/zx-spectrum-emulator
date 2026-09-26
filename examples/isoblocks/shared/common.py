"""What both isoblocks builds share: where things are, sjasmplus, the SLD, the
map and the sprite pictures, and turning an assembled demo into a .z80.

painter/build.py and rays/build.py import this; so do their checks, through
them.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

SHARED = Path(__file__).resolve().parent
ISOBLOCKS = SHARED.parent
REPO = ISOBLOCKS.parent.parent
sys.path.insert(0, str(ISOBLOCKS.parent / "filmation"))
import z80file                                                   # noqa: E402

import isogeom                                                    # noqa: E402

SJASMPLUS = [REPO / "tools" / "sjasmplus" / "sjasmplus.exe",
             REPO / ".venv-win" / "Scripts" / "sjasmplus.exe"]


def find_sjasmplus() -> str:
    for candidate in SJASMPLUS:
        if candidate.is_file():
            return str(candidate)
    found = shutil.which("sjasmplus")
    if found:
        return found
    sys.exit("sjasmplus not found -- see examples/filmation/knightlore/build.py")


def word(value: int) -> str:
    return f"${value & 0xFFFF:04X}"


def find_label(sld: Path, name: str) -> int:
    """A label's address, from the SLD's label records."""
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[1] == name and parts[2] == "":
                return int(fields[5])
    sys.exit(f"no label {name} in {sld}")


def read_map() -> bytes:
    """maps/test.json's boxes, rasterised: 16K of cells, a bit per height."""
    spec = json.loads((SHARED / "maps" / "test.json").read_text(encoding="utf-8"))
    return isogeom.rasterise(spec["boxes"])


def read_sprites() -> dict:
    """{name: picture}, a picture 16 rows of (opaque, ink) 16-bit pairs, bit 15
    the leftmost pixel -- the form the models draw sprites from."""
    spec = json.loads((SHARED / "art" / "sprites.json").read_text(encoding="utf-8"))
    sheet = Image.open(SHARED / "art" / spec["sheet"]).convert("RGB")
    colour = {name: tuple(int(value[i:i + 2], 16) for i in (1, 3, 5))
              for name, value in spec["colours"].items()}
    pictures = {}
    for name, where in spec["sprites"].items():
        left, top = where["at"]
        rows = []
        for y in range(16):
            opaque = ink = 0
            for x in range(16):
                pixel = sheet.getpixel((left + x, top + y))
                if pixel == colour["clear"]:
                    continue
                opaque |= 0x8000 >> x
                if pixel == colour["ink"]:
                    ink |= 0x8000 >> x
                elif pixel != colour["paper"]:
                    sys.exit(f"art/{spec['sheet']}: {name} has a pixel that is not "
                             f"ink, paper or clear at ({x}, {y})")
            rows.append((opaque, ink))
        pictures[name] = rows
    return pictures


def assemble(version: Path, name: str) -> None:
    """sjasmplus on version/demo.s, in version/: it writes output/<name>.banks
    (all eight RAM banks), .bin (the view from $4000, for the checks), .sld
    and .lst; then the banks become output/<name>.z80, a 128K snapshot that
    starts at `start`, with $7FFD 0 -- bank 0 at $C000, the normal screen."""
    out = version / "output"
    subprocess.run([find_sjasmplus(), f"--sld=output/{name}.sld", "--fullpath",
                    f"--lst=output/{name}.lst", "demo.s"], cwd=version, check=True)
    banks = (out / f"{name}.banks").read_bytes()
    start = find_label(out / f"{name}.sld", "start")
    (out / f"{name}.z80").write_bytes(z80file.snapshot_128k(banks, start, 0))
    print(f"Wrote {out / (name + '.z80')} (128K, PC {start:04X}) and {out / (name + '.sld')}")
