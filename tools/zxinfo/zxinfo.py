"""Client for the ZXInfo API v3 -- ZXDB's catalogue of Sinclair software.

Plain urllib and the standard library: the API is unauthenticated JSON over
HTTPS, so there is nothing here worth a dependency. Importable, and runnable
on its own for a quick check that the service is reachable:

    .venv-win\\Scripts\\python.exe tools\\zxinfo\\zxinfo.py "manic miner"

Three hosts are involved, which is not obvious from the API alone -- every
path in a response is host-relative, and which host depends on the prefix:

  * api.zxinfo.dk           -- the JSON API itself.
  * zxinfo.dk/media         -- `/zxscreens/...`, ZXInfo's own screen captures.
  * spectrumcomputing.co.uk -- `/pub/...` and `/zxdb/...`: tape images, inlays,
    instructions, in-game screens, and the raw .scr behind each screen.

Both hosts answer 404 for the other's paths, so media_url() picks by prefix
rather than making the caller remember.

The API authors ask every client to identify itself with a descriptive
User-Agent or risk being treated as a crawler, hence USER_AGENT below.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

BASE_URL = "https://api.zxinfo.dk/v3"
SCREEN_BASE = "https://zxinfo.dk/media"
FILE_BASE = "https://spectrumcomputing.co.uk"
USER_AGENT = "zx-spectrum-emulator/0.1 (+https://github.com/jonsole/zx-spectrum-emulator)"

# Tape formats worth handing to the emulator, best first. TZX carries the real
# pulse timings (so custom loaders survive); TAP is blocks only.
TAPE_PREFERENCE = ("TZX", "TAP")


class ZXInfoError(Exception):
    """A request failed, or the service answered with something unusable."""


def normalise_id(entry_id) -> str:
    """ZXDB ids are zero-padded to 7 digits for WoS compatibility.

    The API itself accepts either form, but it always *answers* with the
    padded one, so an id fed back from a response would not compare equal to
    the one it was asked for. Normalising here keeps ids interchangeable, and
    catches a non-id before it costs a round trip.
    """
    text = str(entry_id).strip()
    if not text.isdigit() or len(text) > 7:
        raise ZXInfoError(f"not a ZXDB entry id: {entry_id!r} (1-7 digits)")
    return text.zfill(7)


def unwrap(doc: dict) -> dict:
    """Return the entry itself.

    The API is an Elasticsearch front end and does not entirely hide it:
    /games/{id} answers with the raw ES document, so the entry is under
    `_source` and the id under `_id`, while /search returns the same shape
    inside `hits.hits[]`. Callers want one flat entry either way.
    """
    if isinstance(doc, dict) and "_source" in doc:
        entry = dict(doc["_source"])
        entry.setdefault("entry_id", doc.get("_id"))
        return entry
    return doc


def media_url(path: str) -> str:
    """Turn a host-relative path from a response into a URL you can fetch.

    `/zxscreens/...` is ZXInfo's own; everything else -- `/pub/sinclair/...`
    and `/zxdb/sinclair/...` -- is served by Spectrum Computing.
    """
    if not path:
        return ""
    if path.startswith("/zxscreens/"):
        return SCREEN_BASE + path
    return FILE_BASE + path


def hash_file(path) -> dict:
    """md5 and sha512 of a file, the two hashes /filecheck accepts."""
    md5 = hashlib.md5()
    sha512 = hashlib.sha512()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            md5.update(chunk)
            sha512.update(chunk)
    return {"md5": md5.hexdigest(), "sha512": sha512.hexdigest()}


def summarise(entry: dict) -> dict:
    """Cut an entry down to what identifies it.

    A full ZXDB entry runs to seventy-odd fields, most of them empty and most
    of the rest cross-references. Search results are summarised through this
    so a ten-hit search does not cost an agent its context window; get_game()
    can still return the whole thing.
    """
    entry = unwrap(entry)
    score = entry.get("score") or {}
    publishers = entry.get("publishers") or []
    releases = entry.get("releases") or []
    tapes = 0
    for release in releases:
        for item in release.get("files") or []:
            if (item.get("type") or "") == "Tape image":
                tapes += 1
    return {
        "entry_id": entry.get("entry_id"),
        "title": entry.get("title"),
        "year": entry.get("originalYearOfRelease"),
        "machine_type": entry.get("machineType"),
        "genre": entry.get("genre"),
        "publishers": [p.get("name") for p in publishers if p.get("name")],
        "availability": entry.get("availability"),
        "score": score.get("score"),
        "votes": score.get("votes"),
        "tape_images": tapes,
        "zxinfo_url": (
            f"https://zxinfo.dk/details/{entry['entry_id']}" if entry.get("entry_id") else None
        ),
    }


class ZXInfo:
    """One instance of the API. Stateless -- no connection to keep alive."""

    def __init__(self, base_url: str = BASE_URL, timeout: float = 15.0,
                 user_agent: str = USER_AGENT):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.user_agent = user_agent

    # -- transport ----------------------------------------------------------

    def _request(self, url: str, binary: bool = False):
        request = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise ZXInfoError(f"{url} -> HTTP {error.code} {error.reason}") from error
        except urllib.error.URLError as error:
            raise ZXInfoError(f"cannot reach {url}: {error.reason}") from error
        if binary:
            return payload
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ZXInfoError(f"{url} did not answer with JSON") from error

    def _get(self, path: str, params: dict | None = None):
        """GET an API path. None means 404 -- no such entry."""
        query = {k: v for k, v in (params or {}).items() if v is not None}
        url = f"{self.base_url}/{path.lstrip('/')}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        return self._request(url)

    def raw(self, path: str, params: dict | None = None):
        """Any endpoint, unedited -- the escape hatch for what is not wrapped
        above (magazines, publisher listings, /games/byletter)."""
        return self._get(path, params)

    def fetch(self, url: str) -> bytes:
        """GET a media URL (screen, inlay, tape image). Not an API call."""
        payload = self._request(url, binary=True)
        if payload is None:
            raise ZXInfoError(f"{url} -> HTTP 404")
        return payload

    # -- endpoints ----------------------------------------------------------

    def search(self, query: str | None = None, **filters) -> dict:
        """/search. Filters: contenttype, machinetype, genretype, year, ...

        `machinetype=ZXSPECTRUM` and `genretype=GAMES` are the API's own
        shorthands for "any variant" and "any game genre".
        """
        params = {"query": query, "mode": "compact", "size": 10}
        params.update(filters)
        return self._get("search", params) or {}

    def game(self, entry_id, mode: str = "full") -> dict | None:
        """/games/{id}. None if there is no such entry."""
        doc = self._get(f"games/{normalise_id(entry_id)}", {"mode": mode})
        return unwrap(doc) if doc else None

    def more_like_this(self, entry_id, size: int = 10) -> dict:
        path = f"games/morelikethis/{normalise_id(entry_id)}"
        return self._get(path, {"mode": "compact", "size": size}) or {}

    def random_games(self, total: int = 5) -> dict:
        return self._get(f"games/random/{int(total)}", {"mode": "compact"}) or {}

    def by_letter(self, letter: str, **filters) -> dict:
        params = {"mode": "compact", "size": 10}
        params.update(filters)
        return self._get(f"games/byletter/{urllib.parse.quote(letter)}", params) or {}

    def suggest(self, term: str, kind: str | None = None) -> list:
        """/suggest -- titles, or authors/publishers with `kind` set."""
        prefix = {None: "suggest", "author": "suggest/author",
                  "publisher": "suggest/publisher"}.get(kind)
        if prefix is None:
            raise ZXInfoError(f"unknown suggestion kind {kind!r}: author, publisher or None")
        return self._get(f"{prefix}/{urllib.parse.quote(term)}") or []

    def metadata(self) -> dict:
        """Valid values for the /search filters (machine types, genres, ...)."""
        return self._get("metadata/") or {}

    def filecheck(self, digest: str) -> dict | None:
        """Look an md5 or sha512 up against ZXDB's own file hashes."""
        digest = digest.strip().lower()
        if len(digest) not in (32, 128):
            raise ZXInfoError("hash must be md5 (32 chars) or sha512 (128 chars)")
        return self._get(f"filecheck/{digest}")

    def identify_file(self, path) -> dict:
        """Which ZXDB entry a local tape/disk image is, by content hash.

        Tries md5 then sha512: ZXDB does not hold both for every file, and
        which one it has is not predictable from the entry.
        """
        digests = hash_file(path)
        for algorithm in ("md5", "sha512"):
            found = self.filecheck(digests[algorithm])
            if found:
                return {"found": True, "matched_by": algorithm, **digests, "entry": found}
        return {"found": False, **digests}

    # -- files --------------------------------------------------------------

    def tape_files(self, entry: dict) -> list:
        """Every tape image on an entry, best format first.

        Sorted so `tape_files(...)[0]` is the one to load: original release
        above re-release, TZX above TAP (TZX keeps the pulse timings custom
        loaders need), and a plain image above a commented one -- a comment
        here means a variant ("(different)", "ULAplus version", "part 2"),
        never the straightforward dump.
        """
        entry = unwrap(entry)
        candidates = []
        for release in entry.get("releases") or []:
            for item in release.get("files") or []:
                if (item.get("type") or "") != "Tape image":
                    continue
                fmt = (item.get("format") or "").upper()
                rank = next((i for i, f in enumerate(TAPE_PREFERENCE) if f in fmt),
                            len(TAPE_PREFERENCE))
                original = 0 if "Original" in (item.get("origin") or "") else 1
                variant = 1 if item.get("comments") else 0
                candidates.append((original, rank, variant, {
                    "path": item.get("path"),
                    "url": media_url(item.get("path") or ""),
                    "format": item.get("format"),
                    "origin": item.get("origin"),
                    "comments": item.get("comments"),
                    "size": item.get("size"),
                    "release_seq": release.get("releaseSeq"),
                }))
        candidates.sort(key=lambda c: (c[0], c[1], c[2]))
        return [c[3] for c in candidates]

    def screens(self, entry: dict) -> list:
        """Loading and in-game screens, as resolvable URLs."""
        entry = unwrap(entry)
        out = []
        for screen in entry.get("screens") or []:
            out.append({
                "type": screen.get("type"),
                "format": screen.get("format"),
                "url": media_url(screen["url"]) if screen.get("url") else None,
                # The 6912-byte original, i.e. exactly what the Spectrum had
                # in display memory -- loadable, not just viewable.
                "scr_url": media_url(screen["scrUrl"]) if screen.get("scrUrl") else None,
            })
        return out

    def download(self, url: str, dest_dir, filename: str | None = None) -> Path:
        """Fetch a file, unzipping single-file archives on the way in.

        Nearly everything under /pub/sinclair/ is a .zip wrapping one .tap or
        .tzx, and an emulator wants the tape rather than the archive.
        """
        payload = self.fetch(url)
        dest_dir = Path(dest_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        name = filename or urllib.parse.unquote(url.rsplit("/", 1)[-1])
        if zipfile.is_zipfile(io.BytesIO(payload)):
            with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                members = [m for m in archive.namelist() if not m.endswith("/")]
                if len(members) == 1:
                    name = filename or Path(members[0]).name
                    payload = archive.read(members[0])
                else:
                    # More than one file in there: keep the archive, and let
                    # the caller decide what to do with it.
                    name = filename or name
        target = dest_dir / Path(name).name
        target.write_bytes(payload)
        return target


def _print_summary(entry: dict) -> None:
    summary = summarise(entry)
    print(f"  {summary['entry_id']}  {summary['title']} "
          f"({summary['year']}, {summary['machine_type']})")
    print(f"      {summary['genre']} -- {', '.join(summary['publishers']) or 'no publisher'}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Query the ZXInfo API from the command line.")
    parser.add_argument("query", nargs="?", help="text to search for")
    parser.add_argument("--id", help="fetch one entry by ZXDB id instead")
    parser.add_argument("--identify", help="identify a local tape file by its hash")
    args = parser.parse_args(argv[1:])

    api = ZXInfo()
    try:
        if args.identify:
            result = api.identify_file(args.identify)
            print(json.dumps(result, indent=2)[:2000])
            return 0
        if args.id:
            entry = api.game(args.id)
            if entry is None:
                print(f"no entry {args.id}")
                return 1
            _print_summary(entry)
            for tape in api.tape_files(entry)[:5]:
                print(f"      tape: {tape['format']:<24} {tape['url']}")
            for screen in api.screens(entry):
                print(f"      {screen['type']}: {screen['url']}")
            return 0
        if not args.query:
            parser.error("give a query, --id or --identify")
        results = api.search(args.query)
        hits = results.get("hits", {}).get("hits", [])
        total = results.get("hits", {}).get("total", {}).get("value", 0)
        print(f"{total} entries match {args.query!r}; showing {len(hits)}:")
        for hit in hits:
            _print_summary(hit)
    except ZXInfoError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
