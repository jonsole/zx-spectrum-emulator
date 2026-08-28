#pragma once
// Beeper-audio streaming TCP server, the audio counterpart to
// screen_stream.h.

#include "engine.h"

#include <cstdint>
#include <string>

namespace zx {

/// Pushes live beeper audio to every connected client as a 12-byte preamble
/// ("ZXA2" + big-endian u32 sample rate + big-endian u32 target latency in
/// milliseconds) followed by
/// `[big-endian u32 byte length][mono int16 little-endian samples]` blocks,
/// forever. Blocking; run on its own thread.
///
/// The latency travels with the stream so that one `--audio-latency-ms` knob
/// sets both the server's buffering and the depth of the client's own jitter
/// buffer -- otherwise the VS Code panel would need a second, separate
/// setting that could disagree with this one.
///
/// Each connection registers its own Engine audio sink, so several clients
/// (and the native device) can listen at once without stealing each other's
/// samples.
void serve_audio_stream(Engine& engine, const std::string& host, uint16_t port,
                        uint32_t latency_ms);

} // namespace zx
