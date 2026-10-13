"""Runs Klaus Dormann's 6502 functional test on bbc/m6502.py.

The test is a 64K image that starts at &0400 and exercises every documented
instruction, addressing mode and flag, decimal mode included. Each check that
fails traps in a JMP to itself; so does the end of the test, at &3469 in this
build. Getting there means the core passed everything.

The binary is GPL-3 and is not committed: it is fetched from the project's
GitHub repository the first time and cached in data/ (gitignored).

    python tests/test_m6502.py
"""

import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "bbc"))

import m6502  # noqa: E402

URL = ("https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/"
       "7954e2dbb49c469ea286070bf46cdd71aeb29e4b/bin_files/6502_functional_test.bin")
CACHE = ROOT / "data" / "6502_functional_test.bin"
START = 0x0400
SUCCESS = 0x3469


def fetch():
    if not CACHE.exists():
        CACHE.parent.mkdir(exist_ok=True)
        with urllib.request.urlopen(URL) as r:
            CACHE.write_bytes(r.read())
    return CACHE.read_bytes()


def main():
    image = fetch()
    mem = bytearray(65536)
    mem[:len(image)] = image
    cpu = m6502.CPU(mem, io_base=0x10000)
    cpu.pc = START
    started = time.time()
    count = 0
    while True:
        pc = cpu.pc
        cpu.step()
        count += 1
        if cpu.pc == pc:
            break
    seconds = time.time() - started
    print(f"stopped at &{cpu.pc:04X} after {count:,} instructions, {cpu.cycles:,} cycles, "
          f"{seconds:.1f} s ({count / seconds / 1000:.0f}K instructions a second)")
    if cpu.pc != SUCCESS:
        print(f"FAIL: trapped at &{cpu.pc:04X}; A={cpu.a:02X} X={cpu.x:02X} Y={cpu.y:02X} P={cpu.p():02X}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
