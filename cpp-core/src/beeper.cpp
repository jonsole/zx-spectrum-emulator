#include "beeper.h"

#include <cmath>

namespace zx {

void Beeper::set_enabled(bool on, uint64_t now_hc) {
    // Already in the wanted state: do NOTHING. In particular do not move the
    // integration origin -- this is called on every publish, and skipping
    // last_hc_ forward here would silently discard the very interval the
    // caller is about to ask for.
    if (on == enabled_) {
        return;
    }
    if (on) {
        // Start integrating from here, not from wherever we left off: the gap
        // could be the whole of a ZEXALL run, and none of it is worth hearing.
        sum_ = 0;
        count_ = 0;
        acc_ = 0;
        dc_in_ = 0.0f;
        dc_out_ = 0.0f;
    }
    last_hc_ = now_hc;
    enabled_ = on;
}

void Beeper::set_sample_rate(uint32_t rate) {
    if (rate == 0 || rate == rate_) {
        return;
    }
    rate_ = rate;
    // The accumulator is scaled to the old rate, so carrying it over would
    // put the first sample in the wrong place.
    sum_ = 0;
    count_ = 0;
    acc_ = 0;
}

void Beeper::write_port_fe(uint8_t value, uint64_t now_hc) {
    // Integrate the OLD level right up to this instant before adopting the new
    // one, so an edge lands on the exact half-clock the OUT happened rather
    // than being rounded to the next drain.
    advance_to(now_hc);
    level_ = ((value & 0x10) != 0 ? SPEAKER_LEVEL : 0)
             + ((value & 0x08) != 0 ? MIC_LEVEL : 0);
}

void Beeper::set_ear(bool high, uint64_t now_hc) {
    // Same shape as write_port_fe: integrate the old level up to this instant
    // before adopting the new one, so a tape edge lands on the half-clock it
    // actually happened on.
    advance_to(now_hc);
    ear_level_ = high ? EAR_LEVEL : 0;
}

void Beeper::advance_to(uint64_t now_hc) {
    if (!enabled_ || now_hc <= last_hc_) {
        last_hc_ = now_hc > last_hc_ ? now_hc : last_hc_;
        return;
    }
    uint64_t remaining = now_hc - last_hc_;
    last_hc_ = now_hc;

    // The level is constant across this whole span, so walk it one SAMPLE at a
    // time rather than one half-clock at a time.
    while (remaining > 0) {
        // Half-clocks still needed for the sample clock to cross, i.e.
        // ceil((HC_PER_SEC - acc_) / AUDIO_SAMPLE_RATE). Always >= 1, since
        // acc_ is kept below HC_PER_SEC.
        const uint32_t deficit = uint32_t(HC_PER_SEC) - acc_;
        const uint32_t need = (deficit + rate_ - 1) / rate_;

        if (uint64_t(need) > remaining) {
            // Not enough left to finish this sample. `remaining` is below
            // `need` here and `need` is at most 159, so neither the multiply
            // below nor `acc_` can overflow.
            const uint32_t n = uint32_t(remaining);
            sum_ += mixed_level() * int32_t(n);
            count_ += n;
            acc_ += rate_ * n;
            return;
        }
        sum_ += mixed_level() * int32_t(need);
        count_ += need;
        acc_ += rate_ * need - uint32_t(HC_PER_SEC);
        remaining -= need;
        emit();
    }
}

void Beeper::emit() {
    // Box-filter average of the level over this sample period, normalised to
    // 0..1. count_ is 158 or 159 -- never zero, since a sample only completes
    // after at least one half-clock has been added.
    const float x = float(sum_) / (float(count_) * float(FULL_LEVEL));
    sum_ = 0;
    count_ = 0;

    // One-pole DC blocker: y[n] = x[n] - x[n-1] + R*y[n-1].
    const float y = x - dc_in_ + DC_BLOCK_R * dc_out_;
    dc_in_ = x;
    dc_out_ = y;

    int32_t scaled = int32_t(y * float(AUDIO_PEAK));
    if (scaled > INT16_MAX) {
        scaled = INT16_MAX;
    } else if (scaled < INT16_MIN) {
        scaled = INT16_MIN;
    }

    if (pending_.size() >= BEEPER_MAX_PENDING) {
        // Nothing is draining us. Drop the oldest half rather than one sample
        // at a time: the erase is O(n), and at this point the audio is already
        // going nowhere, so paying it once per half-buffer beats once per
        // sample.
        pending_.erase(pending_.begin(), pending_.begin() + long(pending_.size() / 2));
    }
    pending_.push_back(int16_t(scaled));
}

void Beeper::drain(std::vector<int16_t>& out) {
    out.insert(out.end(), pending_.begin(), pending_.end());
    pending_.clear();
}

void Beeper::reset() {
    // level_ deliberately survives, like Ula::border does. ear_level_ does
    // NOT: a reset stops the tape (Spectrum48K::reset), so nothing would ever
    // drive it low again, and a stuck EAR level would sit under everything
    // that followed as a DC offset eating headroom.
    ear_level_ = 0;
    sum_ = 0;
    count_ = 0;
    acc_ = 0;
    last_hc_ = 0;
    dc_in_ = 0.0f;
    dc_out_ = 0.0f;
    pending_.clear();
}

// ---- AudioRing --------------------------------------------------------------

void AudioRing::write(const int16_t* data, size_t n) {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t cap = buf_.size();
    if (cap == 0 || n == 0) {
        return;
    }
    if (n >= cap) {
        // More than the ring holds in one go: keep only the newest capacity.
        data += n - cap;
        n = cap;
        head_ = 0;
        size_ = 0;
    }
    if (size_ + n > cap) {
        const size_t drop = size_ + n - cap;
        head_ = (head_ + drop) % cap;
        size_ -= drop;
    }
    size_t w = (head_ + size_) % cap;
    for (size_t i = 0; i < n; i++) {
        buf_[w] = data[i];
        if (++w == cap) {
            w = 0;
        }
    }
    size_ += n;
}

size_t AudioRing::read(int16_t* out, size_t max) {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t cap = buf_.size();
    if (cap == 0) {
        return 0;
    }
    const size_t n = size_ < max ? size_ : max;
    size_t r = head_;
    for (size_t i = 0; i < n; i++) {
        out[i] = buf_[r];
        if (++r == cap) {
            r = 0;
        }
    }
    head_ = r;
    size_ -= n;
    return n;
}

void AudioRing::peek_latest(std::vector<int16_t>& out, size_t max) {
    out.clear();
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t cap = buf_.size();
    if (cap == 0) {
        return;
    }
    const size_t n = size_ < max ? size_ : max;
    size_t r = (head_ + (size_ - n)) % cap;
    out.reserve(n);
    for (size_t i = 0; i < n; i++) {
        out.push_back(buf_[r]);
        if (++r == cap) {
            r = 0;
        }
    }
}

size_t AudioRing::available() {
    std::lock_guard<std::mutex> lock(mutex_);
    return size_;
}

// ---- analysis helpers -------------------------------------------------------

float estimate_frequency_hz(const std::vector<int16_t>& samples) {
    if (samples.size() < 2) {
        return 0.0f;
    }
    int32_t peak = 0;
    for (size_t i = 0; i < samples.size(); i++) {
        const int32_t a = samples[i] < 0 ? -int32_t(samples[i]) : int32_t(samples[i]);
        if (a > peak) {
            peak = a;
        }
    }
    if (peak < 16) {
        return 0.0f; // silence
    }
    const int32_t threshold = peak / 4;

    // A square wave makes two of these transitions per cycle.
    int32_t transitions = 0;
    int32_t state = 0; // -1 below, +1 above, 0 not yet decided
    for (size_t i = 0; i < samples.size(); i++) {
        const int32_t v = samples[i];
        if (v > threshold && state <= 0) {
            if (state != 0) {
                transitions++;
            }
            state = 1;
        } else if (v < -threshold && state >= 0) {
            if (state != 0) {
                transitions++;
            }
            state = -1;
        }
    }
    const float seconds = float(samples.size()) / float(AUDIO_SAMPLE_RATE);
    return float(transitions) / 2.0f / seconds;
}

void measure_level(const std::vector<int16_t>& samples, float& rms, float& peak) {
    rms = 0.0f;
    peak = 0.0f;
    if (samples.empty()) {
        return;
    }
    double square_sum = 0.0;
    int32_t max_abs = 0;
    for (size_t i = 0; i < samples.size(); i++) {
        const double v = double(samples[i]) / 32768.0;
        square_sum += v * v;
        const int32_t a = samples[i] < 0 ? -int32_t(samples[i]) : int32_t(samples[i]);
        if (a > max_abs) {
            max_abs = a;
        }
    }
    rms = float(std::sqrt(square_sum / double(samples.size())));
    peak = float(max_abs) / 32768.0f;
}

// ---- WAV ---------------------------------------------------------------------

namespace {

void put_u32(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(uint8_t(v));
    out.push_back(uint8_t(v >> 8));
    out.push_back(uint8_t(v >> 16));
    out.push_back(uint8_t(v >> 24));
}

void put_u16(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(uint8_t(v));
    out.push_back(uint8_t(v >> 8));
}

void put_tag(std::vector<uint8_t>& out, const char* tag) {
    for (int i = 0; i < 4; i++) {
        out.push_back(uint8_t(tag[i]));
    }
}

} // namespace

std::vector<uint8_t> encode_wav(const std::vector<int16_t>& samples, uint32_t sample_rate) {
    const uint32_t data_bytes = uint32_t(samples.size() * 2);
    std::vector<uint8_t> out;
    out.reserve(44 + data_bytes);

    put_tag(out, "RIFF");
    put_u32(out, 36 + data_bytes);
    put_tag(out, "WAVE");

    put_tag(out, "fmt ");
    put_u32(out, 16);                    // PCM header size
    put_u16(out, 1);                     // format: PCM
    put_u16(out, 1);                     // channels: mono
    put_u32(out, sample_rate);
    put_u32(out, sample_rate * 2);       // byte rate (mono, 2 bytes/sample)
    put_u16(out, 2);                     // block align
    put_u16(out, 16);                    // bits per sample

    put_tag(out, "data");
    put_u32(out, data_bytes);
    for (size_t i = 0; i < samples.size(); i++) {
        put_u16(out, uint16_t(samples[i]));
    }
    return out;
}

} // namespace zx
