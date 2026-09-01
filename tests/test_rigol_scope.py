"""Drive tools/rigol/scope.py against a fake SCPI instrument.

There is no scope on the bench during a test run, so this stands up a
socket server that answers the handful of commands the driver relies on
-- including a chunked :WAV:DATA? -- and checks the parts that are easy
to get wrong: IEEE 488.2 block framing, deep-memory chunking, and the
preamble arithmetic that turns raw bytes into volts and seconds.
"""

from __future__ import annotations

import socket
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "rigol"))

from scope import RigolScope, ScopeError  # noqa: E402

# 8 bits/div, 0 V at code 128, 1 MSa/s starting 1 ms before the trigger.
PREAMBLE = "0,0,1200,1,1e-06,-0.001,0,0.04,0,128"
IDN = "RIGOL TECHNOLOGIES,MSO5074,MS5A000000001,00.01.02.03.04"

# Deliberately smaller than the driver's 250k chunk cap so the test can
# force a multi-chunk read without moving megabytes around.
CHUNK = 500


def block(payload: bytes) -> bytes:
    digits = str(len(payload)).encode()
    return b"#" + str(len(digits)).encode() + digits + payload + b"\n"


def bmp_bytes() -> bytes:
    """A real (tiny) 24-bit BMP, as the scope's screenshot always is."""
    import io

    from PIL import Image as PILImage

    buffer = io.BytesIO()
    PILImage.new("RGB", (8, 4), (10, 20, 30)).save(buffer, format="BMP")
    return buffer.getvalue()


class FakeScope:
    """A socket that speaks just enough SCPI to exercise the driver."""

    def __init__(self, points: int = 1200):
        self.points = points
        self.commands: list[str] = []
        self.start = 1
        self.stop = points
        self.logic: dict[str, bool] = {}
        self.thresholds: dict[str, float] = {}
        self.errors: list[str] = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        try:
            conn, _ = self.listener.accept()
        except OSError:
            return
        buf = b""
        with conn:
            while True:
                try:
                    chunk = conn.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, _, buf = buf.partition(b"\n")
                    reply = self._reply(line.decode().strip())
                    if reply is not None:
                        conn.sendall(reply)

    def _reply(self, command: str) -> bytes | None:
        self.commands.append(command)
        if command.startswith(":WAV:STAR"):
            self.start = int(command.split()[1])
            return None
        if command.startswith(":WAV:STOP"):
            self.stop = int(command.split()[1])
            return None
        if command == "*IDN?":
            return IDN.encode() + b"\n"
        if command == ":WAV:PRE?":
            return PREAMBLE.encode() + b"\n"
        if command == ":WAV:DATA?":
            # Ramp of sample index mod 256, capped like the real scope caps
            # a single transfer, so the driver has to come back for more.
            stop = min(self.stop, self.start + CHUNK - 1)
            return block(bytes((i - 1) % 256 for i in range(self.start, stop + 1)))
        if command == ":DISP:DATA?":
            # Real firmware ignores any format argument and always sends BMP.
            return block(bmp_bytes())
        if command == ":SYST:ERR?":
            # A FIFO, exactly like the real one: one pop per query.
            if self.errors:
                return self.errors.pop(0).encode() + b"\n"
            return b'0,"No error"\n'
        if command.startswith(":LA:DISP? "):
            return b"1\n" if self.logic.get(command.split()[-1]) else b"0\n"
        if command.startswith(":LA:DISP "):
            channel, _, state = command.split(None, 1)[1].partition(",")
            self.logic[channel] = state == "ON"
            return None
        if command.startswith(":LA:POD"):
            pod = command[len(":LA:POD")]
            if command.endswith(":THR?"):
                return f"{self.thresholds.get(pod, 0.0):E}".encode() + b"\n"
            self.thresholds[pod] = float(command.split()[1])
            return None
        # The real firmware rejects the channel-in-mnemonic form outright.
        if command.startswith(":LA:DIG"):
            self.errors.append('-104,"Data type err"')
            return None
        if command.startswith(":MEAS:ITEM?"):
            return b"3.28\n"
        # A query need not end in '?' -- most carry arguments after it.
        if "?" in command:
            return b"0\n"
        return None

    def close(self) -> None:
        self.listener.close()


@pytest.fixture
def fake():
    server = FakeScope()
    yield server
    server.close()


@pytest.fixture
def scope(fake):
    scope = RigolScope("127.0.0.1", fake.port, timeout=5.0)
    yield scope
    scope.close()


def test_identify_splits_the_idn_reply(scope):
    assert scope.identify()["model"] == "MSO5074"
    assert scope.identify()["vendor"] == "RIGOL TECHNOLOGIES"


