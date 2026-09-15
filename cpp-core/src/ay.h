#pragma once
// The AY-3-8912 programmable sound generator a 128K carries, on ports 0xFFFD
// (register select, and reading the selected register back) and 0xBFFD
// (writing it).
//
// Three square-wave tone channels and one noise generator, mixed per channel
// under register 7's enable bits, each channel at either its own fixed volume
// or the one shared envelope generator's. Clocked at half the CPU clock
// (1.7734MHz), and nothing inside it changes faster than every eighth of
// those clocks: the tone counters count at AY/8, the noise and envelope
// counters at AY/16. So the chip is STEPPED at AY/8 -- once every 32
// half-clocks -- rather than clocked every half-clock, which keeps it out of
// the machine's hot loop entirely. The Beeper drives it, chunking its own
// box-filter integration at the AY's step boundaries so that a step's new
// output level is weighted for exactly the half-clocks it was live.
//
// Mono, like the beeper: the three channels are summed. The 128K's own
// output is mono too; the ACB stereo of some later machines is a wiring
// difference, not a chip feature.

#include <cstdint>

namespace zx {

/// Half-clocks per generator step: the AY runs at CPU/2 and steps at AY/8,
/// which is once per 16 T-states.
constexpr uint32_t AY_HC_PER_STEP = 32;

/// Level of one channel at full volume, in the Beeper's mixing units (where
/// the speaker bit is 100). Three channels flat out come to 240, a little over
/// twice the beeper -- the 128K's AY is the louder of the two, and a 128K
/// game's beeper effects sit under its AY music rather than over it.
constexpr int32_t AY_CHANNEL_LEVEL = 80;
constexpr int32_t AY_FULL_LEVEL = 3 * AY_CHANNEL_LEVEL;

constexpr uint8_t AY_REGISTERS = 16;
/// What a read of an unselected register (a select of 16 or more) returns:
/// nothing drives the bus, so it floats high.
constexpr uint8_t AY_NO_REGISTER = 0xFF;

class Ay {
public:
    Ay() { reset(); }

    /// Power-on: every register zero, register 0 selected, generators at rest.
    void reset();

    /// OUT to 0xFFFD. Any value is accepted; 16 and above select nothing.
    void select(uint8_t reg) { selected_ = reg; }
    uint8_t selected() const { return selected_; }
    /// IN from 0xFFFD: the selected register, with the bits it does not have
    /// reading as zero -- a 4-bit coarse period reads back as 4 bits.
    uint8_t read() const;
    /// OUT to 0xBFFD. The caller must have integrated the audio up to the
    /// current instant first (Beeper::advance_to), so the change lands on the
    /// half-clock it happened rather than on the next drain.
    void write(uint8_t value);

    /// Register contents, for snapshots. set_reg stores without the side
    /// effect a write has (restarting the envelope), which is what restoring
    /// a snapshot wants.
    uint8_t reg(uint8_t i) const { return i < AY_REGISTERS ? regs_[i] : 0; }
    void set_reg(uint8_t i, uint8_t value);

    /// Half-clocks until the next generator step, 1..AY_HC_PER_STEP.
    uint32_t hc_until_step() const { return AY_HC_PER_STEP - phase_; }
    /// Moves `hc` half-clocks on -- no more than hc_until_step() -- stepping
    /// the generators if that reaches the step.
    void advance(uint32_t hc);
    /// The summed output of the three channels right now, 0..AY_FULL_LEVEL.
    int32_t level() const { return level_; }

private:
    uint8_t regs_[AY_REGISTERS];
    uint8_t selected_ = 0;
    /// Half-clocks into the current step.
    uint32_t phase_ = 0;

    uint16_t tone_count_[3];
    uint8_t tone_out_[3];
    uint16_t noise_count_ = 0;
    /// The noise and envelope counters run at half the step rate; these
    /// toggle so they count every other step.
    bool noise_half_ = false;
    bool env_half_ = false;
    uint32_t rng_ = 1;
    uint8_t noise_out_ = 0;
    uint16_t env_count_ = 0;
    int32_t env_step_ = 0;
    uint8_t env_attack_ = 0;
    bool env_hold_ = false;
    bool env_alternate_ = false;
    bool env_holding_ = false;
    uint8_t env_volume_ = 0;
    int32_t level_ = 0;

    void step();
    void restart_envelope();
    void update_level();
};

} // namespace zx
