# Memory contention, the floating bus and snow

Part of the [zx-spectrum-emulator README](../README.md).

Status: **contention implemented** in the C++ core (#27, 31 October 2026),
on by default; `--no-contention` and the MCP tool `set_contention` turn it off.
`cpp-core/tests/contention_tests.cpp` checks section 6's examples and the
window's edges. The floating bus follows section 7 in #28; snow (section 8)
is not implemented yet. [retro-spectrum](https://github.com/jonsole/retro-spectrum)
writes its Verilog ULA to the same text, so the two can be compared trace
against trace.

This covers the 48K (issue 3B, the 6C001E-7 ULA) and the 128K (toastrack; the
+2 times the same). It does not cover the +2A/+3, whose gate array contends
differently and has no floating bus, nor the issue 2 48K's later timing.

## 1. What contention is

The ULA and the CPU share the lower 16K of RAM (`0x4000`–`0x7FFF`). While the
ULA reads the screen it cannot let the CPU at that RAM, so it stops the CPU's
clock. The CPU is not told; it simply finds that some of its T-states lasted
longer. Nothing about the Z80 changes: a Z80 run with no contention and the
same Z80 run on a Spectrum differ only in when their clock edges fall.

So contention is modelled as **a held clock, not as WAIT**. WAIT is a CPU pin
sampled in T2; the ULA never drives it. In the emulator, the Spectrum stops
handing the Z80 half-clocks while the ULA keeps running; in the FPGA, the ULA
holds the CPU's clock enable. The Z80 core in both knows nothing of it.

## 2. Time

All times are **frame T-states**: T-states since the start of the interrupt
pulse, as `Ula::frame_hc_ / 2` counts them and as the tracer's `TState` column
shows. One frame is 69,888 T-states on the 48K and 70,908 on the 128K.

"An access at T" means the T-state in which its **T1** begins. "A T-state is
checked at T" means the ULA looks at the bus at the start of T-state T.

| | 48K | 128K | Source |
|---|---|---|---|
| T-states a line | 224 | 228 | `ula.h` |
| Lines a frame | 312 | 311 | `ula.h` |
| First contended T-state, **C₀** | **14335** | **14361** | Fuse; the timing suites pass with these |
| Contended lines | 192 | 192 | the paper |
| Contended T-states a line | 128 | 128 | 16 groups of 8 |

## 3. The contention window

The ULA works in **groups** of 8 T-states, 16 a line, one group for each 16
pixels (two character cells). In each group it reads four bytes and leaves
four T-states free.

Group g (0–15) of paper line l (0–191) starts at

    G(l, g) = C₀ + l × line + 8 × g

A checked T-state at G + k, for k = 0…7, is held for

| k | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| T-states held | 6 | 5 | 4 | 3 | 2 | 1 | 0 | 0 |

That is the published 6, 5, 4, 3, 2, 1, 0, 0 pattern, and it says one simple
thing: **a checked T-state that falls in the first six of a group waits until
G + 6.** Outside the 192 × 128 windows nothing is ever held.

## 4. The rule: when the ULA checks

The ULA checks a T-state in two cases.

**4.1 Address checks.** At the start of every T-state in which **MREQ is
inactive** and the **address bus holds a contended address**, the ULA checks.
A held T-state is stretched in its first half: the address is valid and MREQ
has not yet fallen, the T1H..T1L gap the Z80 core is clocked in half-states to
show (`z80.h`).

**4.2 ULA port checks.** In an I/O cycle to the ULA's own port (A0 = 0), the
ULA checks once, at the start of **T2**, whatever the address. It does not
check that cycle's TW or T3 again, nor by address.

Why MREQ matters: in a memory read or write MREQ is low from T1L to the end of
T3, and in an opcode fetch through T2 and, for the refresh, T3 and T4. So a
memory cycle is checked only at its T1, and an opcode fetch only at its T1. An
internal T-state has no MREQ, so it is checked whenever the address left on the
bus is contended. An I/O cycle has no MREQ, so all four of its T-states are
address-checked unless the ULA's own port rule replaces them.

### 4.3 What is left on the bus

Internal T-states check whatever address the Z80 leaves on the bus. On a real
Z80 that is:

- after an opcode fetch, **IR** (the refresh address, I in the high byte),
- after a memory read or write, that cycle's address.

So `LD A,I`, `INC SP` and the like are contended when I is `0x40`–`0x7F`, and
`INC (HL)` is contended on its internal T-state when HL is. Whether `z80.cpp`
leaves these addresses on the bus in every internal T-state is checked as part
of #27, against the tables below.

### 4.4 Contended addresses

| Machine | Contended |
|---|---|
| 48K | `0x4000`–`0x7FFF` |
| 128K | `0x4000`–`0x7FFF` (always bank 5), and `0xC000`–`0xFFFF` while bank 1, 3, 5 or 7 is paged there |

For an I/O cycle the "address" is the port, so the high byte decides: on the
48K a port is address-checked when A15–A14 are `01`; on the 128K also when
they are `11` and a contended bank is at `0xC000` (open point P3).

## 5. The rule against the published tables

The per-instruction tables in the comp.sys.sinclair FAQ and in Fuse's sources
list each instruction's accesses as `address:T-states`. The rule above gives
every one of them.

| Cycle | Checked T-states | Table |
|---|---|---|
| Opcode fetch | T1 | `pc:4` |
| Memory read or write | T1 | `hl:3` |
| One internal T-state, after a read of HL | itself | `hl:1` |
| One internal T-state, after a fetch | itself, address IR | `ir:1` |
| I/O, high byte not contended, A0 = 1 | none | `N:4` |
| I/O, high byte not contended, A0 = 0 | T2 (ULA port) | `N:1, C:3` |
| I/O, high byte contended, A0 = 1 | T1, T2, TW, T3 | `C:1, C:1, C:1, C:1` |
| I/O, high byte contended, A0 = 0 | T1 (address), T2 (ULA port) | `C:1, C:3` |

## 6. Worked examples

All on the 48K (C₀ = 14335) unless they say otherwise. Code at `0x8000` is
never contended.

**LD A,(HL)** (`7E`), HL = `0x4000`, fetch at 14331. The fetch takes
14331–14334. The read's T1 at 14335 is G + 0, held 6, so T1 runs at 14341,
T2 at 14342, T3 at 14343. 13 T-states instead of 7; the next fetch is at
14344.

**The same, fetch at 14333.** The read's T1 at 14337 is G + 2, held 4, so
the instruction takes 11.

**OUT (0xFE),A** (`D3 FE`), A = `0x07`, fetch at 14328. The fetch and the
operand read take 14328–14334. The I/O cycle's T1 at 14335 has port `0x07FE`,
not contended. Its T2 at 14336 is a ULA port check at G + 1, held 5, so T2
runs at 14341, TW at 14342, T3 at 14343. 16 T-states instead of 11.

**LD A,I** (`ED 57`), I = `0x40`, fetch at 14327. The two fetches take
14327–14334. The internal T-state at 14335 has IR on the bus, contended, at
G + 0: held 6. 15 T-states instead of 9.

**128K: OUT (C),A** (`ED 79`), BC = `0x7FFD`, fetch at 14353. The two fetches
take 14353–14360. Port `0x7FFD`'s high byte is contended and A0 = 1, so each
I/O T-state is address-checked. T1 at 14361 is G + 0 (C₀ = 14361): held 6,
runs at 14367. T2 at 14368 is G + 7: not held. TW at 14369 is the next
group's G + 0: held 6, runs at 14375. T3 at 14376 is G + 7: not held. The I/O
cycle takes 16 T-states instead of 4, the instruction 24 instead of 12.

## 7. The floating bus

When the CPU reads a port nothing answers, nothing drives the data bus and the
CPU reads whatever the ULA's side of it holds.

The ULA's four reads are visible in turn, as **Ramsoft's floating bus
guide** gives them and its test program checks:

| T-state | The CPU reads |
|---|---|
| G + 3 | the bitmap byte of the group's first cell |
| G + 4 | its attribute |
| G + 5 | the bitmap byte of the second cell |
| G + 6 | its attribute |
| G + 7 to the next group's G + 2 | `0xFF` |
| outside the 192 × 128 windows | `0xFF` |

An `IN` latches the bus in the middle of its T3, so the T-state that counts is
the one holding the I/O cycle's T3.

The emulator differs today, and #28 brings it to this table:

- it returns the attribute over both of a cell's reads and never a bitmap
  byte (commit 58d3495). That was based on a measurement this project no
  longer relies on;
- its reads are two T-states earlier than Ramsoft's, and it fetches the
  group it is displaying rather than the one ahead (`Ula::floating_bus`).

Programs that poll the bus for an attribute value and could be fooled by an
equal bitmap byte (stepscroll's raster sync was the reason for 58d3495) are
checked again once #28 lands.

## 8. Snow

The Z80 puts the refresh address IR on the bus in T3 and T4 of every opcode
fetch, with MREQ low and RFSH low. When I is `0x40`–`0x7F`, the lower RAM sees
a row access from the CPU in the middle of the ULA's own reads. The ULA's read
in progress then takes its row from the refresh: the byte it fetches comes
from an address that keeps the ULA's own high part and takes its low part from
R. The wrong byte reaches the screen, as "snow". The CPU is not held for it:
MREQ is low, so rule 4.1 does not check (open point P2 for the details).

Two consequences for the model:

- The tracer's refresh ends half a T-state early, at T4H rather than T4L
  ([tracing.md](tracing.md#what-the-comparison-found)). That shortens the window
  in which snow can happen, so #27 fixes it first.
- On the 128K, I in `0x40`–`0x7F` is known to crash the machine, not only to
  snow. That crash is **not modelled** (decided 31 October 2026); the 128K's
  snow is modelled on the display only.

## 9. Test plan

Expected values are worked out from this text, not captured from either
implementation.

| Test | What it checks |
|---|---|
| Every row of section 5's table, for every k = 0…7 of a group, at G and outside the windows | The rule and the pattern |
| Section 6's examples, each a unit test with its T-state count | Worked numbers |
| One instruction from each line of the FAQ's contention table at each k, against the table | `z80.cpp`'s bus addresses in internal T-states |
| The last group of line 191, and the first T-state after it | The window's edges |
| The 128K with each bank at `0xC000`, memory and I/O | Section 4.4 |
| A trace (`--trace-extra --trace-ula`) around each example | The held half-clocks are visible, between T1H and T1L |
| The rewind determinism test with contention on | Replays still match |
| The public suites (#30): the 48K timing tests, IR contention, snow, floating bus | The whole, against hardware-derived expectations |

## 10. Open points

| # | Question | How to settle |
|---|---|---|
| P1 | ~~The floating bus~~ | Ramsoft's account (section 7); the floating bus suites in #30 check it |
| P2 | Snow's exact address: which bits come from R and which from the ULA's address, and which of the four reads can be hit | Smith, *The ZX Spectrum ULA*, the chapter on the DRAM interface; the snow tests in #30 |
| P3 | Whether the 128K address-checks I/O whose high byte is `0xC0`–`0xFF` while a contended bank is paged | Fuse does; the 128K timing tests in #30 |
| P4 | ~~The 128K's crash with I = `0x40`–`0x7F`~~ | Not modelled (31 October 2026) |
| P5 | Where in the held T-state the check is made, to the half-clock: the clock held high before T1L, as section 4 says | Smith, the chapters on the clock generator and contention |
| P6 | The ULA port rule (4.2): confirm it checks T2 only, and not by address after T1 | Smith; the I/O rows of the 48K timing tests |

Smith's book covers the 48K's ULA only; the 128K's numbers come from Fuse, the
suites and the published tables.

## 11. Sources

- Chris Smith, *The ZX Spectrum ULA: How to Design a Microcomputer* (2010):
  the 48K ULA's schematic-level account. Read for P2, P5 and P6.
- The comp.sys.sinclair FAQ's contended memory and I/O tables, and Fuse's
  `z80_ops` contention annotations: the per-instruction tables of section 5.
- Ramsoft, *The floating bus technical guide*: section 7.
- The ZX Spectrum Next's FPGA source (`zxula`), read for facts only.
- The ZX Spectrum test collection on
  [redcode/ZXSpectrum's wiki](https://github.com/redcode/ZXSpectrum/wiki/Tests):
  the suites #30 runs.
