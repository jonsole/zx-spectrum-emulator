"""Drive tools/zxinfo/zxinfo.py against a fake ZXInfo service.

No network during a test run, so this stands up a local HTTP server answering
the handful of paths the client uses, shaped exactly as the real API shapes
them -- Elasticsearch envelope and all. What it covers is what actually cost
time when the client was written against the live service:

  * entry ids come back zero-padded to 7 digits whichever form you ask with,
  * /games/{id} answers with an ES document, so the entry hides under _source,
  * media paths are host-relative, and the two hosts each 404 the other's,
  * tape images need ordering -- original release and TZX first,
  * nearly every archived file is a .zip wrapping the one tape image,
  * /filecheck holds md5 for some files and sha512 for others.
"""

from __future__ import annotations

import io
import json
import sys
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "zxinfo"))

from zxinfo import ZXInfo, ZXInfoError, media_url, summarise, unwrap  # noqa: E402

TAPE_BYTES = b"\x13\x00\x00\x03zx tape payload"

ENTRY = {
    "title": "Manic Miner",
    "originalYearOfRelease": 1983,
    "machineType": "ZX-Spectrum 48K",
    "genre": "Arcade Game: Platform",
    "availability": "Available",
    "score": {"score": 9.1, "votes": 400},
    "publishers": [{"name": "Bug-Byte Software Ltd", "country": "UK"}],
    "authors": [{"name": "Matthew Smith", "roles": [{"roleName": "Code"}]}],
    "releases": [
        {
            "releaseSeq": 0,
            "files": [
                # Deliberately worst-first, so ordering has to do real work.
                {"path": "/pub/sinclair/games/m/MM.tap.zip", "type": "Tape image",
                 "format": "Tape (TAP)", "origin": None},
                {"path": "/pub/sinclair/games/m/MM-rerelease.tzx.zip", "type": "Tape image",
                 "format": "Perfect tape (TZX)", "origin": "Re-release (R)"},
                {"path": "/pub/sinclair/games/m/MM-variant.tzx.zip", "type": "Tape image",
                 "format": "Perfect tape (TZX)", "origin": "Original release (O)",
                 "comments": "(different)"},
                {"path": "/pub/sinclair/games/m/MM.tzx.zip", "type": "Tape image",
                 "format": "Perfect tape (TZX)", "origin": "Original release (O)"},
                {"path": "/pub/sinclair/games/m/MM-inlay.jpg", "type": "Inlay - Front",
                 "format": "Picture (JPG)", "origin": None},
            ],
        }
    ],
    "screens": [
        {"type": "Loading screen", "url": "/zxscreens/0003012/MM-load.png",
         "scrUrl": "/pub/sinclair/screens/load/m/scr/MM.scr", "format": "Picture"},
    ],
    "additionalDownloads": [
        {"path": "/zxdb/sinclair/entries/0003012/MM-instructions.txt",
         "type": "Instructions", "format": "Text"},
    ],
}

DENIED_ENTRY = dict(ENTRY, title="Still For Sale",
                    availability="Distribution denied - still for sale")


def zipped(name: str, payload: bytes) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, payload)
    return buffer.getvalue()


class Handler(BaseHTTPRequestHandler):
    """Answers the paths the client asks for, and 404s everything else."""

    def log_message(self, *args):  # keep pytest output clean
        pass

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload) -> None:
        self._send(200, json.dumps(payload).encode(), "application/json")

    def do_GET(self):  # noqa: N802 -- BaseHTTPRequestHandler's spelling
        url = urlparse(self.path)
        path = url.path
        query = parse_qs(url.query)
        self.server.seen.append((path, query))

        # The real service answers on either form, and always with the padded id.
        if path == "/v3/games/0003012":
            self._json({"_id": "0003012", "found": True, "_source": ENTRY})
        elif path == "/v3/games/0009999":
            self._json({"_id": "0009999", "found": True, "_source": DENIED_ENTRY})
        elif path == "/v3/search":
            self._json({"hits": {"total": {"value": 2},
                                 "hits": [{"_id": "0003012", "_source": ENTRY}]}})
        elif path == "/v3/filecheck/" + "b" * 128:
            self._json({"_id": "0003012", "_source": {"title": "Manic Miner"}})
        elif path == "/pub/sinclair/games/m/MM.tzx.zip":
            self._send(200, zipped("ManicMiner.tzx", TAPE_BYTES), "application/zip")
        elif path == "/pub/sinclair/games/m/MM.tap.zip":
            self._send(200, zipped("ManicMiner.tap", TAPE_BYTES), "application/zip")
        else:
            self._send(404, b"not found", "text/html")


@pytest.fixture
def service():
    """A fake API on localhost, plus a client pointed at it."""
    server = HTTPServer(("127.0.0.1", 0), Handler)
    server.seen = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    api = ZXInfo(base_url=base + "/v3", timeout=5.0)
    # The media hosts are baked into module constants; point them at the fake
    # too, so download paths resolve to this server.
    import zxinfo as module

    screen_base, file_base = module.SCREEN_BASE, module.FILE_BASE
    module.SCREEN_BASE = module.FILE_BASE = base
    try:
        yield api, server
    finally:
        module.SCREEN_BASE, module.FILE_BASE = screen_base, file_base
        server.shutdown()
        server.server_close()


