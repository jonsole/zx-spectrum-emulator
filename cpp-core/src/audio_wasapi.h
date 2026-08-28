#pragma once
// Low-latency native playback through WASAPI shared mode (IAudioClient3).
//
// The preferred backend; audio_device.cpp falls back to waveOut if this is
// unavailable (pre-Windows-10, or a device that refuses the low-latency path).

#include "engine.h"

#include <cstdint>
#include <string>

namespace zx {

/// Opens the default render endpoint in shared mode at the smallest engine
/// period it will grant, and starts feeding it from a new Engine audio sink.
///
/// Sets the Engine's beeper rate to the audio engine's mix rate: shared mode
/// runs at that rate and nothing else, and generating there directly is both
/// exact and cheaper than resampling onto it.
///
/// On success `actual_latency_ms` reports the buffer depth actually granted,
/// which may be smaller than requested -- that is the point of the API.
bool start_wasapi_playback(Engine& engine, uint32_t latency_ms, uint32_t& actual_latency_ms,
                           std::string& error);

} // namespace zx
