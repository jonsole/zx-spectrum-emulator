"""Prints routines from Mark Moxon's annotated Aviator source, compactly: each
header's arguments and returns in full, then the code with every line's
comment clipped to one line. acornsoft.py fetches the source into data/.

    python source.py Multiply8x8 "ProjectPoint (Part 1 of 3)" [--width=70]
    python source.py "ProjectPoint*"         every part of a routine
    python source.py --full SetMatrices      every comment line as well

--full keeps the comment lines between instructions too, which is where
most of the explanation is.
"""

import re
import sys

import acornsoft


def headers(lines):
    """(line index, name) of every "Name:" line in the source's headers."""
    out = []
    for i, line in enumerate(lines):
        m = re.match(r"\\\s+Name: (.*)", line)
        if m:
            out.append((i, m.group(1).strip()))
    return out


def show(lines, starts, idx, width, full):
    i, name = starts[idx]
    begin = i - 2
    end = starts[idx + 1][0] - 2 if idx + 1 < len(starts) else len(lines)
    print(f"==== {name}  (line {i + 1})")
    stars = 0
    for line in lines[begin:end]:
        if line.startswith("\\ ****"):
            stars += 1
            continue
        if stars < 2:
            # The header: everything but the bookkeeping fields.
            if full or not re.match(r"\\\s+(Name|Type|Category|Deep dive):", line):
                if line.strip() != "\\":
                    print(line)
            continue
        s = line.rstrip()
        if not s:
            continue
        if re.match(r"^\s*\\", s):
            if full:
                print(s)
            continue
        if "\\" in s:
            code, comment = s.split("\\", 1)
            code, comment = code.rstrip(), comment.strip()
            if len(comment) > width:
                comment = comment[:width] + "..."
            print(f"{code:28} \\ {comment}" if comment else code)
        else:
            print(s)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    full = "--full" in sys.argv
    width = 70
    for a in sys.argv[1:]:
        if a.startswith("--width="):
            width = int(a.split("=", 1)[1])
    lines = acornsoft.path("aviator-source.asm").read_text(encoding="latin-1").split("\n")
    starts = headers(lines)
    for want in args:
        found = False
        for idx, (_, name) in enumerate(starts):
            if name == want or (want.endswith("*") and name.startswith(want[:-1])):
                show(lines, starts, idx, width, full)
                found = True
        if not found:
            print(f"==== {want}: no such routine or variable")


if __name__ == "__main__":
    sys.exit(main())
