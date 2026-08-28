"""Minimal, reusable MCP client for reading/driving a zx-server instance's
`get_state`/`get_registers`/`step`/`read_memory`/etc. tools -- simpler than
`dap_client.py` for pure state inspection or single-instruction stepping,
but has no `next`/step-over semantics (those only exist in the DAP layer).

Usage:
    import asyncio
    from mcp_client import McpClient

    async def main():
        async with McpClient.connect("http://127.0.0.1:18000/mcp") as client:
            state = await client.call("get_state")
            print(state["pc"], state["halted"])

    asyncio.run(main())

Requires the `mcp` package -- already present in this repo's
`.venv-win` (run scripts with that interpreter, not a bare `python`).

Prefer this over hand-rolling an HTTP POST for anything carrying a large
payload: a base64-encoded .sna through PowerShell's ConvertTo-Json arrives
mangled, and `load_snapshot` then reports success over a machine that never
actually loaded.
"""

import json
from contextlib import asynccontextmanager

from mcp import ClientSession
# NOTE: the importable name is `streamable_http_client`, not
# `streamablehttp_client` -- easy to get wrong from memory, confirmed
# against the installed package this session after an ImportError. It
# returns a 2-tuple `(read, write)`, not a 3-tuple -- a 3-tuple unpack
# raises `ValueError: not enough values to unpack` on this package version.
from mcp.client.streamable_http import streamable_http_client


class McpClient:
    def __init__(self, session):
        self.session = session

    @staticmethod
    @asynccontextmanager
    async def connect(url="http://127.0.0.1:18000/mcp"):
        async with streamable_http_client(url) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                yield McpClient(session)

    async def call(self, tool_name, arguments=None):
        """Calls an MCP tool and returns its parsed JSON result (or the raw
        text if it isn't JSON, e.g. `text_result` responses like "paused")."""
        result = await self.session.call_tool(tool_name, arguments or {})
        text = result.content[0].text
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text
