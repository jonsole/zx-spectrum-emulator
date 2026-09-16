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

#include <array>
#include <atomic>
#include <cstdint>
#include <vector>

namespace zx {

// ---- timing, in half-clocks (2 per T-state) --------------------------------
// These are the 48K's numbers. They are what a default-constructed machine
// runs at and what the tests reason in; the 128K's differ (see UlaTiming and
// TIMING_128K below), and anything describing a particular machine reads its
// own from Ula::timing() rather than from here.
constexpr uint32_t HC_PER_TSTATE = 2;
constexpr uint32_t HC_PER_LINE = 224 * HC_PER_TSTATE;   // 448
constexpr uint32_t LINES_PER_FRAME = 312;
constexpr uint32_t HC_PER_FRAME = HC_PER_LINE * LINES_PER_FRAME; // 139776
/// The same frame counted the way people quote ZX timings -- "the border
/// starts at T-state 14335" -- which is what a T-state gate is written in.
constexpr uint32_t TSTATES_PER_FRAME = HC_PER_FRAME / HC_PER_TSTATE; // 69888
/// The longest frame any model has, for bounds checks that happen before a
/// machine is to hand: the 128K's 311 lines of 228 T-states.
constexpr uint32_t MAX_TSTATES_PER_FRAME = 228 * 311; // 70908

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

/// What differs between the 48K's ULA and the 128K's, in the terms above.
///
/// The 128K's line is 228 T-states rather than 224 (four more of retrace: the
/// visible part is the same 24+128+24), its frame is 311 lines rather than
/// 312, the paper starts 63 lines after the interrupt rather than 64, INT is
/// held for 36 T-states rather than 32, and the CPU runs at 3.5469MHz rather
/// than 3.5. The numbers are the World of Spectrum / libspectrum reference
/// timings for the two machines.
///
/// The canvas is FULL_WIDTH x FULL_HEIGHT whichever model is running, so
/// everything downstream -- the PNG encoder, the video recorder, the
/// extension's panel -- sees one picture size. A 128K frame is one line
/// short of it, and the last canvas line repeats the one above; see
/// Ula::on_frame_boundary.
struct UlaTiming {
    uint32_t hc_per_line;
    uint32_t lines_per_frame;
    /// Canvas line the paper begins on, which is also how many lines of top
    /// border there are.
    uint32_t paper_line_begin;
    uint32_t int_pulse_hc;
    /// Half-clocks per second of real time: twice the CPU clock.
    uint64_t hc_per_sec;

