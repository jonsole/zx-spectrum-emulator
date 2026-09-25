#!/usr/bin/env python3
"""Fetches sjasmplus, the Z80 assembler, into tools/sjasmplus/.

The Filmation games, the ROM disassembly and the tape designer's fast loader
are all assembled with it, and a release ships it inside the VS Code extension
-- but the repository does not hold it, so the release workflow fetches it
here first. A new checkout can do the same.

The Windows build of a pinned release, checked against its SHA-256 before
anything is unpacked: the version every one of those builds has been tested
with, and not whatever is newest on the day a release is cut.

    python scripts/fetch_sjasmplus.py              # into tools/sjasmplus/
    python scripts/fetch_sjasmplus.py --dest DIR   # somewhere else

sjasmplus is BSD-3-Clause (THIRD_PARTY_NOTICES.md). Windows only: there is no
prebuilt release for anything else, where it is built from source.
"""
import argparse
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

VERSION = "1.23.1"
URL = (f"https://github.com/z00m128/sjasmplus/releases/download/v{VERSION}/"
       f"sjasmplus-{VERSION}.win.zip")
ZIP_SHA256 = "fa0ca77e6e6dcdad77b2c64607b325dd6366844ab6438bfc97661fdfbc29aa35"
# The executable inside, so a copy already in place can be recognised
# without downloading anything.
EXE_SHA256 = "69a24ea87dd142814217a1ed7927a0386f3ed9ff8cea99ce57f7ff25a3f8c10e"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", default=os.path.join(ROOT, "tools", "sjasmplus"),
                        help="directory to put sjasmplus.exe in (default: tools/sjasmplus/)")
    args = parser.parse_args()
    target = os.path.join(args.dest, "sjasmplus.exe")

    if os.path.exists(target):
        with open(target, "rb") as f:
            if sha256(f.read()) == EXE_SHA256:
                print(f"sjasmplus {VERSION}: already present")
                return 0
        print(f"{target} is not sjasmplus {VERSION} -- leaving it alone")
        return 1

    request = urllib.request.Request(URL, headers={"User-Agent": "zx-spectrum-emulator fetch_sjasmplus"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if sha256(data) != ZIP_SHA256:
        print(f"{URL}: SHA-256 {sha256(data)}, expected {ZIP_SHA256} -- not unpacked")
        return 1
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        name = next(n for n in z.namelist() if n.endswith("/sjasmplus.exe"))
        exe = z.read(name)
    if sha256(exe) != EXE_SHA256:
        print(f"{name}: SHA-256 {sha256(exe)}, expected {EXE_SHA256} -- not written")
        return 1
    os.makedirs(args.dest, exist_ok=True)
    with open(target, "wb") as f:
        f.write(exe)
    print(f"sjasmplus {VERSION}: fetched, SHA-256 verified, written to {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
