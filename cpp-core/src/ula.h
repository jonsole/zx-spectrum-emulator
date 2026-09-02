#pragma once
// The 48K ULA: video timing, screen and border rendering, and the once-per-
// frame interrupt.
//
// Clocked once per HALF-T-STATE, in step with the CPU. That falls out
// beautifully for video: a Spectrum draws 2 pixels per T-state, so at half-T
// resolution the ULA emits exactly ONE PIXEL PER CLOCK. No batching, no
// drawing eight pixels at once and pretending they happened at different
// times -- the raster beam position and the clock are the same counter.
//
// Frame geometry (World of Spectrum 48K reference): 312 lines of 224
// T-states. Per line: 24 T-states left border, 128 paper (256px at 2px per
// T-state), 24 right border, 48 horizontal retrace. So in half-clocks a line
// is 448 dots -- 48 left border, 256 paper, 48 right border, 96 retrace --
// and the rendered canvas is 352x312.
//
// Two different origins are in play and it is worth being explicit about
// which is which, because conflating them is what made the previous
// implementation's timing so hard to reason about:
//
//   frame_hc_    counts from the INTERRUPT. This is the "T-states since
//                interrupt" that programs (and the debugger) reason about.
//   canvas       counts from the TOP-LEFT of the visible picture.
//
// They are not the same instant: the interrupt fires partway through the top
// border, not at the corner. CANVAS_LEAD_HC below is the offset between them.

#include "memory.h"

#include <array>
#include <cstdint>
#include <vector>

namespace zx {

// ---- timing, in half-clocks (2 per T-state) --------------------------------
constexpr uint32_t HC_PER_TSTATE = 2;
constexpr uint32_t HC_PER_LINE = 224 * HC_PER_TSTATE;   // 448
constexpr uint32_t LINES_PER_FRAME = 312;
constexpr uint32_t HC_PER_FRAME = HC_PER_LINE * LINES_PER_FRAME; // 139776
/// The same frame counted the way people quote ZX timings -- "the border
/// starts at T-state 14335" -- which is what a T-state gate is written in.
constexpr uint32_t TSTATES_PER_FRAME = HC_PER_FRAME / HC_PER_TSTATE; // 69888

/// The ULA pulls INT low for 32 T-states once per frame. Purely a function of
/// raster position: it is not extended, re-armed or suppressed by anything the
/// CPU does, so a program that has interrupts disabled across the window
/// simply misses that frame's interrupt rather than receiving it late.
constexpr uint32_t INT_PULSE_HC = 32 * HC_PER_TSTATE;

// ---- canvas geometry, in pixels (1 per half-clock) -------------------------
constexpr uint32_t BORDER_LEFT_PX = 48;
constexpr uint32_t BORDER_RIGHT_PX = 48;
constexpr uint32_t SCREEN_WIDTH = 256;
constexpr uint32_t SCREEN_HEIGHT = 192;
constexpr uint32_t BORDER_TOP_LINES = 64;
constexpr uint32_t BORDER_BOTTOM_LINES = 56;

constexpr uint32_t FULL_WIDTH = BORDER_LEFT_PX + SCREEN_WIDTH + BORDER_RIGHT_PX; // 352
constexpr uint32_t FULL_HEIGHT = BORDER_TOP_LINES + SCREEN_HEIGHT + BORDER_BOTTOM_LINES; // 312
static_assert(FULL_HEIGHT == LINES_PER_FRAME, "canvas height must be the whole frame");

/// Dot range within a line that is actually rendered; the rest is retrace.
constexpr uint32_t VISIBLE_DOTS = FULL_WIDTH; // 352
/// First paper dot within a line, and one past the last.
constexpr uint32_t PAPER_DOT_BEGIN = BORDER_LEFT_PX;             // 48
constexpr uint32_t PAPER_DOT_END = PAPER_DOT_BEGIN + SCREEN_WIDTH; // 304
/// First paper line, and one past the last.
constexpr uint32_t PAPER_LINE_BEGIN = BORDER_TOP_LINES;              // 64
constexpr uint32_t PAPER_LINE_END = PAPER_LINE_BEGIN + SCREEN_HEIGHT; // 256

/// How far the canvas origin leads the interrupt.
///
/// The first paper pixel sits 14336 T-states after the interrupt (64 whole
/// lines of 224). In canvas terms that same pixel is at line 64, dot 48. So
/// the canvas top-left corner happens 48 half-clocks BEFORE the interrupt,
/// i.e. right at the end of the previous frame -- which is why "T-states since
/// interrupt" and "raster position" need converting between rather than being
/// treated as the same number.
constexpr uint32_t CANVAS_LEAD_HC = BORDER_LEFT_PX; // 48

/// The ULA latches the border colour every 8 pixels; a write part-way through
/// a group does not take visual effect until the next one.
constexpr uint32_t BORDER_LATCH_DOTS = 8;

/// What a read of a port nothing answers finds on the bus when the ULA is not
/// driving it: nothing pulls it down, so every line reads high.
constexpr uint8_t FLOATING_BUS_IDLE = 0xFF;

constexpr uint16_t BITMAP_BASE = 0x4000;
constexpr uint16_t ATTR_BASE = 0x5800;

/// Address of the bitmap byte holding pixel column `x` of paper row `y`.
/// The Spectrum's famously non-linear screen layout.
constexpr uint16_t pixel_addr(uint16_t x, uint16_t y) {
    return uint16_t(BITMAP_BASE | ((y & 0xC0) << 5) | ((y & 0x07) << 8)
                    | ((y & 0x38) << 2) | (x >> 3));
}

constexpr uint16_t attr_addr(uint16_t x, uint16_t y) {
    return uint16_t(ATTR_BASE + (y >> 3) * 32 + (x >> 3));
}

class Ula {
public:
    /// Border colour as last written to port 0xFE (bits 0-2).
    uint8_t border = 0;
    /// Toggles every 16 frames (~1.56Hz), swapping ink/paper on FLASH cells.
    bool flash_state = false;