    constexpr uint32_t hc_per_frame() const { return hc_per_line * lines_per_frame; }
    constexpr uint32_t tstates_per_frame() const { return hc_per_frame() / HC_PER_TSTATE; }
    constexpr uint32_t paper_line_end() const { return paper_line_begin + SCREEN_HEIGHT; }
};

constexpr UlaTiming TIMING_48K{HC_PER_LINE, LINES_PER_FRAME, BORDER_TOP_LINES, INT_PULSE_HC,
                               7'000'000};
constexpr UlaTiming TIMING_128K{228 * HC_PER_TSTATE, 311, 63, 36 * HC_PER_TSTATE, 7'093'800};
static_assert(TIMING_48K.tstates_per_frame() == TSTATES_PER_FRAME, "48K frame");
static_assert(TIMING_128K.tstates_per_frame() == MAX_TSTATES_PER_FRAME, "128K frame");
static_assert(TIMING_128K.lines_per_frame <= FULL_HEIGHT, "the canvas must hold a frame");

/// The ULA latches the border colour every 8 pixels; a write part-way through
/// a group does not take visual effect until the next one.
constexpr uint32_t BORDER_LATCH_DOTS = 8;

/// What a read of a port nothing answers finds on the bus when the ULA is not
/// driving it: nothing pulls it down, so every line reads high.
constexpr uint8_t FLOATING_BUS_IDLE = 0xFF;

/// Dash period of the raster marker's scanline, in pixels: half lit, half not.
/// Dashed rather than solid so it reads as a cursor laid over the picture and
/// not as something the program drew.
constexpr uint32_t RASTER_DASH = 4;
/// How far the tick marking the beam's exact position stands out of that line,
/// above and below.
constexpr uint32_t RASTER_TICK_REACH = 3;

/// How bright everything that is NOT a pending write -- or, in the write
/// overlay, NOT a byte written this frame -- is drawn, as a percentage. The
/// bytes of interest keep their own colours at full strength and the rest of
/// the picture is dimmed away from them -- which reads better than tinting
/// them, because what is interesting about them is what they SHOW, and a tint
/// is exactly what hides that.
constexpr uint32_t PENDING_DIM_PERCENT = 50;

constexpr uint16_t BITMAP_BASE = 0x4000;
constexpr uint16_t ATTR_BASE = 0x5800;

/// The bitmap half of the display file: 0x4000 up to ATTR_BASE.
constexpr uint32_t BITMAP_BYTES = 6144;
/// ...and its attributes, one byte per 8x8 cell.
constexpr uint32_t ATTR_BYTES = 768;
/// Both together, which is how the pending-write map indexes them.
constexpr uint32_t DISPLAY_BYTES = BITMAP_BYTES + ATTR_BYTES; // 6912
constexpr uint16_t DISPLAY_END = uint16_t(BITMAP_BASE + DISPLAY_BYTES); // 0x5B00

/// Full overlay heat: the byte's own colours at full brightness.
constexpr uint8_t HEAT_MAX = 255;
/// Both overlay knobs below are percentages of it.
constexpr uint32_t PERCENT_MAX = 100;

/// How far a byte is lifted out of the dimmed picture on the frame it is
/// written. 100 -- the default -- takes it all the way to full brightness;
/// lower values leave it part-way between the dim and full, so a write stands
/// out less against what it was drawn over.
constexpr uint32_t DEFAULT_OPACITY_PERCENT = 100;

/// How much of that brightness a frame boundary takes off. 100 -- the default
/// -- clears it completely, so the overlay shows one frame's drawing and
/// nothing else, which is the reading that answers "what did THIS frame do".
/// Lower values leave a trail across the frames that follow (10 fades over
/// about a second at 50Hz), and 0 never fades at all, accumulating everything
/// the program has drawn since.
///
/// Note that it only bites where drawing STOPS: a game that repaints its
/// playfield every frame refreshes those bytes to full opacity before the
/// fade can touch them, so no fade value will dim them.
constexpr uint32_t DEFAULT_FADE_PERCENT = 100;

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

    /// The frame geometry in force. TIMING_48K unless set otherwise.
    const UlaTiming& timing() const { return t_; }
    /// Switches geometry. Only sensible alongside a reset: the counters are
    /// left where they are, and a mid-frame switch would put the beam
    /// somewhere the new frame does not have.
    void set_timing(const UlaTiming& t) { t_ = t; }

    /// One half-clock. Drives INT on `pins`, performs whatever screen fetch
    /// this position calls for, and emits one pixel.
    ///
    /// `screen` is the 16K bank being displayed, which the ULA fetches from
    /// directly rather than through the CPU's map: the 128K displays bank 7
    /// whether or not the CPU can see it anywhere.
    ///
    /// Does NOT move the counters on -- advance() does, and Spectrum::clock()
    /// calls it once everything else has had this half-clock. The two are a
    /// pair and nothing but that function should be calling either.
    void clock(uint64_t& pins, const uint8_t* screen);

    /// Which RAM bank the display is coming from, so note_write can tell a
    /// write to the screen from a write to the same offset of another bank.
    /// Changing it marks the whole display pending: every byte of the
    /// picture may now differ from what the beam has drawn, which is exactly
    /// what a double-buffered game flipping screens means.
    void set_screen_bank(uint8_t bank);
    uint8_t screen_bank() const { return screen_bank_; }

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

