"""The JSON schemas against the real files they describe.

    .venv-win\\Scripts\\python.exe vscode-extension/tests/schemas_test.py

A schema that is merely plausible is worse than none: VS Code shows its
complaints as errors in a file that is actually correct, and you learn to
ignore them. So every schema is checked against every file it claims to
describe, both games, and each one is then checked to be worth having -- a
deliberately broken copy of the file must FAIL it, or the schema is saying
nothing and the pass above proved nothing.

Python rather than Node because jsonschema is in the repository's venv and the
extension has no npm dependencies. The schemas themselves are read by VS Code,
which needs nothing installed.
"""
import copy
import json
import sys
from pathlib import Path

import jsonschema

HERE = Path(__file__).resolve().parent
EXT = HERE.parent
ROOT = EXT.parent
FILMATION = ROOT / "examples" / "filmation"

# schema, the files it describes, and a mangling that must break each one.
#
# The mangling is the point of the test. It is chosen to be a mistake someone
# could actually make by hand -- a colour that is not a colour, a table one row
# short, a sprite index that is the packed form's "none" -- rather than
# something no editor would produce.
def table(said):
    """The graphic table, which is the whole of what graphics.json is."""
    return said["graphics"]


def one(said, wants=None):
    """A graphic to break, by name: the files are keyed by them, and the two
    games' names are their own, so a mangling picks one rather than naming it.

    `wants` asks for the first that has a particular field.
    """
    for name, entry in table(said).items():
        if wants is None or wants in entry:
            return name
    raise KeyError(wants)


CASES = [
    ("rooms.schema.json",
     ["knightlore/rooms.json", "pentagram/rooms.json"],
     [("an ink of 9", lambda d: d["rooms"][0].__setitem__("ink", 9)),
      ("a room with no floor shape",
       lambda d: d["rooms"][0].pop("dimensions")),
      ("a floor shape named by number",
       lambda d: d["rooms"][0].__setitem__("dimensions", 0)),
      ("a cell off the grid", lambda d: d["rooms"][3]["objects"][0]["positions"][0]
                                         .__setitem__("u", 8)),
      ("a misspelt key", lambda d: d["rooms"][0].__setitem__("inks", 3)),
      ("a floor shape missing an axis",
       lambda d: d["roomDimensions"][
           next(iter(d["roomDimensions"]))].pop("z")),
      # The templates are templates.json's now, and have no place here.
      ("the templates put back in with the rooms",
       lambda d: d.__setitem__("sceneryTemplates", {})),
      # Each file names the other; nothing is assumed.
      ("no word of where the templates are",
       lambda d: d["meta"].pop("templates")),
      ("templates somewhere other than beside it",
       lambda d: d["meta"].__setitem__("templates", "../templates.json"))]),

    ("templates.schema.json",
     ["knightlore/templates.json", "pentagram/templates.json"],
     # A template is a LIST of placements, not a record with a name in it.
     [("a template that is a record rather than its pieces",
       lambda d: d["sceneryTemplates"].__setitem__(
           first_template(d), {"name": "x", "blocks": []})),
      ("a placement that names no graphic",
       lambda d: d["sceneryTemplates"][first_template(d)][0].pop("graphic")),
      ("half a box on a placement",
       lambda d: d["sceneryTemplates"][first_template(d)][0]
                  .__setitem__("sizeU", 3)),
      ("no object templates at all", lambda d: d.pop("objectTemplates")),
      ("a game this castle is not", lambda d: d["meta"].__setitem__("game", "hobbit")),
      ("the rooms put in with the templates", lambda d: d.__setitem__("rooms", [])),
      ("no word of which rooms they belong to", lambda d: d["meta"].pop("rooms"))]),

    # sprites.schema.json is NOT here. It still describes the sheet as it was
    # before the group tree, so it would pass every file vacuously and prove
    # nothing -- which is exactly what this test exists to stop. It goes back
    # in when it is rewritten for the sheet's own shape.
    ("graphics.schema.json",
     ["knightlore/graphics.json", "pentagram/graphics.json"],
     [("sprite 255, which means 'none' in the packed form",
       lambda d: table(d)[one(d, "sprite")].__setitem__("sprite", 255)),
      ("a bare number where an entry belongs",
       lambda d: table(d).__setitem__(one(d), 4)),
      ("a graphic with no number of its own",
       lambda d: table(d)[one(d)].pop("number")),
      ("a graphic numbered in hex",
       lambda d: table(d)[one(d)].__setitem__("number", "$1E")),
      ("a nudge that is not a byte",
       lambda d: table(d)[one(d, "x")].__setitem__("x", 900)),
      ("a misspelt field",
       lambda d: table(d)[one(d)].__setitem__("sprit", "a.1")),
      ("a mirrored pair missing its y",
       lambda d: table(d)[one(d, "mirrored")]["mirrored"].pop("y")),
      # The box the size move put here. Two of the three axes is the mistake
      # worth catching: it reads as a box and behaves as half of one.
      ("a box missing its height",
       lambda d: table(d)[one(d, "size")]["size"].pop("z")),
      ("a box whose height is not a byte",
       lambda d: table(d)[one(d, "size")]["size"].__setitem__("z", -1)),
      ("a box with an axis it has not got",
       lambda d: table(d)[one(d, "size")]["size"].__setitem__("w", 4))]),

    ("specials.schema.json",
     ["knightlore/specials.json"],
     [("a table one row short", lambda d: d["collectables"].pop()),
      ("a kind of 9", lambda d: d["wanted"].__setitem__(0, 9)),
      ("a wanted list one short", lambda d: d["wanted"].pop()),
      ("a collectable with no room", lambda d: d["collectables"][0].pop("room"))]),

]


def first_template(said):
    """The first scenery template, by name: both games name their own."""
    return next(iter(said["sceneryTemplates"]))


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    failures = 0
    checked = 0

    for schema_name, files, manglings in CASES:
        schema = load(EXT / "schemas" / schema_name)
        jsonschema.Draft7Validator.check_schema(schema)
        validator = jsonschema.Draft7Validator(schema)

        for relative in files:
            path = FILMATION / relative
            if not path.is_file():
                print("skip %-22s %s is not here" % (schema_name, relative))
                continue
            data = load(path)

            errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
            checked += 1
            if errors:
                failures += 1
                print("FAIL %-22s %s" % (schema_name, relative))
                for e in errors[:5]:
                    where = "/".join(str(p) for p in e.path) or "(root)"
                    print("       %s: %s" % (where, e.message[:120]))
                if len(errors) > 5:
                    print("       ...and %d more" % (len(errors) - 5))
                continue
            print("ok   %-22s %s" % (schema_name, relative))

            # ...and the same file broken on purpose, which must not pass.
            for what, mangle in manglings:
                broken = copy.deepcopy(data)
                try:
                    mangle(broken)
                except (KeyError, IndexError):
                    print("     ?? %-30s could not be applied -- has the file"
                          " changed shape?" % what)
                    failures += 1
                    continue
                checked += 1
                if validator.is_valid(broken):
                    failures += 1
                    print("     FAIL the schema accepts %s -- it is not checking"
                          " that" % what)
                else:
                    print("     rejects %s" % what)

    print()
    if failures:
        print("%d failed out of %d checks" % (failures, checked))
        return 1
    print("all passed (%d checks)" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
