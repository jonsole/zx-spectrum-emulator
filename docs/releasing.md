# Releasing

Part of the [zx-spectrum-emulator README](../README.md).

The emulator (`zx_server`) and the VS Code extension are released together,
under one version, as a GitHub Release with two files:

| File | What it is |
|---|---|
| `zxspectrum-debug-<version>-win32-x64.vsix` | The extension, carrying `zx_server.exe` in `bin/` and the 48K and 128K ROMs in `roms/`. Installed with **Extensions: Install from VSIX...**, it needs nothing else |
| `zx-spectrum-emulator-<version>-win32-x64.zip` | `zx_server.exe` and the ROMs alone, for MCP clients and other editors |

Both carry `LICENSE` (MIT) and `THIRD_PARTY_NOTICES.md`. Windows x64 only, so
far. Releases go to GitHub only: nothing is published to the VS Code
Marketplace or Open VSX.

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
3. `build.ps1 -Release -Distribution -Test` -- the optimised build and the
   fast test suite.
4. `zx_server --version` must say the tag's version.
5. Every `vscode-extension/tests/*_test.js`.
6. `scripts/package_release.py` -- stages a copy of the extension (the tracked
   files only, with the user guide as its details page, the server, the ROMs
   and the notices), runs `vsce package --target win32-x64` on it, and zips the
   server.
7. `release.py notes` and `gh release create`, with both files attached.

Nothing is published until every step before the last has passed.
[ci.yml](../.github/workflows/ci.yml) runs steps 2, 3 (Debug), 5 and 6 on
every push to `master`, plus a build without rewind, so a broken build is
found then rather than at a tag.

To try the packaging by hand (it needs Node for vsce, or `--no-vsix` for the
zip and the staged folder alone):

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
- **The ROM disassembly is not shipped.** It is copyrighted too (see the
  README), so an installed release steps the ROM as plain disassembly,
  without its labels and comments.
- **An installed release defers to a checkout.** In the repository, the
  extension still uses `cpp-core/build/RelWithDebInfo/zx_server.exe` and
  `roms/` first; the bundled ones are for everywhere else
  ([server_launch.js](../vscode-extension/server_launch.js)).
