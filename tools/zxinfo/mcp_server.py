"""An MCP server exposing ZXDB -- the Sinclair software catalogue -- as tools.

Runs over stdio, so an MCP client launches it, and it is deliberately separate
from the emulator's own MCP endpoint: nothing here needs a running machine, and
looking a game up is most useful *before* one is loaded.

The two servers meet at the file system. `download_tape()` writes a .tzx or
.tap to disk and returns the path; the emulator's `load_tape(path)` takes it
from there.

Everything is read-only and unauthenticated. Downloads honour ZXDB's own
`availability` field: entries marked as distribution-denied are refused rather
than fetched.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import tempfile
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer

sys.path.insert(0, str(Path(__file__).resolve().parent))

from zxinfo import ZXInfo, ZXInfoError, media_url, summarise, unwrap  # noqa: E402

# Fields worth carrying past summarise() when a single entry is fetched. The
# rest of a full entry is cross-references to other entries, which an agent can
# follow by id if it wants them.
DETAIL_FIELDS = (
    "alsoKnownAs", "authors", "controls", "features", "language",
    "multiplayerMode", "multiplayerType", "numberOfPlayers", "originalPrice",
    "originalPublication", "programmingLanguage", "remarks", "series",
    "knownErrors", "tosec",
)

IMAGE_TYPES = {b"\x89PNG": "png", b"GIF8": "gif", b"\xff\xd8\xff": "jpeg"}


def image_format(data: bytes) -> str:
    """Sniff an image's format from its magic bytes.

    ZXDB screens are a mix of PNG and GIF depending on when they were
    captured, and the file extension is not always honest about which.
    """
    for magic, name in IMAGE_TYPES.items():
        if data.startswith(magic):
            return name
    raise ZXInfoError("downloaded file is not a PNG, GIF or JPEG")


def hits_of(response: dict) -> list:
    """The `hits.hits[]` list out of an Elasticsearch-shaped response."""
    return ((response or {}).get("hits") or {}).get("hits") or []


def total_of(response: dict) -> int:
    total = ((response or {}).get("hits") or {}).get("total") or {}
    return total.get("value", 0) if isinstance(total, dict) else int(total or 0)


def distribution_denied(entry: dict) -> bool:
    return "denied" in (unwrap(entry).get("availability") or "").lower()


def create_server(api: ZXInfo, download_dir: Path) -> MCPServer:
    server = MCPServer(
        "zxinfo",
        instructions=(
            "Look up ZX Spectrum (and other Sinclair) software in ZXDB via the "
            "ZXInfo API: what a game is, who wrote it, what it scored, its "
            "loading screen, and where its tape image lives. Entry ids are "
            "ZXDB ids -- pass them as you get them. This server does not talk "
            "to the emulator: to actually run something, download_tape() it "
            "and hand the returned path to the emulator's load_tape tool. "
            "Search results are summarised; get_game() has the detail."
        ),
    )

    async def call(func, *args, **kwargs):
        """Run a blocking HTTP request off the event loop."""
        return await asyncio.to_thread(func, *args, **kwargs)

    @server.tool()
    async def search(
        query: str | None = None,
        limit: int = 10,
        machine_type: str | None = None,
        genre_type: str | None = None,
        year: int | None = None,
        content_type: str | None = None,
        titles_only: bool = False,
        sort: str | None = None,
    ) -> dict:
        """Search ZXDB by title, publisher or author.

        `machine_type` accepts an exact machine ("ZX-Spectrum 48K") or the
        shorthand ZXSPECTRUM / ZX81 / PENTAGON for all variants of one;
        `genre_type` likewise takes "Arcade Game" or GAMES for every game
        genre. `content_type` is SOFTWARE, HARDWARE or BOOK. `sort` is one of
        title_asc, title_desc, date_asc, date_desc, rel_asc, rel_desc
        (relevance descending by default). Results are summarised -- call
        get_game() with an entry_id for the whole record."""
        response = await call(
            api.search,
            query,
            size=max(1, min(int(limit), 50)),
            machinetype=machine_type,
            genretype=genre_type,
            year=year,
            contenttype=content_type,
            titlesonly="true" if titles_only else None,
            sort=sort,
        )
        return {
            "total": total_of(response),
            "results": [summarise(hit) for hit in hits_of(response)],
        }

    @server.tool()
    async def get_game(entry_id: str, include_raw: bool = False) -> dict:
        """Everything ZXDB holds on one entry: the summary, its authors and
        credits, remarks, tape images (best format first) and screens.

        `include_raw` adds the unedited API document -- the cross-reference
        fields (compilations, re-releases, magazine references, related
        hardware) that the curated view leaves out."""
        entry = await call(api.game, entry_id)
        if entry is None:
            return {"found": False, "entry_id": entry_id}
        result = {"found": True, **summarise(entry)}
        for field in DETAIL_FIELDS:
            value = entry.get(field)
            if value:
                result[field] = value
        result["tapes"] = api.tape_files(entry)
        result["screens"] = api.screens(entry)
        result["downloads"] = [
            {"type": d.get("type"), "format": d.get("format"),
             "url": media_url(d.get("path") or "")}
            for d in entry.get("additionalDownloads") or []
        ]
        if include_raw:
            result["raw"] = entry
        return result

    @server.tool()
    async def identify_file(path: str) -> dict:
        """Identify a local tape or disk image by content hash.

        Hashes the file (md5, then sha512) and asks ZXDB which entry it is --
        the reliable way to find out what an unlabelled .tap/.tzx actually is.
        Snapshots (.sna/.z80) are usually not in ZXDB, which indexes released
        images, so a miss there is expected rather than an error."""
        if not Path(path).is_file():
            return {"found": False, "error": f"no such file: {path}"}
        found = await call(api.identify_file, path)
        if found.get("found"):
            entry = found["entry"]
            # /filecheck answers with id and title only; fetch the entry so the
            # answer is useful without a second round trip.
            full = await call(api.game, unwrap(entry).get("entry_id") or entry.get("_id"))
            found["entry"] = summarise(full) if full else entry
        return found

    @server.tool()
    async def more_like_this(entry_id: str, limit: int = 10) -> dict:
        """Entries similar to this one -- same machine, genre and content type.
        ZXDB's own "if you liked that" list."""
        response = await call(api.more_like_this, entry_id, max(1, min(int(limit), 50)))
        return {"results": [summarise(hit) for hit in hits_of(response)]}

    @server.tool()
    async def random_games(total: int = 5) -> dict:
        """A few random games, drawn only from entries that have both a loading
        and an in-game screen -- so every one of them is something you can
        actually look at and run."""
        response = await call(api.random_games, max(1, min(int(total), 25)))
        hits = hits_of(response) or (response if isinstance(response, list) else [])
        return {"results": [summarise(hit) for hit in hits]}

    @server.tool()
    async def suggest(term: str, kind: str | None = None) -> dict:
        """Type-ahead suggestions for a partial name. `kind` is "author",
        "publisher", or omitted for titles. Use it to pin down a spelling
        before searching."""
        return {"suggestions": await call(api.suggest, term, kind)}

    @server.tool()
    async def metadata() -> dict:
        """The valid values for search filters: every machine type, genre and
        feature ZXDB knows. Worth reading before guessing at a filter."""
        return await call(api.metadata)

    @server.tool()
    async def get_screen(entry_id: str, kind: str = "loading") -> Image:
        """The game's loading or in-game screen as an image. `kind` is
        "loading" or "running" (matched loosely against ZXDB's screen types).
        The quickest way to confirm an entry is the game you meant."""
        entry = await call(api.game, entry_id)
        if entry is None:
            raise ZXInfoError(f"no entry {entry_id}")
        screens = api.screens(entry)
        wanted = [s for s in screens if kind.lower() in (s.get("type") or "").lower()]
        chosen = (wanted or screens)
        chosen = [s for s in chosen if s.get("url")]
        if not chosen:
            raise ZXInfoError(f"entry {entry_id} has no {kind} screen")
        data = await call(api.fetch, chosen[0]["url"])
        return Image(data=data, format=image_format(data))

    @server.tool()
    async def download_tape(entry_id: str, index: int = 0, dest_dir: str | None = None) -> dict:
        """Download a tape image and return the path to give load_tape().

        Picks the entry's best tape by default -- original release over
        re-release, TZX over TAP, since TZX preserves the pulse timings custom
        loaders depend on. `index` selects another from get_game()'s `tapes`
        list. The archive's .zip wrapper is unpacked here, so what lands on
        disk is the .tzx/.tap itself."""
        entry = await call(api.game, entry_id)
        if entry is None:
            return {"downloaded": False, "error": f"no entry {entry_id}"}
        if distribution_denied(entry):
            return {
                "downloaded": False,
                "error": (f"ZXDB marks entry {entry_id} as "
                          f"'{unwrap(entry).get('availability')}' -- not downloading it"),
            }
        tapes = api.tape_files(entry)
        if not tapes:
            return {"downloaded": False, "error": f"entry {entry_id} has no tape image"}
        if not 0 <= index < len(tapes):
            return {"downloaded": False,
                    "error": f"index {index} out of range; entry has {len(tapes)} tapes"}
        tape = tapes[index]
        target = await call(api.download, tape["url"], dest_dir or download_dir)
        return {
            "downloaded": True,
            "path": str(target),
            "bytes": target.stat().st_size,
            "format": tape.get("format"),
            "origin": tape.get("origin"),
            "title": unwrap(entry).get("title"),
            "entry_id": unwrap(entry).get("entry_id"),
            "next_step": f"load_tape(path={str(target)!r}) on the emulator's MCP server",
        }

    @server.tool()
    async def download_file(url: str, dest_dir: str | None = None) -> dict:
        """Download any URL from a ZXDB response -- an inlay scan, a .scr
        loading screen, instructions -- to disk. Single-file .zip archives are
        unpacked. Only zxinfo.dk and spectrumcomputing.co.uk are allowed."""
        host = url.split("/")[2] if url.startswith("https://") and len(url.split("/")) > 2 else ""
        if host not in ("zxinfo.dk", "spectrumcomputing.co.uk", "api.zxinfo.dk"):
            return {"downloaded": False, "error": f"refusing to fetch from {host or url!r}"}
        target = await call(api.download, url, dest_dir or download_dir)
        return {"downloaded": True, "path": str(target), "bytes": target.stat().st_size}

    @server.tool()
    async def api_get(path: str, params: dict | None = None) -> dict:
        """Raw call against the ZXInfo API -- the escape hatch for endpoints
        these tools do not wrap (magazines, /games/byletter, publisher and
        author listings). `path` is relative to https://api.zxinfo.dk/v3, e.g.
        "magazines/Crash/issues". The reply is returned unedited, so ask for
        mode=tiny or a small size unless you want all of it."""
        response = await call(api.raw, path, params or {})
        if response is None:
            return {"found": False, "error": f"{path} -> HTTP 404"}
        return response if isinstance(response, dict) else {"result": response}

    return server


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--download-dir",
        default=os.environ.get("ZXINFO_DOWNLOAD_DIR", str(Path(tempfile.gettempdir()) / "zxinfo")),
        help="where downloaded tapes and media land when no directory is given",
    )
    parser.add_argument("--timeout", type=float, default=15.0, help="HTTP timeout in seconds")
    parser.add_argument(
        "--user-agent",
        default=os.environ.get("ZXINFO_USER_AGENT", ""),
        help="override the User-Agent this client identifies itself with",
    )
    args = parser.parse_args(argv[1:])

    api = ZXInfo(timeout=args.timeout,
                 **({"user_agent": args.user_agent} if args.user_agent else {}))
    server = create_server(api, Path(args.download_dir))
    server.run(transport="stdio")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
