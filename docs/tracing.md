# Cycle-by-cycle bus tracing

Part of the [zx-spectrum-emulator README](../README.md).

The C++ core runs at half-T-state resolution, so it can record what every
signal on the bus was doing in each half of each T-state. The trace is written
as the same box-drawn table
[visualz80remix](https://floooh.github.io/visualz80remix/) produces, which is
deliberate: a capture from here and a capture from there can be put side by
side and diffed, and that comparison is a test in its own right (see below).

```
┌─────────┬────┬──────┬──────┬──────┬────┬────┬──────┬────┬──────┬───────┬─────
│ Cycle/h │ M1 │ MREQ │ IORQ │ RFSH │ RD │ WR │ AB   │ DB │ PC   │ Watch │ Asm
├─────────┼────┼──────┼──────┼──────┼────┼────┼──────┼────┼──────┼───────┼─────
│     1/1 │ M1 │ MREQ │      │      │ RD │    │ 0000 │ 00 │ 0001 │ ??    │ DI
│     2/0 │ M1 │ MREQ │      │      │ RD │    │ 0000 │ F3 │ 0001 │ ??    │ DI
│     3/0 │    │      │      │ RFSH │    │    │ 0000 │ F3 │ 0001 │ ??    │ DI
```

Start one from the command line, which is the only way to catch the machine's
first few thousand half-clocks:

```bash
zx_server --rom roms/48.rom --trace-log boot.zxtrace --trace-limit 25000
```

| flag | meaning |
| --- | --- |
| `--trace-log PATH` | where to write; enables tracing at boot |
| `--trace-limit N` | half-T-states to record before the capture closes itself (default 25000, `0` = unlimited). One frame is 139,776 |
| `--trace-watch ADDR` | a memory address to sample into the Watch column each half-clock |
| `--trace-extra` | add the 48K-specific columns: HALT, WAIT, INT, NMI, frame, T-state |
| `--trace-start-pc ADDR` | wait for execution to reach this address before recording anything |
| `--trace-stop-pc ADDR` | close the capture on arriving at this address |

Or drive it live — with the trace viewer's own **Record** button in VS Code
(see below), or over MCP with `start_trace` / `stop_trace` / `trace_status`.
That is the usual way: capture a window around a breakpoint rather than from
power-on. All three bypass the emulator's command queue, so a capture can be
opened and closed across a run in flight rather than only around one — you can
record a game as it plays, and stop when you have seen the thing you were
after.

`start_trace` and `stop_trace` both take an optional `pc`, which captures a
window of *code* rather than a window of time:

```
start_trace {path: "sprite.zxtrace", pc: 0x8000}   # armed, recording nothing
stop_trace  {pc: 0x8123}                           # ...and where to stop
run
```

The capture opens its file immediately and writes nothing until execution
reaches `0x8000`; the first row is that instruction's fetch, numbered from 1.
It then closes itself on arriving at `0x8123`, before the instruction there is
fetched — so the file holds exactly the path from A to B, however many frames
of running it took to get there, and two captures split at the same address
join up rather than overlap. `trace_status` reports `waiting: true` while a
capture is armed but has not been reached, so a poller can tell "nothing yet"
from "nothing happening". Both addresses are matched against the address bus at
each opcode fetch, which is where an instruction's own address genuinely
appears — by the time PC is readable it has moved on.

### Addresses by name

Every address a trace takes — `pc`, `watch`, and the three `--trace-*` flags
above — can be written as a symbol rather than a number, resolved against the
loaded program's own debug info first and the ROM disassembly's second:

```
start_trace {pc: "MASK_INT", watch: "FRAMES"}
stop_trace  {pc: "KEY_INT+10"}
```

```bash
zx_server --rom roms/48.rom --trace-log int.zxtrace --trace-start-pc KEY_SCAN
```

| written | means |
| --- | --- |
| `KEY_INT` | the label's own address |
| `KEY_INT+9` | 9 bytes into it — **offsets are decimal**, as the Symbol column prints them |
| `KEY_INT+0x10`, `KEY_INT-2` | `0x` or `$` for a hex offset; `-` wraps at 64K |
| `0x0038`, `$0038`, `0038` | **a bare number is hex**, as the AB column and the disassembly print it |
| `SPRITE-INT_HANDLER` | the distance between two labels |

Both radix rules are the ones the emulator already *prints*, so a row of a
capture can be pasted straight back into the tool that made it. Names match
exactly first and then case-insensitively (`key_scan` finds `KEY_SCAN`), and
the symbol table is consulted before the number parser — so a label spelt
entirely in hex digits (`BED`, `FACE`) still wins, and `0xBED` is how to ask
for the number instead. Anything that will not resolve is an error naming the
reason, never a silent fall back to address 0.

Tracing costs nothing when it is off (one predictable branch per half-clock)
and is slow when it is on, which is why every capture is bounded.

## Viewing a trace

`tools/trace_viewer.html` is a self-contained page — no build step, no
dependencies, no network. Open it in a browser and drop a `.zxtrace` on it, or
run **ZX Spectrum: Show Trace** from the VS Code extension, which loads that
same file into a webview and reloads it whenever the capture is rewritten.

In the VS Code panel it also takes the capture. **Record** starts a trace on
whatever the current debug session is running — running or stopped, it makes no
difference — with the same `limit`, `watch` and 48K-column options the flags
above have; the header counts the half-T-states as they land. **Stop** ends it,
and so does the capture reaching its own limit; either way the finished file is
loaded into the panel straight away. It is written as `live.zxtrace` in the
workspace folder, so it is an ordinary file afterwards: keep it, diff it,
reopen it later.

It has two views over the same data:

* **Trace Log** — the table, banded per instruction and searchable (`$4000`
  jumps to the next row whose address bus holds it).
* **Timing Diagram** — CLK plus a waveform per signal, drawn active-low as a
  datasheet would, with the address/data/PC buses as labelled value segments
  and each instruction shaded behind them.

Clicking in either view moves the selection in the other, and the arrow keys
step half-clock by half-clock.

The viewer reads the header row to discover the columns, so it opens captures
made with or without `--trace-extra`, and visualz80remix's own exports too.

## What the comparison found

`cpp-core/tests/tracelog_tests.cpp` replays visualz80remix's own demo program
and diffs the two tables cell by cell. **M1, MREQ, IORQ, RD, WR, the address
bus and the T-state numbering agree everywhere** — the machine-cycle structure
is identical. Three sub-T-state differences remain, none of them observable to
a running program, all recorded in that test's `KNOWN_DIFFERENCES` so a new
one cannot creep in unnoticed:

* **RFSH** — the real chip holds refresh asserted through T4L; this core
  releases it half a T-state early, at T4H. The one that is a genuine
  inaccuracy: it shortens the window a refresh address is live on the bus,
  which is exactly where 48K "snow" comes from, so it will matter once
  contention lands.
* **Data bus on a write** — the die drives the byte at T1L, this core at T2H.
  Zilog's own timing diagram says the start of T2, so the datasheet agrees
  with us here and the die with neither.
* **PC** — incremented on the H phase here, on the L phase in the real chip.
  Purely internal; PC is not a pin, and the address it produces reaches the
  bus at the same instant either way, which is why AB matches everywhere.
