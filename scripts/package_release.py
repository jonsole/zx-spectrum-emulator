#!/usr/bin/env python3
"""Packages a release: the VS Code extensions, the emulator and the examples.

    python scripts/package_release.py --server <zx_server.exe> --roms <dir> --ref v0.1.0

writes into dist/:

    zxspectrum-debug-<version>-win32-x64.vsix
        The extension, carrying zx_server.exe in bin/, the ROMs in roms/, the
        trace viewer, and the tape designer's builder (with the fast loader)
        in builder/ -- each used only where a checkout's own is not there.
        Not sjasmplus: the extension fetches that the first time something
        needs it (sjasmplus_fetch.js). Its details page is the user guide
        rather than the extension's README, which is about how the extension
        is built.
    zx-spectrum-emulator-<version>-win32-x64.zip
        zx_server.exe and the ROMs alone, for MCP clients and other editors.
    filmation-designer-<version>.vsix
        The Filmation designer (examples/filmation/vscode): the room,
        templates and graphic-map editors. No binaries, so no platform.
    zx-spectrum-example-rom-<version>.zip
    zx-spectrum-example-knightlore-<version>.zip
    zx-spectrum-example-pentagram-<version>.zip
        VS Code workspaces to open and run: release/workspaces/<name>/ for the
        .vscode/ and README, with what they work on. The ROM's commented
        disassembly (rom_disassembly/, built by build_rom_source.py); the two
        Filmation remakes in the repository's own layout, examples/filmation/
        with the engine and the one game's code -- and none of Ultimate's
        data, which each workspace extracts from the user's own copy of the
        original (examples/filmation/extract.py).

Everything carries LICENSE and THIRD_PARTY_NOTICES.md. The version is
package.json's, which is also what the server reports (cpp-core/CMakeLists.txt
reads it); `--ref` is the git tag the release is cut from, which the .vsix
details pages link the docs at, and which names the files.

The extensions are staged into copies (dist/stage/) rather than packaged in
place: the emulator's is installed from vscode-extension/ as a symlink while
working on it, and a bin/ and roms/ appearing in there would take over from
the checkout's own build. Only files git tracks are taken, so nothing lying
around in the working tree ends up in a release. vsce runs through npx, so
this needs Node; with --no-vsix it builds the zips and the staged folders
alone, which is enough to check the staging without it.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTENSION = os.path.join(ROOT, "vscode-extension")
DESIGNER = "examples/filmation/vscode"
WORKSPACES = os.path.join(ROOT, "release", "workspaces")
REPO_URL = "https://github.com/jonsole/zx-spectrum-emulator"
# The one platform a release is built for so far.
TARGET = "win32-x64"
# Pinned to a major version: a vsce that changed what it accepts should not
# turn up in the middle of cutting a release.
VSCE = "@vscode/vsce@3"
ROMS = ["48.rom", "128.rom"]
NOTICES = ["LICENSE", "THIRD_PARTY_NOTICES.md"]
# The tape designer's builder: scripts/build_tape.py and what it imports.
BUILDER = ["build_tape.py", "tape_rom.py", "tape_screen.py"]
# The fast loader's files the builder reads: its Python, the loader as built,
# and the sources it is reassembled from when a design moves it.
FAST_LOADER = ["loader.py", "loader.tap", "loader.s", "basic.s", "tape.s", "counter.s"]
# The Filmation games packaged as examples, and what their build writes.
FILMATION_GAMES = ["knightlore", "pentagram"]
# examples/filmation's own subfolders that are games or the designer: each
# example carries the engine, the shared files and its own game only.
FILMATION_OTHERS = ["knightlore", "knightlore128", "pentagram", "vscode"]

SERVER_README = """ZX Spectrum emulator {version} -- zx_server

zx_server.exe is the emulator: a 48K and 128K ZX Spectrum served over the
Debug Adapter Protocol (VS Code and other editors), MCP (AI agents) and a
screen stream. Run it from this folder:

    zx_server.exe --rom roms\\48.rom --rom roms\\128.rom --audio-device

and point an MCP client at http://127.0.0.1:8000/mcp, or a DAP client at port
4711. zx_server.exe --version says which build this is.

The VS Code extension (the .vsix beside this zip on the release page) carries
its own copy and starts it for you; this zip is for using the emulator without
it.

