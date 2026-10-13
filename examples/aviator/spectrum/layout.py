"""Where the Spectrum version keeps the game's data: the BBC's own layout,
moved up by $8000.

The original keeps its variables and tables at fixed addresses below its
screen, and its code leans on how they sit: the x, y and z object tables
are 40 bytes apart so one index walks all three, the point tables are a page
each so a point ID indexes them, CopyPointToWork takes the low byte of an
address in the &0C00 workspace page as an offset. So the Z80 version keeps
every data region of the original exactly where it was, plus $8000:
BBC &0000-&57FF is Spectrum $8000-$D7FF. Only the data regions are filled;
the gaps between them, where the 6502 code was, hold Z80 code.

This also makes checking easy: a moment of the original (or of the Python
port, which uses the same layout) goes into the Spectrum's memory region by
region at +$8000, and comes back out the same way.

The regions:

- zero page &70-&FF and page 1 &100-&17F: the original's temporaries (which
  the Z80 code may use as scratch) and a few variables (the line buffer's U
  column, the m values for the matrices);
- &0400-&0CFF: nine pages of points, objects' statuses, the line lists and
  the main workspace (the first two of these pages hold run-once setup code
  at first, which the game then reuses as variables);
- the tables among the code above &0D00, each from its label to the next.

The one piece of state the original keeps in its code -- the rounding
constant at mult1+1 that ApplyAerodynamics rewrites -- has a variable of
its own in the Z80 version (CODE_STATE maps it).
"""

import bisect
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import acornsoft  # noqa: E402

OFFSET = 0x8000
TOP = 0x5800                 # the BBC screen; nothing above is data

FIXED_REGIONS = [(0x0070, 0x0100), (0x0100, 0x0180), (0x0400, 0x0D00)]

# The zero-page temporaries: scratch on the BBC, and on the Spectrum, where
# the Z80 code keeps its own working values there or in registers. Also the
# top of page 1, which is the 6502's stack.
SCRATCH = [(0x0070, 0x008A), (0x0180, 0x0200)]


def _data_labels():
    """The labels of every Variable and Workspace in the annotated source."""
    lines = acornsoft.path("aviator-source.asm").read_text(encoding="latin-1").split("\n")
    kind = None
    out = []
    for line in lines:
        m = re.match(r"\\\s+Type: (\w+)", line)
        if m:
            kind = m.group(1)
            continue
        m = re.match(r"^\.(\w+)", line)
        if m and kind in ("Variable", "Workspace"):
            out.append(m.group(1))
    return out


def regions():
    """The BBC data regions as sorted, merged (start, end) pairs."""
    sym = acornsoft.symbols()
    addrs = sorted(set(sym.values()))
    spans = list(FIXED_REGIONS)
    for name in _data_labels():
        a = sym.get(name)
        if a is None or a < 0x0D00 or a >= TOP:
            continue
        i = bisect.bisect_right(addrs, a)
        end = addrs[i] if i < len(addrs) else TOP
        spans.append((a, min(end, TOP)))
    spans.sort()
    merged = []
    for lo, hi in spans:
        if merged and lo <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def in_regions(addr, spans):
    return any(lo <= addr < hi for lo, hi in spans)


def labels(spans=None):
    """Every BBC label inside the data regions, with its Spectrum address,
    except the zero-page temporaries (P, Q ... HH), whose one-letter names
    the assembler would read as registers."""
    spans = spans or regions()
    out = {}
    for name, addr in acornsoft.symbols().items():
        if addr < 0x008A or not in_regions(addr, spans):
            continue
        out[name] = addr + OFFSET
    return out


def gaps(spans=None):
    """The free ranges of the data window, (start, end) in Spectrum
    addresses: where the 6502 code was."""
    spans = spans or regions()
    out = []
    at = 0
    for lo, hi in spans:
        if lo > at:
            out.append((at + OFFSET, lo + OFFSET))
        at = max(at, hi)
    if at < TOP:
        out.append((at + OFFSET, TOP + OFFSET))
    return out


def main():
    spans = regions()
    total = sum(hi - lo for lo, hi in spans)
    for lo, hi in spans:
        print(f"data  ${lo + OFFSET:04X}-${hi + OFFSET - 1:04X}  {hi - lo:5}")
    print(f"{total} bytes of data in {len(spans)} regions")
    for lo, hi in gaps(spans):
        print(f"free  ${lo:04X}-${hi - 1:04X}  {hi - lo:5}")


if __name__ == "__main__":
    main()
