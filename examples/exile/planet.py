"""map.txt: the planet, one character per block, placed by hand.

The map is MAP_W x MAP_H blocks, each 16 pixels square -- 2048 x 2048
pixels. Every row is written between two '|'s, so an editor that strips
trailing spaces cannot shorten one; any line that does not start with '|' is
a comment. Which block each character stands for is blocks.json's business.

The game holds the map whole, a byte a block, row after row: 16K.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
MAP_FILE = HERE / "map.txt"

MAP_W = 128
MAP_H = 128


def read(blockset, path=MAP_FILE):
    """The map as block numbers, row-major."""
    rows = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.startswith("|"):
            continue
        end = line.find("|", 1)
        if end < 0:
            raise ValueError(f"{path}:{number}: a map row needs a closing '|'")
        row = line[1:end]
        if len(row) != MAP_W:
            raise ValueError(f"{path}:{number}: row is {len(row)} blocks, not {MAP_W}")
        out = []
        for col, c in enumerate(row):
            if c not in blockset.chars:
                raise ValueError(f"{path}:{number}: column {col}: {c!r} is no block in blocks.json")
            out.append(blockset.chars[c])
        rows.append(out)
    if len(rows) != MAP_H:
        raise ValueError(f"{path}: {len(rows)} map rows, not {MAP_H}")
    return [n for row in rows for n in row]


def write(blockset, blocks, header, path=MAP_FILE):
    chars = [entry["char"] for entry in blockset.legend]
    lines = list(header)
    for y in range(MAP_H):
        lines.append("|" + "".join(chars[blocks[y * MAP_W + x]] for x in range(MAP_W)) + "|")
    Path(path).write_text("\n".join(lines) + "\n")
