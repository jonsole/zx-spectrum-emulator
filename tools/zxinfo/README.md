# ZXInfo MCP server

Looks ZX Spectrum software up in [ZXDB](https://zxinfo.dk) from an MCP
client — what a game is, who wrote it, what it scored, its loading screen,
and where its tape image lives — and downloads that tape so the emulator
can load it.

Two files, no dependencies beyond the standard library: the
[ZXInfo API v3](https://api.zxinfo.dk/v3/) is unauthenticated JSON over
HTTPS, so [zxinfo.py](zxinfo.py) is plain `urllib`, and
[mcp_server.py](mcp_server.py) wraps it as tools.

- **[zxinfo.py](zxinfo.py)** — the client. Importable and runnable on its own.
- **[mcp_server.py](mcp_server.py)** — the MCP server, over stdio.

## Why this is not part of the emulator's MCP server

The emulator's own MCP endpoint ([docs/mcp.md](../../docs/mcp.md)) is served
by a running `zx_server.exe`. Nothing here needs a running machine — and
looking a game up is most useful *before* one is loaded — so binding these
tools to the emulator's lifetime would only mean losing them whenever it is
down. `zx_server` also has no TLS: [net.cpp](../../cpp-core/src/net.cpp) is a
blocking TCP wrapper and [http.cpp](../../cpp-core/src/http.cpp) is just
enough HTTP/1.1 to *serve* MCP, so reaching an HTTPS API from there would mean
WinHTTP or a vendored TLS stack in the emulator process, for metadata.

The two servers meet at the file system instead:

```
zxinfo.download_tape(entry_id="3012")  ->  ...\zxinfo\Manic Miner.tzx
zx-spectrum.load_tape(path=...)        ->  running
```

## Check the service is reachable

```powershell
.venv-win\Scripts\python.exe tools\zxinfo\zxinfo.py "manic miner"
.venv-win\Scripts\python.exe tools\zxinfo\zxinfo.py --id 3012
.venv-win\Scripts\python.exe tools\zxinfo\zxinfo.py --identify tapes\game.tzx
```

The first prints the top hits, the second one entry with its tapes and
screens, the third asks ZXDB what a local file actually is. If they print
`cannot reach …`, nothing else here will work.

## Connect an MCP client

Like [rigol](../rigol/README.md) and unlike the emulator, this server runs
over stdio, so the client launches it. The repo's `.mcp.json` registers it as
`zxinfo`, so opening this workspace in Claude Code picks it up (you'll be
prompted to approve it once). To add it to another client:

```bash
claude mcp add zxinfo -- .venv-win\Scripts\python.exe tools/zxinfo/mcp_server.py
```

`--download-dir` (or `ZXINFO_DOWNLOAD_DIR`) sets where downloads land; it
defaults to a `zxinfo/` folder in the system temp directory. `--user-agent`
(or `ZXINFO_USER_AGENT`) overrides how the client identifies itself.

**Available tools:**

| Tool | Does |
|---|---|
| `search(query, limit=…, machine_type=…, genre_type=…, year=…, content_type=…, titles_only=…, sort=…)` | Search by title, publisher or author; summarised results |
| `get_game(entry_id, include_raw=…)` | One entry in full: credits, remarks, tapes, screens, downloads |
| `identify_file(path)` | What a local .tap/.tzx actually is, by content hash |
| `more_like_this(entry_id, limit=…)` | ZXDB's own "if you liked that" list |
| `random_games(total=…)` | Random games, all with loading and in-game screens |
| `suggest(term, kind=…)` | Type-ahead for titles, `author` or `publisher` |
| `metadata()` | Every valid machine type, genre and feature for the filters |
| `get_screen(entry_id, kind=…)` | The loading or in-game screen, as an image |
| `download_tape(entry_id, index=…, dest_dir=…)` | Best tape image to disk → path for `load_tape` |
| `download_file(url, dest_dir=…)` | Any inlay, .scr or instructions file from a response |
| `api_get(path, params=…)` | Raw API call — the escape hatch (magazines, byletter, …) |

## Things worth knowing

**Three hosts, and each 404s the other's paths.** Every path in a response is
host-relative. `/zxscreens/…` is served by `zxinfo.dk/media`; `/pub/…` and
`/zxdb/…` by `spectrumcomputing.co.uk`. `media_url()` picks by prefix so
callers don't have to — getting it wrong looks exactly like a missing file.

**The Elasticsearch envelope shows through.** `/games/{id}` answers with the
raw ES document (the entry under `_source`, the id under `_id`), and `/search`
returns the same shape inside `hits.hits[]`. `unwrap()` flattens both.

**Ids are padded, but not required to be.** ZXDB ids appear everywhere as
seven digits (`0003012`); the API accepts `3012` just as happily but always
answers with the padded form. So a 404 means the entry is genuinely absent,
never that the id was written short.

**Which tape image to load is a real choice.** A popular game has a dozen, and
they are not equivalent: `tape_files()` sorts original release above
re-release, TZX above TAP (TZX preserves the pulse timings custom loaders
depend on), and a plain image above a commented one — a comment there marks a
variant (`(different)`, `ULAplus version`, `part 2`), never the straightforward
dump. Everything in the archive is a .zip around one tape, which `download()`
unwraps.

**Downloads honour `availability`.** Entries ZXDB marks as distribution-denied
(still commercially sold) are refused rather than fetched.

**Identify yourself.** The API authors ask every client to send a unique,
descriptive `User-Agent` or risk being treated as a crawler. `USER_AGENT` in
[zxinfo.py](zxinfo.py) does that; keep it honest if you fork this.

## Tests

[tests/test_zxinfo.py](../../tests/test_zxinfo.py) stands up a fake ZXInfo
service on a socket and drives the real client against it — id normalisation,
the `_source` envelope, the two media hosts, tape ordering, .zip unwrapping,
and the md5→sha512 fallback in `/filecheck`.

```powershell
.venv-win\Scripts\python.exe -m pytest tests\test_zxinfo.py
```

A fake is only as good as the shapes it copies, so
[tests/test_zxinfo_live.py](../../tests/test_zxinfo_live.py) re-checks those
same assumptions against the real service. It is marked `live` and deselected
from a normal run, since it goes out to someone else's server; a full run is
six requests.

```powershell
.venv-win\Scripts\python.exe -m pytest tests\test_zxinfo_live.py -m live
```

It has already paid for itself once: the client was written believing the API
404s on an unpadded id, and the live run said otherwise on the first attempt.

**Verified end to end against the live service** through the MCP protocol over
stdio: every tool above, including a Manic Miner tape downloaded from the
archive, unzipped, and handed straight back to `/filecheck`, which recognised
its own file by md5.
