"""Entrypoint: starts the engine, the MCP server, and the DAP server on one
asyncio event loop -- VS Code (DAP) and MCP clients drive the same live
Spectrum48K instance concurrently.
"""
from __future__ import annotations

import argparse
import asyncio

from zxspectrum.engine.actor import Engine
from zxspectrum.server.dap import create_dap_server
from zxspectrum.server.mcp_server import create_server


async def amain(mcp_host: str, mcp_port: int, dap_host: str, dap_port: int) -> None:
    engine = Engine()
    engine.start()
    mcp_server = create_server(engine)
    dap_server = await create_dap_server(engine, host=dap_host, port=dap_port)
    try:
        async with dap_server:
            await asyncio.gather(
                dap_server.serve_forever(),
                mcp_server.run_sse_async(host=mcp_host, port=mcp_port),
            )
    finally:
        await engine.stop()


def main() -> None:
    parser = argparse.ArgumentParser(description="ZX Spectrum emulator: MCP + DAP servers")
    parser.add_argument("--mcp-host", default="127.0.0.1")
    parser.add_argument("--mcp-port", type=int, default=8000)
    parser.add_argument("--dap-host", default="127.0.0.1")
    parser.add_argument("--dap-port", type=int, default=4711)
    args = parser.parse_args()
    asyncio.run(amain(args.mcp_host, args.mcp_port, args.dap_host, args.dap_port))


if __name__ == "__main__":
    main()
