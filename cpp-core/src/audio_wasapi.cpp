// WASAPI shared-mode playback via IAudioClient3.
//
// Why this rather than the waveOut backend next door: waveOut is a legacy
// shim whose buffers are whatever we make them, and it was measured at ~80ms
// end to end with no way to go lower -- its 20ms blocks ARE the floor, and
// three or four of them have to be in flight to survive scheduling jitter.
// IAudioClient3::InitializeSharedAudioStream asks the audio engine for its
// SMALLEST supported period instead, typically 2.5-10ms, and drives us from
// an event rather than a poll. Same shared-mode mixer, an order of magnitude
// less buffering.
//
// Two consequences shape the code:
//
//   * Shared mode runs at the engine's mix format and nothing else. Instead
//     of resampling 44100 onto it, the Beeper is told to generate at the mix
//     rate directly -- its decimator is an integer accumulator that is exact
//     at any rate, so this costs nothing and loses nothing.
//
//   * The mix format is practically always 32-bit float, and usually stereo.
//     Converting mono int16 to that is a multiply and a copy per frame.
//
// The emulator paces against this device (see Engine::set_pacing_clock), so
// the render thread must publish how much is buffered ahead of the speaker.
// Underruns are filled with silence and never with held samples: padding
// hands the device audio the emulator never produced, which both inflates
// latency and -- because pacing counts it -- silently slows the machine down.
//
// The device does not stay put. Plugging in headphones, a Bluetooth speaker
// connecting, a driver update, the machine sleeping and waking -- any of them
// invalidates a shared-mode stream, and the documented remedy is to throw
// everything away and open the current default endpoint afresh. So the stream
// is opened by one function, torn down by another, and a supervising thread
// runs the render loop between them: when the loop reports the device gone, it
// closes up, waits, and opens again, for as long as the process lives.

#include "audio_wasapi.h"

#include "beeper.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>

#pragma comment(lib, "ole32.lib")
#endif

namespace zx {

#ifdef _WIN32

namespace {

/// Releases a COM interface on scope exit. The alternative is a goto chain or
/// a leak on every early return, and there are a lot of early returns here.
template <typename T>
struct ComPtr {
    T* p = nullptr;
    ~ComPtr() {
        if (p != nullptr) {
            p->Release();
        }
    }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
};

/// True if the mix format is 32-bit float, which is what the Windows audio
/// engine mixes in and therefore what shared mode nearly always hands us.
bool is_float_format(const WAVEFORMATEX* f) {
    if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        return true;
    }
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
        return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    }
    return false;
}

struct Shared {
    std::atomic<size_t> buffered{0}; // frames queued ahead of the speaker
};
using SharedPtr = std::shared_ptr<Shared>;

/// Writes `frames` of the ring's mono audio into the device buffer, in the
/// engine's format, padding with SILENCE (never held samples) if the ring
/// runs short. Returns how many real frames were taken.
size_t fill(BYTE* out, UINT32 frames, AudioRing& ring, const WAVEFORMATEX* fmt,
            std::vector<int16_t>& scratch, bool is_float) {
    const size_t channels = fmt->nChannels;
    scratch.resize(frames);
    const size_t got = ring.read(scratch.data(), frames);
    for (size_t i = got; i < frames; i++) {
        scratch[i] = 0; // underrun: silence, deliberately
    }

    if (is_float) {
        float* dst = reinterpret_cast<float*>(out);
        for (UINT32 i = 0; i < frames; i++) {
            const float v = float(scratch[i]) / 32768.0f;
            for (size_t c = 0; c < channels; c++) {
                *dst++ = v;
            }
        }
    } else {
        int16_t* dst = reinterpret_cast<int16_t*>(out);
        for (UINT32 i = 0; i < frames; i++) {
            for (size_t c = 0; c < channels; c++) {
                *dst++ = scratch[i];
            }
        }
    }
    return got;
}

