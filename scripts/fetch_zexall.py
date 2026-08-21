"""Fetch ZEXALL/ZEXDOC (Frank D. Cringle's Z80 instruction-set exerciser,
extracted from YAZE-AG, curated at https://github.com/agn453/ZEXALL) into a
gitignored local directory.

Unlike the ROM/ROM-disassembly/Manic-Miner-disassembly fetches elsewhere in
scripts/, this isn't about avoiding redistribution of someone else's
copyrighted firmware/game -- ZEXALL is GPL v2.0 and meant to be redistributed
for exactly this purpose. It's still fetched rather than committed, purely to
avoid vendoring a second project's source tree into this one; the actual
`.com` binaries this project runs against are the point, not the assembly
source (also fetched here for reference, but unused by the Rust harness).

Usage:
    python scripts/fetch_zexall.py
"""
from __future__ import annotations

import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEST_DIR = PROJECT_ROOT / ".zexall-src"

BASE_URL = "https://raw.githubusercontent.com/agn453/ZEXALL/main/"
FILES = ["zexall.com", "zexdoc.com", "zexall.z80", "zexdoc.z80", "LICENSE", "README.md"]


def main() -> None:
    DEST_DIR.mkdir(exist_ok=True)
    for name in FILES:
        dest = DEST_DIR / name
        print(f"Fetching {name} ...")
        with urllib.request.urlopen(BASE_URL + name) as response:
            dest.write_bytes(response.read())
    print(f"Done. Files written to {DEST_DIR}")


if __name__ == "__main__":
    main()
