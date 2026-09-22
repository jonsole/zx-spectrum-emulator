"""Serve the Filmation room designer as a web page, outside VS Code.

The designer is one page, vscode-extension/room_view.html, and it runs the same
way in both places: everything that differs between a VS Code webview and a
browser arrives through a `roomHost` object the host injects into it. This is
the browser half. The editor half is vscode-extension/room_view.js, and the two
inject the same shape, so the page itself has no idea which it is in.

    python scripts/room_designer.py                 Knight Lore
    python scripts/room_designer.py pentagram
    python scripts/room_designer.py path/to/rooms.json
    python scripts/room_designer.py --port 8900 --no-browser

It edits examples/filmation/<game>/rooms.json in place, which is the game's
rooms in their editable form: rooms.py decodes room_data.bin into it and
rooms_source.py turns it back into room_data.s, so what the designer writes is
what the next build assembles. Nothing here regenerates it from the packed
tables -- that would throw the edits away -- so the round trip is safe.

It also needs the artwork, which is gitignored: sprites.png and sprites.json,
which the game's own build.py unpacks from sprite_data.bin the first time it
runs. Without them the page still opens and still edits, and says it has no
sheet rather than drawing an empty room.

Served on localhost only. It writes to a file in your working tree and runs
build.py on request, so it has no business being reachable from anywhere else.
"""
import argparse
import http.server
import json
import mimetypes
import socketserver
import subprocess
import sys
import threading
import webbrowser
from base64 import b64encode
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FILMATION = REPO / "examples" / "filmation"
EXTENSION = REPO / "vscode-extension"
PAGE = EXTENSION / "room_view.html"

# The two pure files the page inlines, in the order it names them.
INLINED = ("sheet_model.js", "room_model.js", "room_render.js",
           "specials_model.js")

DEFAULT_PORT = 8760


def find_game(argument):
    """The rooms.json to edit, from a game name or a path."""
    if argument is None:
        argument = "knightlore"
    as_path = Path(argument)
    if as_path.suffix == ".json" and as_path.is_file():
        return as_path.resolve()
    guess = FILMATION / argument / "rooms.json"
    if guess.is_file():
        return guess
    sys.exit(
        "no rooms.json for %r.\n"
        "Give a game under examples/filmation (knightlore, pentagram) or a path "
        "to a rooms.json.\n"
        "If the game is there but the file is not, run its rooms.py once against "
        "room_data.bin." % argument
    )


def find_games():
    """Every game under examples/filmation that has rooms to edit.

    What the Load button offers. A game is a directory with a rooms.json in it,
    so a new one needs nothing here -- run its rooms.py once and it appears.
    """
    if not FILMATION.is_dir():
        return []
    return [child.name for child in sorted(FILMATION.iterdir())
            if (child / "rooms.json").is_file()]


def data_uri(path):
    """A file as a data: URI, or None. The page takes its sprite sheet this way
    rather than as a URL, so that the editor and the browser can hand it over
    identically -- a webview has no file access of its own."""
    if not path.is_file():
        return None
    kind = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return "data:%s;base64,%s" % (kind, b64encode(path.read_bytes()).decode("ascii"))


# What a castle is drawn with, when its own meta.sprites does not say. These
# are the names every rooms.json used before that field existed, and the same
# fallback vscode-extension/room_model.js keeps -- change one, change both.
SPRITE_FILES = {
    "sheet": "sprites.png",
    "atlas": "sprites.json",
    "graphics": "graphics.json",
}


def beside(game_dir, name):
    """A file the castle names, resolved next to it.

    Relative to the rooms.json, and not allowed out of its directory: the file
    is data, and data does not get to point the server at the rest of the disk.
    """
    if not isinstance(name, str) or not name:
        return None
    full = (game_dir / name).resolve()
    try:
        full.relative_to(game_dir.resolve())
    except ValueError:
        return None
    return full


def sprite_files(atlas, game_dir):
    """The two artwork files, as the castle names them.

    The atlas carries the pixel nudges as well, under meta.zx.game.graphics, so
    the page needs nothing else to draw a room the way the game would.
    """
    said = (atlas.get("meta") or {}).get("sprites") or {}
    return {key: beside(game_dir, said.get(key) or fallback)
            for key, fallback in SPRITE_FILES.items()}


# Knight Lore's collectables. Not part of the castle -- the game keeps them in
# a table of its own -- so they are a second file, held and saved beside it.
SPECIALS = "specials.json"


def templates_leaf(text):
    """Which file a rooms.json keeps its templates in, from its own meta.

    Nothing is assumed: a rooms.json that does not say is refused, and so is
    one that names a file outside its own directory.
    """
    said = (json.loads(text).get("meta") or {}).get("templates")
    if not isinstance(said, str) or not said or "/" in said or "\\" in said:
        raise SystemExit("rooms.json does not say where its templates are, in "
                         "meta.templates")
    return said