def test_screenshot_unwraps_the_binary_block(scope, fake):
    assert scope.screenshot().startswith(b"BM")
    # Asking for a format is pointless -- the firmware ignores it either way.
    assert fake.commands.count(":DISP:DATA?") == 1


def test_screenshot_is_converted_to_png_for_the_client():
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "rigol"))
    from mcp_server import to_png

    png = to_png(bmp_bytes())
    assert png.startswith(b"\x89PNG")
    assert to_png(png) is png  # already-PNG data is passed straight through


def test_capture_walks_deep_memory_in_chunks(scope, fake):
    times, volts, pre = scope.capture("CHAN1", mode="RAW")

    assert pre.points == 1200
    assert volts.size == 1200
    # 1200 points at 500 per transfer is three round trips, not one.
    assert fake.commands.count(":WAV:DATA?") == 3
    # Raw code 128 is the preamble's y-reference, i.e. 0 V; 129 is +40 mV.
    assert volts[128] == pytest.approx(0.0, abs=1e-9)
    assert volts[129] == pytest.approx(0.04)
    # Samples 1 us apart, the first one 1 ms before the trigger.
    assert times[0] == pytest.approx(-0.001)
    assert times[1] - times[0] == pytest.approx(1e-06)


def test_capture_honours_a_point_limit(scope, fake):
    _, volts, _ = scope.capture("CHAN1", mode="RAW", points=700)

    assert volts.size == 700
    assert fake.commands.count(":WAV:DATA?") == 2
    assert ":STOP" in fake.commands  # RAW reads need the scope stopped


def test_measure_reads_a_value_back(scope, fake):
    assert scope.measure("vpp", "chan1") == pytest.approx(3.28)
    assert ":MEAS:ITEM? VPP,CHAN1" in fake.commands


def test_measure_maps_the_invalid_marker_to_none(scope, monkeypatch):
    monkeypatch.setattr(scope.scpi, "query", lambda command, timeout=None: "9.9e37")
    assert scope.measure("VPP", "CHAN1") is None


def test_setup_logic_puts_the_channel_in_the_argument(scope, fake):
    scope.setup_logic(channels=[0, 3], enabled=True, threshold=1.4)

    assert ":LA:DISP D0,ON" in fake.commands
    assert ":LA:DISP D3,ON" in fake.commands
    # :LA:DIG<n>:DISP is the form the scope rejects as -104 "Data type err".
    assert not any(c.startswith(":LA:DIG") for c in fake.commands)


def test_logic_state_reports_the_scope_not_the_request(scope):
    scope.setup_logic(channels=[0, 1], enabled=True, threshold=1.4)
    scope.setup_logic(channels=[1], enabled=False)

    state = scope.logic_state([0, 1])
    assert state["displayed"] == {"D0": True, "D1": False}
    assert state["pod1_threshold_v"] == pytest.approx(1.4)
    assert state["pod2_threshold_v"] == pytest.approx(1.4)


def test_drain_errors_empties_a_backlogged_queue(scope, fake):
    fake.errors = ['-104,"Data type err"', '-100,"Command err"']

    assert scope.drain_errors() == ['-104,"Data type err"', '-100,"Command err"']
    # Next read is now about whatever runs next, not the backlog.
    assert scope.last_error().startswith("0,")


def test_concurrent_callers_do_not_interleave(scope):
    """Four threads, four multi-chunk reads, one socket.

    The MCP server runs every tool on a worker thread against a single
    shared connection, so without a lock these conversations interleave
    and each caller parses somebody else's reply. Each read here spans
    more than one chunk, which is exactly where that goes wrong.
    """
    results: dict[int, list[float]] = {}
    failures: list[Exception] = []

    def grab(points: int) -> None:
        try:
            _, volts, _ = scope.capture("CHAN1", mode="RAW", points=points)
            results[points] = volts.tolist()
        except Exception as exc:  # noqa: BLE001 -- the test is what it reports
            failures.append(exc)

    sizes = [600, 700, 800, 900]
    threads = [threading.Thread(target=grab, args=(n,)) for n in sizes]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=20)

    assert not failures, failures
    for n in sizes:
        # The fake's ramp is sample index mod 256, scaled by the preamble.
        expected = [((i % 256) - 128) * 0.04 for i in range(n)]
        assert results[n] == pytest.approx(expected), f"{n}-point read came back wrong"


def test_unreachable_address_is_a_scope_error():
    scope = RigolScope("127.0.0.1", 1, timeout=0.5)
    with pytest.raises(ScopeError, match="cannot reach"):
        scope.identify()
