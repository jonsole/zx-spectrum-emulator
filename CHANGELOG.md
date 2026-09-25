# Changelog

One list for the emulator (`zx_server`) and the VS Code extension, which are
released together under one version. `scripts/release.py <version>` moves
what is under **Unreleased** into a section of its own, and the release on
GitHub takes its notes from that section.

## Unreleased

The first release: the emulator and the VS Code extension, packaged.

- **Installs in one step.** The extension's `.vsix` carries `zx_server` and the
  48K and 128K ROMs, so a debug session works without building anything. A
  checkout's own build and ROMs are still used first. The emulator is also
  published on its own, as a zip, for MCP clients and other editors.
- **The machine:** a 48K and 128K Spectrum emulated per half-T-state, pin by
  pin, with the AY chip, `.sna`, `.z80`, `.tap`, `.tzx`, `.wav` and `.csw`.
- **Debugging in VS Code:** breakpoints, stepping in the ROM's and your own
  assembly source, stepping backwards, watchpoints, logpoints, a call stack
  that follows a borrowed stack pointer, an execution profiler, a live screen
  with raster position and a display-write overlay, graphics and tape tools.
- **More than one emulator at once**, each announcing its ports, with the
  screen panel following whichever the debugger is on.
- **MCP:** the same machine driven by an AI agent, alongside the debugger.
- `zx_server --version`, and a version in `serverInfo`; the extension warns
  when a server is older than it.
- MIT licence; third-party terms in `THIRD_PARTY_NOTICES.md`.
