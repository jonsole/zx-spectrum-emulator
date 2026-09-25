# Releasing

Part of the [zx-spectrum-emulator README](../README.md).

The emulator (`zx_server`) and the VS Code extension are released together,
under one version, as a GitHub Release with these files:

| File | What it is |
|---|---|
| `zxspectrum-debug-<version>-win32-x64.vsix` | The extension, carrying `zx_server.exe` in `bin/`, the 48K and 128K ROMs in `roms/`, the trace viewer, and the tape designer's builder with its fast loader in `builder/`. Installed with **Extensions: Install from VSIX...**, it needs nothing else to debug |
| `zx-spectrum-emulator-<version>-win32-x64.zip` | `zx_server.exe` and the ROMs alone, for MCP clients and other editors |
| `filmation-designer-<version>.vsix` | The Filmation designer: the room, templates and graphic-map editors |
| `zx-spectrum-example-rom-<version>.zip` | A workspace for stepping through the ROM in its commented disassembly |
| `zx-spectrum-example-knightlore-<version>.zip` | The Knight Lore remake's workspace: its code, and a task that extracts the game's data from the user's own copy of the original |
| `zx-spectrum-example-pentagram-<version>.zip` | The same for Pentagram |

Everything carries `LICENSE` (MIT) and `THIRD_PARTY_NOTICES.md`. Windows x64
only, so far. Releases go to GitHub only: nothing is published to the VS Code
Marketplace or Open VSX.

**sjasmplus is not in any of them.** The example workspaces and the tape
designer assemble with it, and the extension fetches it the first time one of
them needs it: the pinned 1.23.1, from sjasmplus's own GitHub release, checked
against the same SHA-256s as `scripts/fetch_sjasmplus.py` and kept in the
extension's storage (`vscode-extension/sjasmplus_fetch.js`). One on the PATH is
used instead when there is one.

**The Filmation examples carry none of Ultimate's data** -- no artwork, no
rooms, no built game. Each workspace's **Extract** task runs
`examples/filmation/extract.py` on the user's own copy (Knight Lore as a `.sna`
or `.z80`; Pentagram as a `.tzx`, `.tap`, `.sna` or `.z80`), which makes the
files the repository carries and checks each against the game's
`original.json` -- hashes only. Extraction from the originals reproduces the
repository's files byte for byte, so the game a workspace builds is the one
this repository builds. What a workspace does carry is `graphics.json`, the
remake's own table of which sprite each graphic draws and the nudge that places
it.

## Cutting one

1. **Say what is in it.** Add to the **Unreleased** section of
   [CHANGELOG.md](../CHANGELOG.md) as changes land, or all at once now. It
   becomes the release notes.
2. **Try a release candidate** (recommended, and always for the first release
   of a new kind of change):

   ```powershell
   .venv-win\Scripts\python.exe scripts\release.py 0.1.0 --rc 1
   git push origin master v0.1.0-rc1
   ```

   It sets `package.json`'s version to 0.1.0, commits that if it changed, and
   tags `v0.1.0-rc1`. The workflow publishes it as a GitHub **pre-release**,
   with the Unreleased section as its notes. Install its `.vsix` and try it.
   Another candidate is `--rc 2`.
3. **Release it:**

   ```powershell
   .venv-win\Scripts\python.exe scripts\release.py 0.1.0
   git push origin master v0.1.0
   ```

   This moves Unreleased under `## 0.1.0 (<date>)`, commits it, and tags
   `v0.1.0`.

`release.py` commits only `package.json` and `CHANGELOG.md`, by name, so other
uncommitted work in the tree stays out -- the release is built from the tag,
not from your working tree. It refuses to run off `master`, over an existing
tag, over uncommitted edits to either of its two files, or with an empty
Unreleased section. It never pushes: looking at the commit and tag before
`git push` is the last chance to change your mind. A tag pushed by mistake is
undone with `git push --delete origin <tag>`, and the release it made deleted
on GitHub.

## The version

One number, in [vscode-extension/package.json](../vscode-extension/package.json).
`cpp-core/CMakeLists.txt` reads it too, so the server and the extension cannot
disagree:

