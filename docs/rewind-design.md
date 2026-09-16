# Rewind: design

Status: **built.** How to use it is in
[vscode-debugging.md](vscode-debugging.md#stepping-backwards) and
[mcp.md](mcp.md#stepping-backwards); this file keeps the design, and
[As built](#as-built) lists where the build departed from it.

## What it is for

Stopped at a breakpoint or a pause, go **backwards** through what the program
just did, one instruction at a time or by larger steps, with the machine --
registers, memory, stack, screen -- exactly as it was at each point:

| Operation | Lands on |
|---|---|
| **Step Back Into** | the previous instruction executed, whatever it was (after a `RET`, the `RET`) |
| **Step Back** (over) | the previous instruction in this routine; a whole call just before is skipped, landing on its `CALL` |
| **Step Back Out** | the `CALL` that entered the routine you are in |
| **Reverse Continue** | the most recent earlier breakpoint hit, or the start of the history |
| **Run Back to Cursor** | the last time execution reached that line |
| **Run Back to Last Write** | the instruction that last wrote a given address |

Stepping forwards from the past replays what really happened, as often as you
like. Changing anything while in the past starts a new timeline from there.

## Enabled at compile time

A CMake option, **on by default**:

```
option(ZX_REWIND "Record history for stepping backwards" ON)
```

It sets `ZX_REWIND=1` (or `0`) as a public compile definition on `zx_core`, so
the core, the servers and the tests all see the same value, and everything
rewind-specific is inside `#if ZX_REWIND`. `build.ps1` gains `-NoRewind`, which
configures with `-DZX_REWIND=OFF` into its own build directory
(`build\<config>-norewind`) so switching does not force a full rebuild of the
other.

Compiled out:

- no history is kept and nothing is added to the run loop -- not even a branch;
- the DAP server does not declare `supportsStepBack`, so VS Code shows no
  reverse buttons, and the rewind custom requests answer "not built with
  rewind";
- the MCP rewind tools are not registered; `get_state` reports
  `rewind: false`, so a client can tell;
- the rewind tests are not built.

Compiled in, the cost while running is one frame-boundary check per instruction
(the one `note_frame` already makes) and a checkpoint copy every few frames --
see [cost](#cost). The per-instruction work of stepping backwards happens only
during a replay, never while the program runs live.


## How it works

The emulator is deterministic: from a given machine state and the same inputs,
it runs the same way down to the half-clock. So history is two things, and no
per-instruction record at all:

1. **Checkpoints** -- a full copy of the machine's state, taken at a video frame
   boundary every `CHECKPOINT_FRAMES` frames (default 10, i.e. five a second).
2. **An input log** -- every change that came from outside the machine, stamped
   with the half-clock it was applied at.

Any earlier instant is reached by restoring the nearest checkpoint before it
and replaying forward, re-applying logged inputs at their stamps, to exactly
that instant. Positions in the history are **global half-clocks**
(`Spectrum::global_hc()`), which are unique and monotonic; an instruction
boundary is a half-clock at which `Z80::is_instruction_boundary()` holds.

### What a checkpoint holds

Everything that can influence what the machine does next. From the headers:

| Part | State |
|---|---|
| `Z80` | `regs`, `halted`, `interrupt_count`, and the private mid-instruction state: `step_`, `opcode_`, `dlatch_`, `addr_`, `prefix_active_`, `hlx_idx_`, `pins_` |
| `Spectrum` | `pins_`, `call_stack`, `call_stack_sp_` |
| `SpectrumMemory` | the eight RAM `bank`s (only banks 5, 2 and 0 on a 48K), `model_`, `paging_`, `rom_selected_`, `bank_c000_`, `screen_bank_`, `slot_bank_`; `slot_` pointers are rebuilt on restore, never copied |
| `Ula` | `t_`, `screen_bank_`, `frame_hc_`, `line_`, `dot_`, `frame_count_`, `fetch_count_`/`addr_`/`data_`, the pixel and attribute latches, `border_latch_`, `border` |
| `Keyboard` | `rows_` |
| `Ay` | everything (its registers are readable through the port, and it is small) |
| `Tape` | the playback cursor only: `playing_`, `at_end_`, `fast_load_`, `block_`, `phase_`, `byte_`, `bit_`, `second_half_`, `pulses_left_`, `level_`, `pulse_start_hc_`, `pulse_hc_`, `block_start_hc_`, `total_hc_` -- not the blocks, which do not change while a tape is in |

Deliberately **not** in a checkpoint, because nothing the CPU can observe
depends on them:

- the ROMs (loading one ends the history, below);
- the beeper's integrator and sample buffers -- audio output only;
- the ULA's display-only buffers: `framebuffer_`, `last_frame_` (330 KB each),
  `pending_`, `write_heat_`, and the overlay settings. Instead, a restore always
  starts **at least one whole frame** before its target, so replay redraws the
  previous completed frame and the frame in progress before landing. That costs
  one frame of replay (~3 ms) and saves 660 KB per checkpoint.

Each part gets a plain `State` struct and `save_state(State&) const` /
`restore_state(const State&)`, written beside the class so a new member is hard
to miss -- and the [determinism test](#tests) is what catches the one that is
missed anyway.

### The input log

Live, inputs reach the machine at the run loop's yields, which fall at
different instructions on different runs. Replay must apply each at exactly the
half-clock it landed at, so the Engine records them as it applies them:

| Input | Where it enters today | Logged as |
|---|---|---|
| key state | `Engine::sync_keys` | the eight keyboard rows |
| tape Play / Stop / Rewind / Seek, fast-load flag | `Engine::service_tape` | the command |
| a debugger or MCP memory write | `Engine::write_memory` | address and bytes |
| a register write | `Engine::set_registers` | the `Registers` |

Each entry is `{half_clock, kind, payload}`, appended in order. Replay applies an
entry before the instruction that starts at its half-clock.

Some actions replace the machine rather than feed it, and **end the history**
(everything recorded before them is dropped): reset, loading a snapshot, a ROM
or a tape, ejecting a tape, and switching model.

### The history window

A ring of checkpoints with their input log, bounded by both age (default the
last 60 s of emulated time) and size (default 256 MB); the oldest checkpoint and
its log entries go first. Settings, not constants, so a long hunt can keep more.

### Timelines

The Engine holds a **head** (the newest half-clock recorded) and the machine's
**position**. Normally they are equal.

- **In the past** (position < head), running or stepping forward replays: logged
  inputs are applied, live ones are not. On reaching the head it carries on live
  -- a Continue from the past runs straight through into the present.
- **Changing anything in the past** -- a key, a poke, a register, a tape command
  -- **branches**: checkpoints and log entries after the position are discarded,
  the head becomes the position, and recording carries on from there.
- **Return to Live** replays uncapped to the head and stops there.

### Stepping backwards

Every backward operation is a *search* followed by a *land*:

- **Search** replays an interval (from one checkpoint to the next, or to the
  position) in a recording mode that notes, for each instruction boundary, its
  half-clock, PC and call depth -- `call_stack.size()`, which already follows
  the read-off-or-written-over rule that copes with borrowed stack pointers. A
  reverse watch also notes writes to the watched address, from
  `Spectrum::service_bus`. Searching goes interval by interval, newest first,
  until it finds its target or runs out of history.
- **Land** restores the checkpoint at least a frame before the target and
  replays to it exactly.

With `P` the position and `d(b)` the depth at boundary `b`:

| Operation | Target |
|---|---|
| Step Back Into | the last boundary before `P` |
| Step Back (over) | the last boundary before `P` with `d(b) <= d(P)` -- inside a call just returned from, depth is greater, so its body is passed over and the `CALL` is found |
| Step Back Out | the last boundary before `P` with `d(b) < d(P)` -- the `CALL` |
| Reverse Continue | the last boundary before `P` whose PC has a breakpoint |
| Run Back to Cursor | the last boundary before `P` at that line's address |
| Run Back to Last Write | the boundary starting the last instruction before `P` that wrote the address |

A position part-way through an instruction (after `step_tstates`) is first taken
back to that instruction's own boundary.

While replaying -- searching or landing -- nothing leaves the machine: no
audio, no screen or video frames, no trace rows, no profile counts, no
breakpoint stops, no events. The screen is published once, on landing.

## Cost

- **Checkpoint size:** ~50 KB on a 48K (three RAM banks plus a few KB of CPU,
  ULA, AY and tape state), ~130 KB on a 128K.
- **Memory:** a minute at five a second is 300 checkpoints: ~15 MB on a 48K,
  ~40 MB on a 128K. The input log is tiny.
- **Running live:** a 50-130 KB copy every 10 frames and a few log appends a
  second. Expected to be lost in the benchmark's noise; `bench_machine` gains a
  rewind line to confirm it, and a `-NoRewind` build to compare against.
- **Stepping back a little** (into, over, out of a short routine): at most two
  intervals of replay, 0.2 s of emulated time each, ~35 ms apiece uncapped --
  immediate.
- **Searching a long way** (Reverse Continue with no breakpoint for a minute):
  up to ~300 intervals, ~10 s. The request reports progress and can be
  cancelled, landing nowhere.

## Surface

### DAP

- `initialize` declares `supportsStepBack: true` (only when built with rewind).
  VS Code then shows **Step Back** and **Reverse Continue** on the debug
  toolbar; they send `stepBack` (implemented as step back over) and
  `reverseContinue`.
- Custom requests: `stepBackInto`, `stepBackOut`, `runBackToAddress {address}`,
  `runBackToWrite {address}`, `returnToLive`, and `history` -- the window's
  oldest half-clock and head, the position, and whether the machine is in the
  past.
- Every landing sends the usual `stopped` event, so the call stack, variables,
  disassembly and screen refresh as after any step.

### MCP

- `step_back {mode: "into" | "over" | "out", count}`, `reverse_continue`,
  `run_back_to {address}`, `run_back_to_write {address}`, `return_to_live`,
  and `history_status`.

### VS Code extension

- **Step Back Into** and **Step Back Out** buttons beside VS Code's own Step Back
  on the debug toolbar, shown only when the session declared step-back support.
- **Run Back to Cursor** in the editor's context menu, beside Run to Cursor.
- **Run Back to Last Write...** from the Command Palette, and on a memory or
  variable row in the debug views, taking an address or symbol.
- A status bar item while in the past -- "1,204 instructions before live" --
  that returns to live when clicked.

## Tests

In order, each before the part it guards:

1. **State round trip** (`rewind_tests`): save a machine's state, restore it
   into a fresh machine, and compare every captured field -- a missed member
   fails here first, for the parts it can see.
2. **Determinism** -- the test the whole feature rests on. Run a real program
   (the ROM booting, typing a BASIC loop through logged key presses, with a
   tape playing), checkpointing as it goes and hashing the full machine state
   at every frame boundary. Then restore every checkpoint in turn, replay to
   the end, and require every hash to match. Run on a 48K and a 128K, with
   interrupts, `HALT`, the fast-load trap and a borrowed stack pointer all
   exercised. A member left out of a checkpoint shows up here as a divergence
   at the frame it first mattered.
3. **Each backward operation** on small hand-written programs whose answer is
   worked out by hand: nested calls, a call just returned from, recursion, an
   interrupt handler, a `HALT`, `LD SP` tricks, a write to watch.
4. **Timelines:** replay up to the head carries on live; an input in the past
   branches and discards the old future; reset and loads end the history.
5. **Both builds compile:** `build.ps1 -NoRewind -Target zx_server` runs as part
   of verifying any change to the rewind code.
6. **Live**, with the `zx-live-verify` skill against filmation: step back
   through `sprite_blit`, back out to `objects_draw_all`, reverse-continue to a
   breakpoint, and run back to the last write of an object record.

## Order of work

1. State structs, save/restore, round-trip test.
2. Checkpoint ring and input log in the Engine; determinism test passing.
3. Replay (search and land) and the timeline rules; operation tests.
4. DAP requests and capability; MCP tools.
5. Extension buttons, context menu items and status bar.
6. Documentation, benchmark line, live verification.

## Decisions

- **Compiled in by default.**
- **History window:** the last 60 s or 256 MB, whichever is reached first, with
  a checkpoint every 10 frames.
- **A key pressed or released in the past starts a new timeline**, like any
  other input.

Two refinements found while inventorying the state:

- **The tape's playback position is walked lazily** -- the run loop's yields
  move it on, and those fall at different instructions from run to run. What
  the tape plays is unaffected, but the fast-load trap decides from how far the
  walk has got, so it could decide differently on replay. The trap now walks the
  tape up to the current instant before deciding, and a checkpoint walks it
  before saving, which makes both a function of the machine's clock alone.
- **Sub-instruction stepping** (`step_tstates`, and the frame-at-a-time capture
  on a stopped machine) clocks the machine without going through
  `step_instruction`, so it skips the call-stack tracking and the fast-load
  trap. Replay must do the same, so these are logged as inputs too -- "clock
  raw for N half-clocks from here" -- and replayed exactly.

## As built

Where the implementation differs from the design above, or settles something
it left open:

- **The frame capture on a stopped machine** (`get_screen_sequence`) now steps
  whole instructions to each frame boundary instead of clocking raw frames, so
  it needs no raw-clock input and leaves the machine at an instruction
  boundary. Only `step_tstates` is logged as raw clocking, and in the past it
  starts a new timeline.
- **A `HALT` waiting** is one boundary for a search, not thousands: Step Back
  Into from inside a long `HALT` lands where the waiting began, and once more
  on the `HALT` itself.
- **Checkpoints are taken after the instruction that crosses a frame boundary**,
  not exactly at it, and a search notes boundaries inside a raw-clock span too.
- **Cancelling** is Pause, checked between search intervals.
- **Run Back to Cursor** is `runBackToAddress` with a `source` and `line`
  instead of an address, mapped as `setBreakpoints` maps a line.
- **The status bar** says how far back in time -- T-states, frames or seconds
  -- rather than instructions, which would need counting every instruction
  replayed.
- **Stop reasons:** a Reverse Continue that lands on a breakpoint is reported as
  a breakpoint stop; everything else as a step. A `zxRewind` event follows each
  landing with `moved`, `cancelled` and a message when there is something to
  say.
- **Tests:** `rewind_tests` replays short windows from alternate checkpoints and
  one full replay, rather than every checkpoint to the end, to keep the Debug
  suite quick.
