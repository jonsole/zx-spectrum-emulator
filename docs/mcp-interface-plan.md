# MCP interface plan: the ZX Spectrum and BBC Micro servers

Status: **in progress.** Done so far: the Spectrum's small fixes (5.1) and
its paging tools (5.11.1). The same document is in both repositories
(`zx-spectrum-emulator/docs/mcp-interface-plan.md` and
`vs-code-bbc/docs/mcp-interface-plan.md`); change both together.

This is the plan for bringing the two emulators' MCP servers to one shared
interface: what an agent using them should be able to do, the conventions
both follow, the tools both offer, and the changes each needs to get there.
It comes out of comparing three servers: the ZX Spectrum emulator's
(`cpp-core/src/mcp_server.cpp`), the BBC Micro one (`vs-code-bbc/server/mcp.mjs`),
and [jsbeeb-mcp](https://github.com/mattgodbolt/jsbeeb-mcp), which the BBC
one's interface was modelled on.

## 1. Desired outcome

An agent (Claude Code, VS Code's agent mode, any MCP client) can work on a
Spectrum or a BBC Micro program the way a person at the machine with a
debugger would, without having to know either emulator's internals, and
without having to learn two interfaces.

Concretely, when this plan is done:

1. **One call answers "what happened".** Typing a command and running it
   returns the text it printed, where the CPU ended up, how far the machine
   ran and why it stopped. The agent never has to read a screenshot to find
   out what a `PRINT` said, nor follow every run with `get_state`.
2. **No call can hang.** Every tool that runs the machine has a bound, and
   says when it hit it. Today `run` on the Spectrum waits for a breakpoint
   that may never come.
3. **Experiments are cheap to repeat.** Set the machine up once, keep it as a
   named state in the server, and go back to it between attempts in one call.
4. **Input is what the program sees.** Keys are pressed on the keyboard
   matrix by the machine's own names, or by the numbers a game's keyboard
   scan uses; text can be typed; BASIC can be loaded from source.
5. **Addresses are names.** Every tool that takes an address takes a symbol
   or an expression (`player_x`, `table+2`, `&1900`, `$9C40`), and every
   address a tool reports comes back with its symbol.
6. **The two servers match.** The same job has the same tool name, the same
   argument names and the same result shape on both. What differs is only
   what the machines differ in (tapes and ROM loading on the Spectrum, disc
   drives and a second processor on the BBC).
7. **It stays small enough to use.** About 40 shared tools, grouped, each one
   job. Every tool listed costs the agent context on every turn.
8. **The machine stays shared.** No sessions. The one machine is the one in
   VS Code's debugger and screen panel, so a person and an agent can work on
   it together, and each sees the other's stops.

### How we will know

- An end-to-end script per server (the BBC's `tests/mcp.test.mjs`, a new one
  for the Spectrum driven the way `zx-live-verify` does) walks the agent
  journeys in section 7 and checks each result field named there.
- A client calling a tool with only the documented arguments gets the
  documented fields back on both servers.
- No tool in either server can block for longer than its stated bound.

## 2. Conventions both servers follow

### 2.1 The run report

Every tool that runs the machine and waits returns the same object. That
covers `run` (when it waits), `step`, `run_frames`, `run_for_cycles`,
`run_to`, `run_until_prompt`, `type_text`, `press_key`, `run_basic`, and
on the Spectrum the step-back tools.

```jsonc
{
  "completed": true,                 // got where it was asked to go
  "stopped_reason": "breakpoint",    // only when completed is false:
                                     //   breakpoint | watchpoint | paused | timeout | error
  "stopped": "Breakpoint at &1911 (again+3)",   // a sentence for a person
  "breakpoint_ids": [3],             // which, for a breakpoint stop
  "watch_stop": { "address": "&0070 (counter)", "old": "&01", "new": "&02",
                  "by": "&1911 (again+3)" },    // for a watchpoint stop
  "registers": { ... },              // 2.3
  "cycles_run": 40011,               // T-states on the Spectrum
  "frames_run": 1,
  "output": "PRINT 6*7\n        42\n>"           // 2.4, what was printed during the call
}
```

`run(wait: false)` (start it and return) and `pause` return
`{ running, registers }`; they are not waiting tools.

### 2.2 Bounded waits

- Every waiting tool takes a bound in emulated time (`timeout_secs`, or the
  count it was asked for) and stops with `stopped_reason: "timeout"` when it
  is reached. There are defaults: 20 seconds for `run_to` and `step out`,
  60 for `run_until_prompt`, and 0.1 seconds per frame for `run_frames` (a
  machine that has stopped painting).
- A blocking `run` takes `timeout_secs` too (default 30), and reports
  `timeout` with the machine left stopped, so a breakpoint that is never
  hit does not hang the client. `run(wait: false)` remains the way to leave
  a game running.
- `pause` always reaches a waiting tool. Both servers do this already.

### 2.3 Values a person can read

- Registers come back as hex strings in the machine's own notation, plus
  what makes them useful. `pc` carries its symbol (`"&1911 (again+3)"` /
  `"$9C40 (sprite_move+7)"`), there is a `flags` string (`NV-BDIZC` /
  `SZ5H3PNC`), the `instruction` at PC, and the `frame_count` and
  `elapsed_cycles` counters. A tool returns raw numbers only where it
  computes one (`evaluate`, `cycles_run`).
- Hex is `&1900` on the BBC and `$1900` on the Spectrum, each in its own
  community's notation. Input accepts every form on both.
- Memory dumps are text: `address  bytes  |ascii|`, 16 bytes a row.

### 2.4 Two kinds of text: output and screen

These are different questions, and need different answers:

- **`output`** answers "what did that print?" It is a **transcript**: the
  characters sent through the machine's print routine, in order, since
  output was last taken. Control codes are interpreted only as far as text
  needs: newline, and clear screen as a break marker. Positioning is
  ignored. Waiting tools take it by default; `clear: false` peeks. Being
  chronological, it cannot mix old text into new, which is exactly the fault
  the BBC server's current position-based grid has.
- **`get_screen_text`** answers "what does the screen say now?" It is read
  from the screen as it currently is, as a grid of rows: from screen
  memory, not from what was printed. So it is right after a clear, a
  scroll, or a program that writes screen memory itself.
  - BBC MODE 7: screen memory is the text (&7C00, 40x25). Exact.
  - BBC MODES 0-6 and the Spectrum: match each character cell against the
    ROM font (the MOS font at &C000; the Spectrum ROM's at &3D00, and the
    font CHARS points to). Unmatched cells show as a placeholder (`·`), so a
    picture reads as a picture. This assumes character-cell-aligned text,
    which covers what the ROMs print and most games' score lines.

### 2.5 Addresses

Every address argument accepts an integer, `&1900`, `$1900`, `0x1900`,
decimal, a symbol, or an expression over symbols and registers. The
argument is called `address` on both servers; the Spectrum keeps `addr` as
an accepted alias. Every address reported back carries its nearest symbol.

### 2.6 Keys

- `key_down`, `key_up` and `press_key` press keys **on the matrix**, with no
  host keyboard layout between, named one of these ways:
  - `key`: the machine's own name. BBC: `SHIFT`, `RETURN`, `COLON_STAR`,
    `K1`... (jsbeeb's table). Spectrum: `CAPS SHIFT`, `SYMBOL SHIFT`,
    `ENTER`, `A`...
  - the numbers the hardware or a game uses. BBC: `internal` (OSBYTE 121),
    `inkey` (negative INKEY), or `col` and `row`. Spectrum: `port` (the
    half-row's address, `0xFDFE`) and `bit`, as `IN A,(C)` reads it.
- Each reports the matrix keys that changed, with their name and numbers.
- `keyboard_state` lists what is held, and whether typed text is still
  pending; `release_all_keys` clears both.
- `type_text` types text (then RETURN/ENTER unless `enter: false`) and waits
  until it has all gone in.

### 2.7 States

- **`save_state` / `restore_state` / `list_states` / `delete_state`** hold
  whole-machine states in the server's memory, by id, with a label. Only the
  id crosses the connection. Capped (about 100), refusing at the cap rather
  than evicting. They are gone when the server stops.
- **`save_snapshot` / `load_snapshot`** are the file forms that outlive the
  server, and take a **path** on both servers.
- Breakpoints, watchpoints and the frame counter carry on across a restore.
  Memory, registers and the cycle count rewind.

### 2.8 Results and errors

- A result is JSON text, and also `structuredContent` with an `outputSchema`
  declared for the tools whose results have a fixed shape (the run report,
  registers, states), per MCP 2025-06-18. Clients that read structured
  results get typed fields; others read the text as now.
- A failure is a result with `isError: true` and a message that says what to
  do: "No state "x": list_states shows what is held", "Unknown key "Y": the
  keys are ...".
- `initialize` returns `instructions`: a paragraph on where to start, which
  the BBC server has and the Spectrum server does not.

### 2.9 Shared machine

- No sessions. Tools that move the machine make the resulting stop the
  agent's (the Spectrum's `set_driver(Driver::Mcp)`), and VS Code shows it
  without taking the editor over. The BBC server should do the same.
- Breakpoints have owners: `clear_breakpoint` with no address clears only
  MCP's. `list_breakpoints` shows everyone's, marked.
- Tools that reset or reload the machine (`reset`, `load_program`,
  `run_basic`, `restore_state`, `load_snapshot`) say so in their
  description. When a debug session is attached they reply with
  `"warning": "reset the machine VS Code is debugging"`. They do not refuse;
  the agent may have been asked to do exactly that.

## 3. The shared tool set

The target is 40 tools with the same names, arguments and results on both,
plus each machine's own. Columns: what exists today. "≈" means it exists but
differs from the target.

| Group | Tool (target arguments) | ZX today | BBC today |
|---|---|---|---|
| Machine | `server_info()` | yes | yes |
| | `get_state()` | yes | yes |
| | `reset(hard?, model?, autoboot?)` | ≈ `machine` | yes |
| Loading | `load_program(path, model?, load_address?, exec_address?, run?, boot?, debug_info?, source?, stop_at?)` | — (load_tape/load_snapshot) | yes |
| | `load_basic(source)` | — | yes |
| | `run_basic(source, model?, timeout_secs?, screenshot?)` | — | yes |
| Running | `run(wait?, timeout_secs?)` | ≈ no timeout | ≈ `wait_ms` |
| | `pause()` | yes | yes |
| | `step(mode: into\|over\|out, count?)` | ≈ into only, `instructions`/`ticks` | yes |
| | `run_frames(count, clear?)` | — | yes |
| | `run_for_cycles(cycles, clear?)` | ≈ `step ticks` | yes |
| | `run_to(address, timeout_secs?)` | — | yes |
| | `run_until_prompt(timeout_secs?, clear?)` | — | yes |
| Breakpoints | `set_breakpoint(address, condition?, hit_count?, log_message?)` | ≈ address only | yes |
| | `clear_breakpoint(address? \| id?)` | ≈ | yes |
| | `list_breakpoints()` | — (in get_state) | yes |
| | `set_watchpoint(address, length?, access?, on_change?, value?, not_value?, condition?)` | yes | ≈ no on_change/value |
| | `clear_watchpoint(id?)`, `list_watchpoints()` | yes | yes |
| | `get_log(since?, max?)` | yes | yes |
| Memory and CPU | `read_memory(address, length?, bank?)` | ≈ integer addr | yes |
| | `write_memory(address, data)` | ≈ `data_hex` | yes |
| | `save_memory(address, length, path, bank?)` | — | yes |
| | `get_registers()`, `set_registers(...)` | ≈ decimal | yes |
| | `disassemble(address?, count?)` | — | yes |
| | `evaluate(expression)` | — | yes |
| Screen | `get_screen(scale?, frames?, every?)` | ≈ + `get_screen_sequence` | ≈ no sequence |
| | `get_screen_text(clear?)` | — | ≈ grid from print stream |
| Keyboard | `type_text(text, enter?)` | — | yes |
| | `key_down(...)`, `key_up(...)` | ≈ name only | yes |
| | `press_key(..., frames?)` | — | yes |
| | `keyboard_state()`, `release_all_keys()` | — | yes |
| States | `save_state(label?)`, `restore_state(state_id)`, `list_states()`, `delete_state(state_id)` | — | yes |
| | `save_snapshot(path)`, `load_snapshot(path)` | ≈ load by base64 | yes |
| Sound | `get_sound_state()` | ≈ `get_audio` (beeper) | ≈ `read_sound_state` |
| | `sound_capture(action: start\|stop, max_entries?)` | — | ≈ two tools |
| Symbols | `load_debug_info(...)`, `resolve_symbol(name)`, `resolve_address(address)` | yes | yes |

Each machine keeps its own on top:

- **Spectrum:** `load_rom`, `load_tape`, `tape_control`, `set_speed`,
  `set_break_on_interrupt`, the rewind group (`step_back`,
  `reverse_continue`, `run_back_to`, `run_back_to_write`, `return_to_live`,
  `history_status`), `profile`, video (`start_video`, `stop_video`,
  `video_status`), tracing (`start_trace`, `stop_trace`, `trace_status`),
  and the views (`set_raster_view`, `set_write_overlay`,
  `set_graphics_view`). `set_logpoint`, `list_logpoints` and
  `clear_logpoint` stay as aliases of the breakpoint tools for a release.
- **BBC:** `load_disc(image, drive?)`, `reset(tube?)` and
  `load_program(tube?)`.

## 4. Changes to the BBC Micro server (`vs-code-bbc`)

In order. Each item lists its files and its test.

1. **Output becomes a transcript** (2.4). Hook OSWRCH by watching the WRCHV
   call, or the VDU driver's entry, through the engine's instruction hook,
   only while capturing. Append printable characters, CR as newline,
   VDU 12/22 as a `\f` break, and skip the parameter bytes of VDU
   19/22/23/25/28/29/31. Replace `takeOutput()` in `server/engine.mjs`;
   jsbeeb's `VduTextCapture` is no longer used for output.
   *Test:* `PRINT`, `CLS`, `PRINT` in one run gives both lines in order with
   a break between; a `VDU 31` positioned print appears once.
2. **`get_screen_text` reads the screen** (2.4). MODE 7 straight from screen
   memory (start address from the CRTC/ULA, wrapping at &8000); other modes
   by matching cells against the MOS font, decoding 1/2/4 bits per pixel by
   mode. New `server/screen_text.mjs`, kept free of jsbeeb so it can be unit
   tested from saved screen memory. *Test:* MODE 7 and MODE 1 screens after
   `PRINT` and after `CLS`.
3. **Prune to the shared set** (3). Remove `boot_disc` (it is
   `reset(autoboot)` after `load_disc`) and `set_breakpoint`'s `type`
   (use `set_watchpoint`). Merge `read_sound_state` and the capture pair
   into `get_sound_state` and `sound_capture`. Fold `get_screen`'s sequence
   in (item 6).
4. **Bounds** (2.2). `run(wait_ms)` becomes `run(wait, timeout_secs)`.
   Check every waiting tool has a bound and reports `timeout`.
5. **Watchpoints as the Spectrum has them**: `on_change` (the default),
   `value` and `not_value`, and a `watch_stop` with old and new values and
   the instruction that did it. In `Engine._onAccess` in `server/engine.mjs`.
   *Test:* a watch on a counter written with the same value does not stop
   with `on_change`.
6. **`get_screen(frames, every)`**: consecutive frames as separate images,
   each tagged with its frame number. This is the Spectrum's
   `get_screen_sequence`, built on `runFrames`.
7. **Structured results** (2.8). `structuredContent` and `outputSchema` for
   the run report, registers and states, in `handleMcp` and the tool table.
8. **Shared machine** (2.9). The reset warning when a DAP client is
   attached. A stop caused by an MCP tool sent to VS Code with
   `preserveFocusHint: true`, so the editor does not jump.
9. **Logpoint formats** as the Spectrum's: `{A:d}`, `{?addr:c}`, `{peekw(x):w}`.
10. *Later, optional:* a frame-granularity step back on jsbeeb's own
    `rewind.js` snapshot ring, and a profiler. Neither is in the shared set.

## 5. Changes to the ZX Spectrum server (`zx-spectrum-emulator`)

In order of value for effort. Item 1 is small and independent. Items 2-5
are the core. Items 6-9 complete the shared set. Live behaviour is checked
with `zx-live-verify` as well as CTest.

1. **Small fixes, no engine change** (`mcp_server.cpp` only). *Done.*
   - `instructions` in the `initialize` result.
   - `load_snapshot(path)` alongside `sna_base64`.
   - `address` (and `addr` as an alias) accepting symbol expressions in
     `set_breakpoint`, `clear_breakpoint`, `read_memory` and
     `write_memory`, through the evaluator `set_registers` already uses.
   - `write_memory(data)` accepting hex or an array, keeping `data_hex`.
   - `registers` in the readable form of 2.3, with the raw numbers still
     available under `get_registers(raw: true)`.
   - `list_breakpoints`.
2. **The run report, and bounded runs** (2.1, 2.2). One function,
   `run_report(const MachineState&, start, ...)`, used by `run`, `step` and
   the rewind tools. `run(timeout_secs)`: the Engine needs a deadline on a
   run, in T-states, checked at the run's yields as `pause` is.
   *Test:* a run with no breakpoint ahead returns `timeout` within bound.
3. **`step(mode: over|out, count)`** through MCP, reusing what DAP's `next`
   and `stepOut` use (`engine.cpp`), including its HALT handling.
4. **Output transcript** (2.4). Capture characters at the ROM's print
   routine for channel S. That means PRINT-OUT, reached through RST 10h and
   CURCHL, at &09F4 in the 48K ROM, while the 48K BASIC ROM is paged in.
   Expand keyword tokens the way the ROM does: it reprints them through the
   same routine, so record printable characters and skip the token code.
   CLS (`CL-ALL`) is a break, and AT/TAB parameters are skipped. On a 128K
   only ROM 1's PRINT-OUT is captured (see 9.3). A
   capture-only breakpoint kind on the CPU's fetch, like a logpoint that
   records instead of formatting. New `cpp-core/src/text_capture.{h,cpp}`.
   *Tests:* CTest against the real ROM (skipped without `roms/48.rom`):
   `PRINT "HELLO"`, `PRINT AT 5,5;"X"`, a token (`PRINT "A"` then `LIST`
   shows `PRINT`), `CLS`. Live: on a 128K, check the 128 BASIC editor's
   output, which goes through ROM 0's own printing.
5. **`get_screen_text`** (2.4). Match the 768 cells of the display file
   against the font CHARS (&5C36) points to, normal and inverse, with
   attributes ignored. New `cpp-core/src/screen_text.{h,cpp}`, a pure
   function of 6912 bytes of screen and 768 of font, unit tested from saved
   screens. The display file's third-interleaved layout is already worked
   out in the screen renderer.
6. **Keyboard** (2.6): `press_key(frames)`, `keyboard_state`,
   `release_all_keys`, and `port`/`bit` key addressing, in `keyboard.cpp`
   and `mcp_server.cpp`. Then **`type_text`**: a queue that holds each
   key for a frame and releases it for a frame, letters through
   CAPS/SYMBOL SHIFT as needed, delivered at frame boundaries by the
   engine. On a 48K in K mode a keyword is a single key, so `type_text`
   types letters as they come and is right for the 128K editor, INPUT
   prompts and games. 48K BASIC lines go through `load_basic`.
7. **`load_basic` and `run_basic`.** Tokenise BASIC source into the
   program area (line numbers, keyword tokens, the hidden 5-byte number
   forms) and set PROG, VARS, E_LINE and friends as LOAD would. Then
   `run_basic` is `reset`, `load_basic`, `RUN`, `run_until_prompt`. The
   tokeniser in `cpp-core/src/basic_tokenise.{h,cpp}` can take its keyword
   table from the ROM's token table rather than a hand-made one. *Test:*
   round trip against a program saved by the ROM.
8. **`run_until_prompt`**: run until the ROM waits for a key. On the 48K,
   the editor's wait in KEY-INPUT/WAIT-KEY (around &10A8/&15D4); find the
   exact address from the ROM disassembly, not from this document. On the
   128K, the 128 editor's wait in ROM 0, which needs a paging-aware
   breakpoint. Add `run_frames(count)` (the engine already counts frames;
   stop at the frame interrupt) and `run_for_cycles`, which is
   `step(ticks)` under its shared name. Add `run_to(address)`.
9. **States** (2.7): `save_state`/`restore_state` and friends, holding
   `save_snapshot`'s bytes in memory. `.z80` already keeps the 128K's
   paging and AY. A restore ends the rewind history, as a load does now.
   Then **`disassemble`** (the disassembler exists for DAP) and
   **`evaluate`** (the expression evaluator exists for logpoints and
   `set_registers`). **Sound**: `get_sound_state` (the beeper measurement
   `get_audio` makes, plus on a 128K the AY's registers) and `sound_capture`
   (AY register writes with their T-state).
10. **Breakpoints** with `condition`, `hit_count` and `log_message`, the
    logpoint tools becoming aliases (DAP's conditions are already there).
    Structured results (2.8).

### 5.11 Banked memory on the 128K

On a 128K, `$C000`-`$FFFF` is whichever of eight RAM banks the paging
register selects, and `$0000`-`$3FFF` is ROM 0 or ROM 1. (`$4000` is always
bank 5 and `$8000` always bank 2.) A plain address there is ambiguous, and
today the server treats it as "whatever is paged in": a breakpoint at
`$C000` fires in any bank, and source lines and symbols in that range are
looked up without regard to bank, although sjasmplus's SLD records the page
of every line.

1. **Reading and changing the paging.** *Done.* `set_paging(bank, rom,
   screen, lock, port_7ffd, force)` sets the register as a debugger: a
   program's lock holds unless `force`, and the change is a rewind input, so
   stepping back past it undoes it. `write_memory(bank)` writes a bank that
   is not paged in, as `read_memory(bank)` reads one. `get_registers`
   reports the paging; `get_state` already did.
2. **Addresses that name a bank.** `"3:$C000"`, or `bank` beside
   `address`, and `"ROM0:$0038"` for the ROMs. An address without one keeps
   today's meaning, so nothing written for a 48K changes. A breakpoint,
   watchpoint or logpoint with a bank fires only when that bank (or ROM) is
   paged in at the address: one comparison on a hit, nothing while running.
3. **The SLD's page used.** Source lines and symbols in `$C000`-`$FFFF`
   are kept per bank, so a source breakpoint in banked code lands in its
   bank, and where the machine stops is resolved against the bank actually
   paged in. The DAP side needs the same, so VS Code and MCP agree; and the
   profiler can then count banked code per bank.
4. **Reported addresses carry the bank** where it matters: on a 128K, at
   `$C000` and above, `"3:$C012 (music_play+4)"`.

## 6. What carries which way

- **From jsbeeb-mcp to both:**
  - the run report with printed output
  - `run_frames` stopping on the frame
  - keys by matrix name and hardware number
  - `keyboard_state` and `release_all_keys`
  - server-side states
  - `run_basic`, `load_basic` and `run_until_prompt`
  - sound chip state and a write log
  - paging reported with memory reads
  - `save_memory`
- **From the Spectrum server to the BBC:**
  - frame sequences
  - change-only and value watchpoints with a `watch_stop`
  - logpoint formats
  - the driver/focus handling for a shared machine
  - (later) stepping back and the profiler
- **From the BBC server to the Spectrum:**
  - addresses as expressions everywhere
  - readable registers
  - `step over/out`
  - `disassemble` and `evaluate`
  - `instructions`
- **New in both:**
  - the transcript/screen split for text
  - bounded runs
  - structured results
  - the reset warning

## 7. Agent journeys the tests walk

1. **Try BASIC.** `run_basic('10 PRINT 6*7')` returns `completed`,
   `output` containing `42`, and an image.
2. **Run a command.** `type_text('*CAT')` / `type_text('LOAD ""')`, then
   `run_until_prompt` returns that command's output only.
3. **Find what writes a variable.** `load_program(..., debug_info)`,
   `set_watchpoint(address: "lives")`, `run(timeout_secs: 30)` returns
   `stopped_reason: watchpoint` and a `watch_stop` naming the instruction by
   symbol; `disassemble()` around it.
4. **Play from a checkpoint.** `save_state` at the title screen, then
   `press_key(key: SPACE, frames: 5)` and `run_frames(50)`, then
   `get_screen_text`, then `restore_state`; the same again gives the same
   result.
5. **Never hang.** `run(timeout_secs: 2)` on a machine with no breakpoints
   returns `timeout` in about 2 emulated seconds.
6. **Read the screen after a clear.** `PRINT "A"`, `CLS`, `PRINT "B"`:
   `get_screen_text` shows only B; `output` shows A, a break, then B.

## 8. Compatibility

- The Spectrum's existing argument names (`addr`, `data_hex`,
  `instructions`, `ticks`, `sna_base64`, `machine`) and tools
  (`get_screen_sequence`, `set_logpoint`...) stay accepted for one release,
  marked deprecated in their descriptions and in `docs/mcp.md`, then go.
  Scripts in `scripts/` and the game-disassembly notes that call them are
  updated in the same change that deprecates them.
- The BBC server is unreleased, so it changes without aliases.

## 9. Decisions

1. **Hex notation: decided.** Each machine reports addresses and values in
   its own notation: `&1900` on the BBC, `$1900` on the Spectrum. Both
   servers accept every form on input (`&1900`, `$1900`, `0x1900`, decimal),
   so an agent used to one machine is understood by the other.
2. **`run` default: decided.** Both behave as the Spectrum does now: `run`
   blocks until the machine stops, and `run(wait: false)` starts it and
   returns. The new `timeout_secs` (default 30) bounds the blocking form.
   On the BBC, `run(wait_ms)` becomes this.
3. **Text capture on the 128K: decided.** On a 48K, everything printed on
   the main screen goes through PRINT-OUT (&09F4), so capturing there
   catches it all. A 128K has two ROMs. ROM 1 is the 48K BASIC ROM and holds
   PRINT-OUT, so a program's `PRINT` is still caught there (the capture
   checks that ROM 1 is the one paged in). ROM 0, the 128K editor and menu,
   may draw the menu and the line being typed with its own routines, which
   this capture misses. That gap is accepted: on a 128K, `output` carries
   what programs print, and `get_screen_text`, which reads the screen,
   shows the editor's and menu's text. Item 5.4 confirms against ROM 0
   what is missed, and `docs/mcp.md` says so; it does not capture in ROM 0.
4. **Tool count: decided.** The Spectrum keeps its own tools (rewind,
   video, trace, views, profile) in the MCP list as they are. It will have
   about 60.
