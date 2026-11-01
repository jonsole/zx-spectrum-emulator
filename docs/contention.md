# Contention and the floating bus

Part of the [zx-spectrum-emulator README](../README.md).

On a 48K or 128K Spectrum the CPU and the ULA share some of the RAM. While
the ULA reads the screen out of it, two things happen that a program can
notice:

- **Contention.** A CPU access to that RAM, or to the ULA's port, has to wait:
  the ULA stops the CPU's clock for up to 6 T-states.
- **The floating bus.** A read from a port nothing answers returns whatever
  the ULA's screen read has left on the data bus: a byte of the screen, or
  `0xFF` when the ULA is not reading.

Both follow from one timetable, the ULA's, which this page describes first.
It covers the 48K (issue 3, the 6C001E-7 ULA) and the 128K (the toastrack and
the grey +2, which time alike). The +2A and +3 work differently and are not
emulated.

| | Emulated |
|---|---|
| Memory and I/O contention, 48K and 128K | Yes, on by default |
| The floating bus, 48K and 128K | Yes |
| Snow, and its double, 48K and 128K | Yes, with contention |

## 1. Time

Times are **frame T-states**: T-states since the interrupt began, 0 to 69,887
on the 48K and 0 to 70,907 on the 128K. They are what the debugger's trace
shows in its `TState` column and what timing tests quote.

Within an instruction, each machine cycle is named by its T-states: T1, T2,
T3 (and TW, the wait state in an I/O cycle). Every T-state has two halves,
the clock high then low. In T1 of a memory access the address goes out in the
high half, and the memory request (MREQ) goes down in the low half. That gap
is where the ULA decides whether to hold the CPU.

## 2. The ULA's timetable

The ULA draws 2 pixels a T-state. To draw 16 pixels -- two character cells --
it needs four bytes from RAM: the first cell's bitmap and attribute, then the
second's. It reads them in groups of 8 T-states, one group for each 16 pixels,
16 groups across the 256 pixels of a line, on each of the 192 lines that have
paper.

The first group of the frame starts at **C₀**:

| | 48K | 128K |
|---|---|---|
| T-states a line | 224 | 228 |
| C₀, the first group of line 0 | **14335** | **14362** |

and group g (0 to 15) of paper line l (0 to 191) starts at

    G = C₀ + l × (T-states a line) + 8 × g

Every T-state of a group plays the same part, whatever the group:

| T-state | G | G+1 | G+2 | G+3 | G+4 | G+5 | G+6 | G+7 |
|---|---|---|---|---|---|---|---|---|
| The ULA reads | | | bitmap 1 | attribute 1 | bitmap 2 | attribute 2 | | |
| An `IN` from a free port sees | `FF` | `FF` | `FF` | bitmap 1 | attribute 1 | bitmap 2 | attribute 2 | `FF` |
| A contended T-state starting here waits | 6 | 5 | 4 | 3 | 2 | 1 | 0 | 0 |

Outside the groups -- the borders above, below and to each side, and the
retrace -- the ULA reads nothing: nothing waits, and a free port reads `0xFF`.

The bottom row is the 6, 5, 4, 3, 2, 1, 0, 0 pattern quoted for the Spectrum
everywhere. It says one thing: a CPU T-state that the ULA holds is let go at
G + 6, once the ULA has its four bytes.

## 3. Contention

### 3.1 Which T-states the ULA holds

The ULA looks at the CPU's bus at the start of every T-state and holds it
when either is true:

1. **The address on the bus is contended and MREQ is not down.** MREQ is down
   from the low half of T1 to the end of every memory read and write, and
   through the refresh at the end of an opcode fetch. So:
   - a memory read, write or opcode fetch is checked once, at its T1;
   - an internal T-state -- one where the CPU works without using the bus --
     is checked every time, by whatever address the CPU left on the bus;
   - an I/O cycle has no MREQ, so all four of its T-states are checked, by
     the port number as an address.
2. **An I/O cycle to the ULA's own port** -- any even port -- is checked once,
   at its T2, whatever its address. After that the ULA lets the cycle finish:
   its TW and T3 are not checked again.

A held T-state stretches in its first half, the clock held high with the
address out and MREQ not yet down, until the ULA lets go. The CPU knows
nothing about it: it simply finds that T-state took longer.

### 3.2 Contended addresses

| | Contended |
|---|---|
| 48K | `0x4000`–`0x7FFF` |
| 128K | `0x4000`–`0x7FFF` (bank 5, always), and `0xC000`–`0xFFFF` while bank 1, 3, 5 or 7 is paged there |

For an I/O cycle the port's high byte decides, as if it were an address.

### 3.3 What the CPU leaves on the bus

Internal T-states are checked by the address still on the bus from the cycle
before:

- after an opcode fetch, **IR** -- the refresh address, with I in the high
  byte. So instructions such as `LD A,I`, `INC SP` or `LD SP,HL` are held when
  I is `0x40`–`0x7F`.
- after a memory read or write, that cycle's address. So `INC (HL)` is held
  on its internal T-state when HL is contended, and `LD A,(IX+d)` on the five
  T-states after it reads d when the code is in contended memory.

