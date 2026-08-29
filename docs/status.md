# Status & roadmap

Part of the [zx-spectrum-emulator README](../README.md).

The full core build order is complete and verified end-to-end (Z80 →
memory/ULA/keyboard/snapshot/machine → disassembler → engine → MCP
server → DAP server), including a live concurrent-session check: a real DAP
client and a real MCP client connected simultaneously, each observing the
other's changes as unsolicited events.

A [VS Code workspace](vscode-debugging.md) (`.vscode/tasks.json` +
`launch.json`) is included and confirmed working end to end in a real,
interactive VS Code session (see the note there about one VS Code UI rough
edge that isn't fixable from the adapter side).

Windows is the supported platform: MSVC Build Tools 2022, built through
`cpp-core/build.ps1`. Linux/macOS is plausible but unverified — see
[Requirements](../README.md#requirements).

**Known limitation, not yet fixed:** if a client starts `run()` and
disconnects without ever `pause()`-ing (e.g. a crashed or killed client
mid-session), the machine keeps running that program forever. Commands that
tolerate it are still serviced at each run-loop yield, and pause, keys, the
screen, tracing and the tape transport bypass the queue entirely — but
anything that drives emulation itself still waits for the run to end, and
there is no auto-pause on disconnect or run-time cap.

Source-level debugging against a real, commented disassembly (not just raw
instructions) is done, for both
[the ROM](vscode-debugging.md#source-level-debugging-of-the-rom) and
[your own assembled programs](vscode-debugging.md#source-level-debugging-of-your-own-program):
`scripts/build_rom_source.py` reproduces the ROM **byte-for-byte** via
`skool2asm.py` + `sjasmplus --sld`; `load_debug_info` attaches the same kind
of map for any `sjasmplus`-assembled program, layered on top of (not
replacing) the ROM's own, so a call from your program into a ROM routine
still resolves. `dap.cpp` uses whichever map applies for `source`-annotated
stack frames and source-line breakpoints; `resolve_symbol`/`resolve_address`
expose the same lookup over MCP. Verified end-to-end (build → `stackTrace` →
`setBreakpoints` → hit → correct PC, and separately, own-program address →
ROM address → correct source switches for both).

A [live screen viewer](vscode-debugging.md#live-screen-viewer) is done too:
a third server port (`screen_stream.cpp`) streams the display as a continuous sequence of PNG
frames to any client, and the `vscode-extension/` extension bridges that into
a webview panel — the project's first extension with real code (previously
just a declarative debugger-type stub). Explicitly designed to keep working
standalone, independent of VS Code: the streaming port has no VS-Code-specific
code in it, same as DAP/MCP.

Stretch goals, not blocking normal use:
- `.z80` snapshot format (versioned, compressed — `.sna` works today)
- Tape loading — **done** for `.tap`/`.tzx` (see [Tape](tape.md));
  `.pzx` and tape *saving* are still open, as are the `.tzx` sampled-data block
  types (`0x15` direct recording, `0x18` CSW, `0x19` generalized)
- Beeper audio synthesis — **done** (see [Audio](audio.md)); the AY chip is not
