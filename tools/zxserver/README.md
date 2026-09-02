# zx_server MCP launcher

Puts the emulator's MCP tools in front of a client whether or not the emulator
happens to be running: it **adopts** a server that is already there, and
**spawns** one when there is not.

The problem it solves: `zx_server.exe` serves MCP over HTTP, so a client
configured with `"url": "http://127.0.0.1:8000/mcp"` connects once, at startup.
If the emulator is not running at that moment the connection is refused and
the tools are missing for the rest of the session — no amount of starting the
server afterwards brings them back.

This runs over stdio instead, so the **client** launches it, and it starts the
emulator on demand.

- **[mcp_server.py](mcp_server.py)** — the launcher and proxy. One file.

## What it does with the server

| Situation | What happens |
|---|---|
| Something is listening on the MCP port | **Adopt** it. Never stopped, never restarted — that is the debug session's server, or one started by hand. |
| Nothing is listening | **Spawn** `zx_server.exe`, wait for the port, and stop it again when the client disconnects. |
| The server disappears mid-session | The next tool call reconnects; failing that, spawns a fresh one and retries once. |

That last row is routine rather than exceptional: `.vscode/tasks.json`'s
`zxspectrum-cpp.stop-stale-server` kills **every** running `zx_server` before a
debug launch, so starting a debug session while an MCP client is connected is
expected to pull the server out from under it.

## Tools

The emulator's own tools are **not** redeclared here. `tools/list` and
`tools/call` are forwarded upstream verbatim, so [mcp_server.cpp](../../cpp-core/src/mcp_server.cpp)
stays the single definition of what the emulator can do and this file cannot
drift from it. A tool added there appears here with no change.

Two tools are added, being the two this layer alone can answer:

| Tool | Does |
|---|---|
| `server_status()` | Whether the emulator is up, whether the launcher started it or adopted it, its pid, and where its log went |
| `restart_server()` | Stop the launcher's own server and start a fresh one — how to pick up a rebuilt `zx_server.exe`. Refuses when the server was adopted |

## Configuration

The repo's `.mcp.json` registers it as `zx-spectrum`, so opening this workspace
in Claude Code picks it up. Everything has a flag and an environment variable:

| Flag | Variable | Default |
|---|---|---|
| `--exe` | `ZX_SERVER_EXE` | `cpp-core/build/RelWithDebInfo/zx_server.exe` |
| `--rom` | `ZX_SERVER_ROM` | `roms/48.rom` (empty string for none) |
| `--mcp-port` | `ZX_SERVER_MCP_PORT` | 8000 |
| `--host` | `ZX_SERVER_HOST` | 127.0.0.1 |
| `--server-args` | `ZX_SERVER_ARGS` | — extra `zx_server` arguments, one shell-quoted string |
| `--no-spawn` | — | off; when set, only ever adopts |

`.mcp.json` passes `ZX_SERVER_ARGS="--audio-device --no-audio"`, matching the
server `.vscode/tasks.json` starts: sound out of the host's speakers rather
than through the screen panel.

## Things worth knowing

**The emulator starts when a client first asks for the tool list**, which for
most clients is at connect — the list is fetched upstream, so there has to be
an upstream. That is deliberate and cheap: a fresh `zx_server` sits paused
using no CPU, and a debug launch kills it anyway before starting its own, so
holding the port cannot block anything. `--no-spawn` turns it off if you would
rather start servers yourself.

**Connecting is the liveness test.** There is no "is it up?" probe before each
call: `zx_server` gives every connection its own thread, so probing to avoid an
occasional error would cost more than the error does. The proxy simply tries,
and spawns only when the attempt fails. (`server_status` still probes — that is
what it is for.)

**A session per request, not one held open.** The server can be replaced
between two calls, and a cached session would be holding a dead socket and a
session id the new process never issued. Reconnecting costs two local round
trips.

**It only ever stops what it started.** Both `restart_server` and shutdown
check ownership first. An adopted server outlives the client that adopted it.

**A `run` in flight blocks other MCP calls** — that is the emulator's own
behaviour, not the launcher's. `pause` bypasses the command queue and gets
through; anything else queues behind the run until it returns.

## Tests

[tests/test_zxserver_launcher.py](../../tests/test_zxserver_launcher.py) covers
the decision and — the part that matters — the ownership rules, driving the
real `Upstream` against a fake server that is a few lines of Python holding a
socket. Adopting, spawning, waiting for the port, timing out, a server that
dies on startup with its log preserved, `--no-spawn`, a missing executable, and
both directions of restart.

```powershell
.venv-win\Scripts\python.exe -m pytest tests\test_zxserver_launcher.py
```

**Verified end to end** through the MCP protocol over stdio, against the real
emulator: adopting a running server (still running after the client
disconnected), spawning one on a spare port (gone after the client
disconnected), all 29 emulator tools listed through the proxy alongside the
launcher's two, and — the interesting one — killing the spawned server
mid-session, after which the next `get_state` came back from a new process.