def boot_for(rooms_json):
    """What the page needs to open: the file, the artwork, and how to save it."""
    game_dir = rooms_json.parent
    text = rooms_json.read_text(encoding="utf-8", newline="")
    art = sprite_files(json.loads(text), game_dir)
    sheet = art["atlas"]
    return {
        "atlas": json.loads(text),
        # The file's own line endings, so writing it back changes only what was
        # edited. Python's text-mode write makes these CRLF on Windows.
        "eol": "\r\n" if "\r\n" in text else "\n",
        "sheet": json.loads(sheet.read_text(encoding="utf-8"))
                 if sheet and sheet.is_file() else None,
        "sheetPng": data_uri(art["sheet"]) if art["sheet"] else None,
        "graphics": json.loads(art["graphics"].read_text(encoding="utf-8"))
                    if art["graphics"] and art["graphics"].is_file() else None,
        # The templates the rooms place, which are a file of their own. The
        # designer draws with them but never edits them -- that is the
        # templates editor's -- so Save here still writes rooms.json alone.
        "templates": json.loads((game_dir / templates_leaf(text)).read_text(encoding="utf-8"))
                     if (game_dir / templates_leaf(text)).is_file() else None,
        "specials": json.loads((game_dir / SPECIALS).read_text(encoding="utf-8"))
                    if (game_dir / SPECIALS).is_file() else None,
        "room": None,
        "showSave": True,
        "buildLabel": "Build " + game_dir.name,
        # Only the browser half has these. In the editor the document is the
        # model, so undo is the text editor's and opening a file is the
        # editor's own business.
        "game": game_dir.name,
        "games": find_games(),
        "ownUndo": True,
    }


# The browser's half of the host seam.
#
# The page reports every change as it happens, because in the editor each one
# is a WorkspaceEdit and an undo step. Here there is no undo stack and the only
# copy of the castle is the file, so a change is HELD and nothing is written
# until Save is pressed. An earlier version wrote on a timer instead, and the
# first thing that happened was a session's worth of clicking about ending up
# on disk without anyone having saved anything.
HOST_SHIM = """
window.roomHost = (function () {
  const boot = __BOOT__;
  let pending = null;          // what Save would write, or null when in step
  let pendingSpecials = null;  // ...and the collectables, when they were touched
  let saved = null;

  function put(name, text) {
    return fetch(name, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: text
    }).then(function (response) {
      if (!response.ok) throw new Error('could not save ' + name + ': ' + response.status);
    });
  }
  window.addEventListener('beforeunload', function (event) {
    if (pending === null && pendingSpecials === null) return;
    event.preventDefault();
    event.returnValue = '';
  });
  return {
    boot: boot,
    save: function (text, what, now) {
      pending = text;
      if (!now) return;
      const writes = [put('rooms.json', text)];
      if (pendingSpecials !== null) writes.push(put('specials.json', pendingSpecials));
      Promise.all(writes).then(function () {
        pending = null;
        pendingSpecials = null;
        if (saved) saved();
      }).catch(function (err) { console.error(err); alert(String(err)); });
    },
    // Held the same way, and written by the same Save. Two files, one button:
    // they are edited in one page and there is nothing useful about saving
    // half of it.
    saveSpecials: function (text) { pendingSpecials = text; },
    onSaved: function (fn) { saved = fn; },
    unsaved: function () { return pending !== null || pendingSpecials !== null; },
    games: boot.games || [],
    open: function (game) {
      return fetch('open', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ game: game })
      }).then(function (response) {
        if (!response.ok) throw new Error('could not load: ' + response.status);
        return response.json();
      }).then(function (next) {
        pending = null;                  // a fresh file, nothing held over
        return next;
      });
    },
    build: function () {
      if (pending !== null &&
          !confirm('There are unsaved changes. Build the game as it was last saved?')) {
        return;
      }
      fetch('build', { method: 'POST' }).then(function (r) { return r.text(); })
        .then(function (out) { console.log(out); alert(out.slice(-2000)); })
        .catch(function (err) { alert(String(err)); });
    }
  };
})();
"""


def page_html(rooms_json):
    """room_view.html with the two pure files and the host shim inlined.

    The same three substitutions the editor makes, minus its content-security
    policy and nonce, which a webview needs and a browser does not.
    """
    html = PAGE.read_text(encoding="utf-8")
    for name in INLINED:
        source = (EXTENSION / name).read_text(encoding="utf-8")
        html = html.replace("/*@%s@*/" % name, source, 1)
    shim = HOST_SHIM.replace("__BOOT__", json.dumps(boot_for(rooms_json)))
    return html.replace("/*@host@*/", shim, 1)


