#!/usr/bin/env python3
"""Fetches the 48K and 128K ROMs from the Fuse emulator's source into roms/.

The ROMs are copyright Amstrad, who allow their distribution, so a release
bundles them (THIRD_PARTY_NOTICES.md) -- but the repository never holds them,
so the release workflow fetches them here first. A new checkout can do the
same instead of finding its own.

Each file is checked against a pinned SHA-256, the hash of the copies the
emulator has always been tested with. A download that differs fails rather
than being written: a release must not quietly ship a different ROM because
an upstream file moved.

    python scripts/fetch_roms.py              # into roms/
    python scripts/fetch_roms.py --dest DIR   # somewhere else

Fuse keeps the 128K's two ROMs as separate files; the emulator wants them as
one 32K image, ROM 0 then ROM 1 (the usual 128.rom), so they are joined.
"""
import argparse
import hashlib
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Fuse's roms/ directory, as SourceForge serves a raw file from it.
FUSE_RAW = "https://sourceforge.net/p/fuse-emulator/fuse/ci/master/tree/roms/{}?format=raw"

# What to write, the Fuse files it is made of, and the SHA-256 it must have.
ROMS = [
    ("48.rom", ["48.rom"],
     "d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42"),
    ("128.rom", ["128-0.rom", "128-1.rom"],
     "c1ff621d7910105d4ee45c31e9fd8fd0d79a545c78b66c69a562ee1ffbae8d72"),
]

ROM_SIZE = 16384


def download(name):
    request = urllib.request.Request(FUSE_RAW.format(name),
                                     headers={"User-Agent": "zx-spectrum-emulator fetch_roms"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    if len(data) != ROM_SIZE:
        raise RuntimeError(f"{name}: expected {ROM_SIZE} bytes, got {len(data)} "
                           "(an error page rather than the ROM?)")
    return data


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", default=os.path.join(ROOT, "roms"),
                        help="directory to write the ROMs into (default: roms/)")
    args = parser.parse_args()
    os.makedirs(args.dest, exist_ok=True)

    for target, parts, expected in ROMS:
        path = os.path.join(args.dest, target)
        # One already there and right is left alone, so running this in a
        # checkout that has its ROMs costs nothing and changes nothing.
        if os.path.exists(path):
            with open(path, "rb") as f:
                if sha256(f.read()) == expected:
                    print(f"{target}: already present")
                    continue
            print(f"{target}: present but not the expected ROM -- leaving it alone")
            return 1
        data = b"".join(download(part) for part in parts)
        actual = sha256(data)
        if actual != expected:
            print(f"{target}: SHA-256 {actual}, expected {expected} -- not written")
            return 1
        with open(path, "wb") as f:
            f.write(data)
        print(f"{target}: fetched from Fuse ({' + '.join(parts)}), SHA-256 verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
