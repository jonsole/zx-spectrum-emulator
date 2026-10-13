"""Assembles the Revs-style road engine: sjasmplus, from revs.s ->
output/revs.{z80,sld,lst}, beside this script.

Two things are generated before assembling, both into output/ and neither
committed: the track (track_data.py fetches it from revs.bbcelite.com and
caches it in data/) and the lookup tables (tables.py). sjasmplus writes all
48K of RAM with the SAVEBIN at the bottom of revs.s; this wraps that as a
version 3 .z80 that starts at `start`, the way the Filmation build does.

    python build.py
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT_DIR = HERE / "output"
sys.path.insert(0, str(HERE))

import object_types  # noqa: E402
import tables  # noqa: E402
import track_data  # noqa: E402

SJASMPLUS_CANDIDATES = [
    REPO / "tools" / "sjasmplus" / "sjasmplus.exe",
    REPO / ".venv-win" / "Scripts" / "sjasmplus.exe",
]


def find_sjasmplus() -> str:
    named = os.environ.get("SJASMPLUS")
    if named and Path(named).is_file():
        return named
    for candidate in SJASMPLUS_CANDIDATES:
        if candidate.is_file():
            return str(candidate)
    on_path = shutil.which("sjasmplus")
    if on_path is not None:
        return on_path
    sys.exit("sjasmplus not found -- see examples/filmation/knightlore/build.py for where to get it,\n"
             "or name it in the SJASMPLUS environment variable.")


def generate(track: str) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    data = track_data.fetch(track)
    lines = [f"; {track}: the Revs track data file, fetched by track_data.py -- not committed"]
    for i in range(0, len(data), 16):
        lines.append("    db " + ",".join(f"${b:02X}" for b in data[i:i + 16]))
    (OUT_DIR / "track.s.gen").write_text("\n".join(lines) + "\n")
    (OUT_DIR / "tables.s").write_text(tables.source())
    (OUT_DIR / "log12.s").write_text(
        tables.big_source(["log12_lo", "log_he", "log_hs", "log_hl"], aligned=True))
    (OUT_DIR / "exp8.s").write_text(tables.big_source(["exp8"]))
    (OUT_DIR / "objects.s.gen").write_text(object_types.source())


def assemble(sjasmplus: str, defines: list[str]) -> None:
    subprocess.run(
        [sjasmplus, "--nologo", "--sld=output/revs.sld", "--fullpath", "--lst=output/revs.lst",
         "-Ioutput", *[f"-D{d}" for d in defines], "revs.s"],
        cwd=HERE, check=True)
    ram = (OUT_DIR / "revs.bin").read_bytes()
    start = find_label(OUT_DIR / "revs.sld", "start")
    (OUT_DIR / "revs.z80").write_bytes(z80_snapshot(ram, start))
    print(f"Wrote {OUT_DIR / 'revs.z80'} (PC {start:04X}) and {OUT_DIR / 'revs.sld'}")


def find_label(sld: Path, name: str) -> int:
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[1] == name and parts[2] == "":
                return int(fields[5])
    sys.exit(f"no label {name} in {sld}")


# Version 3 .z80, 48K -- the same writer as examples/filmation's build.
Z80_V3_EXTRA = 54
Z80_PAGES = ((8, 0x0000), (4, 0x4000), (5, 0x8000))


def z80_compress(data: bytes) -> bytes:
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
    assert len(ram) == 0xC000, len(ram)
    header = bytearray(30 + 2 + Z80_V3_EXTRA)
    header[10] = 0x3F
    header[29] = 1
    header[30:32] = Z80_V3_EXTRA.to_bytes(2, "little")
    header[32:34] = pc.to_bytes(2, "little")
    header[34] = 0
    header[61] = header[62] = 0xFF
    body = bytearray()
    for page, offset in Z80_PAGES:
        packed = z80_compress(ram[offset:offset + 0x4000])
        body += len(packed).to_bytes(2, "little") + bytes((page,)) + packed
    return bytes(header + body)


def main() -> None:
    parser = argparse.ArgumentParser(description="Assemble the Revs-style road engine.")
    parser.add_argument("--track", default="silverstone")
    parser.add_argument("--define", action="append", default=[], metavar="NAME",
                        help="an assembler define, such as SYNCED (see revs.s)")
    args = parser.parse_args()
    sjasmplus = find_sjasmplus()
    generate(args.track)
    assemble(sjasmplus, args.define)


if __name__ == "__main__":
    main()
