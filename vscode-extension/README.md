# ZX Spectrum Debug (VS Code extension)

Two things, in one small extension:

1. **Registers the `zxspectrum` debugger type** so `launch.json`'s `debugServer` field can connect
   directly to `zx-spectrum-emulator`'s DAP server -- purely declarative for this part, no adapter
   code, since `debugServer` overrides how VS Code connects.
2. **A live screen viewer.** The "ZX Spectrum: Show Screen" command opens a panel that stays live,
   fed by the emulator's screen-stream port (`--screen-port`, default `8500`) -- this is real
   extension code (`extension.js`), the first the project needed, since a webview panel can't be
   created any other way.

## Install

Copy (or symlink) this directory into your VS Code extensions folder as
`<publisher>.zxspectrum-debug-<version>` (values from `package.json` -- currently
`jonsole.zxspectrum-debug-0.0.2`):

```powershell
# PowerShell, from the repo root
Copy-Item -Recurse .\vscode-extension "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
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
- If the image doesn't appear, check the webview's own console: **"Developer: Open Webview Developer
  Tools"** while the panel is focused.