    /// Dims the whole frame to PENDING_DIM_PERCENT and shows every BITMAP
    /// BYTE WRITTEN during it -- all eight of its pixels -- at full
    /// brightness, then fades it back into the dim. "Show me what this frame
    /// actually drew", which is otherwise invisible in a picture that only
    /// shows the result. The same look as draw_pending_writes, and for the
    /// same reason: the bytes keep their own colours, so what was drawn and
    /// what it looks like are read off one picture.
    ///
    /// A byte is lit whole, whatever bits it holds, whether or not they
    /// differ from what was there before, and whether or not they are all
    /// zero: the unit the program works in is the byte, and what is
    /// interesting is that the routine went to the trouble of writing it. An
    /// erase is a write like any other -- a sprite routine that clears the
    /// last frame's shape before drawing the new one did that work, and a
    /// view that hid it would say the routine touched half what it touched.
    ///
    /// Attributes are not tracked at all: one colour byte covers 64 pixels,
    /// so attribute work drowns the pixel work it sits on top of.
    ///
    /// Off by default, and deliberately so: it dims the picture. It is a
    /// debugging view of the screen, not a decoration on it.
    ///
    /// Atomic because the toggle comes from a DAP or MCP client's thread while
    /// the machine is running, and waiting for the run's next yield to turn an
    /// overlay on is a needless half-frame of lag. The heat map itself is only
    /// ever touched by the emulator thread.
    void set_write_overlay(bool on) { write_overlay_.store(on, std::memory_order_relaxed); }
    bool write_overlay() const { return write_overlay_.load(std::memory_order_relaxed); }

    /// How far a freshly written byte is lifted out of the dim, 0-100. See
    /// DEFAULT_OPACITY_PERCENT.
    void set_write_overlay_opacity(uint32_t percent) {
        opacity_percent_.store(percent > PERCENT_MAX ? PERCENT_MAX : percent,
                               std::memory_order_relaxed);
    }
    uint32_t write_overlay_opacity() const {
        return opacity_percent_.load(std::memory_order_relaxed);
    }

    /// How much of that lift a byte loses per frame, 0-100. See
    /// DEFAULT_FADE_PERCENT. Clamped rather than rejected, as opacity is: both
    /// come off a wire, and the nearest sensible overlay beats an error nobody
    /// can see.
    void set_write_overlay_fade(uint32_t percent) {
        fade_percent_.store(percent > PERCENT_MAX ? PERCENT_MAX : percent,
                            std::memory_order_relaxed);
    }
    uint32_t write_overlay_fade() const { return fade_percent_.load(std::memory_order_relaxed); }

    /// Records a write to the display file, for the overlay to show at the
    /// end of the frame and the pending view to show until the beam gets
    /// there. Called for every byte the CPU puts anywhere in memory, as the
    /// RAM bank it landed in and the offset within it, so the checks come
    /// first and the overlay's enabled check right after: with the overlay
    /// off a bitmap write is a store, a relaxed load and a branch. Neither
    /// view cares what was written -- a byte is a byte -- so the value is not
    /// passed in.
    ///
    /// Only writes to the DISPLAYED bank count. A game drawing into the 128K's
    /// other screen is not changing the picture, and will show as having
    /// changed all of it the moment it flips -- see set_screen_bank.
    void note_write(uint8_t bank, uint16_t offset) {
        if (bank != screen_bank_ || offset >= DISPLAY_BYTES) {
            return;
        }
        // Kept unconditionally, not behind the view's own switch. Turning
        // a switch on cannot fill in a map of what was written before it,
        // so a tracked-on-demand version shows an empty screen until the
        // program happens to write again -- which looks exactly like a
        // broken feature. bench_machine measures the cost of keeping it
        // always as being inside the run-to-run noise.
        //
        // Pending covers attributes as well as the bitmap: what it
        // answers is "will the picture here change when the beam
        // arrives", and a colour change does that as much as a draw.
        pending_[offset] = 1;
        pending_active_ = true;
        if (!write_overlay_.load(std::memory_order_relaxed)) {
            return;
        }
        if (offset >= BITMAP_BYTES) {
            return;
        }
        // Scaled by opacity here rather than at paint time, so the fade then
        // works down from whatever this byte was actually drawn at -- and a
        // rewrite lifts a fading byte back to full opacity, which is what
        // "the program drew this again" should look like.
        const uint32_t opacity = opacity_percent_.load(std::memory_order_relaxed);
        const uint8_t heat = uint8_t(HEAT_MAX * opacity / PERCENT_MAX);
        if (heat == 0) {
            return;
        }
        write_heat_[offset] = heat;
        heat_active_ = true;
    }