    Ula();

    /// One half-clock. Drives INT on `pins`, performs whatever screen fetch
    /// this position calls for, and emits one pixel.
    ///
    /// Does NOT move the counters on -- advance() does, and Spectrum48K::clock()
    /// calls it once everything else has had this half-clock. The two are a
    /// pair and nothing but that function should be calling either.
    void clock(uint64_t& pins, Memory& mem);

    /// Moves to the next half-clock, ending the frame if this was its last.
    ///
    /// Separate from clock() so that for the whole duration of a half-clock --
    /// the ULA's work, the CPU's, the trace's and the bus service -- the
    /// counters below describe THE HALF-CLOCK BEING PROCESSED rather than the
    /// one after it. Anything reading them mid-half-clock (the trace's Frame
    /// and TState columns, and the T-state gate that opens a capture) would
    /// otherwise be half a T-state out, which is a whole contended cycle.
    void advance();

    /// What the ULA itself read from memory during this half-clock, for the
    /// trace's ULA-AB/ULA-DB columns. The ULA is the machine's OTHER bus
    /// master, and until now it fetched the screen without leaving any record
    /// of having done so -- which is precisely the traffic contention and
    /// snow are about.
    ///
    /// Shaped for one fetch per half-clock, which is what this becomes once
    /// the display fetch is staggered across four T-states the way the
    /// hardware does it. Until then a whole 16-pixel group is read in one
    /// half-clock (see clock()), so `fetch_count` is 4 there and 0 everywhere
    /// else, and the address and byte are the FIRST of the four -- the one
    /// that will still belong to this half-clock afterwards.
    uint32_t fetch_count() const { return fetch_count_; }
    uint16_t fetch_addr() const { return fetch_addr_; }
    uint8_t fetch_data() const { return fetch_data_; }

    /// What the ULA is putting on the data bus THIS half-clock -- the
    /// "floating bus".
    ///
    /// Reading a port nothing decodes does not return a defined value: the
    /// CPU simply latches whatever happens to be on the bus, and on a
    /// Spectrum the other thing using the bus is the ULA fetching the screen.
    /// So a read of an odd port during the paper area hands back a byte of
    /// the display, and the same read during the border finds nothing driving
    /// and reads 0xFF.
    ///
    /// That is not a curiosity -- it is a raster clock. A program with no
    /// interrupt to hand can sit in `IN A,(0xFF)` until the byte it sees says
    /// the beam has reached a particular part of the screen, which is how
    /// several games synchronise to the display. Cobra's loader does exactly
    /// this, and without it the wait never ends.
    uint8_t floating_bus() const;

    /// Half-clocks since the interrupt, 0..HC_PER_FRAME-1. This is the
    /// "T-states since interrupt" programs reason about, times two.
    ///
    /// These describe the half-clock CURRENTLY BEING PROCESSED, and keep doing
    /// so until advance() is called at the end of it -- so both halves of a
    /// T-state report the same tstate(), and the last half-clock of a frame
    /// belongs to that frame rather than to the one about to start.
    uint32_t frame_hc() const { return frame_hc_; }
    uint32_t tstate() const { return frame_hc_ / HC_PER_TSTATE; }
    uint64_t frame_count() const { return frame_count_; }

    /// The last FULLY COMPLETED frame as RGB (FULL_WIDTH * FULL_HEIGHT * 3),
    /// not the one in progress -- viewers poll far slower than 50Hz and want
    /// one whole stable picture.
    const std::vector<uint8_t>& screen() const { return last_frame_; }

    /// Clears rendering state (reset / snapshot load). Leaves border and
    /// flash_state alone, matching what a reset actually does.
    void reset();

private:
    uint32_t frame_hc_ = 0;
    // Cleared at the top of every clock(), so "did the ULA read anything this
    // half-clock" is answered by fetch_count_ alone.
    uint32_t fetch_count_ = 0;
    uint16_t fetch_addr_ = 0;
    uint8_t fetch_data_ = 0;
    // Raster position, tracked incrementally rather than divided out of
    // frame_hc_ every clock -- this runs 7 million times a second.
    uint32_t line_ = 0;
    uint32_t dot_ = 0;
    uint64_t frame_count_ = 0;

    // Bytes for the 16-pixel group currently being emitted.
    uint8_t pixel0_ = 0, attr0_ = 0, pixel1_ = 0, attr1_ = 0;
    uint8_t border_latch_ = 0;

    std::vector<uint8_t> framebuffer_;
    std::vector<uint8_t> last_frame_;

    /// Whether the beam is over paper right now -- the only time the ULA
    /// fetches, and so the only time it drives the bus.
    bool in_paper_area() const {
        return line_ >= PAPER_LINE_BEGIN && line_ < PAPER_LINE_END && dot_ >= PAPER_DOT_BEGIN
               && dot_ < PAPER_DOT_END;
    }

    void emit_pixel();
    void on_frame_boundary();
};

} // namespace zx
