"""Makes a game's data out of your own copy of the original, and checks it.

    python examples/filmation/extract.py knightlore [path/to/your/copy]
    python examples/filmation/extract.py pentagram  [path/to/your/copy]

The release's example workspaces carry none of Ultimate's artwork or tables:
this is how a workspace gets them. It runs the game's extractor on your copy
(kl_extract.py or pg_extract.py, which read it through original.py), then the
steps that turn what that pulls out into the files the build reads --
rooms.py for the rooms and their templates, sprite_sheet.py for the sprite
sheet -- and checks every one against <game>/original.json: the hashes a
right copy gives. A copy that differs is said to, and nothing is kept from it.

With no path, it looks for the copy itself: a .sna, .z80, .tzx or .tap in the
folder it is run from, or in the game's own folder. Knight Lore needs a
snapshot (.sna or .z80); Pentagram takes its tape or a snapshot. A snapshot
wants to be from before a game is started -- the menu, say -- since playing
changes what the game holds.

A copy of Knight Lore saved once the menu is up holds the corner of the
menu's frame upside down -- the game turns it in place as it draws the frame,
and records that nowhere -- so a Knight Lore copy is tried as it is and then
with that sprite turned back over (kl_extract.py --turn-menu-corner). Its
sprite_data.bin is not held to original.json's hash either: that covers flag
bits in every sprite's width byte that the game sets or not depending on
when the copy was saved, and that nothing after it reads. The sprites are
checked by what they make instead -- the carried sprites.json byte for byte,
and sprites.png pixel for pixel (original.json's 'pictures': another version
of Pillow writes the same picture as other bytes). Everything else is held to
its hash.

Nothing is kept from a copy that does not check out: the carried files are
put back as they were, and any that were not there are taken away again.

graphics.json is not Ultimate's: it is this remake's table of which sprite
each graphic number draws and the nudge that lines it up, carried with the
code. sprite_sheet.py rewrites it from the extraction, so it is put back
afterwards.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

GAMES = {
    "knightlore": {"title": "Knight Lore", "extractor": "kl_extract.py",
                   "copies": (".sna", ".z80"),
                   # The ways to run the extractor on a copy, in turn.
                   "attempts": ((), ("--turn-menu-corner",)),
                   # Extracted files checked by what the steps make of them,
                   # not by their own hash.
                   "loose": ("sprite_data.bin",)},
    "pentagram": {"title": "Pentagram", "extractor": "pg_extract.py",
                  "copies": (".tzx", ".tap", ".sna", ".z80")},
}
# What turns the extraction into what the build reads, in order.
STEPS = ("rooms.py", "sprite_sheet.py")


def file_hash(path):
    """SHA-256, with a JSON file's line endings made LF first: Python writes
    the platform's own, and the check is of the content."""
    data = path.read_bytes()
    if path.suffix == ".json":
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def picture_hash(path):
    """SHA-256 of a picture's pixels: its width and height, then its RGBA
    bytes. The same picture written by another version of Pillow is other
    bytes, and only the pixels are what the build reads."""
    from PIL import Image
    image = Image.open(path).convert("RGBA")
    return hashlib.sha256(b"%dx%d:" % image.size + image.tobytes()).hexdigest()


def mismatches(folder, wanted, pictures=None):
    """The files in `wanted` (name -> hash) missing or different in `folder`.
    A file named in `pictures` may match by its pixels instead."""
    wrong = []
    for name, digest in wanted.items():
        path = folder / name
        if not path.is_file():
            wrong.append(name)
        elif file_hash(path) != digest and (
                name not in (pictures or {}) or picture_hash(path) != pictures[name]):
            wrong.append(name)
    return wrong


def candidates(game, spec):
    """Copies to try, the folder it is run from first."""
    found = []
    for folder in (Path.cwd(), HERE / game):
        for path in sorted(folder.iterdir()):
            if path.is_file() and path.suffix.lower() in spec["copies"] and path not in found:
                found.append(path)
    return found


def run(folder, script, *args):
    done = subprocess.run([sys.executable, script, *args], cwd=folder, capture_output=True, text=True)
    return done.returncode, (done.stdout + done.stderr).strip()


