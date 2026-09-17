# Testing and performance

Part of the [zx-spectrum-emulator README](../README.md).

## Testing

```powershell
cd cpp-core
.\build.ps1 -Release -Test     # the fast suite, via CTest
.\build.ps1 -Release -Slow     # ZEXALL + ZEXDOC only -- many minutes each
```

128 assertions across ten executables: the ALU and a pin-level check diffed
against the vendored `z80.h` reference (`alu_tests`, `pin_level`, and
`differential`, which runs both cores in lockstep), the 48K memory map, the
beeper's decimator, interrupt timing, the machine layer against a real ROM
(`spectrum_tests`), `.tap`/`.tzx` parsing and the fast-load trap
(`tape_tests`, 49 of them), `.wav`/`.csw` decoding and the Schmitt trigger
(`tape_audio_tests`, 19), and the bus trace against a captured
visualz80remix reference (`tracelog_tests`).

`tape_audio_tests` is worth singling out for how it is built: it renders a
`.tap`'s own pulses out to 44.1kHz audio, dirties them the way a cassette and a
sound card would, and requires the real ROM to load a BASIC program back off
the result. Neither end of that can pass by agreeing with a bug -- one end is
the emulator's playback and the other is Sinclair's loader, and only the code
under test sits between them. Tests that need the real ROM skip
themselves rather than fail when `roms/48.rom` is absent.

The execution profiler has two of its own: `profile_tests` checks costs worked
out by hand from the Z80's documented timings (a `DJNZ` loop, a `HALT` woken by
interrupts, nested and recursive calls, a stack pointer borrowed for data, frame
and turn periods), plus the rule that every half-clock is charged exactly once;
`profile_report_tests` checks the folding into lines, routines and the call
tree against a handful of SLD records. `call_stack` covers the debugger's call
stack, which follows the profile's rule for when a call has ended.

`watchpoint_tests` covers both halves of watchpoints on hand-written programs:
the machine's -- a write reporting both values, a write of the same value
tripping "every write" but not "only when it changes", a read watch ignoring
the instruction fetch at that address and the ULA's own screen reads, `PUSH`
and `CALL` onto a watched stack slot, a range hit by `LDIR`, and a debugger's
poke tripping nothing -- and the Engine's, where a run stops at the
instruction after the access, resumes correctly, honours a value test, and can
have a watchpoint armed on a machine that is already running.

Stepping backwards has `rewind_tests` (built only with rewind, the default).
Its core is a determinism test: the ROM boots, keys are typed through the
input log, a tape loads through the fast-load trap and a register edit sends
the machine into code that borrows the stack pointer and `HALT`s, all while the
whole machine state is hashed at every frame -- then replays from checkpoints
across the run must reproduce every hash, on a 48K and on a 128K. A part of the
machine a checkpoint misses shows up as the frame it first diverges at. The
rest check each backward operation against the boundaries a program was seen to
pass through the first time (a step back must land on exactly that half-clock,
PC, call depth and state), and the timeline rules: replaying forward reaches
the head and goes live, and a key pressed in the past branches. Check a change
to the rewind code with `build.ps1 -NoRewind -Target zx_server` as well: the
feature must compile out cleanly.

The VS Code extension's logic that does not need VS Code itself is tested from
plain Node: `node vscode-extension/tests/asm_index_test.js` (the Z80 symbol
index: definitions, references, rename and call hierarchy, including against
this repo's own sources) and `node vscode-extension/tests/profile_model_test.js`
(how a profile report becomes the heat map and the call tree),
`node vscode-extension/tests/rewind_model_test.js` (the "before live" status
text), `node vscode-extension/tests/watchpoint_model_test.js` (how a
watchpoint reads, and what "player 8" in the Watch Address box means) and
`node vscode-extension/tests/screen_scaling_test.js` (how big the screen panel
draws the picture on a scaled display, how the border crop keeps each side in
proportion, where the scanline gaps fall, and that the functions the page is
given as source still work there).

Above those sits the full [ZEXALL/ZEXDOC](https://github.com/agn453/ZEXALL)
exerciser, labelled `slow` and excluded from the routine run: over a billion
emulated instructions per pass.

## Performance

Measured by `tests/bench_machine.cpp` (`bench_machine.exe`, RelWithDebInfo) —
the machine and Engine layers, i.e. what a connected client actually
experiences, rather than bare CPU throughput:

```
  machine (CPU+ULA, direct clock)        47.6 M half-clocks/s     6.81x realtime
  engine run(), uncapped                 42.4 M half-clocks/s     6.06x realtime
  engine run(), uncapped, profiling      40.6 M half-clocks/s     5.81x realtime
  engine run(), realtime (default)        7.0 M half-clocks/s     1.00x realtime
```

The "profiling" line is the same run with the
[execution profile](vscode-debugging.md#execution-profile) counting: a few
percent slower, within the run-to-run noise of these numbers. With profiling
off it costs nothing measurable -- one pointer test per instruction.

`bench_machine` also has a watchpoint line: an armed watchpoint that nothing
ever trips, so every memory access the CPU makes pays the flag test, reads
included. It measured 5.85x realtime against 5.83x and 5.95x for the same run
unwatched -- no cost worth reporting, which is what made watching reads as well
as writes worth having from the start.

`bench_machine` says at the top whether rewind is compiled in, and the engine
lines include keeping its history. Side by side with a `-NoRewind` build of the
benchmark (`build.ps1 -Release -NoRewind -Target bench_machine`, into
`build\RelWithDebInfo-norewind`), uncapped engine runs measured 4.25x and
3.83x realtime with rewind against 4.36x and 4.05x without: a few percent at
most, inside the noise between runs. Realtime runs are unaffected.

So the core runs a 48K at **~7× real hardware speed** with headroom to spare,
and paces itself down to 1.00× for normal use — games run at the right speed,
and `--uncapped` hands the rest back to the exercisers. Link-time optimisation
is worth ~23% of that on its own (41.5 → 51.2 M half-clocks/s when it was
turned on), because the hot loop crosses a translation-unit boundary on every
half-clock; see the comment in `cpp-core/CMakeLists.txt`.

<details>
<summary>Historical: the deprecated Python core's performance</summary>

Because every T-state crossed the Python↔native-C boundary, bulk execution ran
at roughly **0.5× real hardware speed** (~1.7 MHz effective vs. 3.5MHz real).
That was a deliberate tradeoff: the design target is debugger-driven
single-stepping, not real-time gameplay, and a faster bulk-tick path would
have required duplicating the bus-servicing logic outside the single code path
that per-T-state watchpoints depend on. The C++ core keeps that same single
code path and is fast enough anyway, which is what removed the tradeoff.

</details>
