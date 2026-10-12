"""Fetches a Revs track data file from Mark Moxon's annotated source.

The track data is Acornsoft's (Geoff Crammond's Revs, 1985), so like the ROMs
it is never committed: the build fetches the annotated listing from
revs.bbcelite.com, reassembles the data directives back into the original
binary, checks it against the file's own checksum, and caches the result in
data/ (gitignored). See the "track data file format" deep dive on that site
for what every byte means.

    python track_data.py silverstone                  fetch (if not cached) and verify
    python track_data.py silverstone --from page.html from a saved copy of the page
"""

import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / "data"
URL = "https://revs.bbcelite.com/source/all/revs_{}.html"

# The standard format is 1,849 bytes, loaded at &5300 (Silverstone). The four
# extra tracks use a different, hook-driven format that is not supported yet.
TRACK_SIZE = 1849
BASE = 0x5300

# Offsets into the file, from the deep dive.
SECTION_DATA = 0x000      # 8 bytes per section, part 1
SIGN_VECTOR_X = 0x0D0
SIGN_VECTOR_Z = 0x0E0
SIGN_VECTOR_Y = 0x0F0
SEGMENT_XI = 0x100        # five 256-byte segment vector tables
SEGMENT_YI = 0x200
SEGMENT_ZI = 0x300
SEGMENT_XO = 0x400
SEGMENT_ZO = 0x500
SECTION_FLAG = 0x600      # 8 bytes per section, part 2
SECTION_COUNT = 0x6FA     # number of sections * 8
VECTOR_COUNT = 0x6FB
TRACK_LENGTH = 0x6FC      # 16-bit, in segments
START_LINE = 0x6FE        # 16-bit, 1024 - the starting line's segment
CHECKSUM = 0x725          # four counts of bytes by their low two bits


def _value(token: str) -> int:
    token = token.strip()
    if token.startswith("&"):
        return int(token[1:], 16)
    if token.startswith("%"):
        return int(token[1:], 2)
    # Plain arithmetic such as "1024 - 181" or "-10".
    if not re.fullmatch(r"[-+ 0-9*()]+", token):
        raise ValueError(f"cannot evaluate {token!r}")
    return int(eval(token, {"__builtins__": {}}))


OPCODES = {"RTS": [0x60], "NOP": [0xEA]}


def assemble(listing: str) -> bytes:
    """The bytes of every data directive between .trackData and the SAVE."""
    text = re.sub(r"<br\s*/?>", "\n", listing)
    text = re.sub(r"<[^>]+>", "", text)
    for entity, char in (("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'")):
        text = text.replace(entity, char)
    out = bytearray()
    started = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith(".trackData"):
            started = True
            continue
        if not started:
            continue
        if line.startswith("SAVE "):
            break
        code = line.split("\\", 1)[0].strip()
        if code.startswith("EQUB "):
            out += bytes(_value(v) & 0xFF for v in code[5:].split(","))
        elif code.startswith("EQUW "):
            for v in code[5:].split(","):
                out += (_value(v) & 0xFFFF).to_bytes(2, "little")
        elif code.startswith("EQUS "):
            out += code[5:].strip().strip('"').encode("ascii")
        elif code in OPCODES:
            out += bytes(OPCODES[code])
    return bytes(out)


def verify(data: bytes, name: str) -> None:
    if len(data) != TRACK_SIZE:
        raise SystemExit(f"{name}: {len(data)} bytes, expected {TRACK_SIZE}")
    # The checksum counts the bytes before it by their two low bits.
    counts = [0, 0, 0, 0]
    for b in data[:CHECKSUM]:
        counts[b & 3] += 1
    stored = list(data[CHECKSUM:CHECKSUM + 4])
    if [c & 0xFF for c in counts] != stored:
        raise SystemExit(f"{name}: checksum {counts} does not match {stored}")


def fetch(name: str, listing_file: Path | None = None) -> bytes:
    """The track's binary, from the cache or fetched and verified. A saved
    copy of the listing's HTML page can stand in for the download."""
    path = CACHE / f"{name}.bin"
    if path.exists() and listing_file is None:
        data = path.read_bytes()
        verify(data, name)
        return data
    if listing_file is not None:
        listing = listing_file.read_text(encoding="utf-8", errors="replace")
    else:
        request = urllib.request.Request(URL.format(name), headers={"User-Agent": "zx-spectrum-emulator revs example"})
        with urllib.request.urlopen(request, timeout=60) as response:
            listing = response.read().decode("utf-8", "replace")
    data = assemble(listing)
    verify(data, name)
    CACHE.mkdir(exist_ok=True)
    path.write_bytes(data)
    return data


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tracks", nargs="*", default=["silverstone"])
    parser.add_argument("--from", dest="listing", type=Path, help="a saved copy of the listing page")
    args = parser.parse_args()
    for track in args.tracks:
        d = fetch(track, args.listing)
        print(f"{track}: {len(d)} bytes, {d[SECTION_COUNT] // 8} sections, "
              f"{d[VECTOR_COUNT]} vectors, length {int.from_bytes(d[TRACK_LENGTH:TRACK_LENGTH + 2], 'little')} segments")
