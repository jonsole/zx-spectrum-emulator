# The public timing test suites

Part of the [zx-spectrum-emulator README](../README.md).

The ZX Spectrum's timing has been pinned down over the years by test programs
written against real machines. This emulator runs them as tests (issue #30),
alongside the rule they check in [contention.md](contention.md).

## Fetching and running them

The programs are other people's work, so they are fetched, not committed:

```powershell
.venv-win\Scripts\python.exe scripts\fetch_timing_suites.py   # into .timing-suites\, gitignored
cd cpp-core
.\build.ps1 -Release -Target suite_shot
ctest --test-dir build\RelWithDebInfo -L suites -j 8         # these alone
.\build.ps1 -Release -Slow                                   # with ZEXALL and ZEXDOC
```

They come from the collection the
[redcode/ZXSpectrum wiki](https://github.com/redcode/ZXSpectrum/wiki/Tests)
keeps, downloaded as one archive; `fetch_timing_suites.py` keeps the programs
listed below under short names. Without the fetch, or without `roms/`, the
tests skip.

Each test is one run of `suite_shot`, a tool in `cpp-core/tests/`. It loads a
program through the Engine as VS Code would -- a snapshot, or a tape with
auto-start and fast loading -- runs it headless for a number of frames,
pressing keys at given frames, and saves the screen as a PNG beside the test.
It also prints the screen as text, matching each character cell against the
ROM's character set, and a test passes when the text it expects is there:

```
suite_shot <program> <frames> <out.png> [48|128|128in48] [KEY@frame ...]
           [expect=TEXT ...] [reject=TEXT ...]
```

`128in48` loads a tape from the 128's own 48 BASIC, for programs that ask for
it. `PLAY@frame` presses the tape's Play.

## Where each suite stands

Checked means a CTest reads the program's own verdict. The rest report as a
picture or a table of values that needs the right answer from real hardware
before it can be a test; their state here is what they show today.

| Suite | Machine | Reports | State |
|---|---|---|---|
| ZX Spectrum Timing Tests 48K (Butler) | 48K | Pass or Fail per test, uncontended and contended | **Checked: all 35 pass** |
| ZX Spectrum Timing Tests 128K (Butler) | 128K, from 48 BASIC | the same | **Checked: tests 1-34 pass.** Test 35 stops at once with a STOP report and runs nothing; not understood |
| 48K NEC Contention Test Suite (Woodmass): R register | 48K | "passed" | **Checked: passes** |
| 48K NEC suite: IR contention, LDIR/LDDR, CPIR/CPDR, INIR/INDR, OTIR/OTDR | 48K | a pattern | Not checked |
| Floating Spy (Ramsoft), self-test (T) | 48K | each read against the expected byte, lingering on a wrong one | **Checked: passes**, ending "Floating bus OK for ULA 48K" after some 15,000 frames. With the reads one T-state earlier it lingers on the first burst read |
| Float48K (Woodmass) | 48K | the byte read at each T-state | **Checked:** 0xFF to 14337, bitmap, attribute, bitmap, attribute at 14338-14341, 0xFF again, as [contention.md](contention.md) section 4 gives it |
| HALT Contention Test (Woodmass) | 48K | values and "0 OK" | Ends "0 OK, 40:1"; what it checks is not yet read |
| Contention (Woodmass, 2005) | 48K | contended or not, T-state by T-state | Not compared |
| Timing Test (Rak) | 48K, 128K | a menu of nine tests, each a picture | Not compared; its frame length reads 69888 |
| ULA 48 Simple Test, ULA 128 Timing Test (azesmbog) | 48K, 128K | a picture | Not compared |
| IR Contention, IR Contention 128 (Woodmass) | 48K, 128K | a picture | Not compared |
| Snow48 (azesmbog), variant b6 | 48K | a test card under snow | Compared by eye with a real 48K's video (Jari Komppa's, on the wiki): both buried in snow columns. Not automated |
| Snow tests (Weiv), ULA128, other Snow48 variants, ULA Snow Crash | 48K, 128K | a picture | Not compared |

## What they have found

- **The indexed instructions' internal T-states.** The 48K's tests 23 and 24
  failed on their contended runs. The core read the displacement of `(IX+d)`
  a T-state late and ran `DD CB d` half a T-state out, so the address the ULA
  saw in their internal T-states was wrong. ZEXALL could not see it: the
  totals were right.
- **The 128K's contention start** is 14362 in this machine's frame, one later
  than Fuse's 14361: the 128K's tests 4, 17, 18, 26 and 33 fail with 14361 and
  pass with 14362, and 14360 or 14363 fails at least one.
- **The floating bus** returned the attribute over both of a cell's reads,
  two T-states early. It now returns bitmap and attribute in turn at G + 3 to
  G + 6, which Floating Spy and Float48K both check.
