# ZX Spectrum Debug (VS Code extension)

Two things, in one small extension:

1. **Registers the `zxspectrum` debugger type** so `launch.json`'s `debugServer` field can connect
   directly to `zx-spectrum-emulator`'s DAP server -- purely declarative for this part, no adapter
   code, since `debugServer` overrides how VS Code connects.
2. **A live screen viewer.** The "ZX Spectrum: Show Screen" command opens a panel that stays live,
   fed by the emulator's screen-stream port (`--screen-port`, default `8500`) -- this is real
   extension code (`extension.js`), the first the project needed, since a webview panel can't be
   created any other way.
3. **A trace viewer and recorder.** The "ZX Spectrum: Show Trace" command opens a `.zxtrace`
   capture (see [docs/tracing.md](../docs/tracing.md)) as a banded table and a timing
   diagram. The page itself is `tools/trace_viewer.html` in the repo, hosted in a webview rather
   than copied here -- the same file opens standalone in a browser. The extension host reads the
   file and posts its text in, and re-posts it whenever the capture is rewritten, so recapturing
   updates the panel in place. Its **Record** button goes the other way, driving the debug
   session's own emulator through `startTrace`/`stopTrace`/`traceStatus` custom requests: those
   bypass the emulator's command queue, so a capture can be started and stopped while a game is
   running, and the finished file loads into the panel by itself.
4. **A tape pane.** A tree in the debug sidebar, docked with Call Stack and Breakpoints, listing
   what is on the inserted tape block by block. See "Tape pane" below.

## Load Tape

**"ZX Spectrum: Load Tape…"** puts a `.tap`, `.tzx`, `.wav` or `.csw` into a
session that is
already running, over a `loadTape` custom request — the same channel the trace
panel's Record button uses. It resets, types `LOAD ""`, starts the tape and
opens the screen panel, so the load is visible as it happens.

A tape that is always the same is better named in `launch.json` (`tape`, plus
`tapeAutoStart` and `tapeFastLoad`); this command is for reaching for a
different one mid-session.

## Tape pane

**ZX Spectrum Tape** appears in the debug sidebar while a `zxspectrum` session
is running, below Call Stack and Breakpoints. It lists the tape a block at a
time — the headers with their filenames decoded, the data blocks that follow
them, the tone and pause blocks a `.tzx` can carry, and the stretches of signal
an audio recording is cut into at its silences — with the block that is
playing marked, the ones already loaded dimmed, and a clock icon on any block
whose timings are non-standard, which is the answer to "why is this one loading
at real speed".

Expand a row for its `.tzx` block ID, its pause and whether fast load will take
it. Hovering a row gives a **seek** button that positions the tape at that block
with the motor stopped, so *Play* starts the load from there — which is how to
replay one part of a multi-load tape without rewinding through everything in
front of it.

The title bar carries a play/pause button that swaps with the state of the
motor — the way the debug toolbar's Continue and Pause share one slot — then
Rewind, the fast-load toggle, Load tape and Eject. All of it goes over the
`tapeControl` custom request, which bypasses the emulator's command queue, so
every button works mid-load and mid-game.

The pane polls for its position, and only while it is actually visible —
collapse the section and it stops asking.

## Install

Copy (or symlink) this directory into your VS Code extensions folder as
`<publisher>.zxspectrum-debug-<version>` (values from `package.json` -- currently
`jonsole.zxspectrum-debug-0.0.2`):

```powershell
# PowerShell, from the repo root
$dest = "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
Copy-Item -Recurse .\vscode-extension $dest
# The trace viewer lives in tools/, outside this directory -- copy it in too, or
# "Show Trace" has to fall back to finding it in the open workspace.
Copy-Item .\tools\trace_viewer.html $dest
```

Then **"Developer: Reload Window"** to pick it up. Re-run the copy (or use a symlink instead, so
edits show up without re-copying) after changing anything here, then reload again.

## Notes

- `SCREEN_HOST`/`SCREEN_PORT` in `extension.js` are hardcoded to match the server's own defaults
  (`127.0.0.1:8500`) -- edit both sides together if you run a non-default `--screen-port`.
- The panel auto-opens when a `zxspectrum`-type debug session starts (`vscode.debug.onDidStartDebugSession`),
  or open it manually via the Command Palette.
- If the emulator server restarts (a normal part of picking up code changes during development),
  the panel reconnects on its own within about a second rather than needing to be reopened.
- "Show Trace" looks for `trace_viewer.html` beside `extension.js` first, then at
  `../tools/trace_viewer.html` (the symlink-install case), then in `tools/` of any open workspace
  folder. If none of those exist it says so rather than opening an empty panel.
- Recording writes `live.zxtrace` into the first workspace folder, one fixed name that each
  capture supersedes. Record is disabled, and says so, when there is no `zxspectrum` debug
  session to record from.
- If the image doesn't appear, check the webview's own console: **"Developer: Open Webview Developer
  Tools"** while the panel is focused.