    /// Where the beam is: the canvas line and dot of the half-clock about to be
    /// emitted. `dot` runs past VISIBLE_DOTS during horizontal retrace, when
    /// the beam is off the right-hand edge of the picture.
    uint32_t raster_line() const { return line_; }
    uint32_t raster_dot() const { return dot_; }

    /// The frame AS THE BEAM HAS ACTUALLY DRAWN IT: everything above and to the
    /// left of the beam from the frame in progress, everything beyond it from
    /// the frame before. Which is what a CRT is showing at this instant, and
    /// what makes a raster effect visible while stepping -- a border stripe
    /// appears at the line the OUT happened on, instead of only turning up in
    /// the next completed frame.
    ///
    /// Only meaningful on a STOPPED machine. A running one moves the beam
    /// faster than anything can look at it, and screen() -- one whole stable
    /// frame -- is what a viewer wants there.
    std::vector<uint8_t> screen_in_progress() const;

    /// Picks out every display byte written since the beam last passed it --
    /// the changes that are ON SCREEN IN MEMORY but not yet on the picture,
    /// because the beam has not reached them. What a frame-synchronised
    /// routine races against, and invisible in any picture of the screen.
    ///
    /// Those bytes keep their own colours; everything else is dimmed to
    /// PENDING_DIM_PERCENT. Bitmap bytes cover the eight pixels they hold,
    /// attribute bytes their whole 8x8 cell. Attributes are included here,
    /// unlike in the write overlay, precisely because a colour change landing
    /// ahead of or behind the beam is the classic thing to get wrong.
    ///
    /// The dim goes on even when nothing is pending, so a screen with nothing
    /// at full brightness means "nothing is waiting" rather than leaving you
    /// to wonder whether the view is switched on at all. The map is kept
    /// whether or not anyone is looking at it -- see note_write.
    void draw_pending_writes(std::vector<uint8_t>& rgb) const;

    /// Marks the beam's position on a copy of the screen: a dashed line across
    /// the raster line it is on, and a solid tick standing out of that line at
    /// the dot itself.
    ///
    /// Takes a buffer rather than drawing into the ULA's own, because this is
    /// a DEBUGGER'S annotation on a picture, not part of the picture. It goes
    /// onto the frame a stopped machine is showing and never into the frame
    /// itself.
    ///
    /// Drawn by inverting what is underneath rather than in a colour of its
    /// own: every Spectrum colour channel is 0, 0xCD or 0xFF, so an inverted
    /// pixel always contrasts sharply with its neighbours, which no fixed
    /// colour can promise against a screen that might be any of them.
    void draw_raster_marker(std::vector<uint8_t>& rgb) const;

    /// The last FULLY COMPLETED frame as RGB (FULL_WIDTH * FULL_HEIGHT * 3),
    /// not the one in progress -- viewers poll far slower than 50Hz and want
    /// one whole stable picture.
    const std::vector<uint8_t>& screen() const { return last_frame_; }