- `zx_server --version` prints it, the log's second line says it, and it is
  `serverVersion` in `serverInfo`, the MCP `server_info` tool and the advert.
- A build that is not a release reports it with `-dev` after it (`0.1.0-dev`):
  the same number on a build with unreleased changes would claim to be
  something it is not. `build.ps1 -Distribution` drops the suffix, and
  `-Distribution -Prerelease rc1` makes it `-rc1`.
- The extension warns, once per server, when a session's server is older than
  itself -- a server left running across an update, or a checkout's build that
  has not been rebuilt. `-dev` counts as the release it is heading for.

## What the workflow does

[.github/workflows/release.yml](../.github/workflows/release.yml) runs on a
pushed `v*` tag, on `windows-latest`:

1. `release.py check` -- the tag must be `package.json`'s version (with `-rcN`
   for a candidate).
2. `scripts/fetch_roms.py` -- the ROMs, from the Fuse emulator's source,
   checked against pinned SHA-256 hashes. Fetched before the build, so the
   tests that need a real ROM run rather than skip.
3. The `examples/zx-tape-loader` submodule, for the tape builder;
   `scripts/fetch_sjasmplus.py` and SkoolKit, and with them
   `scripts/build_rom_source.py` -- the ROM disassembly for the ROM example,
   which it refuses to write unless it reassembles the ROM byte for byte.
4. `build.ps1 -Release -Distribution -Test` -- the optimised build and the
   fast test suite.
5. `zx_server --version` must say the tag's version.
6. Every `vscode-extension/tests/*_test.js`.
7. `scripts/package_release.py` -- stages copies of the two extensions (the
   tracked files only; the emulator's with the user guide as its details page,
   the server, the ROMs, the trace viewer, the tape builder and the notices),
   runs `vsce package` on each, zips the server, and zips the example
   workspaces from `release/workspaces/` and what each works on. A Filmation
   game whose carried data no longer matches its `original.json` stops it: an
   edit extraction cannot reproduce.
8. `release.py notes` and `gh release create`, with every file attached.

Nothing is published until every step before the last has passed.
[ci.yml](../.github/workflows/ci.yml) runs steps 2, 3, 4 (Debug), 6 and 7 on
every push to `master`, plus a build without rewind, so a broken build is
found then rather than at a tag.

To try the packaging by hand (it needs Node for vsce, or `--no-vsix` for the
zips and the staged folders alone; and `rom_disassembly/`, built by
`scripts/build_rom_source.py`):

```powershell
.venv-win\Scripts\python.exe scripts\package_release.py `
  --server cpp-core\build\RelWithDebInfo\zx_server.exe --roms roms --ref v0.1.0
```

## Things worth knowing

- **The ROMs are not in the repository**, and a release is the one place they
  are distributed. They are copyright Amstrad, who allow distribution but not
  sale; `THIRD_PARTY_NOTICES.md` quotes the terms. If Fuse's files ever change,
  `fetch_roms.py` fails on the hash rather than shipping something different.
- **The C++ runtime is linked in** (`CMAKE_MSVC_RUNTIME_LIBRARY`), so
  `zx_server.exe` needs only DLLs that come with Windows, not the Visual C++
  Redistributable.
- **The executable is not code-signed.** Windows SmartScreen warns the first
  time a downloaded `zx_server.exe` runs. Signing costs money and can come
  later.
- **The ROM disassembly ships in the ROM example only**, by the author's
  choice: skoolkid/rom, the SkoolKit edition of *The Complete Spectrum ROM
  Disassembly*, is published with no licence of its own (the notices say
  whose it is). The extension does not carry it, so outside that workspace the
  ROM steps as plain disassembly, without its labels and comments.
- **Changing a Filmation game's data** -- a room in the designer, a sprite in
  `sprites.png` -- stops the next release until it is dealt with, since the
  example workspace makes that data from the original and could not reproduce
  the change (see step 7).
- **An installed release defers to a checkout.** In the repository, the
  extension still uses `cpp-core/build/RelWithDebInfo/zx_server.exe` and
  `roms/` first; the bundled ones are for everywhere else
  ([server_launch.js](../vscode-extension/server_launch.js)).
