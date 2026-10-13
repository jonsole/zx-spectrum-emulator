"""Fetches Acornsoft's Aviator files from Mark Moxon's annotated source.

Aviator is Geoff Crammond's (Acornsoft, 1983), and Mark Moxon's repository of
it is published without a licence, so none of it is committed here. The first
build or test fetches what it needs from a pinned commit of
github.com/markmoxon/aviator-source-code-bbc-micro, checks the binaries
against their known hashes, and caches everything in data/ (gitignored):

    AVIA.bin            the game binary from the original disc (loads at &1100)
    DASHBD.bin          the dashboard image (Mode 5, loads at &7100)
    aviator-source.asm  the annotated source, for the port's data tables
    compile.txt         BeebAsm's listing, for the address of every label

The game binary is the copy from the bbcmicro.co.uk archive; the repository's
own build reassembles the source to the same bytes.

    python acornsoft.py             fetch anything not cached, and check it
"""

import hashlib
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / "data"
COMMIT = "d613d80fcb08a855c4cf7fdd305270808d2de8e7"
BASE = f"https://raw.githubusercontent.com/markmoxon/aviator-source-code-bbc-micro/{COMMIT}/"

FILES = {
    "AVIA.bin": ("4-reference-binaries/bbcmicro-co-uk/AVIA.bin",
                 "439b9b741365e18f45bd4b7ccc62bc8dc5b49a70aaef61a77a320aca73084ab6"),
    "DASHBD.bin": ("1-source-files/images/$.DASHBD.bin",
                   "f8dfad1f0f81243f2eabcf34afed332881c7ca89f16be306284e60764c0cdec7"),
    "aviator-source.asm": ("1-source-files/main-sources/aviator-source.asm",
                           "5646f4181e9a729c7645482105396372a3068a327aacccc65d20cf1f859a6615"),
    "compile.txt": ("3-assembled-output/compile.txt",
                    "be8fd10ee79c0c669400d618d86ff8e48d360b6faf81ca6ca2e172c89f375e2b"),
}

AVIA_LOAD = 0x1100
AVIA_EXEC = 0x5E00
DASHBD_LOAD = 0x7100


def path(name):
    """The cached file, fetched and checked first if it is not there."""
    remote, digest = FILES[name]
    local = CACHE / name
    if not local.exists():
        CACHE.mkdir(exist_ok=True)
        url = BASE + remote.replace("$", "%24")
        with urllib.request.urlopen(url) as r:
            data = r.read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != digest:
            raise RuntimeError(f"{name}: fetched {len(data)} bytes with SHA-256 {actual}, expected {digest}")
        local.write_bytes(data)
    return local


def read(name):
    return path(name).read_bytes()


def symbols():
    """Every label in BeebAsm's listing, by name, with its runtime address.

    The listing prints a label on one line and its address, indented, on the
    next. Labels in the code that the game moves at startup (&0B00-&10FF) are
    listed at the addresses they run from."""
    out = {}
    lines = path("compile.txt").read_text(encoding="latin-1").splitlines()
    for i, line in enumerate(lines[:-1]):
        m = re.fullmatch(r"\.(\w+)", line.strip()) if line.startswith(".") else None
        if m is None:
            continue
        nxt = lines[i + 1].strip()
        a = re.match(r"([0-9A-F]{4})\b", nxt)
        if a:
            out.setdefault(m.group(1), int(a.group(1), 16))
    return out


def main():
    for name in FILES:
        p = path(name)
        print(f"{name:20} {p.stat().st_size:8,} bytes  ok")
    print(f"{len(symbols())} labels")


if __name__ == "__main__":
    sys.exit(main())
