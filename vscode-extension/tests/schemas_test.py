"""The tape designer's JSON schemas, against files they describe.

    .venv-win\\Scripts\\python.exe vscode-extension/tests/schemas_test.py

The same bargain as examples/filmation/vscode/tests/schemas_test.py: a schema
that is merely plausible is worse than none, because VS Code shows its
complaints as errors in a file that is actually correct, and you learn to
ignore them. So each schema is checked against files it claims to describe --
the shapes tape_model.js's serializeTape and serializeScreen write, and any
*.tape.json or *.screen.json in the repository -- and then checked to be worth
having: each deliberately broken copy, a mistake someone could really make by
hand, must FAIL it.

Python rather than Node because jsonschema is in the repository's venv and the
extension has no npm dependencies.
"""
import copy
import json
import sys
from pathlib import Path

import jsonschema

HERE = Path(__file__).resolve().parent
EXT = HERE.parent
ROOT = EXT.parent

# What serializeTape and serializeScreen write, one of each scheme.
FAST = {
    "meta": {"version": 1},
    "scheme": "zx-tape-loader",
    "loaderAddress": "$9000",
    "loadingScreen": "lunarjetman.screen.json",
    "blocks": {
        "relocator": {"file": "jetman.bin", "address": "$7000"},
        "level": {"file": "game.tap", "address": "$A000", "offset": 7235, "length": 4000},
    },
    "entry": "$7000",
    "stack": "$FE4D",
    "output": "lunarjetman.wav",
}
ROM = {
    "meta": {"version": 1, "comment": "The standard loader"},
    "scheme": "rom",
    "loadingScreen": None,
    "blocks": {"code": {"file": "code.bin", "address": 32768}},
    "entry": None,
    "stack": None,
}
SCREEN = {
    "meta": {"version": 1},
    "picture": "LunarJetman.scr",
    "order": [{"x": 11, "y": 0, "w": 10, "h": 2}, {"x": 0, "y": 8, "w": 32, "h": 8}],
}


def broken(document, mangle):
    copied = copy.deepcopy(document)
    mangle(copied)
    return copied


def block(document):
    return next(iter(document["blocks"].values()))


# schema, good documents, and manglings that must each fail.
CASES = [
    ("tape.schema.json", [FAST, ROM], [
        ("an unknown scheme", FAST, lambda d: d.update(scheme="speedlock")),
        ("a block given as a list, the way a name field would want", FAST,
         lambda d: d.update(blocks=[{"name": "code", "file": "a.bin", "address": "$8000"}])),
        ("a block with no address", FAST, lambda d: block(d).pop("address")),
        ("a block with a name field -- the key is the name", FAST, lambda d: block(d).update(name="code")),
        ("an address past the 64K", FAST, lambda d: d.update(entry=70000)),
        ("an address in words", FAST, lambda d: d.update(entry="seven thousand")),
        ("a stack past the 64K", FAST, lambda d: d.update(stack="$10000")),
        ("a negative offset", FAST, lambda d: block(d).update(offset=-1)),
        ("a loader address on a standard ROM tape", ROM, lambda d: d.update(loaderAddress="$9000")),
        ("a loading screen that is a picture, not a screen file", FAST,
         lambda d: d.update(loadingScreen="LunarJetman.scr")),
        ("no blocks at all", FAST, lambda d: d.pop("blocks")),
    ]),
    ("screen.schema.json", [SCREEN], [
        ("a rectangle off the screen", SCREEN, lambda d: d["order"][0].update(x=32)),
        ("a rectangle with no height", SCREEN, lambda d: d["order"][0].pop("h")),
        ("a zero-width rectangle", SCREEN, lambda d: d["order"][0].update(w=0)),
        ("a picture that is not a Spectrum file", SCREEN, lambda d: d.update(picture="title.png")),
        ("the order as an object", SCREEN, lambda d: d.update(order={"1": {"x": 0, "y": 0, "w": 1, "h": 1}})),
    ]),
]

failures = 0


def check(name, ok):
    global failures
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures += 1


for schema_name, goods, manglings in CASES:
    schema = json.loads((EXT / "schemas" / schema_name).read_text(encoding="utf-8"))
    jsonschema.Draft7Validator.check_schema(schema)
    validator = jsonschema.Draft7Validator(schema)
    pattern = "*.tape.json" if schema_name.startswith("tape") else "*.screen.json"
    found = [p for p in ROOT.rglob(pattern) if "node_modules" not in p.parts]
    for good in goods:
        errors = list(validator.iter_errors(good))
        check(f"{schema_name} accepts a {good.get('scheme', 'screen')} file"
              + (f": {errors[0].message}" if errors else ""), not errors)
    for path in found:
        errors = list(validator.iter_errors(json.loads(path.read_text(encoding="utf-8"))))
        check(f"{schema_name} accepts {path.relative_to(ROOT)}" + (f": {errors[0].message}" if errors else ""),
              not errors)
    for what, base, mangle in manglings:
        check(f"{schema_name} refuses {what}", not validator.is_valid(broken(base, mangle)))

print()
print(f"{failures} failed" if failures else "all passed")
sys.exit(1 if failures else 0)
