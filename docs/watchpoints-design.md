# Watchpoints: design

Status: **built.** How to use them is in
[vscode-debugging.md](vscode-debugging.md#watchpoints) and
[mcp.md](mcp.md#watchpoints); this file keeps the design, and [As
built](#as-built) lists where the build departed from it.

## What it is for

A breakpoint answers *when does execution reach here*. A watchpoint answers the
question that actually comes up while debugging a game: *what wrote that?* The
player's X coordinate is suddenly 255, an object record is corrupt, a system
variable moved -- and nothing in the code obviously touches it.

Today the emulator can answer that only after the fact, with
[Run Back to Last Write](vscode-debugging.md#stepping-backwards): notice the bad
value, then search the history backwards for the instruction that wrote it. That
is often the better tool, because you do not have to know in advance which
address will go wrong. What is missing is the forward half -- stop the machine
*as* it happens, with the call stack of the routine doing it, and let the program
run on from there.

| Watch | Stops when |
|---|---|
| **write** | the program writes the address, whatever the value |
| **change** (the default) | a write actually changes the value there |
| **read** | the program reads the address as data -- not when it executes it |
| **value** | a write leaves a particular value there (`= 0`, `<> 3`) |

Each covers an address or a **range**, so "anything in this 8-byte object
record" is one watchpoint, not eight.

## How it works

Every write the CPU makes already passes through one place --
`Spectrum::service_bus`, where `ula.note_write` and rewind's search hook already
sit -- and so does every read. A watchpoint is a flag on an address, checked
there.

```
    uint8_t* watch_flags_;   // 64K of flags, or null when nothing is watched
```

- `watch_flags_` is null until the first watchpoint, so a machine with none pays
  **one null test per memory access** and nothing else. The array is 64K, which
  is a fifth of what the ULA's own display buffers already cost, and never
  reallocated once made.
- Bits per address: `WATCH_WRITE`, `WATCH_READ`. A range sets the flag over
  every address in it, so the check never becomes a list walk however many
  watchpoints there are.
- On a hit the machine records what happened and **does not stop there**. A Z80
  instruction is mid-flight at that point -- half-way through a `LDIR` iteration,
  or between the two halves of a `PUSH` -- and stopping inside one would leave
  the call stack, the profile and rewind's positions all describing an instant
  no debugger can step from.

```
    struct WatchHit {
        bool hit = false;
        uint16_t addr = 0;
        uint8_t old_value = 0, new_value = 0;
        bool write = false;
        uint16_t pc = 0;      // the instruction that did it
    };
```

`pc` is `step_instruction`'s own `pc_before`, which it already computes, so the
hit names the instruction that wrote rather than the one after it. The run loop
checks `m.watch_hit.hit` after each instruction, exactly as it checks
`break_on_interrupt` today, and stops with a new `StopReason::DataBreakpoint`.
The machine stops **after** the writing instruction completes: the new value is
in memory and `old_value` says what it replaced.

The Engine owns the list of watchpoints (id, address, length, access, condition,
enabled) and rebuilds the flags whenever it changes; the machine holds only the
flags and the hit. That is the same split as breakpoints, where the machine holds
a `std::set<uint16_t>` and everything else lives above it.

### What counts

- **The program's own accesses only.** A debugger's `write_memory` poke goes
  through `Spectrum::write_memory`, not the bus, and deliberately does not
  trigger: you asked for that write.
- **A read means a data read.** The flag is checked on `MREQ|RD` with `M1`
  clear, so executing code at a watched address does not count as reading it --
  that is what a breakpoint is for. The ULA's own display fetches never reach
  this path at all, so watching screen memory does not fire fifty times a frame.
- **The stack counts.** `PUSH`, `CALL` and an accepted interrupt all write
  through the bus, so a watchpoint on a stack slot catches whatever overwrote a
  return address -- the failure mode the call stack's own rule exists for.
- **A 128K watches the 16-bit address**, whichever bank is paged there, matching
  how breakpoints and the profile already treat a 128K. Watching a bank that is
  paged out is the same as watching whatever is paged in instead. (Watching
  bank-and-offset is possible later -- `memory.bank_of` is right there -- but it
  is a second kind of watchpoint, not a better one.)

### Cost

One flag load and a branch per CPU memory access, plus one test per instruction
in the run loop. Writes are a small share of a program's accesses; reads are
two or three an instruction, which is why read watching is worth measuring
separately. `bench_machine` gets a watchpoint line, measured with a write-heavy
program (filmation's blitter) rather than the ROM's boot, which barely writes.
Expected: lost in the noise with none set, a percent or two with some.

If reads turn out to cost more than that, the fallback is a second pointer,
null unless a read watch exists, so a write-only watchpoint leaves the read path
exactly as it is now.

## Interaction with rewind

The two halves of the same question, and they should share the same hook.

- [Run Back to Last Write](rewind-design.md) already watches writes during a
  replay search through `Spectrum::write_watch`. That becomes a watchpoint on
  the same flags array, which gets ranges and reads backwards for free: *what
  last touched anything in this record?*
- **Reverse Continue stops at the previous watchpoint hit**, as it stops at the
  previous breakpoint hit. This is the tool that answers "what wrote that?" with
  no forward planning at all: notice the bad value, set a watchpoint on it,
  reverse-continue.
- A replay must not stop or announce anything, so `History::replay` detaches the
  flags and clears the hit the way it already detaches the profile and the trace.
  `rewind_tests`' determinism test covers the machine state; a watchpoint left
  armed across a replay would show up there as a divergence.

## Surface

### DAP

DAP has watchpoints already -- it calls them data breakpoints -- so VS Code's own
UI works once the adapter says it supports them.

- `initialize` declares `supportsDataBreakpoints` and
  `supportsDataBreakpointBytes`.
- `dataBreakpointInfo` answers with a `dataId`:
  - from **VS Code's memory inspector** (`asAddress: true`, `name` an address,
    `bytes` a length) -- its "Break on Value Change" on a byte range;
  - from **our own commands**, where `name` is an address or a symbol
    expression, so `sprite_x` and `$9C40+2` both work;
  - from the **variables pane**, where `name` is a register. Registers are not
    memory: the answer there is either a null `dataId` with "watch the memory it
    points at instead", or register watching (see the open questions).
  - `dataId` is `"addr:length"`, `description` is what the BREAKPOINTS pane
    shows (`player_x ($9C40), 2 bytes`), `accessTypes` is read/write/readWrite,
    and `canPersist` is true -- an address means the same thing next session.
- `setDataBreakpoints` replaces that client's set, with `accessType` and DAP's
  `condition` (a value test, `= 0` / `<> 3`) and `hitCondition` (an nth-hit
  count). Tracked per connection like source breakpoints, so a watchpoint set
  over MCP is not wiped by a client that sets none.
- The stop is the standard `stopped` event with reason `data breakpoint` and a
  description saying what happened: `player_x ($9C40) 3 -> 255, written by
  sprite_move+7`.

VS Code shows data breakpoints in the BREAKPOINTS pane with checkboxes, so
enable/disable and remove come free -- for the ones it set. Ours (set from a
command or over MCP) live in the emulator, which is why the extension gets a
small view of its own.

### MCP

| Tool | Does |
|---|---|
| `set_watchpoint(address, length=1, access="write", on="change", value=None)` | Watch an address or range; `address` takes a symbol expression |
| `clear_watchpoint(id=None, address=None)` | One, or all of them |
| `list_watchpoints()` | What is watched, each with its hit count |

`run()` gains `reason` and, on a watchpoint stop, the hit: address, symbol, old
and new value, and the instruction that did it. `get_state()` reports the list.

### VS Code extension

- **Set Watchpoint...** in the editor context menu on a label and in the Command
  Palette, taking an address or symbol, a length and read/write/change -- the
  same shape as Run Back to Last Write, which it sits beside.
- **A Watchpoints view** in the debug sidebar (like the tape pane), listing what
  the emulator is watching, whoever set it, with enable/disable and remove, and
  each one's hit count.
- A hit reads like a breakpoint stop, plus a line in the Debug Console saying
  what changed and who changed it.

## Tests

1. **`watchpoint_tests`**, on hand-written programs whose answer is worked out
   rather than captured: `LD (nn),A` hits and reports both values; a write of the
   same value hits `write` but not `change`; `LDIR` into a range hits on the
   first byte in it; `PUSH` onto a watched stack slot hits; a read watch fires on
   `LD A,(nn)` but not on executing that address, and not on the ULA's display
   fetches; a debugger poke fires nothing; a range fires once per instruction,
   not once per byte.
2. **Through the Engine:** a `run` stops with the data-breakpoint reason at the
   instruction after the write, with the call stack of the routine that did it,
   and carries on correctly when resumed.
3. **With rewind:** a watchpoint armed across a step back does not fire during
   the replay, and Reverse Continue lands on the previous hit.
4. **Cost:** `bench_machine` with none, with a write watch, and with a read
   watch, against a write-heavy program.
5. **Live** (`zx-live-verify`, against filmation): watch an object record, run,
   and land on the routine that writes it; watch a stack slot; set one from VS
   Code's memory inspector and one over MCP at the same time and check neither
   clobbers the other.

## Order of work

1. Flags, the hit record and the bus checks in `Spectrum`; `watchpoint_tests`.
2. The Engine's list, the run-loop stop and the new stop reason; Engine tests.
3. Rewind: share the hook, detach across replays, Reverse Continue to the
   previous hit.
4. DAP requests and capabilities; MCP tools.
5. Extension command, context menu and the Watchpoints view.
6. Documentation, the benchmark line, live verification.

## Decisions

- **Reads are watched from the start**, alongside writes -- "who is reading
  this?" on day one rather than later. The read path is the hotter of the two
  (two or three accesses an instruction against a fraction of one), so it is
  measured on its own, and the fallback above -- a second pointer, null unless a
  read watch exists -- is what keeps a write-only watchpoint off it if the
  measurement says so.
- **Memory only; registers are not watchable.** "Break when `HL` changes" is a
  different mechanism -- a per-instruction compare, no address and no bus -- and
  would be its own feature. VS Code's "Break on Value Change" on a register row
  answers with the memory it points at instead.
- **`change` is the default, with an optional value test** (`= 0`, `<> 3`).
  DAP's hit count is not passed through for now: it is easy to add later, and
  "the 40th write" is a rarer question than "the write that made it zero".
- **The stop is after the writing instruction**, showing old and new values,
  because there is no safe place to stop inside an instruction. Rewind is what
  gets you to before it: one Step Back Into from the stop.

## As built

- **The flags carry one condition, not all of them.** `WATCH_ON_CHANGE` is a
  third flag bit, because only the machine can see the old value at the instant
  of the write; the value test and which watchpoint a hit belongs to are worked
  out in the Engine from the hit. Where two watchpoints cover one byte the
  machine reports what the laxer of them wants and the stricter filters its own
  hits out again.
- **One hit per instruction, kept until it is read.** The machine never clears
  a hit itself, so a driver that only looks between instructions cannot lose
  one; the run and step loops clear it when they start, so a hit left over from
  the last stop cannot stop the next run before it has run anything.
- **Cost:** nothing measurable. An armed watchpoint that never trips measured
  5.85x realtime against 5.83x and 5.95x unwatched -- inside the noise, with
  reads checked as well as writes.
- **Rewind shares the hook.** `Spectrum::write_watch`, which Run Back to Last
  Write used, is gone: a replay installs watch flags of its own instead, and
  `History::replay` puts the machine's own aside while it runs so a watchpoint
  cannot fire in the past. Reverse Continue matches watchpoint accesses as well
  as breakpoints, filtered through the same value tests as a forward stop.
- **DAP:** `dataBreakpointInfo` answers a register row with a null `dataId` and
  says to watch the memory it points at. `hitCondition` is accepted and
  ignored, with a message on the breakpoint saying so. A client's
  `setDataBreakpoints` only replaces the watchpoints that client set, so one set
  over MCP or from the editor's own command survives.
- **The editor got a view rather than relying on the BREAKPOINTS pane**, since
  nothing but VS Code can put entries there, and a watchpoint on a symbol, a
  range, or one set over MCP has to appear somewhere.
