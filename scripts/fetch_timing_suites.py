"""Fetch the public ZX Spectrum timing test suites into a gitignored local
directory, for the slow CTests and the survey in docs/timing-suites.md.

The programs come from the collection the redcode/ZXSpectrum wiki keeps
(https://github.com/redcode/ZXSpectrum/wiki/Tests), downloaded as one archive
from zxe.io. Each is somebody else's work under its own terms, so they are
fetched rather than committed, the same as ZEXALL; only the programs the tests
and the survey use are kept, under short names, so the CMake and the docs can
name them plainly.

Usage:
    python scripts/fetch_timing_suites.py
"""
from __future__ import annotations

import io
import urllib.request
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEST_DIR = PROJECT_ROOT / ".timing-suites"

ARCHIVE_URL = "https://zxe.io/depot/download/ZX%20Spectrum%20-%20Tests.zip"

# Short name -> the start of the entry's name in the archive, and, for an entry
# that is itself a zip, the file to take out of it.
PROGRAMS = {
    "butler48.sna": ("ZX Spectrum Timing Tests - 48K v1.0 (2010-04-06)", None),
    "butler128.wav": ("ZX Spectrum Timing Tests - 128K v1.0 (2015-03-30)(Butler, Richard; Butler, Tim)[!].wav", None),
    "nec48.tap": ("48K NEC Contention Test Suite (2008-09-14)", None),
    "halt_contention.tap": ("HALT Contention Test (2021-09-14)", None),
    "contention2005.tap": ("Contention (2005-03-03)", None),
    "ir_contention.tap": ("IR Contention (2023-01-08)", None),
    "ir_contention128.tap": ("IR Contention 128 (2023-07-02)", None),
    "ula48_simple.tap": ("ULA 48 Simple Test (2012-10-06)", None),
    "ula128_timing.tap": ("ULA 128 Timing Test (2012-10-06)", None),
    "float48k.tap": ("Float48K (2008-03-24)", None),
    "float128k.tap": ("Float128K (2008-04-02)(Woodmass, Mark)[!].tap", None),
    "floatspy.tap": ("Floating Spy v0.33 (2002-04)", "floatspy.tap"),
    "timingtest.tap": ("Timing Test v0.3 (2013-12-09)", "timingtest-0.3/timing.tap"),
    "snow48.tap": ("Snow48 (2021-09-13)", None),
    "snow48_b6.tap": ("Snow48 (var b6) (2021-09-15)", None),
    "snow_crash.tap": ("ULA Snow Crash (2018-02-06)", None),
    "weiv_snow.tap": ("Snow Tests (2022-10-19)", "SnowTests/snow.tap"),
    "weiv_snow48plus.tap": ("Snow Tests (2022-10-19)", "SnowTests/snow48+.tap"),
    "weiv_snow128plus.tap": ("Snow Tests (2022-10-19)", "SnowTests/snow128+.tap"),
    "weiv_ula128.tap": ("Snow Tests (2022-10-19)", "SnowTests/ula128.tap"),
    "weiv_snow128n.tap": ("Snow128N (2023-04-04)", "snow128n.tap"),
}


def main() -> None:
    DEST_DIR.mkdir(exist_ok=True)
    print(f"Fetching {ARCHIVE_URL} ...")
    with urllib.request.urlopen(ARCHIVE_URL) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))
    names = archive.namelist()
    for short, (prefix, inner) in PROGRAMS.items():
        matches = [n for n in names if n.startswith(prefix)]
        if inner is not None:
            matches = [n for n in matches if n.endswith(".zip")]
        if not matches:
            raise SystemExit(f"{prefix!r} is not in the archive")
        data = archive.read(matches[0])
        if inner is not None:
            nested = zipfile.ZipFile(io.BytesIO(data))
            hits = [n for n in nested.namelist() if n.endswith(inner)]
            if not hits:
                raise SystemExit(f"{inner!r} is not in {matches[0]!r}")
            data = nested.read(hits[0])
        (DEST_DIR / short).write_bytes(data)
        print(f"  {short}")
    print(f"Done. Files written to {DEST_DIR}")


if __name__ == "__main__":
    main()