/// One open connection to the device: what open_stream hands back, what
/// render_loop feeds, and what close_stream gives back to Windows.
struct Stream {
    IAudioClient3* client = nullptr;
    IAudioRenderClient* render = nullptr;
    HANDLE event = nullptr;
    WAVEFORMATEX* format = nullptr;
    UINT32 buffer_frames = 0;
    bool is_float = false;
    /// The sink the emulator writes into, and what it paces against. Both are
    /// registered with the Engine while the stream is open and withdrawn when
    /// it closes, so a machine with no device simply runs on the wall clock.
    std::shared_ptr<AudioRing> ring;
    SharedPtr shared;
};

/// Hands everything back. Safe on a half-open stream -- every field is
/// checked -- which is what lets open_stream use it for its own failures.
void close_stream(Engine& engine, Stream& s) {
    if (s.client != nullptr) {
        s.client->Stop(); // fails on an invalidated device; nothing to do about it
    }
    engine.clear_pacing_clock();
    if (s.ring) {
        engine.remove_audio_sink(s.ring);
        s.ring.reset();
    }
    if (s.render != nullptr) {
        s.render->Release();
        s.render = nullptr;
    }
    if (s.client != nullptr) {
        s.client->Release();
        s.client = nullptr;
    }
    if (s.event != nullptr) {
        CloseHandle(s.event);
        s.event = nullptr;
    }
    if (s.format != nullptr) {
        CoTaskMemFree(s.format);
        s.format = nullptr;
    }
    s.shared.reset();
    s.buffer_frames = 0;
}

/// Opens the current default output device and registers the sink and the
/// pacing clock. COM must already be initialised on the calling thread.
bool open_stream(Engine& engine, uint32_t latency_ms, Stream& out, uint32_t& actual_latency_ms,
                 std::string& error) {
    out = Stream();

    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator)))) {
        error = "no audio device enumerator";
        return false;
    }
    // Asked for afresh every time: after a device change, the default endpoint
    // is precisely what has changed.
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device))) {
        error = "no default audio output device";
        return false;
    }

    // IAudioClient3 is the whole point: IAudioClient alone cannot ask for a
    // period below the engine default.
    if (FAILED(device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&out.client)))) {
        error = "IAudioClient3 unavailable (needs Windows 10 or later)";
        close_stream(engine, out);
        return false;
    }

    if (FAILED(out.client->GetMixFormat(&out.format))) {
        error = "GetMixFormat failed";
        close_stream(engine, out);
        return false;
    }

    UINT32 default_period = 0, fundamental = 0, min_period = 0, max_period = 0;
    if (FAILED(out.client->GetSharedModeEnginePeriod(out.format, &default_period, &fundamental,
                                                     &min_period, &max_period))) {
        error = "GetSharedModeEnginePeriod failed";
        close_stream(engine, out);
        return false;
    }

    // Aim at the requested latency but never below what the engine allows.
    // Periods must be whole multiples of the fundamental.
    UINT32 period = UINT32(uint64_t(out.format->nSamplesPerSec) * latency_ms / 1000);
    if (fundamental != 0) {
        period = (period / fundamental) * fundamental;
    }
    if (period < min_period) {
        period = min_period;
    } else if (period > max_period) {
        period = max_period;
    }

    if (FAILED(out.client->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period,
                                                       out.format, nullptr))) {
        error = "InitializeSharedAudioStream failed";
        close_stream(engine, out);
        return false;
    }

    out.event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (out.event == nullptr || FAILED(out.client->SetEventHandle(out.event))) {
        error = "SetEventHandle failed";
        close_stream(engine, out);
        return false;
    }

    if (FAILED(out.client->GetBufferSize(&out.buffer_frames))
        || FAILED(out.client->GetService(__uuidof(IAudioRenderClient),
                                         reinterpret_cast<void**>(&out.render)))) {
        error = "could not obtain the render client";
        close_stream(engine, out);
        return false;
    }

    out.is_float = is_float_format(out.format);

    // Generate at the engine's rate rather than resampling onto it. Told again
    // on every reopen: the device that replaced the old one is entitled to a
    // different mix rate.
    const uint32_t rate = out.format->nSamplesPerSec;
    engine.set_audio_sample_rate(rate);

    // The ring only bridges the emulator's publishes (roughly twice per
    // frame) and the render callback; pacing keeps it near empty, so it needs
    // to be a few periods deep and no more.
    const size_t ring_frames =
        size_t(out.buffer_frames) * 4 + size_t(uint64_t(rate) * latency_ms / 1000);
    out.ring = engine.add_audio_sink(ring_frames);
    out.shared = std::make_shared<Shared>();

    // Pace against what is queued ahead of the speaker plus what has not
    // reached it yet, with one device buffer of headroom so the emulator can
    // keep producing while the current one drains. Without that headroom it
    // produces one chunk per callback and runs at a fraction of full speed.
    //
    // This is also where --audio-latency-ms keeps meaning something on this
    // backend. The engine caps how large a shared-mode period it will grant,
    // so asking for more cannot deepen the device buffer -- but it can hold
    // more ahead of it here, which is the knob to reach for if the smallest
    // period turns out too tight to stay glitch-free.
    size_t target = size_t(out.buffer_frames) * 2;
    const size_t requested = size_t(uint64_t(rate) * latency_ms / 1000);
    if (requested > target) {
        target = requested;
    }
    const SharedPtr shared = out.shared;
    const std::shared_ptr<AudioRing> ring = out.ring;
    engine.set_pacing_clock([shared, ring]() { return shared->buffered.load() + ring->available(); },
                            target);

    if (FAILED(out.client->Start())) {
        error = "could not start the audio stream";
        close_stream(engine, out);
        return false;
    }

    actual_latency_ms = uint32_t(uint64_t(out.buffer_frames) * 1000 / rate);
    return true;
}

