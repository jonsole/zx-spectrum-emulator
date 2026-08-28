#pragma once
// Optional native playback: the server process opens the host's sound device
// and plays the beeper itself, instead of (or as well as) streaming it to a
// VS Code panel.

#include "engine.h"

#include <cstdint>
#include <string>

namespace zx {

/// Default playback buffer depth. Low enough that a keypress and its beep
/// feel simultaneous, high enough to survive the emulator's pacing sleeps and
/// ordinary Windows scheduling jitter without gapping.
constexpr uint32_t DEFAULT_AUDIO_LATENCY_MS = 80;

/// Opens the default playback device and starts feeding it from a new Engine
/// audio sink, buffering roughly `latency_ms` of audio ahead of the speaker.
/// Returns false and fills `error` if there is no usable device.
///
/// Tries WASAPI shared mode (IAudioClient3) first and falls back to waveOut,
/// so `actual_latency_ms` reports what was really granted -- WASAPI will
/// usually beat the request by a wide margin, waveOut will round it to its
/// own 20ms blocks.
///
/// Never fatal: a headless box, a machine with no sound card, or a device
/// already held exclusively by something else are all ordinary situations for
/// a debug server, and none of them are a reason to refuse to emulate.
bool start_audio_device(Engine& engine, uint32_t latency_ms, uint32_t& actual_latency_ms,
                        std::string& error);

/// What `latency_ms` rounds to on the waveOut fallback, whose buffers come in
/// fixed 20ms steps.
uint32_t waveout_latency_ms(uint32_t latency_ms);

} // namespace zx
