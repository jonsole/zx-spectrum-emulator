// The emulator in a web page: the core compiled to WebAssembly, driven a frame
// at a time from the page's requestAnimationFrame.
//
// This drives a Spectrum directly rather than through the Engine. The Engine
// exists to share one machine between a run thread and the protocol threads
// (DAP, MCP, the screen and audio streams); a page has none of those -- one
// thread asks for a frame, reads the screen and the samples it made, and asks
// for the next -- so its queue and its locks would be all cost. Built without
// rewind for the same reason: there is no debugger here to step backwards.
//
// The interface is a handful of C functions, so the page needs no binding
// generator: bytes go in through a buffer zx_alloc hands out, and the screen
// and the audio come back as pointers into the module's memory.

#include "snapshot.h"
#include "spectrum.h"

#include <emscripten/emscripten.h>

#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

zx::Spectrum* machine = nullptr;

/// The last error, kept so its pointer stays good until the next call.
std::string last_error;

/// The samples the last frame made, for the page to copy out.
std::vector<int16_t> audio;

/// The page's audio rate. Its AudioContext picks one (often 48000, not the
/// beeper's 44100), and the beeper's pitch is right only at the rate it is
/// actually played at.
uint32_t sample_rate = zx::AUDIO_SAMPLE_RATE;

zx::Spectrum& m() {
    if (machine == nullptr) {
        machine = new zx::Spectrum();
    }
    return *machine;
}

const char* result(const std::string& error) {
    last_error = error;
    return last_error.empty() ? nullptr : last_error.c_str();
}

} // namespace

extern "C" {

/// A buffer of `len` bytes in the module's memory, for the page to fill.
EMSCRIPTEN_KEEPALIVE uint8_t* zx_alloc(size_t len) {
    return static_cast<uint8_t*>(std::malloc(len));
}

EMSCRIPTEN_KEEPALIVE void zx_free(uint8_t* p) {
    std::free(p);
}

/// Loads a ROM image: 16K for the 48K's, 32K for the 128K's pair. Both can be
/// loaded, and a snapshot then picks the model it needs. Null on success, or
/// why not.
EMSCRIPTEN_KEEPALIVE const char* zx_load_rom(const uint8_t* data, size_t len) {
    return result(m().load_rom(data, len));
}

/// Loads a .z80 or .sna, switching the model to match it. Null on success, or
/// why not.
EMSCRIPTEN_KEEPALIVE const char* zx_load_snapshot(const uint8_t* data, size_t len) {
    zx::Spectrum& s = m();
    std::string error = zx::load_snapshot(s, data, len);
    // A model switch resets the beeper's clock and rate, so they are set
    // again rather than trusted to have survived.
    s.beeper.set_sample_rate(sample_rate);
    s.beeper.set_enabled(true, s.global_hc());
    return result(error);
}

/// Resets the machine into the ROM of whichever model it is.
EMSCRIPTEN_KEEPALIVE void zx_reset() {
    m().reset();
    m().beeper.set_enabled(true, m().global_hc());
}

/// 0 for a 48K, 1 for a 128K: what the page paces frames by, since the two
/// run at slightly different frame rates.
EMSCRIPTEN_KEEPALIVE int zx_is_128k() {
    return m().model() == zx::Model::Spectrum128 ? 1 : 0;
}

/// Frames per second of the current model, times 1000.
EMSCRIPTEN_KEEPALIVE uint32_t zx_frame_rate_milli() {
    const zx::UlaTiming& t = m().ula.timing();
    return uint32_t(t.hc_per_sec * 1000 / t.hc_per_frame());
}

EMSCRIPTEN_KEEPALIVE void zx_set_sample_rate(uint32_t rate) {
    sample_rate = rate;
    m().beeper.set_sample_rate(rate);
    m().beeper.set_enabled(true, m().global_hc());
}

/// Runs one video frame, to the next interrupt, and collects what the beeper
/// made of it.
EMSCRIPTEN_KEEPALIVE void zx_run_frame() {
    zx::Spectrum& s = m();
    s.run_frame();
    s.beeper.advance_to(s.global_hc());
    audio.clear();
    s.beeper.drain(audio);
}

/// The last completed frame, RGB, FULL_WIDTH x FULL_HEIGHT, border included.
EMSCRIPTEN_KEEPALIVE const uint8_t* zx_screen() {
    return m().screen().data();
}

EMSCRIPTEN_KEEPALIVE uint32_t zx_screen_width() {
    return zx::FULL_WIDTH;
}

EMSCRIPTEN_KEEPALIVE uint32_t zx_screen_height() {
    return zx::FULL_HEIGHT;
}

/// The samples zx_run_frame made, signed 16-bit mono at the page's rate.
EMSCRIPTEN_KEEPALIVE const int16_t* zx_audio() {
    return audio.data();
}

EMSCRIPTEN_KEEPALIVE size_t zx_audio_length() {
    return audio.size();
}

/// A key by its Spectrum name: "A", "1", "ENTER", "SPACE", "CAPS SHIFT",
/// "SYM SHIFT". Unknown names are ignored.
EMSCRIPTEN_KEEPALIVE void zx_key(const char* name, int down) {
    if (down) {
        m().keyboard.key_down(name);
    } else {
        m().keyboard.key_up(name);
    }
}

/// Lets go of every key -- for when the page loses focus with one held.
EMSCRIPTEN_KEEPALIVE void zx_keys_clear() {
    m().keyboard.clear();
}

} // extern "C"