/// Milliseconds after which render_loop pretends the device went away, from
/// ZX_AUDIO_DROP_TEST, or 0. The reopening path is otherwise only reachable by
/// pulling hardware out of a running machine, which is no way to check that it
/// works; with this, `ZX_AUDIO_DROP_TEST=1500 zx_server --audio-device` drops
/// and reopens every second and a half, and the log says so each time.
uint64_t drop_test_ms() {
    static const uint64_t ms = [] {
        // GetEnvironmentVariableW rather than getenv, which MSVC deprecates
        // and this build treats deprecation as an error.
        wchar_t value[32] = {};
        const DWORD n = GetEnvironmentVariableW(L"ZX_AUDIO_DROP_TEST", value,
                                                DWORD(sizeof value / sizeof value[0]));
        return n > 0 && n < sizeof value / sizeof value[0] ? uint64_t(_wtoi64(value)) : 0ull;
    }();
    return ms;
}

/// Feeds the device until it stops wanting audio. Returns why it ended, for
/// the log -- it only returns when the stream is finished with.
const char* render_loop(Stream& s, std::vector<int16_t>& scratch) {
    const auto started = std::chrono::steady_clock::now();
    for (;;) {
        if (drop_test_ms() != 0) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                                     std::chrono::steady_clock::now() - started)
                                     .count();
            if (uint64_t(elapsed) >= drop_test_ms()) {
                return "a drop forced by ZX_AUDIO_DROP_TEST";
            }
        }
        // A healthy stream signals every period, a few milliseconds apart.
        // Two seconds of silence from it means the device is not there any
        // more, whatever it says about itself.
        if (WaitForSingleObject(s.event, 2000) != WAIT_OBJECT_0) {
            return "it stopped asking for audio";
        }
        UINT32 padding = 0;
        if (FAILED(s.client->GetCurrentPadding(&padding))) {
            return "the device was invalidated";
        }
        const UINT32 free_frames = s.buffer_frames - padding;
        if (free_frames == 0) {
            s.shared->buffered.store(size_t(padding));
            continue;
        }
        BYTE* data = nullptr;
        if (FAILED(s.render->GetBuffer(free_frames, &data))) {
            return "its buffer could not be written";
        }
        fill(data, free_frames, *s.ring, s.format, scratch, s.is_float);
        s.render->ReleaseBuffer(free_frames, 0);

        // What the speaker still has to get through, which is what the
        // emulator paces against.
        s.shared->buffered.store(size_t(padding) + size_t(free_frames));
    }
}