def test_entry_ids_are_padded_to_seven_digits(service):
    api, server = service
    entry = api.game(3012)
    assert entry["title"] == "Manic Miner"
    # Asked for as 3012, requested as 0003012 -- so an id read back from a
    # response and one typed by hand address the same entry.
    assert ("/v3/games/0003012", {"mode": ["full"]}) in server.seen


def test_bad_entry_id_is_rejected_before_the_request(service):
    api, _ = service
    with pytest.raises(ZXInfoError):
        api.game("not-an-id")
    with pytest.raises(ZXInfoError):
        api.game("12345678")


def test_missing_entry_is_none_not_an_error(service):
    api, _ = service
    assert api.game(1) is None


def test_unwrap_lifts_the_elasticsearch_source(service):
    api, _ = service
    entry = api.game(3012)
    # _source is gone, and the id it was wrapped in survives.
    assert "_source" not in entry
    assert entry["entry_id"] == "0003012"


def test_summarise_keeps_what_identifies_an_entry(service):
    api, _ = service
    summary = summarise(api.game(3012))
    assert summary["title"] == "Manic Miner"
    assert summary["year"] == 1983
    assert summary["publishers"] == ["Bug-Byte Software Ltd"]
    assert summary["score"] == 9.1
    # Four tape images on the entry; the inlay is not one of them.
    assert summary["tape_images"] == 4
    assert summary["zxinfo_url"].endswith("/details/0003012")


def test_media_url_picks_the_host_by_path_prefix():
    # Not against the fake: this is the mapping between the two real hosts.
    import zxinfo as module

    assert media_url("/zxscreens/0003012/MM-load.png").startswith(module.SCREEN_BASE)
    assert media_url("/pub/sinclair/games/m/MM.tzx.zip").startswith(module.FILE_BASE)
    assert media_url("/zxdb/sinclair/entries/0003012/x.txt").startswith(module.FILE_BASE)
    assert media_url("") == ""


def test_tape_files_prefer_the_original_tzx(service):
    api, _ = service
    tapes = api.tape_files(api.game(3012))
    assert [t["path"] for t in tapes] == [
        "/pub/sinclair/games/m/MM.tzx.zip",            # original release, plain TZX
        "/pub/sinclair/games/m/MM-variant.tzx.zip",    # as original, but a variant
        "/pub/sinclair/games/m/MM-rerelease.tzx.zip",  # TZX, but a re-release
        "/pub/sinclair/games/m/MM.tap.zip",            # TAP last
    ]
    assert tapes[0]["url"].endswith("/pub/sinclair/games/m/MM.tzx.zip")


def test_screens_resolve_both_the_png_and_the_raw_scr(service):
    api, _ = service
    screen = api.screens(api.game(3012))[0]
    assert screen["type"] == "Loading screen"
    assert screen["url"].endswith("/zxscreens/0003012/MM-load.png")
    assert screen["scr_url"].endswith("/pub/sinclair/screens/load/m/scr/MM.scr")


def test_download_unpacks_the_single_file_archive(service, tmp_path):
    api, _ = service
    tape = api.tape_files(api.game(3012))[0]
    target = api.download(tape["url"], tmp_path)
    # The .zip wrapper is gone: what lands is the tape the emulator can load.
    assert target.name == "ManicMiner.tzx"
    assert target.read_bytes() == TAPE_BYTES


def test_identify_file_falls_back_from_md5_to_sha512(service, tmp_path, monkeypatch):
    api, server = service
    sample = tmp_path / "unknown.tzx"
    sample.write_bytes(TAPE_BYTES)
    # This file's real md5 is not in the fake; its "sha512" is.
    monkeypatch.setattr("zxinfo.hash_file", lambda path: {"md5": "a" * 32, "sha512": "b" * 128})
    found = api.identify_file(sample)
    assert found["found"] is True
    assert found["matched_by"] == "sha512"
    assert unwrap(found["entry"])["title"] == "Manic Miner"
    assert [p for p, _ in server.seen if p.startswith("/v3/filecheck/")] == [
        "/v3/filecheck/" + "a" * 32,
        "/v3/filecheck/" + "b" * 128,
    ]


def test_identify_file_reports_a_clean_miss(service, tmp_path):
    api, _ = service
    sample = tmp_path / "homebrew.tap"
    sample.write_bytes(b"nothing ZXDB has ever seen")
    found = api.identify_file(sample)
    assert found["found"] is False
    assert len(found["md5"]) == 32 and len(found["sha512"]) == 128


def test_filecheck_rejects_a_hash_of_the_wrong_length(service):
    api, _ = service
    with pytest.raises(ZXInfoError):
        api.filecheck("abc123")


def test_search_returns_summarisable_hits(service):
    api, server = service
    response = api.search("manic miner", size=5)
    assert response["hits"]["total"]["value"] == 2
    assert summarise(response["hits"]["hits"][0])["title"] == "Manic Miner"
    path, query = next(s for s in server.seen if s[0] == "/v3/search")
    assert query["query"] == ["manic miner"] and query["size"] == ["5"]


def test_unreachable_service_raises_rather_than_hanging():
    api = ZXInfo(base_url="http://127.0.0.1:1/v3", timeout=2.0)
    with pytest.raises(ZXInfoError):
        api.search("anything")
