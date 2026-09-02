"""An MCP server that starts zx_server.exe on demand and proxies to it.

The emulator's own MCP endpoint is served by a running `zx_server.exe`, so an
MCP client configured to talk to `http://127.0.0.1:8000/mcp` directly fails at
startup whenever the emulator happens not to be running -- and MCP clients
connect once, so that failure lasts the whole session.

This sits in front of it over stdio, where the CLIENT launches the process, and
makes the emulator's absence a non-event:

    adopt   something is already listening on the MCP port -- use it, and
            never kill it. That is the VS Code debug session's server, or one
            the user started by hand.
    spawn   nothing is listening -- start zx_server.exe, wait for the port,
            and kill it again when this process exits.

Tools are NOT redeclared here. `tools/list` and `tools/call` are forwarded
upstream verbatim, so the C++ server stays the single definition of what the
emulator can do and this file never goes stale against it. The only tools
added are the two it alone can answer -- `server_status` and `restart_server`.

Note that the emulator starts when an MCP client first asks for the tool list,
which for most clients is at connect. That is deliberate and safe: a fresh
`zx_server` sits paused, using no CPU, and VS Code's own launch kills every
running server before starting its own (see .vscode/tasks.json), so holding
the port cannot block a debug session.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import mcp.types as types
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_EXE = REPO_ROOT / "cpp-core" / "build" / "RelWithDebInfo" / "zx_server.exe"
DEFAULT_ROM = REPO_ROOT / "roms" / "48.rom"
DEFAULT_PORT = 8000
DEFAULT_HOST = "127.0.0.1"
# Generous: a cold start has to load the ROM and its disassembly before it
# listens. Exceeded only when something is actually wrong.
STARTUP_TIMEOUT_S = 20.0
# How often to re-test the port while waiting for a spawn to come up.
POLL_INTERVAL_S = 0.1


class LauncherError(Exception):
    """The emulator could not be reached, and could not be started either."""


class Upstream:
    """The one zx_server this proxy talks to, started if it has to be."""

    def __init__(self, exe: Path, host: str, port: int, extra_args: list[str],
                 log_path: Path, allow_spawn: bool = True,
                 startup_timeout: float = STARTUP_TIMEOUT_S):
        self.exe = exe
        self.host = host
        self.port = port
        self.extra_args = extra_args
        self.log_path = log_path
        self.allow_spawn = allow_spawn
        self.startup_timeout = startup_timeout
        self.process: subprocess.Popen | None = None

    def command(self) -> list[str]:
        """The command line for a server of our own.

        Its own method so a test can stand in a fake server without having to
        intercept subprocess itself -- what the tests are about is the waiting
        and the ownership, not which executable gets run.
        """
        return [str(self.exe), "--mcp-port", str(self.port), *self.extra_args]

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}/mcp"

    def is_listening(self) -> bool:
        """Whether anything at all has the MCP port open."""
        with contextlib.closing(socket.socket()) as probe:
            probe.settimeout(0.4)
            return probe.connect_ex((self.host, self.port)) == 0

    def we_spawned_it(self) -> bool:
        """True while the server running is one this process started."""
        return self.process is not None and self.process.poll() is None

    def ensure(self) -> None:
        """Adopt whatever is listening, or start one. Idempotent."""
        if self.is_listening():
            return
        # A server we started earlier but is now gone -- VS Code's launch kills
        # every zx_server before starting its own, so this is routine rather
        # than exceptional. Forget it and start again.
        self.process = None
        if not self.allow_spawn:
            raise LauncherError(
                f"nothing is listening on {self.host}:{self.port} and --no-spawn is set; "
                "start zx_server yourself, or drop the flag")
        if not self.exe.is_file():
            raise LauncherError(
                f"{self.exe} does not exist -- build it first:\n"
                "    cd cpp-core; .\\build.ps1 -Release")

        # Its output goes to a file rather than to our stdout, which belongs to
        # the MCP protocol and would be corrupted by a stray line of logging.
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        log = open(self.log_path, "wb")
        self.process = subprocess.Popen(
            self.command(), cwd=str(REPO_ROOT), stdout=log, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL)

        deadline = time.monotonic() + self.startup_timeout
        while time.monotonic() < deadline:
            if self.is_listening():
                return
            if self.process.poll() is not None:
                raise LauncherError(
                    f"zx_server exited immediately (code {self.process.returncode}). "
                    f"Its output is in {self.log_path}")
            time.sleep(POLL_INTERVAL_S)
        raise LauncherError(
            f"zx_server did not open {self.host}:{self.port} within {self.startup_timeout:.0f}s. "
            f"Its output is in {self.log_path}")

    def restart(self) -> str:
        """Stop a server we own and start a fresh one.

        Only ever stops our own: an adopted server belongs to a debug session
        or to whoever started it, and taking that away from underneath them is
        not this process's call. Killing it is one line in a terminal if that
        is really what is wanted.
        """
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process = None
        elif self.is_listening():
            raise LauncherError(
                "the server on this port was not started by me -- it belongs to a debug "
                "session or was started by hand, so I will not stop it")
        self.ensure()
        return f"started {self.exe.name} (pid {self.process.pid if self.process else '?'})"

    def status(self) -> dict:
        listening = self.is_listening()
        return {
            "listening": listening,
            "url": self.url,
            "owned_by_this_proxy": self.we_spawned_it(),
            "pid": self.process.pid if self.we_spawned_it() else None,
            "executable": str(self.exe),
            "executable_exists": self.exe.is_file(),
            "extra_args": self.extra_args,
            "server_log": str(self.log_path) if self.we_spawned_it() else None,
            "note": (
                "adopted: started by a debug session or by hand, and not mine to stop"
                if listening and not self.we_spawned_it()
                else "spawned on demand by the MCP launcher" if listening
                else "not running -- the next tool call will start it"),
        }

    def shutdown(self) -> None:
        """Stops only a server this process started. Adopted ones are left."""
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.process.wait(timeout=5)
            if self.process.poll() is None:
                self.process.kill()
        self.process = None


async def ask_upstream(upstream: Upstream, action):
    """Run `action(session)` against the emulator, starting it if it is not up.

    Two things are deliberate here.

    A short-lived session per request, rather than one held open. The server
    can disappear between two calls -- a VS Code launch kills every running
    zx_server before starting its own, and a rebuild replaces the executable
    -- and a cached session would then hold a dead socket and a session id
    the new process has never heard of. Reconnecting costs two local round
    trips and removes that whole class of failure.

    And connecting is the liveness test: no separate "is it up?" probe on the
    happy path. A probe would be a second TCP connection per tool call, and
    zx_server gives every connection a thread, so probing to avoid an error
    would quietly cost more than the error does.
    """
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            async with streamable_http_client(upstream.url) as (read, write, *_):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    return await action(session)
        except Exception as error:  # noqa: BLE001 -- see below
            # Deliberately wide. A refused connection surfaces from inside the
            # transport's task group, so it arrives wrapped in an
            # ExceptionGroup whose contents vary with the httpx and anyio
            # versions underneath; pinning the type here would break quietly
            # on an upgrade. What matters is the same either way: the emulator
            # did not answer, so start one and try once more.
            last_error = error
            if attempt == 1:
                break
            upstream.ensure()  # raises LauncherError if it cannot
    raise LauncherError(f"{upstream.url} did not answer, and starting a server did not "
                        f"help: {last_error}")


def build_server(upstream: Upstream) -> Server:
    # Tools this layer owns. Named so they cannot collide with the emulator's
    # own -- those are all about the machine, these are about the process.
    LAUNCHER_TOOLS = [
        types.Tool(
            name="server_status",
            description=(
                "Whether the emulator is running, and whether this MCP launcher started it "
                "or adopted one that was already there (a VS Code debug session, or one "
                "started by hand). Also reports where the executable is and where its log "
                "went."),
            input_schema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="restart_server",
            description=(
                "Stop the emulator this launcher started and start a fresh one -- the way "
                "to pick up a rebuilt zx_server.exe, or to get back to a clean machine. "
                "Refuses when the running server was not started by this launcher, since "
                "that one belongs to a debug session."),
            input_schema={"type": "object", "properties": {}},
        ),
    ]

    def text(message: str) -> types.CallToolResult:
        return types.CallToolResult(content=[types.TextContent(type="text", text=message)])

    def failure(message: str) -> types.CallToolResult:
        return types.CallToolResult(
            content=[types.TextContent(type="text", text=message)], is_error=True)

    async def on_list_tools(ctx, params) -> types.ListToolsResult:
        # The emulator's own list, plus this layer's two. Fetched rather than
        # copied, so a tool added to mcp_server.cpp shows up here with no
        # change to this file.
        try:
            found = await ask_upstream(upstream, lambda session: session.list_tools())
            return types.ListToolsResult(tools=[*found.tools, *LAUNCHER_TOOLS])
        except LauncherError:
            # The client asks for this once, at connect. Failing the whole
            # request would leave it with no tools at all for the session;
            # answering with the launcher's own at least leaves a way to ask
            # what went wrong and to retry.
            return types.ListToolsResult(tools=LAUNCHER_TOOLS)

    async def on_call_tool(ctx, params) -> types.CallToolResult:
        if params.name == "server_status":
            status = upstream.status()
            lines = [f"{key}: {value}" for key, value in status.items()]
            return text("\n".join(lines))
        if params.name == "restart_server":
            try:
                return text(await asyncio.to_thread(upstream.restart))
            except LauncherError as error:
                return failure(str(error))

        try:
            result = await ask_upstream(
                upstream, lambda session: session.call_tool(params.name, params.arguments or {}))
        except LauncherError as error:
            return failure(str(error))
        # Forwarded as-is: content blocks, structured content and the error
        # flag all belong to the emulator's answer, not to this layer.
        return types.CallToolResult(
            content=list(result.content),
            structured_content=result.structured_content,
            is_error=result.is_error,
        )

    return Server("zx-spectrum", on_list_tools=on_list_tools, on_call_tool=on_call_tool)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", default=os.environ.get("ZX_SERVER_EXE", str(DEFAULT_EXE)),
                        help="zx_server.exe to start when none is running")
    parser.add_argument("--host", default=os.environ.get("ZX_SERVER_HOST", DEFAULT_HOST))
    parser.add_argument("--mcp-port", type=int,
                        default=int(os.environ.get("ZX_SERVER_MCP_PORT", DEFAULT_PORT)))
    parser.add_argument("--rom", default=os.environ.get("ZX_SERVER_ROM", str(DEFAULT_ROM)),
                        help="ROM to start with; pass an empty string for none")
    parser.add_argument("--server-args", default=os.environ.get("ZX_SERVER_ARGS", ""),
                        help="extra arguments for zx_server, as one shell-quoted string")
    parser.add_argument("--no-spawn", action="store_true",
                        help="only ever adopt a running server, never start one")
    return parser.parse_args(argv[1:])


async def serve(upstream: Upstream) -> None:
    server = build_server(upstream)
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    extra: list[str] = []
    if args.rom:
        extra += ["--rom", args.rom]
    extra += shlex.split(args.server_args)

    upstream = Upstream(
        exe=Path(args.exe),
        host=args.host,
        port=args.mcp_port,
        extra_args=extra,
        log_path=Path(tempfile.gettempdir()) / "zxserver" / "zx_server.log",
        allow_spawn=not args.no_spawn,
    )
    try:
        asyncio.run(serve(upstream))
    finally:
        # Only ever our own child. An adopted server outlives this process, as
        # it should -- it was there first.
        upstream.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
