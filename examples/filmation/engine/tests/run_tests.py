"""Assembles and runs the Filmation example's Z80 unit tests.

The engine's suites are here, beside this script, and the game's are in
knightlore/tests; the game's use the harness from here. Every *_tests.s is a
self-contained program: it INCLUDEs the file it tests, checks it, and returns
its failure count in A. sjasmplus turns each into a .com under
examples/filmation/output/tests, and cpp-core's z80_com_runner runs it on the
C++ Z80 core and exits with that count.

    python examples/filmation/engine/tests/run_tests.py [name ...]

With no names it runs them all, the engine's first; `depth` runs
depth_tests.s, wherever it is. The runner has to have been built first:

    cpp-core/build.ps1 -Release -Target z80_com_runner
"""

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILMATION = HERE.parent.parent
REPO = FILMATION.parent.parent
OUT_DIR = FILMATION / "output" / "tests"
SUITE_DIRS = [HERE, FILMATION / "knightlore" / "tests"]

# The same search knightlore/build.py makes, kept here so that the engine's
# tests do not reach into the game's build.
SJASMPLUS_CANDIDATES = [
    REPO / "tools" / "sjasmplus" / "sjasmplus.exe",
    REPO / ".venv-win" / "Scripts" / "sjasmplus.exe",
]


def find_sjasmplus() -> str:
    for candidate in SJASMPLUS_CANDIDATES:
        if candidate.is_file():
            return str(candidate)
    on_path = shutil.which("sjasmplus")
    if on_path is not None:
        return on_path
    sys.exit("sjasmplus not found -- see knightlore/build.py for where to get it")


RUNNER_CANDIDATES = [
    REPO / "cpp-core" / "build" / "RelWithDebInfo" / "z80_com_runner.exe",
    REPO / "cpp-core" / "build" / "Debug" / "z80_com_runner.exe",
    REPO / "cpp-core" / "build" / "RelWithDebInfo" / "z80_com_runner",
    REPO / "cpp-core" / "build" / "Debug" / "z80_com_runner",
]


def find_runner() -> Path:
    for candidate in RUNNER_CANDIDATES:
        if candidate.is_file():
            return candidate
    sys.exit("z80_com_runner not built -- run: cpp-core/build.ps1 -Release -Target z80_com_runner")


def run_suite(source: Path, sjasmplus: str, runner: Path) -> bool:
    com = OUT_DIR / (source.stem + ".com")
    lst = OUT_DIR / (source.stem + ".lst")
    assembled = subprocess.run(
        [sjasmplus, "--nologo", "--fullpath", f"--raw={com}", f"--lst={lst}", source.name],
        cwd=source.parent,
        capture_output=True,
        text=True,
    )
    if assembled.returncode != 0:
        print(assembled.stdout + assembled.stderr)
        print(f"{source.stem}: did not assemble")
        return False
    ran = subprocess.run([str(runner), str(com)])
    return ran.returncode == 0


def main() -> None:
    names = sys.argv[1:]
    everything = [s for d in SUITE_DIRS for s in sorted(d.glob("*_tests.s"))]
    if names:
        by_name = {s.stem: s for s in everything}
        missing = [f"{n}_tests.s" for n in names if f"{n}_tests" not in by_name]
        if missing:
            sys.exit("no such suite: " + ", ".join(missing))
        sources = [by_name[f"{n}_tests"] for n in names]
    else:
        sources = everything

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sjasmplus = find_sjasmplus()
    runner = find_runner()
    failed = [s.stem for s in sources if not run_suite(s, sjasmplus, runner)]
    if failed:
        sys.exit("failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
