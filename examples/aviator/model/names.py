"""Every label in the original game as a module-level address constant, read
from BeebAsm's listing (see acornsoft.symbols), plus the source's
configuration constants, which are assembler values rather than labels: the
screen addresses (row25_char13_1 and so on) and nextAxis.

    from model.names import xObjectHi, timesTable, row25_char13_1
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import acornsoft  # noqa: E402


def _constants():
    """The `name = value` lines at the top of the source, before the code."""
    out = {}
    text = acornsoft.path("aviator-source.asm").read_text(encoding="latin-1")
    for line in text.splitlines():
        m = re.match(r"^ ([A-Za-z_]\w*) = (&[0-9A-Fa-f]+|\d+)\s", line + " ")
        if not m:
            continue
        name, value = m.groups()
        out.setdefault(name, int(value[1:], 16) if value.startswith("&") else int(value))
    return out


globals().update(_constants())
globals().update(acornsoft.symbols())
