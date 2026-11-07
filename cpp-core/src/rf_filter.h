#pragma once
// The RF look: an optional filter on the picture that makes it look as it did
// on a television through the Spectrum's RF lead -- the PAL subcarrier's dot
// crawl and cross-colour, colour bleed, soft luma, a ghost, noise,
// scanlines and jail bars. A display effect only: the machine runs the same with it on or
// off, and nothing of it is machine state, rewind input or snapshot.
//
// It is specified to the bit in retro-spectrum's docs/spec/rf.md, so that
// this, retro-spectrum's C++ model (sim/rf/rf_model.h) and its FPGA give the
// same pixels and can be diffed. It is a full PAL encode and decode rather
// than an imitation: each line's colours are turned into the composite signal
// with the subcarrier's real phase, then decoded as a simple TV would. The
// tables come from that repository too (scripts/rf_tables_inc.py), not worked
// out again here. Every step is integer arithmetic, and a right shift of a
// negative number is the arithmetic one the spec asks for -- what MSVC, GCC,
// Clang and Emscripten all do.
//
// It works on SAMPLES, two a canvas dot: a 352-dot line is 704 samples at
// 14 MHz in the 48K's time. So the filtered picture is 704 wide, and each
// line is drawn twice, the scanlines darkening the second copy: 704x624.
//
// docs/rf-look.md describes it for users.

#include <cstdint>
#include <vector>

namespace zx {

/// The settings, in the board's own layout -- SPACE 2 offsets 22 to 28 on
/// retro-spectrum -- so the two read and write them the same way.
struct RfSettings {
    /// Bit 0 the master switch, 1 COMPOSITE, 2 GHOST, 3 NOISE, 4 SCANLINES,
    /// 6-5 the jail bars' level (0 none), 7 the bars on the RGB rather than
    /// the composite. The defaults throughout are the board's power-on, its
    /// Good TV with the switch off (rf.md section 5): here the composite,
    /// the ghost, the noise, the scanlines and 4 % bars on the composite.
    uint8_t flags = 0x7E;
    /// Bits 1-0 the luma setting, 2 the PAL delay line, 3 unused (it was a
    /// sharp luma notch, taken out of the board for room), 5-4 the chroma
    /// setting, 7-6 the colour gain taken down in eighths (0 is 8/8). The
    /// default: luma 3, the delay line, chroma 3, colour x3/4.
    uint8_t band = 0xB7;
    /// The ghost's delay in samples, 0-63 (one is 71 ns); 0 is no ghost.
    uint8_t ghost_d = 6;
    /// Bits 3-0 the ghost's strength, as G/32 of the picture; 7-4 the dot
    /// crawl taken out, in eighths (9-15 read as 8). The default: 2, and half.
    uint8_t ghost_g = 0x42;
    /// Bits 3-0 the noise level; 7-4 the colour fringes taken out, in
    /// eighths (9-15 read as 8). The default: 1, and half.
    uint8_t noise = 0x41;
    /// The scanlines' depth, 0-15: d/16 darker.
    uint8_t scan = 6;
    /// The 48K's crystal offset in 0.1 ppm, signed: how far its 14 MHz
    /// crystal is from the modulator's, which sets how the dots move from
    /// frame to frame. 1 ppm is 0.0885 of a turn a frame. The default,
    /// -5.7 ppm, is a trimmed machine whose dots creep slowly; 0 is nominal
    /// crystals, the dots nearly inverting every frame.
    int8_t crystal = -57;

    static constexpr uint8_t ON = 0x01;
    static constexpr uint8_t COMPOSITE = 0x02;
    static constexpr uint8_t GHOST = 0x04;
    static constexpr uint8_t NOISE = 0x08;
    static constexpr uint8_t SCANLINES = 0x10;
    static constexpr uint8_t JAIL_SHIFT = 5;
    static constexpr uint8_t JAIL_RGB = 0x80;
    static constexpr uint8_t PAL_DELAY = 0x04;
    static constexpr uint8_t GAIN_SHIFT = 6;
    /// The dials' place in ghost_g and noise: their high nibbles.
    static constexpr uint8_t CUT_SHIFT = 4;
    static constexpr int CUT_MAX = 8;

