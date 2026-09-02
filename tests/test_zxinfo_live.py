"""Check tests/test_zxinfo.py's fake still matches the real ZXInfo service.

The offline tests are only as good as the shapes they assume, and those came
from probing the live API rather than from a schema -- so they can rot silently
when ZXDB's index is rebuilt. This suite re-checks the assumptions against
api.zxinfo.dk itself.

Deselected by default, because it goes out to someone else's server:

    .venv-win\\Scripts\\python.exe -m pytest tests\\test_zxinfo_live.py -m live

It is deliberately frugal -- one entry fetch shared by every test that needs
one, and a HEAD-sized read of a single screen. Six requests for a whole run.
Manic Miner (entry 3012) is the fixed point: an original 1983 release with
tape images and both screens, and about as unlikely to leave ZXDB as anything
in it.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "zxinfo"))

from zxinfo import ZXInfo, ZXInfoError  # noqa: E402

pytestmark = pytest.mark.live

MANIC_MINER = "3012"


@pytest.fixture(scope="module")
def api() -> ZXInfo:
    return ZXInfo(timeout=20.0)


@pytest.fixture(scope="module")
def entry(api: ZXInfo) -> dict:
    """One fetch, shared -- most of what follows is about this document."""
    try:
        found = api.game(MANIC_MINER)
    except ZXInfoError as error:
        pytest.skip(f"ZXInfo unreachable: {error}")
    if found is None:
        pytest.fail(f"entry {MANIC_MINER} has gone from ZXDB")
    return found


def test_the_service_answers_and_the_entry_is_what_we_think(entry):
    assert entry["title"] == "Manic Miner"
    assert entry["originalYearOfRelease"] == 1983
    assert entry["machineType"].startswith("ZX-Spectrum")


def test_the_envelope_is_still_elasticsearch_shaped(entry):
    # unwrap() lifted _source and kept the id -- if the API ever flattens its
    # responses, this is where the fake stops matching.
    assert entry["entry_id"] == MANIC_MINER.zfill(7)
    assert "_source" not in entry


def test_either_id_form_reaches_the_same_entry(api):
    """Unpadded ids work too -- but the reply is always the padded one.

    Worth pinning down: it is why normalise_id() exists (so ids compare
    equal), and it is *not* why a lookup fails. A 404 here means the entry is
    genuinely absent, not that the id was written short.
    """
    document = api.raw(f"games/{MANIC_MINER}")
    assert document is not None
    assert document["_id"] == MANIC_MINER.zfill(7)


def test_tape_images_and_screens_are_still_where_we_look_for_them(api, entry):
    tapes = api.tape_files(entry)
    assert tapes, "no tape images -- releases[].files[].type may have been renamed"
    assert "TZX" in (tapes[0]["format"] or "").upper()
    assert "Original" in (tapes[0]["origin"] or "")
    assert not tapes[0]["comments"], "the plain image should sort above the variants"

    screens = api.screens(entry)
    assert any("loading" in (s["type"] or "").lower() for s in screens)


def test_media_urls_resolve_on_the_host_media_url_picks(api, entry):
    """The one request that proves the two-host split is still right.

    A screen path and a tape path go to different hosts, and each host 404s
    the other's paths -- so fetching one screen through media_url() is a real
    check, not a formality.
    """
    screen = next(s for s in api.screens(entry) if s["url"])
    data = api.fetch(screen["url"])
    assert data[:4] in (b"\x89PNG", b"GIF8"), "screen is neither PNG nor GIF"


def test_filecheck_recognises_a_hash_zxdb_holds(api, entry, tmp_path):
    """Download the tape ZXDB offers, and check ZXDB then recognises it.

    Round-tripping like this covers the whole chain in one go: the archive
    host, the .zip unwrapping, and that /filecheck hashes the file inside the
    archive rather than the archive itself.
    """
    tape = api.tape_files(entry)[0]
    path = api.download(tape["url"], tmp_path)
    assert path.suffix.lower() in (".tzx", ".tap")
    found = api.identify_file(path)
    assert found["found"], f"ZXDB does not recognise its own {path.name}"
    assert found["matched_by"] in ("md5", "sha512")