class Designer(http.server.SimpleHTTPRequestHandler):
    rooms_json = None
    quiet = True

    def log_message(self, fmt, *args):
        if not self.quiet:
            super().log_message(fmt, *args)

    def _send(self, status, body, kind="text/plain; charset=utf-8"):
        payload = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def open_game(self):
        """Switch to another game's rooms, or re-read this one from disk.

        Whatever the page was holding unsaved goes with it -- the page asks
        first. Nothing is written here; this only changes which file the
        designer is pointed at.
        """
        length = int(self.headers.get("Content-Length") or 0)
        try:
            asked = json.loads(self.rfile.read(length).decode("utf-8")).get("game")
        except Exception as err:                            # noqa: BLE001
            self._send(400, "not a request: %s" % err)
            return
        target = FILMATION / str(asked) / "rooms.json"
        if not target.is_file():
            self._send(404, "no rooms.json for %r" % asked)
            return
        type(self).rooms_json = target.resolve()
        try:
            self._send(200, json.dumps(boot_for(self.rooms_json)), "application/json")
        except Exception as err:                            # noqa: BLE001
            self._send(500, "could not read %s: %s" % (target, err))

    def do_GET(self):
        route = self.path.split("?")[0]
        if route in ("/", "/index.html"):
            try:
                self._send(200, page_html(self.rooms_json), "text/html; charset=utf-8")
            except Exception as err:                        # noqa: BLE001
                self._send(500, "could not build the page: %s" % err)
            return
        if route == "/rooms.json":
            self._send(200, self.rooms_json.read_bytes(), "application/json")
            return
        self._send(404, "no such thing here")

    def do_PUT(self):
        route = self.path.split("?")[0]
        if route == "/specials.json":
            self.put_specials()
            return
        if route != "/rooms.json":
            self._send(404, "no such thing here")
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        try:
            # Refuse to write something that is not a castle: a truncated or
            # mangled body would otherwise overwrite the game's rooms.
            atlas = json.loads(body.decode("utf-8"))
            for key in ("roomDimensions", "sceneryTemplates",
                        "objectTemplates", "rooms"):
                if not isinstance(atlas.get(key), list):
                    raise ValueError("no %s array" % key)
        except Exception as err:                            # noqa: BLE001
            self._send(400, "not a rooms.json: %s" % err)
            return
        # Written with newline="" so the page's own line endings survive: it
        # sends back whatever the file had.
        self.rooms_json.write_text(body.decode("utf-8"), encoding="utf-8", newline="")
        self._send(200, "saved %d bytes" % len(body))

    def put_specials(self):
        """The collectables, checked the same way the castle is.

        A truncated or mangled body would otherwise overwrite the game's own
        table, and the build would stop on a table that is not 32 rows rather
        than on anything that says what happened.
        """
        path = self.rooms_json.parent / SPECIALS
        if not path.is_file():
            self._send(404, "no %s beside this castle" % SPECIALS)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        try:
            said = json.loads(body.decode("utf-8"))
            if not isinstance(said.get("collectables"), list):
                raise ValueError("no collectables array")
            if not isinstance(said.get("wanted"), list):
                raise ValueError("no wanted array")
        except Exception as err:                            # noqa: BLE001
            self._send(400, "not a %s: %s" % (SPECIALS, err))
            return
        path.write_text(body.decode("utf-8"), encoding="utf-8", newline="")
        self._send(200, "saved %d bytes" % len(body))

    def do_POST(self):
        route = self.path.split("?")[0]
        if route == "/open":
            self.open_game()
            return
        if route != "/build":
            self._send(404, "no such thing here")
            return
        build = self.rooms_json.parent / "build.py"
        if not build.is_file():
            self._send(404, "no build.py beside %s" % self.rooms_json.name)
            return
        done = subprocess.run([sys.executable, str(build)], cwd=str(build.parent),
                              capture_output=True, text=True)
        self._send(200 if done.returncode == 0 else 500,
                   (done.stdout or "") + (done.stderr or ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("game", nargs="?",
                        help="a game under examples/filmation, or a path to a rooms.json")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--no-browser", action="store_true",
                        help="do not open a browser window")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args()

    rooms_json = find_game(args.game)
    if not PAGE.is_file():
        sys.exit("%s is missing" % PAGE)

    Designer.rooms_json = rooms_json
    Designer.quiet = not args.verbose

    # Localhost only: it writes into the working tree and will run build.py.
    with socketserver.TCPServer(("127.0.0.1", args.port), Designer) as server:
        url = "http://127.0.0.1:%d/" % args.port
        print("Room designer for %s" % rooms_json)
        print("  %s   (ctrl-c to stop)" % url)
        art = sprite_files(json.loads(rooms_json.read_text(encoding="utf-8")),
                           rooms_json.parent)
        if not art["sheet"] or not art["sheet"].is_file():
            print("  no sprite sheet yet -- run %s/build.py once to unpack the artwork"
                  % rooms_json.parent.name)
        if not args.no_browser:
            threading.Timer(0.3, webbrowser.open, (url,)).start()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")


if __name__ == "__main__":
    main()
