"""Assembles and runs the Filmation example's Z80 unit tests.

The engine's suites are here, beside this script, and the games' are in
knightlore/tests and pentagram/tests; the games' use the harness from here.
Every *_tests.s is a self-contained program: it INCLUDEs the file it tests,
checks it, and returns its failure count in A. sjasmplus turns each into a
.com under examples/filmation/output/tests/<engine or game>, and cpp-core's
z80_com_runner runs it on the C++ Z80 core and exits with that count.

    python examples/filmation/engine/tests/run_tests.py [name ...]

With no names it runs them all, the engine's first; `depth` runs
depth_tests.s, wherever it is, and `movers` every movers_tests.s there is --
the engine's and each game's. `pentagram/movers` names one of them. The runner
has to have been built first:

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
SUITE_DIRS = [HERE, FILMATION / "knightlore" / "tests", FILMATION / "pentagram" / "tests"]

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


def owner(source: Path) -> str:
    """engine, knightlore or pentagram: the folder above the suite's tests/."""
    return source.parent.parent.name


def run_suite(source: Path, sjasmplus: str, runner: Path) -> bool:
    # A folder each, because two of them may have a suite of the same name.
    out = OUT_DIR / owner(source)
    out.mkdir(parents=True, exist_ok=True)
    com = out / (source.stem + ".com")
    lst = out / (source.stem + ".lst")
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
        sources = []
        missing = []
        for n in names:
            found = [s for s in everything
                     if f"{n}_tests" in (s.stem, f"{owner(s)}/{s.stem}")]
            if not found:
                missing.append(f"{n}_tests.s")
            sources += found
        if missing:
            sys.exit("no such suite: " + ", ".join(missing))
    else:
        sources = everything

    sjasmplus = find_sjasmplus()
    runner = find_runner()
    failed = [f"{owner(s)}/{s.stem}" for s in sources if not run_suite(s, sjasmplus, runner)]
    if failed:
        sys.exit("failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
