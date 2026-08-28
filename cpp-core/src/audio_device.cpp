// Native playback through waveOut, and the clock the emulator paces against.
//
// waveOut rather than a vendored miniaudio/PortAudio: winmm is ALREADY linked
// (engine.cpp uses timeBeginPeriod for pacing), so the whole feature costs no
// new dependency at all -- which matters in a project whose only third-party
// code is two single headers and which has no package manager. It is a legacy
// API, but "play a mono 16-bit stream" is exactly what it has always been
// good at, and it is present on every Windows.
//
// The feeder thread polls rather than using a callback: waveOut callbacks run
// with restrictions on what may be called from them, and there is nothing to
// gain here -- a 2ms poll against 20ms buffers stays comfortably ahead.
//
// Two rules keep the latency where it was asked to be.
//
// 1. NEVER queue a partially-filled block -- not even to bridge an underrun.
//    Padding a short read out to a whole buffer hands the device samples the
//    emulator never produced. Two things follow, and both were measured
//    rather than guessed. Audio backs up ahead of the speaker until it hits
//    the cap and stays there, a permanent delay no buffer tuning can undo.
//    And because the emulator paces against this queue (rule 2), the padding
//    counts against it: the machine is throttled by samples that were never
//    real, and runs SLOW. A shallow queue measured 40.1fps against 50.08 --
//    the game in visible slow motion, silently. A gap is the honest failure:
//    it costs a click, the emulator keeps correct time, and the fix is simply
//    a larger --audio-latency-ms.
//
// 2. The emulator paces against this device, not against a wall clock. The
//    card consumes samples at its own rate, which is never exactly the rate a
//    timer believes a 48K runs at, so timer pacing lets the two drift apart:
//    either audio piles up ahead of the speaker (latency) or the device runs
//    dry (gaps). Publishing how much is buffered and letting
//    Engine::pace_wait hold on it makes the emulator produce exactly what the
//    hardware consumes -- and because frames come off the same emulation
//    loop, the picture stays locked to the sound rather than being timed
//    separately from it.

#include "audio_device.h"

#include "audio_wasapi.h"

#include "beeper.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mmsystem.h>
#pragma comment(lib, "winmm.lib")
#endif

