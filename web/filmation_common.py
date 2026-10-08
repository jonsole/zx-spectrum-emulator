"""What web/knightlore_template.py and web/pentagram_template.py share.

Nothing here knows either game: the two games' own Python modules share their
names -- rooms.py, rooms_source.py, sprite_sheet.py -- so a script imports one
game's, and whatever both scripts need lives here instead.
"""
import hashlib
import subprocess
import sys


def run(folder, *args):
    """Runs a Python script in `folder`, stopping with its output if it fails."""
    done = subprocess.run([sys.executable, *args], cwd=folder, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(" ".join(args) + " failed:\n" + done.stdout + done.stderr)
    return done.stdout


def labels(sld):
    """Every label's address, from the SLD -- as build.py's find_label reads one.
    EQUs are labels there too, with their values."""
    found = {}
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[2] == "":
                found[parts[1]] = int(fields[5])
    return found


def emitted_rows(sprite):
    """A sprite's rows as sprite_source.py emits them: top row first, each byte
    the inverted mask and then the data."""
    out = bytearray()
    for mask, data in zip(sprite["mask"], sprite["data"]):
        for m, d in zip(mask, data):
            out += bytes((255 ^ m, d))
    return bytes(out)


def differences(a, b):
    return [n for n in range(len(a)) if a[n] != b[n]]


def outside(spans, offsets):
    """The offsets in none of the (start, length) spans."""
    return [n for n in offsets if not any(s <= n < s + length for s, length in spans)]


def carried_hash(path):
    """SHA-256 as extract.py takes it: a JSON file's line endings made LF."""
    data = path.read_bytes()
    if path.suffix == ".json":
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def picture_hash(path):
    """SHA-256 of a picture's pixels, as extract.py takes it: its width and
    height, then its RGBA bytes."""
    from PIL import Image
    image = Image.open(path).convert("RGBA")
    return hashlib.sha256(b"%dx%d:" % image.size + image.tobytes()).hexdigest()


def edited(folder, pins):
    """The carried files in `folder` no longer what original.json's hashes say
    an original gives -- a picture may match by its pixels."""
    pictures = pins.get("pictures") or {}
    out = []
    for name, digest in pins["carried"].items():
        path = folder / name
        if carried_hash(path) == digest:
            continue
        if name in pictures and picture_hash(path) == pictures[name]:
            continue
        out.append(name)
    return out
