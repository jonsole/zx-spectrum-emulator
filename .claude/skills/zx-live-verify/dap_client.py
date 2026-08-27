"""Minimal, reusable DAP (Debug Adapter Protocol) client for driving a
zx-server instance live, the same protocol VS Code speaks to it.

Built from real usage debugging rust-core/zx-server's `next`-over-HALT and
interrupt-pulse bugs: the two gotchas baked in here (settle-based
`wait_for_settled_stop`, explicit process/port lifecycle in the skill that
uses this) were each the direct cause of a wasted debugging detour.

Usage:
    import asyncio
    from dap_client import DapClient

    async def main():
        client = await DapClient.connect("127.0.0.1", 14711)
        await client.initialize()
        await client.launch(rom="roms/48.rom", snapshot="path/to/test.sna")
        await client.request("configurationDone")

        regs = await client.registers()
        print(regs["PC"])

        await client.request("next", {"threadId": 1})
        regs = await client.wait_for_settled_stop()
        print(regs["PC"], regs["BC"])

        client.close()

    asyncio.run(main())
"""

import asyncio
import json


class DapClient:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.seq = 0
        self.events = []

    @classmethod
    async def connect(cls, host="127.0.0.1", port=14711):
        reader, writer = await asyncio.open_connection(host, port)
        return cls(reader, writer)

    def close(self):
        self.writer.close()

    # ---- base protocol -----------------------------------------------

    async def _send(self, command, arguments=None):
        self.seq += 1
        msg = {"seq": self.seq, "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        body = json.dumps(msg).encode()
        self.writer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        await self.writer.drain()
        return self.seq

    async def _recv(self):
        headers = {}
        while True:
            line = await self.reader.readline()
            if not line:
                raise ConnectionError("DAP connection closed while reading a message")
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
        length = int(headers["content-length"])
        body = await self.reader.readexactly(length)
        return json.loads(body)

    async def request(self, command, arguments=None):
        """Send a request and return its response body. Any events seen
        while waiting are queued (see `events`, `wait_for_settled_stop`)."""
        my_seq = await self._send(command, arguments)
        while True:
            msg = await self._recv()
            if msg.get("type") == "event":
                self.events.append(msg)
                continue
            if msg.get("type") == "response" and msg.get("request_seq") == my_seq:
                if not msg.get("success", True):
                    raise RuntimeError(f"{command} failed: {msg.get('message')}")
                return msg.get("body", {})

    # ---- convenience wrappers -----------------------------------------

    async def initialize(self):
        return await self.request("initialize", {})

    async def launch(self, rom, snapshot=None, sld=None, asm=None):
        args = {"rom": rom}
        if snapshot:
            args["snapshot"] = snapshot
        if sld:
            args["sld"] = sld
        if asm:
            args["asm"] = asm
        return await self.request("launch", args)

    async def registers(self):
        """Register/flag values as {name: value_string} via scopes+variables
        (matches what VS Code's own Variables pane shows)."""
        await self.request("scopes", {"frameId": 0})
        r = await self.request("variables", {"variablesReference": 1000})
        return {v["name"]: v["value"] for v in r["variables"]}

    # ---- events ---------------------------------------------------------

    async def _next_event(self, timeout):
        while True:
            for i, e in enumerate(self.events):
                return self.events.pop(i)
            msg = await asyncio.wait_for(self._recv(), timeout=timeout)
            if msg.get("type") == "event":
                return msg
            # a stray response to an already-answered request; ignore

    async def wait_for_settled_stop(self, timeout=15.0, settle_delay=0.3, max_settle_checks=8):
        """Waits for a `stopped` event, THEN confirms the machine has
        actually stopped changing before trusting it.

        Several `next` cases in this server's DAP layer (CALL/RST, the
        block-repeat instructions, HALT) do their real work in a spawned
        background task and reply to the request immediately -- and a real,
        reproducible quirk found debugging this exact server is that the
        FIRST `stopped` event received afterward can be a stray/delayed one
        from an earlier, already-completed step, arriving out of order
        relative to the real one for THIS step. Trusting that first event's
        own payload (e.g. its `description`) directly is unsafe.

        The robust fix used here: wait for a `stopped` event (any reason),
        then re-read live register state repeatedly with a short delay
        between reads until it stops changing (or `max_settle_checks` is
        hit) -- the machine's true state once the current background
        command actually finishes, regardless of which event arrived when.
        Returns the settled `registers()` dict.
        """
        await self._next_event(timeout)
        last = await self.registers()
        for _ in range(max_settle_checks):
            await asyncio.sleep(settle_delay)
            current = await self.registers()
            if current == last:
                return current
            last = current
        return last

    async def drain_events(self):
        """Discards any queued/unread events -- call after a `continue`
        you don't intend to wait on, so a later `wait_for_settled_stop`
        doesn't pick up something stale."""
        self.events.clear()
