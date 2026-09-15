#include "ay.h"

namespace zx {
namespace {

/// The chip's logarithmic volume curve, one entry per 4-bit level, scaled to
/// AY_CHANNEL_LEVEL. The shape is the measured AY-3-8910 curve (MAME's
/// ay8910 table): roughly 3dB per step at the top, steeper below.
constexpr int32_t VOLUME[16] = {0, 1, 2, 2, 3, 5, 7, 11, 14, 21, 28, 36, 46, 55, 68, 80};
static_assert(VOLUME[15] == AY_CHANNEL_LEVEL, "the table is scaled to the channel level");

/// The bits each register actually has; the rest read as zero.
constexpr uint8_t REGISTER_MASK[AY_REGISTERS] = {
    0xFF, 0x0F, // A period fine, coarse
    0xFF, 0x0F, // B
    0xFF, 0x0F, // C
    0x1F,       // noise period
    0xFF,       // mixer / IO direction
    0x1F, 0x1F, 0x1F, // A, B, C volume (bit 4 = envelope)
    0xFF, 0xFF, // envelope period fine, coarse
    0x0F,       // envelope shape
    0xFF, 0xFF, // IO ports A, B
};

constexpr uint8_t ENVELOPE_SHAPE = 13;
constexpr uint8_t IO_PORT_A = 14;
/// Register 7 bit 6: port A is an output. When it is an input nothing on a
/// stock 128K drives it (the keypad and RS232 lines idle high), so it reads
/// as 0xFF.
constexpr uint8_t PORT_A_OUTPUT = 0x40;

} // namespace

void Ay::reset() {
    for (uint8_t i = 0; i < AY_REGISTERS; i++) {
        regs_[i] = 0;
    }
    selected_ = 0;
    phase_ = 0;
    for (int ch = 0; ch < 3; ch++) {
        tone_count_[ch] = 0;
        tone_out_[ch] = 0;
    }
    noise_count_ = 0;
    noise_half_ = false;
    env_half_ = false;
    rng_ = 1;
    noise_out_ = 0;
    env_count_ = 0;
    env_step_ = 0;
    env_attack_ = 0;
    env_hold_ = false;
    env_alternate_ = false;
    env_holding_ = false;
    env_volume_ = 0;
    level_ = 0;
}

uint8_t Ay::read() const {
    if (selected_ >= AY_REGISTERS) {
        return AY_NO_REGISTER;
    }
    if (selected_ == IO_PORT_A && (regs_[7] & PORT_A_OUTPUT) == 0) {
        return 0xFF;
    }
    return regs_[selected_];
}

void Ay::write(uint8_t value) {
    if (selected_ >= AY_REGISTERS) {
        return;
    }
    regs_[selected_] = uint8_t(value & REGISTER_MASK[selected_]);
    if (selected_ == ENVELOPE_SHAPE) {
        // Writing the shape register restarts the envelope, whether or not
        // the shape changed -- which is how a tune retriggers a note.
        restart_envelope();
    }
    update_level();
}

void Ay::set_reg(uint8_t i, uint8_t value) {
    if (i >= AY_REGISTERS) {
        return;
    }
    regs_[i] = uint8_t(value & REGISTER_MASK[i]);
    if (i == ENVELOPE_SHAPE) {
        // A snapshot holds the shape but not where the envelope had got to,
        // so restarting is the nearest thing to the truth.
        restart_envelope();
    }
    update_level();
}

void Ay::restart_envelope() {
    const uint8_t shape = regs_[ENVELOPE_SHAPE];
    // Bit 2 is ATTACK (ramp up rather than down), bit 3 CONTINUE. Without
    // CONTINUE the envelope runs once and then holds at zero -- the shapes
    // usually drawn as \___ and /___ -- whatever bits 0 and 1 say.
    env_attack_ = (shape & 0x04) != 0 ? 0x0F : 0x00;
    if ((shape & 0x08) == 0) {
        env_hold_ = true;
        env_alternate_ = env_attack_ != 0;
    } else {
        env_hold_ = (shape & 0x01) != 0;
        env_alternate_ = (shape & 0x02) != 0;
    }
    env_step_ = 0x0F;
    env_holding_ = false;
    env_count_ = 0;
    env_volume_ = uint8_t(env_step_ ^ env_attack_);
}

void Ay::advance(uint32_t hc) {
    phase_ += hc;
    if (phase_ >= AY_HC_PER_STEP) {
        phase_ -= AY_HC_PER_STEP;
        step();
    }
}

void Ay::step() {
    // ---- tone --------------------------------------------------------------
    // Each channel's 12-bit period, counted at this step rate; the output
    // toggles at the end of every period, so a period of P makes a square
    // wave of AY/(16P). A period of 0 counts as 1, as on the chip.
    for (int ch = 0; ch < 3; ch++) {
        uint16_t period = uint16_t(regs_[2 * ch] | (regs_[2 * ch + 1] << 8));
        if (period == 0) {
            period = 1;
        }
        if (++tone_count_[ch] >= period) {
            tone_count_[ch] = 0;
            tone_out_[ch] ^= 1;
        }
    }

    // ---- noise -------------------------------------------------------------
    // A 17-bit shift register, clocked at half the tone rate against the
    // 5-bit noise period.
    noise_half_ = !noise_half_;
    if (noise_half_) {
        uint16_t period = regs_[6];
        if (period == 0) {
            period = 1;
        }
        if (++noise_count_ >= period) {
            noise_count_ = 0;
            rng_ ^= (((rng_ & 1) ^ ((rng_ >> 3) & 1)) << 17);
            rng_ >>= 1;
            noise_out_ = uint8_t(rng_ & 1);
        }
    }

    // ---- envelope ----------------------------------------------------------
    // Also at half the tone rate, against the 16-bit envelope period: one
    // step of the 16-level ramp per period, so a whole ramp takes 256 x EP
    // AY clocks -- the figure the data sheet quotes.
    env_half_ = !env_half_;
    if (env_half_ && !env_holding_) {
        uint16_t period = uint16_t(regs_[11] | (regs_[12] << 8));
        if (period == 0) {
            period = 1;
        }
        if (++env_count_ >= period) {
            env_count_ = 0;
            env_step_--;
            if (env_step_ < 0) {
                if (env_hold_) {
                    if (env_alternate_) {
                        env_attack_ ^= 0x0F;
                    }
                    env_holding_ = true;
                    env_step_ = 0;
                } else {
                    // The ramp has looped. On an alternating shape every
                    // other loop runs the opposite way, which is what
                    // flipping the attack mask on an odd wrap does.
                    if (env_alternate_ && (env_step_ & 0x10) != 0) {
                        env_attack_ ^= 0x0F;
                    }
                    env_step_ &= 0x0F;
                }
            }
        }
        env_volume_ = uint8_t(env_step_ ^ env_attack_);
    }

    update_level();
}

void Ay::update_level() {
    // Register 7: bits 0-2 DISABLE tone on A, B, C and bits 3-5 disable
    // noise -- active low, so a channel with both bits set is silent and one
    // with both clear is tone AND noise gated together. A disabled source
    // reads as "always on" into that AND, which is how a channel plays tone
    // alone or noise alone.
    const uint8_t enable = regs_[7];
    int32_t level = 0;
    for (int ch = 0; ch < 3; ch++) {
        const uint8_t tone = uint8_t(tone_out_[ch] | ((enable >> ch) & 1));
        const uint8_t noise = uint8_t(noise_out_ | ((enable >> (3 + ch)) & 1));
        if ((tone & noise) == 0) {
            continue;
        }
        const uint8_t vol = regs_[8 + ch];
        const uint8_t index = (vol & 0x10) != 0 ? env_volume_ : uint8_t(vol & 0x0F);
        level += VOLUME[index];
    }
    level_ = level;
}

} // namespace zx