    bool on() const { return (flags & ON) != 0; }
    uint32_t jail() const { return (flags >> JAIL_SHIFT) & 3u; }
    uint32_t luma() const { return band & 3u; }
    uint32_t chroma() const { return (band >> 4) & 3u; }
    bool pal_delay() const { return (band & PAL_DELAY) != 0; }
    /// The dot crawl dial, 0-8 eighths.
    int dots_cut() const { return cut(ghost_g); }
    /// The colour fringes dial, 0-8 eighths.
    int fringes_cut() const { return cut(noise); }
    static int cut(uint8_t b) {
        const int r = b >> CUT_SHIFT;
        return r > CUT_MAX ? CUT_MAX : r;
    }
    /// The colour gain in eighths: 8, 7, 6 or 5.
    int gain() const { return 8 - int((band >> GAIN_SHIFT) & 3u); }
};

/// What a line leaves for the next: the PAL delay line's U and V (step 5b),
/// held to 12 bits signed as the board's line memory is. A frame starts with
/// it clear; the first line shown takes nothing from it.
struct RfLineMemory {
    int u[704] = {};
    int v[704] = {};
};

/// The size of the filtered picture: two samples a dot, each line twice.
constexpr uint32_t RF_WIDTH = 704;
constexpr uint32_t RF_HEIGHT = 624;

/// The filtered picture of one frame. `rgb` is the plain picture, FULL_WIDTH
/// x FULL_HEIGHT; `frame` is the ULA's frame counter for it (the phase and the
/// noise are worked out from it, so a frame gives the same picture however
/// many were skipped before it); `locked_subcarrier` is a 128K, whose
/// subcarrier is made from its pixel clock and so does not crawl. Returns
/// RF_WIDTH x RF_HEIGHT RGB -- unless the settings are off, when the filter
/// is not there at all and `rgb` comes back as it was.
std::vector<uint8_t> rf_filter_frame(const std::vector<uint8_t>& rgb, const RfSettings& settings,
                                     uint64_t frame, bool locked_subcarrier);

/// One canvas line, as the spec writes it: 352 colour indices (bit 0 blue,
/// 1 red, 2 green, 3 bright) in, 704 RGB samples out. `phase` is the
/// subcarrier's phase at sample 0 and `step` its advance a sample, both in
/// 2^32 a turn; `line` the canvas line, 0-311 (its oddness is the PAL
/// switch's -1, and the jail bars are on lines 64-255); `second_copy` the copy the
/// scanlines darken; `lfsr` the noise generator at the start of the line;
/// `memory` the delay line, read for this line and,
/// on the second copy, written with it -- as the board does.
/// rf_filter_frame is this, line by line; it is separate so the tests can
/// put the same lines through retro-spectrum's model.
void rf_filter_line(const uint8_t index[352], const RfSettings& settings, uint32_t phase,
                    uint32_t step, uint32_t line, bool second_copy, uint16_t lfsr,
                    RfLineMemory& memory, uint8_t out[RF_WIDTH * 3]);

/// The noise generator one step on: a 16-bit Galois LFSR, taps 0xB400.
uint16_t rf_lfsr_step(uint16_t l);

/// The noise generator at the start of canvas line `line` of frame `frame`:
/// stepped (frame x 312 + line) x 704 times from 0xACE1.
uint16_t rf_lfsr_at(uint64_t frame, uint32_t line);

/// The 48K's phase constants (rf.md section 3): a sample, a line, a frame.
constexpr uint32_t RF_K_48K = 0x5112671Au;
constexpr uint32_t RF_M_48K = 0xC068DB00u;
constexpr uint32_t RF_FRAME_48K = 0x7FCAE800u;
/// 0.1 ppm of a frame's 88,530.5 subcarrier cycles, in 2^32 a turn: what one
/// step of the crystal offset adds to RF_FRAME_48K.
constexpr uint32_t RF_FRAME_PER_TENTH_PPM = 38023560u;
/// The 128K's: exactly 5/16 of a turn a sample, and whole turns a line.
constexpr uint32_t RF_K_128K = 0x50000000u;

} // namespace zx
