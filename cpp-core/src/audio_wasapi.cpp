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

#include "audio_wasapi.h"

#include "beeper.h"

#include <atomic>
#include <cstdint>
#include <memory>
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

void render_thread(IAudioClient3* client, IAudioRenderClient* render, HANDLE event,
                   WAVEFORMATEX* format, UINT32 buffer_frames, Engine* engine,
                   std::shared_ptr<AudioRing> ring, SharedPtr shared) {
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

    const bool is_float = is_float_format(format);
    std::vector<int16_t> scratch;

    for (;;) {
        if (WaitForSingleObject(event, 2000) != WAIT_OBJECT_0) {
            break; // the device went away
        }
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) {
            break;
        }
        const UINT32 free_frames = buffer_frames - padding;
        if (free_frames == 0) {
            shared->buffered.store(size_t(padding));
            continue;
        }
        BYTE* data = nullptr;
        if (FAILED(render->GetBuffer(free_frames, &data))) {
            break;
        }
        fill(data, free_frames, *ring, format, scratch, is_float);
        render->ReleaseBuffer(free_frames, 0);

        // What the speaker still has to get through, which is what the
        // emulator paces against.
        shared->buffered.store(size_t(padding) + size_t(free_frames));
    }

    client->Stop();
    if (task != nullptr && revert != nullptr) {
        revert(task);
    }
    engine->clear_pacing_clock();
    engine->remove_audio_sink(ring);
    CoTaskMemFree(format);
    render->Release();
    client->Release();
    CloseHandle(event);
    CoUninitialize();
}

} // namespace

bool start_wasapi_playback(Engine& engine, uint32_t latency_ms, uint32_t& actual_latency_ms,
                           std::string& error) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_owned = SUCCEEDED(com);
    if (!com_owned && com != RPC_E_CHANGED_MODE) {
        error = "CoInitializeEx failed";
        return false;
    }

    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator)))) {
        error = "no audio device enumerator";
        return false;
    }
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device))) {
        error = "no default audio output device";
        return false;
    }

    // IAudioClient3 is the whole point: IAudioClient alone cannot ask for a
    // period below the engine default.
    IAudioClient3* client = nullptr;
    if (FAILED(device->Activate(__uuidof(IAudioClient3), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(&client)))) {
        error = "IAudioClient3 unavailable (needs Windows 10 or later)";
        return false;
    }

    WAVEFORMATEX* format = nullptr;
    if (FAILED(client->GetMixFormat(&format))) {
        client->Release();
        error = "GetMixFormat failed";
        return false;
    }

    UINT32 default_period = 0, fundamental = 0, min_period = 0, max_period = 0;
    if (FAILED(client->GetSharedModeEnginePeriod(format, &default_period, &fundamental,
                                                 &min_period, &max_period))) {
        CoTaskMemFree(format);
        client->Release();
        error = "GetSharedModeEnginePeriod failed";
        return false;
    }

    // Aim at the requested latency but never below what the engine allows.
    // Periods must be whole multiples of the fundamental.
    UINT32 period = UINT32(uint64_t(format->nSamplesPerSec) * latency_ms / 1000);
    if (fundamental != 0) {
        period = (period / fundamental) * fundamental;
    }
    if (period < min_period) {
        period = min_period;
    } else if (period > max_period) {
        period = max_period;
    }

    if (FAILED(client->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period,
                                                   format, nullptr))) {
        CoTaskMemFree(format);
        client->Release();
        error = "InitializeSharedAudioStream failed";
        return false;
    }

    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (event == nullptr || FAILED(client->SetEventHandle(event))) {
        if (event != nullptr) {
            CloseHandle(event);
        }
        CoTaskMemFree(format);
        client->Release();
        error = "SetEventHandle failed";
        return false;
    }

    UINT32 buffer_frames = 0;
    IAudioRenderClient* render = nullptr;
    if (FAILED(client->GetBufferSize(&buffer_frames))
        || FAILED(client->GetService(__uuidof(IAudioRenderClient),
                                     reinterpret_cast<void**>(&render)))) {
        CloseHandle(event);
        CoTaskMemFree(format);
        client->Release();
        error = "could not obtain the render client";
        return false;
    }

    // Generate at the engine's rate rather than resampling onto it.
    const uint32_t rate = format->nSamplesPerSec;
    engine.set_audio_sample_rate(rate);

    // The ring only bridges the emulator's publishes (roughly twice per
    // frame) and the render callback; pacing keeps it near empty, so it needs
    // to be a few periods deep and no more.
    const size_t ring_frames =
        size_t(buffer_frames) * 4 + size_t(uint64_t(rate) * latency_ms / 1000);
    std::shared_ptr<AudioRing> ring = engine.add_audio_sink(ring_frames);
    SharedPtr shared = std::make_shared<Shared>();

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
    size_t target = size_t(buffer_frames) * 2;
    const size_t requested = size_t(uint64_t(rate) * latency_ms / 1000);
    if (requested > target) {
        target = requested;
    }
    engine.set_pacing_clock(
        [shared, ring]() { return shared->buffered.load() + ring->available(); }, target);

    if (FAILED(client->Start())) {
        engine.clear_pacing_clock();
        engine.remove_audio_sink(ring);
        render->Release();
        CloseHandle(event);
        CoTaskMemFree(format);
        client->Release();
        error = "could not start the audio stream";
        return false;
    }

    actual_latency_ms = uint32_t(uint64_t(buffer_frames) * 1000 / rate);

    std::thread(render_thread, client, render, event, format, buffer_frames, &engine, ring,
                shared)
        .detach();
    return true;
}

#else

bool start_wasapi_playback(Engine&, uint32_t, uint32_t&, std::string& error) {
    error = "WASAPI is Windows-only";
    return false;
}

#endif

} // namespace zx