Documentation: {repo}/blob/{ref}/README.md
The ROMs are copyright Amstrad, who allow their distribution: see
THIRD_PARTY_NOTICES.md.
"""


def package_version():
    with open(os.path.join(EXTENSION, "package.json"), encoding="utf-8") as f:
        return json.load(f)["version"]


def tracked_files(folder, cwd=ROOT):
    """The files git tracks under `folder`, relative to `cwd`."""
    out = subprocess.run(["git", "ls-files", "-z", "--", folder], cwd=cwd, check=True,
                         capture_output=True).stdout.decode("utf-8")
    return [path for path in out.split("\0") if path]


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def copy_tracked(folder, stage):
    """Everything git tracks under `folder`, into `stage` without the prefix."""
    for rel in tracked_files(folder):
        copy(os.path.join(ROOT, rel), os.path.join(stage, os.path.relpath(rel, folder)))


# ---- the emulator's extension --------------------------------------------------


def stage_extension(stage, server, roms):
    shutil.rmtree(stage, ignore_errors=True)
    copy_tracked("vscode-extension", stage)
    # The details page: the user guide, whose links vsce makes absolute
    # (--baseContentUrl) since docs/ is not in the package.
    copy(os.path.join(ROOT, "docs", "vscode-user-guide.md"), os.path.join(stage, "README.md"))
    copy(os.path.join(ROOT, "CHANGELOG.md"), os.path.join(stage, "CHANGELOG.md"))
    for name in NOTICES:
        copy(os.path.join(ROOT, name), os.path.join(stage, name))
    copy(server, os.path.join(stage, "bin", "zx_server.exe"))
    for name in ROMS:
        copy(os.path.join(roms, name), os.path.join(stage, "roms", name))
    # extension.js looks for the viewer beside itself first.
    copy(os.path.join(ROOT, "tools", "trace_viewer.html"), os.path.join(stage, "trace_viewer.html"))
    # tape_files.js looks for builder/build_tape.py, and build_tape.py for
    # the fast loader beside it.
    for name in BUILDER:
        copy(os.path.join(ROOT, "scripts", name), os.path.join(stage, "builder", name))
    loader = os.path.join(ROOT, "examples", "zx-tape-loader")
    for name in FAST_LOADER:
        source = os.path.join(loader, name)
        if not os.path.isfile(source):
            raise SystemExit(f"{source} missing: git submodule update --init examples/zx-tape-loader")
        copy(source, os.path.join(stage, "builder", "zx-tape-loader", name))


# ---- the Filmation designer -----------------------------------------------------


def stage_designer(stage, version):
    shutil.rmtree(stage, ignore_errors=True)
    copy_tracked(DESIGNER, stage)
    for name in NOTICES:
        copy(os.path.join(ROOT, name), os.path.join(stage, name))
    # One version for everything a release holds, whatever the designer's own
    # package.json last said.
    path = os.path.join(stage, "package.json")
    with open(path, encoding="utf-8") as f:
        package = json.load(f)
    package["version"] = version
    with open(path, "w", encoding="utf-8") as f:
        json.dump(package, f, indent=2)
        f.write("\n")
    with open(os.path.join(stage, ".vscodeignore"), "w", encoding="utf-8") as f:
        f.write("tests/**\n.vscodeignore\n")


def run_vsce(stage, out, content_url, target=None):
    npx = shutil.which("npx")
    if not npx:
        raise SystemExit("npx not found: vsce needs Node (or pass --no-vsix)")
    command = [npx, "--yes", VSCE, "package"]
    if target:
        command += ["--target", target]
    command += [
        # Nothing to bundle: neither extension has npm dependencies.
        "--no-dependencies",
        "--baseContentUrl", f"{REPO_URL}/blob/{content_url}",
        "--baseImagesUrl", f"{REPO_URL}/raw/{content_url}",
        "--out", out,
    ]
    subprocess.run(command, cwd=stage, check=True)


# ---- the zips -------------------------------------------------------------------


def build_server_zip(path, version, server, roms, ref):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(server, "zx_server.exe")
        for name in ROMS:
            z.write(os.path.join(roms, name), f"roms/{name}")
        for name in NOTICES:
            z.write(os.path.join(ROOT, name), name)
        z.writestr("README.txt", SERVER_README.format(version=version, repo=REPO_URL, ref=ref))


def add_workspace_template(z, top, name):
    """release/workspaces/<name>/: its README and .vscode/, and the notices."""
    base = os.path.join(WORKSPACES, name)
    for rel in tracked_files(os.path.relpath(base, ROOT).replace(os.sep, "/")):
        z.write(os.path.join(ROOT, rel), f"{top}/{os.path.relpath(rel, 'release/workspaces/' + name)}"
                .replace(os.sep, "/"))
    for notice in NOTICES:
        z.write(os.path.join(ROOT, notice), f"{top}/{notice}")


def build_rom_example(path, top, disassembly):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        add_workspace_template(z, top, "rom")
        for name in ("rom.asm", "rom.sld"):
            source = os.path.join(disassembly, name)
            if not os.path.isfile(source):
                raise SystemExit(f"{source} missing: python scripts/build_rom_source.py")
            z.write(source, f"{top}/rom_disassembly/{name}")


def json_hash(path):
    """SHA-256 as extract.py takes it: a JSON file's line endings made LF first."""
    with open(path, "rb") as f:
        data = f.read()
    if path.endswith(".json"):
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def build_filmation_example(path, top, game):
    """The engine, the shared tools and one game's code -- but none of
    Ultimate's data. original.json names the files the repository carries that
    came out of the game; the workspace makes them from the user's own copy
    with extract.py, and they are left out here.

    They must still be what extraction gives, or a workspace would build a
    different game from the one this code was written against: an edit to one
    (a room moved in the designer, say) is something extraction cannot
    reproduce, so the release stops and says which."""
    base = f"examples/filmation/{game}"
    with open(os.path.join(ROOT, base, "original.json"), encoding="utf-8") as f:
        pins = json.load(f)
    changed = [name for name, digest in pins["carried"].items()
               if json_hash(os.path.join(ROOT, base, name)) != digest]
    if changed:
        raise SystemExit(f"{base}: {', '.join(changed)} no longer match{'es' if len(changed) == 1 else ''} "
                         "what extraction from the original gives (original.json), so the example "
                         "workspace could not reproduce them. Ship the edit some other way, or "
                         "undo it.")
    leave_out = {f"{base}/{name}" for name in pins["carried"]}
    others = [f"examples/filmation/{other}/" for other in FILMATION_OTHERS if other != game]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        add_workspace_template(z, top, game)
        for rel in tracked_files("examples/filmation"):
            if rel in leave_out or any(rel.startswith(prefix) for prefix in others):
                continue
            z.write(os.path.join(ROOT, rel), f"{top}/{rel}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--server", required=True, help="the zx_server.exe to ship")
    parser.add_argument("--roms", required=True, help="a directory holding 48.rom and 128.rom")
    parser.add_argument("--rom-disassembly", default=os.path.join(ROOT, "rom_disassembly"),
                        help="rom.asm and rom.sld (default: rom_disassembly/)")
    parser.add_argument("--ref", required=True, help="the tag the release is cut from, e.g. v0.1.0")
    parser.add_argument("--out", default=os.path.join(ROOT, "dist"), help="where to write (default: dist/)")
    parser.add_argument("--no-vsix", action="store_true", help="stage and zip, but do not run vsce")
    args = parser.parse_args()

    # What the files are called: the tag's version, which is package.json's
    # with -rc1 and so on after it for a release candidate.
    version = args.ref[1:] if args.ref.startswith("v") else package_version()
    for name in ROMS:
        if not os.path.isfile(os.path.join(args.roms, name)):
            raise SystemExit(f"{name} not in {args.roms} (scripts/fetch_roms.py fetches them)")
    if not os.path.isfile(args.server):
        raise SystemExit(f"no server at {args.server}")

    os.makedirs(args.out, exist_ok=True)
    stage = os.path.join(args.out, "stage", "extension")
    stage_extension(stage, args.server, args.roms)
    designer = os.path.join(args.out, "stage", "filmation-designer")
    stage_designer(designer, package_version())
    print(f"staged the extensions in {os.path.dirname(stage)}")

    written = []
    zip_path = os.path.join(args.out, f"zx-spectrum-emulator-{version}-{TARGET}.zip")
    build_server_zip(zip_path, version, args.server, args.roms, args.ref)
    written.append(zip_path)
    top = "zx-spectrum-example-rom"
    zip_path = os.path.join(args.out, f"{top}-{version}.zip")
    build_rom_example(zip_path, top, args.rom_disassembly)
    written.append(zip_path)
    for game in FILMATION_GAMES:
        top = f"zx-spectrum-example-{game}"
        zip_path = os.path.join(args.out, f"{top}-{version}.zip")
        build_filmation_example(zip_path, top, game)
        written.append(zip_path)

    if not args.no_vsix:
        vsix = os.path.join(args.out, f"zxspectrum-debug-{version}-{TARGET}.vsix")
        run_vsce(stage, vsix, f"{args.ref}/docs", TARGET)
        written.append(vsix)
        vsix = os.path.join(args.out, f"filmation-designer-{version}.vsix")
        run_vsce(designer, vsix, f"{args.ref}/{DESIGNER}")
        written.append(vsix)
    for path in written:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
