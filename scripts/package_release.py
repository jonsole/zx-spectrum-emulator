#!/usr/bin/env python3
"""Packages a release: the VS Code extension's .vsix and the emulator's zip.

    python scripts/package_release.py --server <zx_server.exe> --roms <dir> --ref v0.1.0

writes into dist/:

    zxspectrum-debug-<version>-win32-x64.vsix
        The extension, with zx_server.exe in bin/ and the ROMs in roms/, where
        server_launch.js looks once a checkout's own build and ROMs are not
        there. Its details page is the user guide rather than the extension's
        README, which is about how the extension is built.
    zx-spectrum-emulator-<version>-win32-x64.zip
        zx_server.exe and the ROMs alone, for MCP clients and other editors.

Both carry LICENSE and THIRD_PARTY_NOTICES.md. The version is package.json's,
which is also what the server reports (cpp-core/CMakeLists.txt reads it);
`--ref` is the git tag the release is cut from, which the .vsix's links to the
docs point at, so they show the docs as they were at that release.

The extension is staged into a copy (dist/stage/) rather than packaged in
place: it is installed from vscode-extension/ as a symlink while working on
it, and a bin/ and roms/ appearing in there would take over from the
checkout's own build. vsce runs through npx, so this needs Node; with
--no-vsix it builds the zip and the staged folder alone, which is enough to
check the staging without it.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTENSION = os.path.join(ROOT, "vscode-extension")
REPO_URL = "https://github.com/jonsole/zx-spectrum-emulator"
# The one platform a release is built for so far.
TARGET = "win32-x64"
# Pinned to a major version: a vsce that changed what it accepts should not
# turn up in the middle of cutting a release.
VSCE = "@vscode/vsce@3"
ROMS = ["48.rom", "128.rom"]
NOTICES = ["LICENSE", "THIRD_PARTY_NOTICES.md"]

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


def tracked_files(folder):
    """The extension's files as git has them, so nothing lying around in the
    working tree (a capture, an editor's backup) ends up in a release."""
    out = subprocess.run(["git", "ls-files", "-z", "--", folder], cwd=ROOT, check=True,
                         capture_output=True).stdout.decode("utf-8")
    return [path for path in out.split("\0") if path]


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def stage_extension(stage, server, roms):
    shutil.rmtree(stage, ignore_errors=True)
    for rel in tracked_files("vscode-extension"):
        copy(os.path.join(ROOT, rel), os.path.join(stage, os.path.relpath(rel, "vscode-extension")))
    # The details page: the user guide, whose links vsce makes absolute
    # (--baseContentUrl) since docs/ is not in the package.
    copy(os.path.join(ROOT, "docs", "vscode-user-guide.md"), os.path.join(stage, "README.md"))
    copy(os.path.join(ROOT, "CHANGELOG.md"), os.path.join(stage, "CHANGELOG.md"))
    for name in NOTICES:
        copy(os.path.join(ROOT, name), os.path.join(stage, name))
    copy(server, os.path.join(stage, "bin", "zx_server.exe"))
    for name in ROMS:
        copy(os.path.join(roms, name), os.path.join(stage, "roms", name))


def run_vsce(stage, out, ref):
    npx = shutil.which("npx")
    if not npx:
        raise SystemExit("npx not found: vsce needs Node (or pass --no-vsix)")
    subprocess.run([
        npx, "--yes", VSCE, "package",
        "--target", TARGET,
        # Nothing to bundle: the extension has no npm dependencies.
        "--no-dependencies",
        "--baseContentUrl", f"{REPO_URL}/blob/{ref}/docs",
        "--baseImagesUrl", f"{REPO_URL}/raw/{ref}/docs",
        "--out", out,
    ], cwd=stage, check=True)


def build_zip(path, version, server, roms, ref):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(server, "zx_server.exe")
        for name in ROMS:
            z.write(os.path.join(roms, name), f"roms/{name}")
        for name in NOTICES:
            z.write(os.path.join(ROOT, name), name)
        z.writestr("README.txt", SERVER_README.format(version=version, repo=REPO_URL, ref=ref))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--server", required=True, help="the zx_server.exe to ship")
    parser.add_argument("--roms", required=True, help="a directory holding 48.rom and 128.rom")
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
    print(f"staged the extension in {stage}")

    zip_path = os.path.join(args.out, f"zx-spectrum-emulator-{version}-{TARGET}.zip")
    build_zip(zip_path, version, args.server, args.roms, args.ref)
    print(f"wrote {zip_path}")

    if not args.no_vsix:
        vsix = os.path.join(args.out, f"zxspectrum-debug-{version}-{TARGET}.vsix")
        run_vsce(stage, vsix, args.ref)
        print(f"wrote {vsix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
