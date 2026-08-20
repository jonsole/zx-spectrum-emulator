"""Raw TCP screen-frame streaming server: pushes the live display as a
continuous sequence of length-prefixed PNG frames to any connected client.

A plain asyncio TCP server, structurally identical to dap.py's
create_dap_server() -- one more independent front-end onto the shared
Engine, no different in kind from DAP or MCP. It has no VS-Code-specific
code in it: the VS Code extension (vscode-extension/extension.js) is just
one client of this port, bridging frames into a webview panel via
postMessage since a webview's own JS can't open a raw socket -- but any
other client (a script, a future standalone viewer) can connect directly
and read the same stream.

Framing is a fixed 4-byte big-endian length prefix followed by that many
PNG bytes, repeated for as long as the client stays connected -- simpler
than dap.py's Content-Length text header since there's no need for named
fields here, just "how many bytes is the next frame."
"""
from __future__ import annotations

import asyncio
import io
import struct

from PIL import Image as PILImage

from zxspectrum.engine.actor import Engine

FRAME_INTERVAL = 0.1  # seconds -- 10fps, plenty for a debugging aid, not real-time gameplay


def _encode_frame(engine: Engine) -> bytes:
    # Reads engine.machine directly rather than going through
    # engine.get_screen()'s queued command -- Run's handler occupies the
    # actor loop's single _handle() call for its entire duration (only
    # returning once it stops), so a QUEUED command sits unserved until
    # then. That made the live view freeze completely during a run() and
    # only catch up once it paused -- confirmed live, not just in theory.
    # render_screen() is a synchronous, read-only computation with no
    # awaits in it, so calling it directly can't interleave with or
    # corrupt whatever the actor loop is doing mid-instruction -- same
    # queue-bypass-for-reads pattern dap.py's _read_memory_sync already
    # uses for exactly this reason.
    rgb = engine.machine.render_screen()
    buf = io.BytesIO()
    PILImage.fromarray(rgb, mode="RGB").save(buf, format="PNG")
    return buf.getvalue()


async def create_screen_stream_server(
    engine: Engine, host: str = "127.0.0.1", port: int = 8500, frame_interval: float = FRAME_INTERVAL
):
    async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                frame = _encode_frame(engine)
                writer.write(struct.pack(">I", len(frame)) + frame)
                await writer.drain()
                await asyncio.sleep(frame_interval)
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()

    return await asyncio.start_server(handle_client, host, port)
