# Tape

Part of the [zx-spectrum-emulator README](../README.md).

`.tap`, `.tzx`, `.wav` and `.csw` images load in the C++ core. Every format is
detected from the file's contents rather than its extension.

The first two *describe* a signal; the last two *are* one — see
[Audio recordings](#audio-recordings).

```bash
zx_server --rom roms/48.rom --tape games/manic.tzx
```

That inserts the tape, resets, types `LOAD ""` for you, and starts it — so the
machine is already loading by the time a client connects.
`--no-tape-autostart` inserts it stopped instead, which is what you want for a
program that loads its own next part.

There is no tape in the repo (games are copyrighted), so
`scripts/make_test_tape.py` generates one: a tiny autostarting BASIC program
that turns the border yellow and prints `TAPE LOADED OK`, written to
`tapes/loading-test.tap` and `.tzx`. Two launch configs point at it —
**Tape (fast load)** and **Tape (real pulse load)** — which is the quickest way
to see both paths working.

A third, **Tape (waiting for LOAD)**, takes no tape at all: it boots, types
`LOAD ""` and stops in the ROM loader, where a real Spectrum sits once you have
typed the command and not yet pressed Play. Insert whatever you like afterwards
and press Play:

```jsonc
load_tape    { "path": "...", "auto_start": false }
tape_control { "action": "play" }
```

That always loads at real tape speed even with fast load on, and it is not a
bug — the trap fires on *arriving* at `LD-BYTES`, and the ROM is already inside
it by then. Insert with `auto_start` left on (what the VS Code command does) and
it resets and retypes, so the trap gets its moment.

Either way the machine does not have to be stopped first: the emulator's run
loop services queued commands at its yields, so a tape dropped into a running
machine is picked up and the run carries straight on into loading it.

The same thing on the command line is `--wait-for-tape`.

The same thing from the other three directions:

- **launch.json**: `"tape": "${workspaceFolder}/games/manic.tzx"`, alongside
  `"tapeAutoStart"` and `"tapeFastLoad"`.
- **VS Code**: *ZX Spectrum: Load Tape…*, which puts a tape into a session that
  is already running, and the **ZX Spectrum Tape** pane in the debug sidebar —
  the block list, alongside Call Stack and Breakpoints, with the transport on
  its title bar. See [the extension's README](../vscode-extension/README.md).
- **MCP**: `load_tape {path}` and `tape_control {action}` — play, stop, rewind,
  seek, eject, status. Every reply lists the blocks, so `tape_control {}` on
  its own is how to find out what an image contains. The transport bypasses the
  emulator's command queue, so Play reaches a game that is already running and
  asking for its next part; that is the only moment Play is any use.

## How it loads

Two mechanisms, and the fast one falls back to the slow one on its own.

The foundation is **pulse-level playback**: the tape resolves to a one-bit EAR
level on port `0xFE` bit 6, pulse by pulse, in the machine's own half-clock
time base. That is what a real cassette does, so it works with any loader at
all — turbo, custom `.tzx` block timings, whatever the publisher wrote. It is
also as slow as a real cassette, which for a whole game is minutes. `set_speed
uncapped` (MCP) or `"uncapped": true` (launch.json) is the way to hurry it up.

On top of that sits a **fast-load trap**. When the CPU reaches the ROM's
`LD-BYTES` at `0x0556` — and the bytes there really are the stock ROM's, which
is checked — a standard-speed block is copied straight into memory, the flags
and registers are set the way the routine would have left them, and the trap
returns as if from its final `RET`. It costs zero emulated T-states. Anything
that is *not* a standard-speed block (a turbo block, a pure-tone or pure-data
block, a tape that has run out) makes the trap decline, and the real ROM
routine then runs against real pulses. So a `.tzx` with a stock header and a
turbo body fast-loads the header and pulse-loads the body, which is exactly
right.

Fast load is on by default; `--no-tape-fast-load`, `"tapeFastLoad": false`, or
`load_tape {fast_load: false}` turns it off. Two differences when it is on:
there are no loading stripes in the border, because the trap never runs the ROM
code that draws them, and no loading screech, because the tape never plays.

## The loading sound

Worth being precise about, because the obvious guess is wrong. The ROM's loader
never touches the speaker bit at all — `LD_SAMPLE` ends `AND $07 / OR $08 /
OUT ($FE),A`, which is border bits plus a MIC bit that never changes. The
stripes are the CPU's doing; the screech is not.

What makes the noise is the EAR input itself: the ULA feeds the tape signal
into the same audio output as the speaker. So the emulator mixes EAR into the
beeper (`EAR_LEVEL` in `beeper.h`), sampled from the port reads the loader is
already making — thousands a second, far finer than the tone being reproduced.
A pilot pulse is 2168 T-states, so the leader comes out at 3.5e6/4336 ≈ 807 Hz,
which is what `get_audio` reports while one is playing.

Resetting the machine stops the motor but leaves the tape in the deck at the
block it had reached — a reset zeroes the frame counter, and with it the clock
every pulse timestamp is measured against.

## Audio recordings

`.wav` and `.csw` are recordings rather than descriptions: a rip off a real
cassette, or a pulse capture. They load the same way as anything else —

```bash
zx_server --rom roms/48.rom --tape "games/jet set willy side a.wav"
```

— because they are decoded into an edge list at insert time and then played by
exactly the same pulse engine. Nothing downstream knows the difference.

`.wav` may be 8/16/24/32-bit PCM or 32/64-bit float, at any sample rate, mono
or multi-channel (channels are averaged: a stereo rip of a mono cassette is the
same signal twice). `.csw` may be v1 or v2, RLE or Z-RLE. The two `.tzx` blocks
that carry a recording inline — `0x15` direct recording and `0x18` CSW — go
through the same code, so a `.tzx` built around either now loads where before
it was refused outright.

Recordings never fast-load. A recording is by definition not a standard-speed
block, so the trap declines and the ROM reads real pulses at real cassette
speed. `set_speed uncapped` is how to make that bearable.

**Turning a waveform back into edges is the whole problem.** A `.csw` is
already an edge list, but a `.wav` is an analogue signal with a DC offset that
drifts, a level that varies between rips by 30dB, and decades of hiss on it.
`tape_audio.cpp` runs a Schmitt trigger whose centre and hysteresis are both
derived from the signal, by tracking a decaying maximum and minimum — the
midpoint between those rails is the comparison point, a quarter of the gap
between them is the hysteresis, and a floor under that gap is what makes
silence read as silence instead of as hiss. That floor is also what lets a
recording be **cut into blocks at its gaps**, so the block list is a list and
`tape_control {action: "seek"}` can jump to part four of a multi-load without
playing parts one to three.

The pairing that does *not* work, for the record, is a low-pass follower for
the centre plus a peak envelope for the hysteresis. After any long stretch at a
constant level the follower has settled onto that level rather than onto the
midpoint of the signal either side of it, so the first swing out of it reads as
twice the real amplitude, doubles the threshold, and swallows the next two or
three genuine edges. Inside a pilot tone that is invisible — every pulse is the
same length as the one before — until the tone ends and the block turns out to
be two edges out of step. Rails have no such transient.

Sample rate matters. 44.1kHz resolves a pulse to 79 T-states, which is fine for
anything including turbo loaders. Below 22kHz a recording still plays, and says
so in the tape's warnings, but the shortest turbo pulses are then only two or
three samples long and a marginal rip will not load.
