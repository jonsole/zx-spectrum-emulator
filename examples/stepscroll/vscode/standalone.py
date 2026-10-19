"""The designer's pages as standalone HTML: each page with the JavaScript it
uses inlined and standalone_host.js as its host, so it opens straight in a
browser with nothing running behind it (pages.js does the same in VS Code).

    python examples/stepscroll/vscode/standalone.py    # output/steps_editor.html
"""
from __future__ import annotations

import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "output"
PAGES = {"steps_view.html": "steps_editor.html"}
MARKER = re.compile(r"/\*@([\w.]+\.js)@\*/")


def page(name: str) -> str:
    html = (HERE / name).read_text(encoding="utf-8")
    html = MARKER.sub(lambda m: (HERE / m.group(1)).read_text(encoding="utf-8"), html)
    return html.replace("/*@host@*/", (HERE / "standalone_host.js").read_text(encoding="utf-8"))


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for source, target in PAGES.items():
        (OUT / target).write_text(page(source), encoding="utf-8", newline="\n")
        print(f"wrote {OUT / target}")


if __name__ == "__main__":
    main()
