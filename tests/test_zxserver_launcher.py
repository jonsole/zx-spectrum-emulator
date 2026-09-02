"""Adopt-or-spawn logic for the zx_server MCP launcher.

The proxying itself is the SDK's job and needs a real emulator to mean
anything; what is worth testing here is the part that decides whether to start
one -- and, more importantly, what it is allowed to stop again. Killing a
server that belongs to somebody's debug session is the failure this guards
against, so ownership is asserted in both directions.

The fake server is a couple of lines of Python that open a socket: enough to
be adopted, to be waited for, and to be killed.
"""

from __future__ import annotations

import socket
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "zxserver"))

from mcp_server import LauncherError, Upstream  # noqa: E402

# Opens the port after a beat, then sits there. The delay is the point: it
# makes ensure() actually wait rather than happening to find the port open.
FAKE_SERVER = """
import socket, sys, time
time.sleep(0.4)
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
# Accepts and drops, as zx_server does. A fake that only listens would let one
# probe through and refuse the next once the backlog filled, which reads as a
# server that died rather than one nobody is talking to.
while True:
    conn, _ = s.accept()
    conn.close()
"""

FAKE_SERVER_THAT_DIES = """
import sys
sys.stderr.write("couldn't read ROM\\n")
raise SystemExit(3)
"""

FAKE_SERVER_THAT_NEVER_LISTENS = """
import time
time.sleep(60)
"""


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class FakeUpstream(Upstream):
    """An Upstream that runs a Python script instead of zx_server.exe."""

    def __init__(self, script: Path, tmp_path: Path, port: int, **kwargs):
        super().__init__(exe=script, host="127.0.0.1", port=port, extra_args=[],
                         log_path=tmp_path / "server.log", startup_timeout=5.0, **kwargs)
        self.script = script

    def command(self) -> list[str]:
        return [sys.executable, str(self.script), str(self.port)]


def write_script(tmp_path: Path, name: str, body: str) -> Path:
    path = tmp_path / name
    path.write_text(body, encoding="utf-8")
    return path


@pytest.fixture
def listener():
    """Something already on a port -- the stand-in for a running server."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    # Backlog room to spare: is_listening() probes by connecting and never
    # accepts, so a listen(1) here would refuse the second probe of a test and
    # look exactly like a server that had gone away.
    sock.listen(16)
    try:
        yield sock, sock.getsockname()[1]
    finally:
        sock.close()


def test_an_already_running_server_is_adopted_not_started(listener, tmp_path):
    sock, port = listener
    script = write_script(tmp_path, "fake.py", FAKE_SERVER)
    upstream = FakeUpstream(script, tmp_path, port)

    upstream.ensure()

    # Nothing was started, so there is nothing of ours to stop.
    assert upstream.process is None
    assert upstream.we_spawned_it() is False
    assert upstream.status()["owned_by_this_proxy"] is False
    assert "adopted" in upstream.status()["note"]


def test_shutdown_leaves_an_adopted_server_alone(listener, tmp_path):
    sock, port = listener
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    upstream.ensure()

    upstream.shutdown()

    # Still there. This is the debug session's server, and stopping it from
    # here would take the machine out from under whoever is using it.
    assert upstream.is_listening()


def test_nothing_listening_starts_a_server_and_waits_for_the_port(tmp_path):
    port = free_port()
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    try:
        upstream.ensure()
        assert upstream.is_listening()
        assert upstream.we_spawned_it() is True
        assert upstream.status()["pid"] == upstream.process.pid
    finally:
        upstream.shutdown()


def test_shutdown_stops_a_server_we_started(tmp_path):
    port = free_port()
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    upstream.ensure()

    upstream.shutdown()

    assert upstream.process is None
    # Give the OS a moment to release the port before asking.
    for _ in range(20):
        if not upstream.is_listening():
            break
        time.sleep(0.1)
    assert not upstream.is_listening()


def test_ensure_is_idempotent(tmp_path):
    port = free_port()
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    try:
        upstream.ensure()
        first = upstream.process.pid
        upstream.ensure()
        assert upstream.process.pid == first  # adopted its own, did not start a second
    finally:
        upstream.shutdown()


def test_a_server_that_dies_immediately_is_reported_with_its_log(tmp_path):
    port = free_port()
    upstream = FakeUpstream(
        write_script(tmp_path, "dies.py", FAKE_SERVER_THAT_DIES), tmp_path, port)
    with pytest.raises(LauncherError) as caught:
        upstream.ensure()
    assert "exited immediately" in str(caught.value)
    assert str(upstream.log_path) in str(caught.value)
    # And the reason it died is in that file, not swallowed.
    assert "couldn't read ROM" in upstream.log_path.read_text(encoding="utf-8")


def test_a_server_that_never_listens_times_out(tmp_path):
    port = free_port()
    upstream = FakeUpstream(
        write_script(tmp_path, "quiet.py", FAKE_SERVER_THAT_NEVER_LISTENS), tmp_path, port)
    upstream.startup_timeout = 1.0
    try:
        with pytest.raises(LauncherError) as caught:
            upstream.ensure()
        assert "did not open" in str(caught.value)
    finally:
        upstream.shutdown()


def test_no_spawn_refuses_rather_than_starting_one(tmp_path):
    port = free_port()
    upstream = FakeUpstream(
        write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port, allow_spawn=False)
    with pytest.raises(LauncherError) as caught:
        upstream.ensure()
    assert "--no-spawn" in str(caught.value)


def test_a_missing_executable_says_how_to_build_it(tmp_path):
    upstream = FakeUpstream(tmp_path / "not-built.exe", tmp_path, free_port())
    with pytest.raises(LauncherError) as caught:
        upstream.ensure()
    assert "build.ps1" in str(caught.value)


def test_restart_will_not_stop_a_server_it_does_not_own(listener, tmp_path):
    sock, port = listener
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    upstream.ensure()  # adopts

    with pytest.raises(LauncherError) as caught:
        upstream.restart()
    assert "not started by me" in str(caught.value)
    assert upstream.is_listening()


def test_restart_replaces_a_server_it_does_own(tmp_path):
    port = free_port()
    upstream = FakeUpstream(write_script(tmp_path, "fake.py", FAKE_SERVER), tmp_path, port)
    try:
        upstream.ensure()
        first = upstream.process.pid
        message = upstream.restart()
        assert upstream.process.pid != first
        assert upstream.is_listening()
        assert str(upstream.process.pid) in message
    finally:
        upstream.shutdown()


def test_the_real_command_line_carries_the_port_and_extra_args(tmp_path):
    upstream = Upstream(exe=Path("zx_server.exe"), host="127.0.0.1", port=8123,
                        extra_args=["--rom", "roms/48.rom", "--no-audio"],
                        log_path=tmp_path / "log")
    assert upstream.command() == [
        "zx_server.exe", "--mcp-port", "8123", "--rom", "roms/48.rom", "--no-audio",
    ]