### 3.4 The rule against the published tables

The per-instruction contention tables (the comp.sys.sinclair FAQ, Fuse's
sources) write each instruction as a list of `address:T-states`. The rule
gives every entry:

| Cycle | Checked | Published as |
|---|---|---|
| Opcode fetch | T1 | `pc:4` |
| Memory read or write | T1 | `hl:3` |
| Internal T-state after a read of HL | itself | `hl:1` |
| Internal T-state after a fetch | itself, by IR | `ir:1` |
| I/O, high byte not contended, odd port | none | `N:4` |
| I/O, high byte not contended, even port | T2 | `N:1, C:3` |
| I/O, high byte contended, odd port | T1, T2, TW, T3 | `C:1, C:1, C:1, C:1` |
| I/O, high byte contended, even port | T1, then T2 | `C:1, C:3` |
| Interrupt acknowledge (M1 with IORQ, PC on the bus) | T1, T2, TW, TW, by PC | not in the tables |

### 3.5 Worked examples

On the 48K, with the code at `0x8000`, which is never contended.

**`LD A,(HL)`, HL = `0x4000`, fetch at 14331.** 7 T-states uncontended:
fetch 4, read 3. The fetch takes 14331–14334. The read's T1 at 14335 is the
first group's G, held 6, so it runs at 14341. **13 T-states.**

**The same, fetch at 14333.** The read's T1 at 14337 is G + 2, held 4.
**11 T-states.**

**`OUT (0xFE),A`, A = `0x07`, fetch at 14328.** 11 T-states uncontended. The
I/O cycle starts at 14335 with port `0x07FE`: its T1 is not checked, since
`0x07` is not a contended high byte. Its T2 at 14336 is the ULA's port check,
at G + 1, held 5. **16 T-states.**

**`LD A,I`, I = `0x40`, fetch at 14327.** 9 T-states uncontended. Its
internal T-state at 14335 has IR on the bus, contended, at G: held 6.
**15 T-states.**

**128K: `OUT (C),A`, BC = `0x7FFD`, fetch at 14354.** 12 T-states
uncontended. Port `0x7FFD`'s high byte is contended and the port is odd, so
every T-state of the I/O cycle is checked. T1 at 14362 is G, held 6. T2 at
14369 is G + 7, not held. TW at 14370 is the next group's G, held 6. T3 at
14377 is G + 7, not held. **24 T-states.**

## 4. The floating bus

A port nothing answers -- on the 48K, any odd port; on the 128K, any odd port
the AY does not decode -- leaves the data bus undriven. An `IN` takes its byte
in its T3, and what it finds there is what the ULA's screen read has left:

| T3 of the `IN` at | Value |
|---|---|
| G + 3 | the group's first bitmap byte |
| G + 4 | the first cell's attribute |
| G + 5 | the second bitmap byte |
| G + 6 | the second cell's attribute |
| anywhere else | `0xFF` |

That is one T-state after the ULA reads each byte (section 2): the CPU picks
up what the read left on the bus. The bytes come from the screen as it is at
that moment, in the screen bank shown.

`IN A,(n)` takes its byte 10 T-states after its fetch starts (fetch 4, operand
3, then T1, T2 and TW of the I/O cycle), so an `IN A,(0xFF)` fetched at 14328
reads the first bitmap byte of the screen.

**Using it.** A program with no interrupt to hand can poll the floating bus to
find where the beam is: put a recognisable attribute where it wants to wait,
and loop on `IN A,(0xFF)` until it comes back. Some commercial games do this
(Arkanoid, Cobra, Sidewize). Two things to know:

- **Bitmap bytes come back too.** A loop waiting for an attribute value can
  stop early on a bitmap byte that happens to equal it; choose a value the
  bitmap there cannot hold.
- **Make the loop an odd number of T-states long.** A loop of a multiple of
  8 T-states samples the same T-state of every group, and one of an even
  length samples only every other one: started on the wrong ones it never
  sees the attribute at all.

## 5. Snow

Snow is the ULA reading the wrong screen bytes because the CPU's memory
refresh lands in the middle of its read. It needs **I to point at contended
memory** -- I = `0x40`–`0x7F`, or on the 128K I = `0xC0`–`0xFF` with an odd
bank paged at `0xC000` -- and code running from uncontended memory: a fetch
from contended memory is always held until G + 6, clear of the ULA's reads.

Why it happens: the ULA reads in two bursts, one per cell. For each it sets
the RAM's column address (screen address bits 6–0) once, then gives two row
strobes (bits 13–7), one for the bitmap and one for the attribute. The CPU's
refresh drives the same RAM's column strobe, from the middle of the fetch's
T3 to the middle of its T4. So it matters where that refresh falls:

| The opcode fetch | Its refresh (T3 and T4) | Effect |
|---|---|---|
| starts at G − 1 | G + 1 and G + 2, across the first read | **Snow.** The first cell's bitmap and attribute are read with bits 6–0 of their addresses taken from R (as R is after the fetch). The cell shows those bytes |
| starts at G + 1 | G + 3 and G + 4, across the gap before the second read | **Double.** The second read does not happen; the second cell shows the first cell's bitmap and attribute again |
| starts anywhere else | elsewhere | Nothing |

