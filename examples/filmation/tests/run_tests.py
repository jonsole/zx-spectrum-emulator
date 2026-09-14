"""Assembles and runs the Filmation engine's Z80 unit tests.

Every *_tests.s here is a self-contained program: it INCLUDEs the engine file
it tests, checks it, and returns its failure count in A. sjasmplus turns each
into a .com under output/tests, and cpp-core's z80_com_runner runs it on the
C++ Z80 core and exits with that count.

    python examples/filmation/tests/run_tests.py [name ...]

With no names it runs them all; `depth` runs depth_tests.s. The runner has to
have been built first:

    cpp-core/build.ps1 -Release -Target z80_com_runner
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILMATION = HERE.parent
REPO = FILMATION.parent.parent
OUT_DIR = FILMATION / "output" / "tests"

sys.path.insert(0, str(FILMATION))
from build import find_sjasmplus  # noqa: E402

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
        cwd=HERE,
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
    if names:
        sources = [HERE / f"{name}_tests.s" for name in names]
        missing = [s.name for s in sources if not s.is_file()]
        if missing:
            sys.exit("no such suite: " + ", ".join(missing))
    else:
        sources = sorted(HERE.glob("*_tests.s"))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sjasmplus = find_sjasmplus()
    runner = find_runner()
    failed = [s.stem for s in sources if not run_suite(s, sjasmplus, runner)]
    if failed:
        sys.exit("failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
