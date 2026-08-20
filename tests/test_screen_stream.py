"""server/screen_stream.py: exercised over a real asyncio TCP connection."""
import asyncio
import io
import struct

from PIL import Image as PILImage

from zxspectrum.engine import commands as cmd
from zxspectrum.engine.actor import Engine
from zxspectrum.server.screen_stream import create_screen_stream_server


def _run(coro):
    return asyncio.run(coro)


async def _read_frame(reader: asyncio.StreamReader) -> bytes:
    length_bytes = await reader.readexactly(4)
    (length,) = struct.unpack(">I", length_bytes)
    return await reader.readexactly(length)


def test_stream_pushes_valid_png_frames_at_the_expected_size():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_screen_stream_server(engine, port=0, frame_interval=0.01)
        port = server.sockets[0].getsockname()[1]
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            try:
                for _ in range(2):
                    frame = await asyncio.wait_for(_read_frame(reader), timeout=2)
                    img = PILImage.open(io.BytesIO(frame))
                    assert img.format == "PNG"
                    assert img.size == (256, 192)
            finally:
                writer.close()
        finally:
            server.close()
            await engine.stop()

    _run(scenario())


def test_one_client_disconnecting_does_not_affect_another():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_screen_stream_server(engine, port=0, frame_interval=0.01)
        port = server.sockets[0].getsockname()[1]
        try:
            reader_a, writer_a = await asyncio.open_connection("127.0.0.1", port)
            await asyncio.wait_for(_read_frame(reader_a), timeout=2)
            writer_a.close()
            await writer_a.wait_closed()

            # A second, independent client must still be served fine --
            # same guarantee dap.py already has for multiple DapConnections,
            # now proven for this server too.
            reader_b, writer_b = await asyncio.open_connection("127.0.0.1", port)
            try:
                frame = await asyncio.wait_for(_read_frame(reader_b), timeout=2)
                img = PILImage.open(io.BytesIO(frame))
                assert img.size == (256, 192)
            finally:
                writer_b.close()
        finally:
            server.close()
            await engine.stop()

    _run(scenario())


def test_multiple_simultaneous_clients_each_get_frames():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_screen_stream_server(engine, port=0, frame_interval=0.01)
        port = server.sockets[0].getsockname()[1]
        try:
            reader_a, writer_a = await asyncio.open_connection("127.0.0.1", port)
            reader_b, writer_b = await asyncio.open_connection("127.0.0.1", port)
            try:
                frame_a = await asyncio.wait_for(_read_frame(reader_a), timeout=2)
                frame_b = await asyncio.wait_for(_read_frame(reader_b), timeout=2)
                assert PILImage.open(io.BytesIO(frame_a)).size == (256, 192)
                assert PILImage.open(io.BytesIO(frame_b)).size == (256, 192)
            finally:
                writer_a.close()
                writer_b.close()
        finally:
            server.close()
            await engine.stop()

    _run(scenario())


def test_stream_still_delivers_frames_while_a_run_is_in_progress():
    # Regression test for a real bug found via the live VS Code viewer: the
    # screen panel froze completely during run() and only caught up once it
    # stopped. Root cause was _encode_frame() going through
    # engine.get_screen()'s QUEUED command -- Run's handler occupies the
    # actor loop's single _handle() call for the run's entire duration, so a
    # queued GetScreen sits unserved until Run returns. Fixed by reading
    # engine.machine.render_screen() directly (a synchronous, read-only
    # computation, same queue-bypass-for-reads pattern dap.py's
    # _read_memory_sync already uses). This test would hang and time out
    # against the old queued implementation.
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_screen_stream_server(engine, port=0, frame_interval=0.01)
        port = server.sockets[0].getsockname()[1]
        try:
            # memory is all zero -> free-running NOPs forever, so only
            # pause() can stop it -- same setup as
            # test_engine.py's test_pause_interrupts_a_run_in_progress_from_another_task.
            sub = engine.subscribe()
            run_task = asyncio.create_task(engine.run())
            event = await asyncio.wait_for(sub.get(), timeout=2)
            assert isinstance(event, cmd.Continued)

            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            try:
                frame = await asyncio.wait_for(_read_frame(reader), timeout=2)
                assert PILImage.open(io.BytesIO(frame)).size == (256, 192)
            finally:
                writer.close()

            await engine.pause()
            await asyncio.wait_for(run_task, timeout=2)
        finally:
            server.close()
            await engine.stop()

    _run(scenario())
