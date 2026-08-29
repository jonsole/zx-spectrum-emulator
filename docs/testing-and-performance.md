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

Above those sits the full [ZEXALL/ZEXDOC](https://github.com/agn453/ZEXALL)
exerciser, labelled `slow` and excluded from the routine run: over a billion
emulated instructions per pass.

## Performance

Measured by `tests/bench_machine.cpp` (`bench_machine.exe`, RelWithDebInfo) —
the machine and Engine layers, i.e. what a connected client actually
experiences, rather than bare CPU throughput:

```
  machine (CPU+ULA, direct clock)        50.7 M half-clocks/s     7.25x realtime
  engine run(), uncapped                 40.5 M half-clocks/s     5.79x realtime
  engine run(), realtime (default)        7.0 M half-clocks/s     1.00x realtime
```

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
