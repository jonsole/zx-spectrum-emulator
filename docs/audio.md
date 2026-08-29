# Audio

Part of the [zx-spectrum-emulator README](../README.md).

The C++ core emulates the 48K beeper: writes to port `0xFE` latch the speaker
(bit 4) and MIC (bit 3) levels, and those become mono 16-bit PCM.

**Nothing is sampled per clock cycle.** The level only changes when a program
writes the port -- a few thousand times a second at most -- so each write is
recorded against the half-T-state it happened on, and the level is integrated
forward when somebody asks for the audio. The cost lands per *sample* rather
than per *half-clock*, which keeps it out of the emulator's hot loop
entirely: `bench_machine` measures the same throughput with the feature as
without it.

The write is stored as a *latch*, not an edge. Control lines are not
auto-cleared, so `service_bus()` sees a single `OUT` assert IORQ/WR on five
consecutive half-clocks and applies it five times over; assigning a level is
idempotent under that, whereas counting edges would count five.

## Sound as the master clock

With a native output device, the emulator paces against the **sound card**
rather than against `steady_clock`. This is what keeps picture and sound
locked together, and it is worth understanding before changing anything here.

A card consumes samples at its own rate, which is never exactly the rate a
timer believes a 48K runs at. Pacing against the timer lets the two drift
apart, and the drift has to go somewhere: either audio piles up ahead of the
speaker (latency that never drains) or the device runs dry (gaps). Pacing
against the device instead makes the emulator produce exactly what the
hardware consumes -- and since frames come off the same emulation loop, the
picture follows the sound rather than being timed separately from it.
Measured at 50.09fps against a nominal 50.08.

Two corollaries, both learned the hard way and both commented in the source:

- A partially-filled buffer is **never** padded out and queued. Padding hands
  the device samples the emulator never produced, and because pacing counts
  them, the machine gets throttled by audio that was never real -- measured at
  40.1fps, a game running in visible slow motion with no indication anything
  was wrong. A gap is the honest failure: it costs a click, timing stays
  correct, and the fix is a larger `--audio-latency-ms`.
- The emulator needs production headroom *above* the device queue. With a
  target equal to the queue itself, any chunk at all puts it over, so it
  produces one chunk per buffer completion and runs at a fraction of speed
  (measured 23.5fps).

Without a native device -- panel playback only -- pacing stays on the wall
clock, since a network client should not be able to stall the emulator.

## Hearing and inspecting it

- **In VS Code.** The screen panel plays it. The extension host connects to
  the audio stream port and forwards blocks to the webview, which schedules
  them through the Web Audio API. There is a mute button in the top-right
  corner. Browsers will not start audio until you have interacted with the
  panel, so the first keypress or click is what gets it going.
- **Out of the server process.** `--audio-device` opens the default output
  directly. Never fatal: no sound card, or a device held exclusively by
  something else, prints a warning and carries on.
- **Over MCP.** `get_audio` reports sample count, RMS, peak and an estimated
  pitch over a rolling window, optionally with the window as a base64 WAV. It
  is a non-consuming read, so it can be called while something is playing.
  Handy for asserting that a BEEP came out at the frequency it should have --
  driving the ROM's own BEEPER routine at 440Hz measures 440.0.

```
zx_server.exe --rom roms/48.rom --audio-device --audio-latency-ms 80
```

`--no-audio` stops the stream server binding at all; pair it with
`--audio-device` for native-only output, which is what the Manic Miner and
Aquaplane launch configurations do (otherwise the panel plays the same audio
a second time, slightly out of phase). Audio is dropped entirely while the
emulator runs uncapped (`--uncapped`) -- samples generated hundreds of times
faster than real time are not playable.

## Backends and latency

Native playback prefers **WASAPI shared mode via `IAudioClient3`**, falling
back to waveOut if that is unavailable (pre-Windows-10, or a device that
refuses the low-latency path). `InitializeSharedAudioStream` asks the audio
engine for its *smallest* supported period and drives rendering from an event
rather than a poll; the render thread registers as `Pro Audio` through MMCSS
so it is not descheduled by the emulator thread. Measured 21ms of device
buffer, against 80ms for waveOut, whose 20ms blocks are its floor.

Shared mode runs at the engine's mix format and nothing else, so rather than
resampling onto it, **the beeper is told to generate at the mix rate
directly** -- its decimator is an integer accumulator that is exact at any
rate, so this costs nothing and loses nothing. That is why the sample rate is
not a constant, and why everything downstream learns it from the stream
preamble or `Engine::audio_sample_rate()` rather than assuming 44100.

`--audio-latency-ms` (default 80) behaves differently per backend, which is
worth knowing when tuning:

| | waveOut | WASAPI |
|---|---|---|
| What the flag sets | device queue depth, in 20ms blocks | how much is held *ahead* of the device |
| Why | buffers are ours to size | the engine caps the period it will grant |

So on WASAPI, raising the flag cannot deepen the device buffer, but it still
adds slack in front of it -- which is the lever to reach for if the smallest
period turns out too tight to stay glitch-free.

**Remote Desktop:** RDP redirects audio as a compressed stream with its own
buffering, typically adding 100-250ms plus jitter, all of it downstream of
anything measurable here. If audio seems far more delayed than the configured
buffer, or glitches under network load, check whether you are on RDP before
looking anywhere else -- and raise `--audio-latency-ms` hard (200+) to ride
out the jitter, since the delay itself cannot be recovered from this side.

## Stream format

Served on `--audio-port`, default `8501`, alongside the screen stream on
8500. A 12-byte preamble -- `ZXA2`, a big-endian `u32` sample rate, and a
big-endian `u32` target latency in milliseconds -- followed by
`[big-endian u32 byte length][mono int16 little-endian]` blocks, the same
framing the screen stream uses for PNGs. The latency travels with the stream
so one `--audio-latency-ms` sets both the server's buffering and the depth of
the client's own jitter buffer, rather than two settings that can disagree.

`cpp-core/build/…/beep.exe` is a diagnostic that drives the whole path and
writes a WAV you can listen to: `beep tone` for a known square wave, `beep
rom` to call the ROM's own BEEPER routine, `beep serve` to stand the servers
up on their own without `main.cpp`.