/// How long to wait before opening the device again, and the ceiling that
/// backs off to. A device change is over in well under a second; a device
/// that is simply not there yet (a Bluetooth speaker reconnecting) can take
/// as long as it likes, and is not worth asking about every quarter second.
constexpr auto FIRST_RETRY = std::chrono::milliseconds(250);
constexpr auto MAX_RETRY = std::chrono::seconds(5);

/// Runs the render loop, and reopens the device whenever it ends. Detached and
/// never joined: it lives as long as the server does.
void playback_thread(Engine* engine, uint32_t latency_ms, Stream stream) {
    // The COM apartment belongs to the thread, not to the process: this thread
    // does its own reopening, so it needs its own. (The stream itself was
    // opened on the caller's thread and is used here, which multithreaded
    // apartments allow.)
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    // This thread does small amounts of work on a tight deadline; without the
    // bump it competes with the emulator thread and drops buffers.
    HANDLE task = nullptr;
    DWORD task_index = 0;
    using AvSetMmThreadCharacteristicsWFn = HANDLE(WINAPI*)(LPCWSTR, LPDWORD);
    using AvRevertMmThreadCharacteristicsFn = BOOL(WINAPI*)(HANDLE);
    AvRevertMmThreadCharacteristicsFn revert = nullptr;
    if (HMODULE avrt = LoadLibraryW(L"avrt.dll")) {
        auto set = reinterpret_cast<AvSetMmThreadCharacteristicsWFn>(
            reinterpret_cast<void*>(GetProcAddress(avrt, "AvSetMmThreadCharacteristicsW")));
        revert = reinterpret_cast<AvRevertMmThreadCharacteristicsFn>(
            reinterpret_cast<void*>(GetProcAddress(avrt, "AvRevertMmThreadCharacteristics")));
        if (set != nullptr) {
            task = set(L"Pro Audio", &task_index);
        }
    }

    std::vector<int16_t> scratch;
    for (;;) {
        const char* why = render_loop(stream, scratch);
        close_stream(*engine, stream);
        // Said out loud, because the alternative is silence that looks like a
        // bug in the emulator: nothing else in the server would mention it.
        std::printf("Native audio: the device stopped (%s); reopening\n", why);
        std::fflush(stdout);

        auto wait = FIRST_RETRY;
        bool complained = false;
        for (;;) {
            std::this_thread::sleep_for(wait);
            uint32_t actual_ms = latency_ms;
            std::string error;
            if (open_stream(*engine, latency_ms, stream, actual_ms, error)) {
                std::printf("Native audio playback resumed on the default device "
                            "(%u Hz, %ums buffer)\n",
                            unsigned(engine->audio_sample_rate()), unsigned(actual_ms));
                std::fflush(stdout);
                break;
            }
            // Once, not once a retry: a machine with the device unplugged
            // would otherwise fill the terminal with it.
            if (!complained) {
                std::fprintf(stderr, "Native audio: cannot reopen the device (%s); still trying\n",
                             error.c_str());
                complained = true;
            }
            wait = wait * 2 > MAX_RETRY ? MAX_RETRY : wait * 2;
        }
    }

    // Unreachable: the loop above only ends with the process. The teardown is
    // what close_stream and the MMCSS revert would be, and is left here as a
    // note rather than as code that cannot run.
    (void)revert;
    (void)task;
}

} // namespace

bool start_wasapi_playback(Engine& engine, uint32_t latency_ms, uint32_t& actual_latency_ms,
                           std::string& error) {
    // On the caller's thread, so a machine with no audio device at all is an
    // error this function can report rather than a thread quietly retrying
    // for ever.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_owned = SUCCEEDED(com);
    if (!com_owned && com != RPC_E_CHANGED_MODE) {
        error = "CoInitializeEx failed";
        return false;
    }

    Stream stream;
    if (!open_stream(engine, latency_ms, stream, actual_latency_ms, error)) {
        return false;
    }

    std::thread(playback_thread, &engine, latency_ms, std::move(stream)).detach();
    return true;
}

#else

bool start_wasapi_playback(Engine&, uint32_t, uint32_t&, std::string& error) {
    error = "WASAPI is Windows-only";
    return false;
}

#endif

} // namespace zx
