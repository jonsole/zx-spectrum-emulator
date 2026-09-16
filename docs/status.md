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

An [execution profiler](vscode-debugging.md#execution-profile) is done: the
core counts each instruction's clock time per address and per call path
(`profile.cpp`), with idle time and per-frame (or per-turn) busy time kept
apart and the worst frames in detail; `profile_report.cpp` folds that through
the SLD data for the DAP `profile` request and the MCP `profile` tool, and the
extension paints it as a heat map and a call tree. Verified live against
filmation, Manic Miner and the ROM's idle loop. Known limits: code reached by
`JP` counts as the routine that jumped to it; a 128K's paged code is counted by
16-bit address; and with contention not yet emulated, contended code is
measured at its uncontended cost.

[Stepping backwards](vscode-debugging.md#stepping-backwards) is done: a
history of checkpoints and logged inputs (`rewind.cpp`) behind step back
into/over/out, reverse continue, run back to cursor and run back to last write,
in VS Code and over MCP, with running forward from the past replaying and any
change there starting a new timeline. On by default; `build.ps1 -NoRewind`
builds without it. Verified by hashing the whole machine at every frame through
replays of a ROM boot, a fast-loaded tape and a 128K's paging, and live against
filmation. Known limits: run back to last write sees the CPU's writes only, and
on a 128K watches the 16-bit address whatever bank is paged.

[Z80 assembly editing](vscode-debugging.md#editing-z80-assembly) is done in the
extension: sjasmplus syntax colouring and a workspace symbol index behind Go to
Definition, Find All References, Rename, Call Hierarchy, hover and the outline.
`MODULE` prefixes are not modelled.

Stretch goals, not blocking normal use:
- `.z80` snapshot format (versioned, compressed — `.sna` works today)
- Tape loading — **done** for `.tap`/`.tzx` (see [Tape](tape.md));
  `.pzx` and tape *saving* are still open, as are the `.tzx` sampled-data block
  types (`0x15` direct recording, `0x18` CSW, `0x19` generalized)
- Beeper audio synthesis — **done** (see [Audio](audio.md)); the AY chip is not
