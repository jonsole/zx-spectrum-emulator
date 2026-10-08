#!/usr/bin/env python3
"""Builds the web emulator: the core compiled to WebAssembly, and the page.

Needs Emscripten's emcc and em++ on PATH (or --emsdk-bin). Writes web/site/, which is what
GitHub Pages serves -- the page, its script, zx.js and zx.wasm, and the ROMs
when --roms names a directory holding them (scripts/fetch_roms.py fetches
them). site/ is gitignored and regenerated whole. knightlore.html's and
pentagram.html's remakes are web/knightlore_template.py's and
web/pentagram_template.py's, run after this one into the same site.

    python web/build.py --roms roms
    python -m http.server -d web/site      # then http://localhost:8000

The core is built without rewind (there is nothing here to step backwards
with) and without the Engine, the server or anything else that needs a thread
or a socket: zx_web.cpp drives a Spectrum itself.
"""
import argparse
import os
import shutil
import subprocess
import sys

WEB = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(WEB)
SRC = os.path.join(ROOT, "cpp-core", "src")
THIRD_PARTY = os.path.join(ROOT, "cpp-core", "third_party")

# The core's sources the machine needs: zx_core in cpp-core/CMakeLists.txt,
# less the Engine (threads), rewind (compiled out) and the video recorder.
CORE = [
    "alu.cpp", "ay.cpp", "beeper.cpp", "disassembler.cpp", "keyboard.cpp",
    "logpoint.cpp", "memory.cpp", "profile.cpp", "register_names.cpp",
    "snapshot.cpp", "spectrum.cpp", "tape.cpp", "tape_audio.cpp",
    "tracelog.cpp", "ula.cpp", "z80.cpp",
]

# The page's own files, copied into site/ as they are.
STATIC = ["index.html", "main.js", "style.css", "remake_page.js",
          "knightlore.html", "remake.js",
          "pentagram.html", "remake_pentagram.js"]

# The same cut-down miniz the native build uses -- inflate and nothing else.
MINIZ_DEFINES = ["MINIZ_NO_DEFLATE_APIS", "MINIZ_NO_ARCHIVE_APIS",
                 "MINIZ_NO_STDIO", "MINIZ_NO_TIME"]

# What the page calls, and what of Emscripten's runtime it uses to call them.
EXPORTS = [
    "_zx_alloc", "_zx_free", "_zx_load_rom", "_zx_load_snapshot", "_zx_reset",
    "_zx_is_128k", "_zx_frame_rate_milli", "_zx_set_sample_rate",
    "_zx_run_frame", "_zx_screen", "_zx_screen_width", "_zx_screen_height",
    "_zx_audio", "_zx_audio_length", "_zx_key", "_zx_keys_clear",
]
RUNTIME = ["HEAPU8", "HEAP16", "UTF8ToString", "stringToNewUTF8"]

ROMS = ["48.rom", "128.rom"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--emsdk-bin", default="",
                        help="the directory holding emcc and em++, if not on PATH")
    parser.add_argument("--roms", help="a directory holding 48.rom and 128.rom to bundle")
    parser.add_argument("--out", default=os.path.join(WEB, "site"), help="where to write the site")
    args = parser.parse_args()

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)

    emcc = os.path.join(args.emsdk_bin, "emcc")
    empp = os.path.join(args.emsdk_bin, "em++")
    defines = ["-DZX_REWIND=0"] + ["-D" + d for d in MINIZ_DEFINES]
    sources = [os.path.join(SRC, f) for f in CORE]
    sources.append(os.path.join(WEB, "zx_web.cpp"))

    # miniz is C, and someone else's: compiled on its own, without -std=c++17
    # or our warnings, as the native build adds it as its own target.
    miniz = os.path.join(args.out, "miniz.o")
    result = subprocess.run([emcc, "-O3", "-c", *defines,
                             os.path.join(THIRD_PARTY, "miniz", "miniz.c"), "-o", miniz])
    if result.returncode != 0:
        return result.returncode
    sources.append(miniz)
    command = [
        empp, "-O3", "-std=c++17", "-Wall", "-Wextra", "-Werror",
        "-I", SRC, "-isystem", THIRD_PARTY, *defines, *sources,
        "-o", os.path.join(args.out, "zx.js"),
        # node as well as web, so web/tests/smoke_test.js can run the module.
        "-sMODULARIZE=1", "-sEXPORT_NAME=createZx", "-sENVIRONMENT=web,node",
        "-sALLOW_MEMORY_GROWTH=1",
        # Emscripten's stack is 64K unless told otherwise, and load_z80 keeps
        # all eight 128K banks on it while it decodes them -- 128K, so every
        # .z80 overflowed it and crashed the page. A native thread's stack
        # is a megabyte or more, which is why nothing else ever noticed.
        "-sSTACK_SIZE=1MB",
        "-sEXPORTED_FUNCTIONS=" + ",".join(EXPORTS),
        "-sEXPORTED_RUNTIME_METHODS=" + ",".join(RUNTIME),
    ]
    print(" ".join(command))
    result = subprocess.run(command)
    os.remove(miniz)
    if result.returncode != 0:
        return result.returncode

    for name in STATIC:
        shutil.copy(os.path.join(WEB, name), os.path.join(args.out, name))
    if args.roms:
        os.makedirs(os.path.join(args.out, "roms"))
        for name in ROMS:
            path = os.path.join(args.roms, name)
            if not os.path.isfile(path):
                print(f"{path}: not found (python scripts/fetch_roms.py fetches it)",
                      file=sys.stderr)
                return 1
            shutil.copy(path, os.path.join(args.out, "roms", name))
    # GitHub Pages runs Jekyll over a site unless told not to, and Jekyll
    # leaves out anything it does not recognise as content.
    open(os.path.join(args.out, ".nojekyll"), "w").close()
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