def extract(game, spec, copy, pins, extra):
    """Runs the extractor on one copy, one way, and the steps after it.
    Returns None when what came out checks out, or why not."""
    folder = HERE / game
    code, said = run(folder, spec["extractor"], *extra, str(copy))
    if code != 0:
        return said.splitlines()[-1] if said else f"{spec['extractor']} failed"
    wrong = mismatches(folder, pins["extracted"])
    strict = [name for name in wrong if name not in spec.get("loose", ())]
    if strict:
        return ("it is not the copy these were made from -- " + ", ".join(strict)
                + " came out different (a different release, a crack, or a snapshot "
                "taken after a game was started?)")

    graphics = folder / "graphics.json"
    kept = graphics.read_bytes()
    try:
        for step in STEPS:
            code, said = run(folder, step)
            if code != 0:
                sys.exit(f"{step} failed:\n{said}")
    finally:
        # sprite_sheet.py writes its own graphics.json from the extraction;
        # the remake's, with its nudges, is the one the build wants.
        graphics.write_bytes(kept)

    made = mismatches(folder, pins["carried"], pins.get("pictures"))
    if made and not wrong:
        sys.exit("The extraction checked out, but " + ", ".join(made) + " did not come "
                 "out as expected -- the tools that make them have changed since "
                 "original.json was written.")
    if made:
        return ("it is not the copy these were made from -- " + ", ".join(made)
                + " came out different (a different release, a crack, or a snapshot "
                "taken after a game was started?)")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("game", choices=sorted(GAMES))
    parser.add_argument("copy", nargs="?", help="your copy of the original: "
                        "Knight Lore as .sna or .z80, Pentagram as .tzx, .tap, .sna or .z80")
    parser.add_argument("--force", action="store_true", help="extract again even if the data is there")
    args = parser.parse_args()
    spec = GAMES[args.game]
    folder = HERE / args.game
    pins = json.loads((folder / "original.json").read_text(encoding="utf-8"))

    if not args.force and not mismatches(folder, pins["carried"], pins.get("pictures")):
        print(f"{spec['title']}'s data is already here and checks out -- nothing to do "
              "(--force to extract again)")
        return 0

    copies = [Path(args.copy)] if args.copy else candidates(args.game, spec)
    if not copies:
        kinds = ", ".join(spec["copies"])
        sys.exit(f"No copy of {spec['title']} to extract from. Put your own ({kinds}) in "
                 f"{Path.cwd()} and run this again, or name it:\n"
                 f"    python examples/filmation/extract.py {args.game} path/to/your/copy")

    # What is here now, to put back if no copy checks out: the extractor
    # and the steps write the carried files as they go.
    carried = [folder / name for name in pins["carried"]] + [folder / "graphics.json"]
    kept = {path: path.read_bytes() for path in carried if path.is_file()}

    def put_back():
        for path in carried:
            if path in kept:
                path.write_bytes(kept[path])
            else:
                path.unlink(missing_ok=True)

    problems = []
    done = False
    for copy in copies:
        for extra in spec.get("attempts", ((),)):
            # Each attempt from the files as they were: sprite_sheet.py reads
            # the trims the sheet already records, so a failed attempt's
            # sheet would otherwise colour the next.
            put_back()
            why = extract(args.game, spec, copy, pins, extra)
            if why is None:
                turned = " (with the menu's corner turned back over)" if extra else ""
                print(f"{copy.name}: {spec['title']}, checked{turned}")
                done = True
                break
        if done:
            break
        problems.append(f"  {copy.name}: {why}")
    if not done:
        put_back()
        sys.exit(f"None of these gave {spec['title']}:\n" + "\n".join(problems))
    # A picture that came out the same but encoded differently goes back to
    # the bytes it had, so a checkout does not show it changed.
    for path, data in kept.items():
        if (path.suffix == ".png" and path.read_bytes() != data
                and picture_hash(path) == (pins.get("pictures") or {}).get(path.name)):
            path.write_bytes(data)

    made = ", ".join(sorted(pins["carried"]))
    print(f"Wrote {made} -- {spec['title']} is ready to build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