In Weiv's words, snow is the fetch's fourth T-state on the ULA's third, and
the double on its fifth, counting the ULA's T-states from 1 at G.

On the 128K the snow bytes come from a bank set by the bank I points at and
the screen shown:

| I points at bank | Screen in bank 5 | Screen in bank 7 |
|---|---|---|
| 1 or 3 | bank 1 | bank 3 |
| 5 or 7 | bank 5 | bank 7 |

Some 128Ks hang or reset when I points at contended memory. That is not to be
modelled.

## 6. In the emulator

- **On by default.** `zx_server --no-contention`, or the MCP tool
  `set_contention`, turns contention off; every instruction then takes its
  uncontended time. Changing it restarts the rewind history. The floating bus
  is always on.
- **Seeing it.** A bus trace (`--trace-log` with `--trace-extra`, or
  `start_trace`, [tracing.md](tracing.md)) shows a held T-state as repeated
  rows with the address out and MREQ not yet down, while the `TState` column
  moves on. The profiler's costs include the waits.
- **Where it lives.** `Spectrum::clock` decides the holds between the CPU's
  two halves of a T-state, from a table of hold lengths for the frame, and
  spots each refresh for snow; `Ula::floating_bus` answers free ports and
  `Ula::snow` and `Ula::double_read` change the bytes of the group being
  drawn. The Z80 core knows about none of it.
- **Port writes to the ULA** -- the border, MIC and speaker -- take effect
  in the second half of T2, after the check and any hold, half a T-state
  after WR goes down: until the hold ends, the ULA's data bus carries the
  screen and not the CPU's byte.
- **Tests.** `contention_tests` and `floating_bus` check every worked number
  on this page, each worked out from the rules here, not taken from the code.
  The public timing tests ([timing-suites.md](timing-suites.md)) check the
  whole against programs written on real machines.

## 7. How we know, and what is still assumed

**Settled by the public tests.**

- C₀: the Butlers' 48K and 128K timing tests all pass with 14335 and 14362,
  and each fails something one T-state either side. Fuse gives 14361 for the
  128K, one earlier, in its own count of the frame.
- The floating bus's four T-states: Ramsoft's Floating Spy self-test ends
  "Floating bus OK" with the table in section 4, and with it one T-state
  earlier reports its first reads wrong -- 64 where it expects 0, 1 where it
  expects 64 -- and lingers on them. Mark
  Woodmass's Float48K, which prints the byte read at each T-state, shows the
  same table.
- The internal T-states of the indexed instructions: the 48K's tests 23 and
  24 failed until the core left the right addresses on the bus there.

**Settled by a real machine.**

- Snow's phase. Weiv's account disagrees with itself by a T-state: his text
  puts the snowing fetch's T4 on the ULA's third T-state, his phase table its
  T3. azesmbog's Snow48 test (variant b6) on a real 48K -- issue 3, NEC
  D780C-1, ULA 6C001E-6, filmed by Jari Komppa -- shows its test card buried
  in snow columns. With the text's phase the emulator draws much the same;
  with the table's the card comes out almost clean. The text's is the one
  here.

**Assumed, and what would settle it.**

| | Assumed | Settled by |
|---|---|---|
| The 128K and I/O at `0xC000` | A port with high byte `0xC0`–`0xFF` is contended while an odd bank is paged at `0xC000`, as Fuse does | The 128K timing tests that exercise it |
| Where a hold sits | In the first half of the T-state, the clock held high | Chris Smith's *The ZX Spectrum ULA* |
| The interrupt acknowledge | Held by the rule, like any T-state without MREQ, when the interrupted code is in contended memory: PC is on the bus through T1, T2 and both wait states | A test that times an interrupt taken in contended code; none of the suites run here does |
| The ULA's own port | Checked once, at T2 | Smith; the only rule that gives `C:1, C:3` |
| A held border `OUT` | The port takes the value at T2's second half, after the check and any hold, not at its first half with WR already down. The ULA reads the write from its own data bus, which carries screen bytes until the hold ends -- the reason the cycle is held at all. The Next's core does the same; Fuse and the ZX-Uno's ULA latch at the start of the hold | How the ULA latches port `0xFE` in Smith; or a border-timing test on a real 48K |
| Snow's detail | The bits from R, the double, and the 128K's bank table, from Weiv | His snow tests and the ULA128 test, compared with videos of real machines |

## 8. Sources

- Chris Smith, *The ZX Spectrum ULA: How to Design a Microcomputer* (2010).
- The comp.sys.sinclair FAQ's contended memory and I/O tables, and Fuse's
  contention annotations.
- Ramsoft, *The floating bus technical guide*, and its Floating Spy program.
- Weiv, *Exact emulation of the Snow effect* (forum post, 19 October 2022,
  updated April 2023), with TheMartian's explanation of the DRAM signals.
- The test collection on
  [redcode/ZXSpectrum's wiki](https://github.com/redcode/ZXSpectrum/wiki/Tests).