    /// Clears rendering state (reset / snapshot load). Leaves border and
    /// flash_state alone, matching what a reset actually does.
    void reset();

#if ZX_REWIND
    /// The ULA's position and latches, for rewind's checkpoints. Not the
    /// picture it has drawn, which nothing the CPU sees depends on: a restore
    /// replays at least a frame to redraw it.
    struct State {
        UlaTiming timing = TIMING_48K;
        uint8_t border = 0;
        bool flash_state = false;
        uint8_t screen_bank = 5;
        uint32_t frame_hc = 0;
        uint32_t fetch_count = 0;
        uint16_t fetch_addr = 0;
        uint8_t fetch_data = 0;
        uint32_t line = 0;
        uint32_t dot = 0;
        uint64_t frame_count = 0;
        uint8_t pixel0 = 0, attr0 = 0, pixel1 = 0, attr1 = 0;
        uint8_t border_latch = 0;
    };
    void save_state(State& s) const;
    void restore_state(const State& s);
#endif

private:
    UlaTiming t_ = TIMING_48K;
    uint8_t screen_bank_ = 5;
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

    /// 1 for a display byte written since the beam last displayed it. Set on
    /// write and cleared by the screen fetch that puts the byte on the
    /// picture, so it needs no clearing at the frame boundary -- "pending"
    /// means pending against the BEAM, not against the frame counter, and a
    /// byte written in the bottom border for a row near the top stays pending
    /// across the frame boundary exactly as it should.
    std::array<uint8_t, DISPLAY_BYTES> pending_{};
    /// Whether anything has ever been written into pending_, so the screen
    /// fetch's clearing can be skipped until there is something to clear.
    /// Written by the emulator thread only, like heat_active_.
    bool pending_active_ = false;

    std::atomic<bool> write_overlay_{false};
    std::atomic<uint32_t> opacity_percent_{DEFAULT_OPACITY_PERCENT};
    std::atomic<uint32_t> fade_percent_{DEFAULT_FADE_PERCENT};
    /// How far each bitmap byte's eight pixels are lifted out of the dim, from
    /// the opacity it was written at down to 0.
    std::array<uint8_t, BITMAP_BYTES> write_heat_{};
    /// Whether anything in write_heat_ is non-zero, so the per-frame pass can
    /// be skipped entirely when it is not. Worth the flag: an uncapped run
    /// (ZEXALL and friends) crosses thousands of frame boundaries a second.
    bool heat_active_ = false;

    /// Whether the beam is over paper right now -- the only time the ULA
    /// fetches, and so the only time it drives the bus.
    bool in_paper_area() const {
        return line_ >= t_.paper_line_begin && line_ < t_.paper_line_end()
               && dot_ >= PAPER_DOT_BEGIN && dot_ < PAPER_DOT_END;
    }

    void emit_pixel();
    void on_frame_boundary();
    /// Paints the overlay onto the just-completed frame -- everything dimmed,
    /// each written byte lifted back by its heat -- and fades the heat map on
    /// by one frame. Wipes the map instead when the overlay is switched off,
    /// so switching back on starts from what is drawn next.
    void update_write_overlay();
    /// Clears the pending flags of the bytes a screen fetch has just latched:
    /// from this instant they are what the picture shows.
    ///
    /// The bitmap byte is one row and so is finished with immediately. An
    /// ATTRIBUTE is not: it covers eight rows and the beam displays them one
    /// at a time, so it stays pending until the last of them has been drawn.
    /// Clearing it on the first row is what made a whole 8x8 block stop being
    /// highlighted the instant the beam touched its top edge.
    void clear_pending(uint16_t bitmap, uint16_t attr, bool last_row_of_cell) {
        pending_[bitmap - BITMAP_BASE] = 0;
        if (last_row_of_cell) {
            pending_[attr - BITMAP_BASE] = 0;
        }
    }
};

} // namespace zx