namespace zx {
namespace {

#ifdef _WIN32

/// Size of one waveOut buffer, and so the granularity at which a requested
/// latency can be honoured and the length of a gap if the emulator stalls.
constexpr uint32_t BLOCK_MS = 20;

/// Bounds on how many of those the feeder keeps queued at the device. The
/// default latency works out at three at the device plus one of headroom --
/// 80ms in total -- which is deep enough that ordinary Windows scheduling
/// jitter cannot empty it between polls and shallow enough that a keypress
/// and its beep still feel simultaneous.
constexpr int MIN_BLOCKS = 2;
constexpr int MAX_BLOCKS = 16;

/// Blocks of production headroom the emulator is allowed above the device
/// queue before pacing holds it.
///
/// Without this the emulator runs at HALF SPEED on small buffers, and the
/// reason is worth keeping written down. Pacing is checked once per yield,
/// after a chunk has already been produced. If the target is exactly the
/// device queue, then the moment the queue is full any chunk at all puts the
/// emulator over it, so it blocks until a whole block drains -- producing one
/// ~10ms chunk per 20ms block completion. Measured at 23.5fps against 50.08
/// with a two-block queue. One block of headroom means the ring always has a
/// whole block ready the instant the device frees a header, so production and
/// consumption interleave instead of taking turns.
constexpr int HEADROOM_BLOCKS = 1;

constexpr auto POLL_INTERVAL = std::chrono::milliseconds(2);

struct Layout {
    size_t block_samples;
    int block_count;
    size_t ring_samples;
};

/// Splits a requested end-to-end latency into a device queue plus the
/// headroom above it, so the flag means the total a listener actually hears.
Layout layout_for(uint32_t latency_ms) {
    Layout out;
    out.block_samples = size_t(AUDIO_SAMPLE_RATE) * BLOCK_MS / 1000;
    int blocks = int(latency_ms / BLOCK_MS) - HEADROOM_BLOCKS;
    if (blocks < MIN_BLOCKS) {
        blocks = MIN_BLOCKS;
    } else if (blocks > MAX_BLOCKS) {
        blocks = MAX_BLOCKS;
    }
    out.block_count = blocks;
    // Headroom only. Pacing holds the ring near empty by construction, so
    // this is what absorbs a burst when pacing is NOT in charge -- an
    // uncapped run, or the fallback after a device stops draining.
    out.ring_samples = out.block_samples * (size_t(blocks) + 2);
    return out;
}

/// Blocks currently handed to the device. Published by the feeder so that
/// Engine::pace_wait can see how much audio is queued ahead of the speaker.
using QueueDepth = std::shared_ptr<std::atomic<size_t>>;

#ifdef _MSC_VER
// The teardown at the end of feed() is deliberately unreachable (see the note
// there), and /W4 /WX would otherwise fail the build over it. C4702 comes from
// the code generator, so the pragma has to wrap the whole function -- inside
// the body it has no effect at all.
#pragma warning(push)
#pragma warning(disable : 4702)
#endif
void feed(HWAVEOUT device, Engine& engine, std::shared_ptr<AudioRing> ring, Layout layout,
          QueueDepth depth) {
    const size_t block_samples = layout.block_samples;
    const int block_count = layout.block_count;

    // Sized through a named variable, not `blocks(size_t(block_count))` --
    // that parses as a function declaration, not a vector.
    const size_t count = size_t(block_count);
    std::vector<std::vector<int16_t>> blocks(count);
    std::vector<WAVEHDR> headers(count);
    for (int i = 0; i < block_count; i++) {
        blocks[size_t(i)].assign(block_samples, 0);
        WAVEHDR& h = headers[size_t(i)];
        ZeroMemory(&h, sizeof h);
        h.lpData = reinterpret_cast<LPSTR>(blocks[size_t(i)].data());
        h.dwBufferLength = DWORD(block_samples * sizeof(int16_t));
        waveOutPrepareHeader(device, &h, sizeof h);
        h.dwFlags |= WHDR_DONE; // nothing queued yet, so all are free
    }

    for (;;) {
        int in_flight = 0;
        for (int i = 0; i < block_count; i++) {
            if ((headers[size_t(i)].dwFlags & WHDR_DONE) == 0) {
                in_flight++;
            }
        }

        // Top the device back up to a full queue. There are exactly
        // block_count headers, so this cannot overshoot the target depth.
        for (int i = 0; i < block_count; i++) {
            WAVEHDR& h = headers[size_t(i)];
            if ((h.dwFlags & WHDR_DONE) == 0) {
                continue; // still playing
            }

            if (ring->available() < block_samples) {
                break; // not a whole block yet
            }
            std::vector<int16_t>& block = blocks[size_t(i)];
            ring->read(block.data(), block_samples);

            h.dwFlags &= ~WHDR_DONE;
            if (waveOutWrite(device, &h, sizeof h) != MMSYSERR_NOERROR) {
                h.dwFlags |= WHDR_DONE;
                break;
            }
            in_flight++;
        }

        depth->store(size_t(in_flight));
        std::this_thread::sleep_for(POLL_INTERVAL);
    }

    // Unreachable in practice -- the server runs until the process exits --
    // but left correct so the shape of the teardown is on record.
    for (int i = 0; i < block_count; i++) {
        waveOutUnprepareHeader(device, &headers[size_t(i)], sizeof headers[size_t(i)]);
    }
    waveOutClose(device);
    engine.clear_pacing_clock();
    engine.remove_audio_sink(ring);
}
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#endif // _WIN32

} // namespace

#ifdef _WIN32

/// waveOut fallback, used only when the WASAPI path is unavailable.
bool start_waveout_playback(Engine& engine, uint32_t latency_ms, std::string& error) {
    if (waveOutGetNumDevs() == 0) {
        error = "no audio output device";
        return false;
    }

    WAVEFORMATEX format;
    ZeroMemory(&format, sizeof format);
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = AUDIO_SAMPLE_RATE;
    format.wBitsPerSample = 16;
    format.nBlockAlign = WORD(format.nChannels * format.wBitsPerSample / 8);
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;

    HWAVEOUT device = nullptr;
    const MMRESULT result = waveOutOpen(&device, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
    if (result != MMSYSERR_NOERROR) {
        error = "waveOutOpen failed (" + std::to_string(unsigned(result)) + ")";
        return false;
    }

    const Layout layout = layout_for(latency_ms);
    std::shared_ptr<AudioRing> ring = engine.add_audio_sink(layout.ring_samples);
    QueueDepth depth = std::make_shared<std::atomic<size_t>>(0);

    // The sound card becomes the master clock. "Buffered ahead of the
    // speaker" is what is queued at the device plus whatever has not reached
    // it yet; the emulator holds whenever that exceeds a full queue, so it
    // settles at exactly block_count blocks and stays there.
    const size_t block_samples = layout.block_samples;
    const size_t target = size_t(layout.block_count + HEADROOM_BLOCKS) * block_samples;
    engine.set_pacing_clock(
        [depth, ring, block_samples]() {
            return depth->load() * block_samples + ring->available();
        },
        target);

    std::thread([device, &engine, ring, layout, depth]() {
        feed(device, engine, ring, layout, depth);
    }).detach();
    return true;
}

bool start_audio_device(Engine& engine, uint32_t latency_ms, uint32_t& actual_latency_ms,
                        std::string& error) {
    // WASAPI first: it is the only path that can ask the audio engine for a
    // period below its default, and waveOut's own blocks are the floor on
    // what that backend can do.
    std::string wasapi_error;
    if (start_wasapi_playback(engine, latency_ms, actual_latency_ms, wasapi_error)) {
        return true;
    }
    if (start_waveout_playback(engine, latency_ms, error)) {
        actual_latency_ms = waveout_latency_ms(latency_ms);
        return true;
    }
    error = "WASAPI: " + wasapi_error + "; waveOut: " + error;
    return false;
}

uint32_t waveout_latency_ms(uint32_t latency_ms) {
    return uint32_t(layout_for(latency_ms).block_count + HEADROOM_BLOCKS) * BLOCK_MS;
}

#else

bool start_audio_device(Engine&, uint32_t, uint32_t&, std::string& error) {
    error = "native audio playback is implemented for Windows only; "
            "use the audio stream server instead";
    return false;
}

uint32_t waveout_latency_ms(uint32_t latency_ms) { return latency_ms; }

#endif

} // namespace zx
