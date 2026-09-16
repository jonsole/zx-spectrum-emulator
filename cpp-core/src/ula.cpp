#include "ula.h"

#include "pins.h"

#include <algorithm>

namespace zx {
namespace {

/// The 8 Spectrum colours at normal and BRIGHT intensity.
struct Rgb {
    uint8_t r, g, b;
};

constexpr Rgb colour(uint8_t index, bool bright) {
    uint8_t level = bright ? 0xFF : 0xCD;
    return Rgb{
        uint8_t((index & 0x02) ? level : 0), // bit 1 = red
        uint8_t((index & 0x04) ? level : 0), // bit 2 = green
        uint8_t((index & 0x01) ? level : 0), // bit 0 = blue
    };
}

/// One pixel of an RGB canvas buffer, replaced by its own inverse.
void invert_pixel(std::vector<uint8_t>& rgb, uint32_t x, uint32_t y) {
    const size_t idx = (size_t(y) * FULL_WIDTH + x) * 3;
    rgb[idx] = uint8_t(255 - rgb[idx]);
    rgb[idx + 1] = uint8_t(255 - rgb[idx + 1]);
    rgb[idx + 2] = uint8_t(255 - rgb[idx + 2]);
}

/// Puts a w x h block of PAPER pixels at (x, y) back to the brightness it had
/// before the dim, out of a copy taken beforehand. `paper_begin` is the
/// canvas line the paper starts on, which differs between models.
void undim(std::vector<uint8_t>& rgb, const std::vector<uint8_t>& bright, uint32_t paper_begin,
           uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    for (uint32_t row = 0; row < h; row++) {
        const size_t idx =
            (size_t(paper_begin + y + row) * FULL_WIDTH + PAPER_DOT_BEGIN + x) * 3;
        std::copy(bright.begin() + idx, bright.begin() + idx + w * 3, rgb.begin() + idx);
    }
}

} // namespace

Ula::Ula()
    : framebuffer_(size_t(FULL_WIDTH) * FULL_HEIGHT * 3, 0),
      last_frame_(size_t(FULL_WIDTH) * FULL_HEIGHT * 3, 0) {
    // Start at the canvas position corresponding to frame_hc_ == 0 (the
    // interrupt), which is CANVAS_LEAD_HC dots into line 0 -- see ula.h.
    line_ = 0;
    dot_ = CANVAS_LEAD_HC;
}

void Ula::reset() {
    std::fill(framebuffer_.begin(), framebuffer_.end(), uint8_t(0));
    std::fill(last_frame_.begin(), last_frame_.end(), uint8_t(0));
    frame_hc_ = 0;
    frame_count_ = 0;
    line_ = 0;
    dot_ = CANVAS_LEAD_HC;
    pixel0_ = attr0_ = pixel1_ = attr1_ = 0;
    border_latch_ = 0;
    write_heat_.fill(0);
    heat_active_ = false;
    pending_.fill(0);
    pending_active_ = false;
}

void Ula::set_screen_bank(uint8_t bank) {
    if (bank == screen_bank_) {
        return;
    }
    screen_bank_ = bank;
    pending_.fill(1);
    pending_active_ = true;
}

void Ula::clock(uint64_t& pins, const uint8_t* screen) {
    // Nothing fetched until proven otherwise. Read back by the trace later in
    // the same half-clock -- Spectrum::clock() runs the ULA first, then the
    // CPU, then record().
    fetch_count_ = 0;

    // ---- interrupt ---------------------------------------------------------
    // The ULA drives this line, not the CPU. Active low.
    if (frame_hc_ < t_.int_pulse_hc) {
        pins = assert_pins(pins, INT);
    } else {
        pins = release_pins(pins, INT);
    }

    // ---- screen fetch ------------------------------------------------------
    if (in_paper_area()) {
        uint32_t px = dot_ - PAPER_DOT_BEGIN; // 0..255 across the paper
        if ((px & 15) == 0) {
            // Start of a 16-pixel group: fetch the two cells' bitmap and
            // attribute bytes. Real hardware staggers these across four
            // T-states and displays them a group late through a shift
            // register; fetching them together at the group's first dot is
            // equivalent for what is observable here (which byte value a
            // mid-frame write lands on) and avoids a pipeline whose only
            // visible effect would be a one-group display lag.
            uint16_t y = uint16_t(line_ - t_.paper_line_begin);
            uint16_t x = uint16_t(px);
            const uint16_t first = pixel_addr(x, y);
            const uint16_t first_attr = attr_addr(x, y);
            const uint16_t second = pixel_addr(uint16_t(x + 8), y);
            const uint16_t second_attr = attr_addr(uint16_t(x + 8), y);
            // The display file starts at the bottom of its bank, so a CPU
            // address of it is an offset into `screen` once BITMAP_BASE is
            // taken off.
            pixel0_ = screen[first - BITMAP_BASE];
            attr0_ = screen[first_attr - BITMAP_BASE];
            pixel1_ = screen[second - BITMAP_BASE];
            attr1_ = screen[second_attr - BITMAP_BASE];
            if (pending_active_) {
                // These are now latched, so whatever was written to them is
                // what the next 16 pixels show: no longer pending. Guarded on
                // pending_active_ rather than on the setting, so switching
                // tracking off still lets the map drain itself.
                //
                // The attributes only stop being pending on the cell's last
                // pixel row, since that is when the beam has finished showing
                // them -- see clear_pending.
                const bool last_row_of_cell = (y & 7) == 7;
                clear_pending(first, first_attr, last_row_of_cell);
                clear_pending(second, second_attr, last_row_of_cell);
            }
            // Reported as four bytes read at one instant, which is what this
            // currently is. Once the fetch is staggered these become four
            // separate half-clocks of one byte each and only the count
            // changes.
            fetch_count_ = 4;
            fetch_addr_ = first;
            fetch_data_ = pixel0_;
        }
    }

    // ---- border latch ------------------------------------------------------
    // Latched every 8 pixels, so an OUT part-way through a group only takes
    // effect at the next boundary -- the reason border-timing effects have
    // the granularity they do.
    if ((dot_ % BORDER_LATCH_DOTS) == 0) {
        border_latch_ = border;
    }

    // ---- emit exactly one pixel -------------------------------------------
    emit_pixel();

    // Deliberately does NOT advance: see advance(), which Spectrum::clock()
    // calls once the CPU, the trace and the bus service have all had this same
    // half-clock at the counters describing it.
}

uint8_t Ula::floating_bus() const {
    // Outside paper -- both borders, retrace, and the whole of the top and
    // bottom borders -- the ULA has nothing to fetch, so nothing drives the
    // bus.
    if (!in_paper_area()) {
        return FLOATING_BUS_IDLE;
    }
    // A 16-pixel group is 8 T-states, and that is exactly the ULA's fetch
    // cycle: four bytes read in the first four T-states, then four T-states
    // with the bus idle. Those four bytes are already latched -- clock() reads
    // them at the group's first dot -- so this reports them rather than
    // fetching anything again.
    //
    // Real hardware fetches the group it is ABOUT to display, so its floating
    // bus runs one group (8 T-states, half a character cell) ahead of what
    // this returns. That offset is below the resolution of what the effect is
    // used for -- a program waiting for the beam to reach a region of the
    // screen -- and closing it would mean the display pipeline that clock()
    // deliberately does not model.
    switch (((dot_ - PAPER_DOT_BEGIN) & 15) / HC_PER_TSTATE) {
    case 0:
        return pixel0_;
    case 1:
        return attr0_;
    case 2:
        return pixel1_;
    case 3:
        return attr1_;
    default:
        // The idle half of the group: fetched, not fetching.
        return FLOATING_BUS_IDLE;
    }
}

void Ula::advance() {
    if (++dot_ >= t_.hc_per_line) {
        dot_ = 0;
        if (++line_ >= t_.lines_per_frame) {
            line_ = 0;
        }
    }
    if (++frame_hc_ >= t_.hc_per_frame()) {
        frame_hc_ = 0;
        on_frame_boundary();
    }
}

void Ula::emit_pixel() {
    if (dot_ >= VISIBLE_DOTS) {
        return; // horizontal retrace -- nothing rendered
    }

    Rgb rgb;
    if (in_paper_area()) {
        uint32_t px = dot_ - PAPER_DOT_BEGIN;
        // Which of the group's two cells, and which bit within it.
        bool second_cell = (px & 15) >= 8;
        uint8_t bits = second_cell ? pixel1_ : pixel0_;
        uint8_t attr = second_cell ? attr1_ : attr0_;
        uint8_t bit = uint8_t(px & 7);

        uint8_t ink = uint8_t(attr & 0x07);
        uint8_t paper = uint8_t((attr >> 3) & 0x07);
        bool bright = (attr & 0x40) != 0;
        if ((attr & 0x80) && flash_state) {
            uint8_t tmp = ink;
            ink = paper;
            paper = tmp;
        }
        bool lit = (bits & (0x80 >> bit)) != 0;
        rgb = colour(lit ? ink : paper, bright);
    } else {
        rgb = colour(uint8_t(border_latch_ & 0x07), false);
    }

    size_t idx = (size_t(line_) * FULL_WIDTH + dot_) * 3;
    framebuffer_[idx] = rgb.r;
    framebuffer_[idx + 1] = rgb.g;
    framebuffer_[idx + 2] = rgb.b;
}

void Ula::on_frame_boundary() {
    // A frame shorter than the canvas (the 128K's 311 lines against 312)
    // leaves the bottom line undrawn. Repeating the last real line there
    // keeps it border-coloured rather than black, and keeps every consumer
    // of the picture on one fixed size.
    for (uint32_t line = t_.lines_per_frame; line < FULL_HEIGHT; line++) {
        const size_t from = size_t(line - 1) * FULL_WIDTH * 3;
        const size_t to = size_t(line) * FULL_WIDTH * 3;
        std::copy(framebuffer_.begin() + long(from), framebuffer_.begin() + long(from + FULL_WIDTH * 3),
                  framebuffer_.begin() + long(to));
    }
    // Swap rather than copy: the completed frame becomes what screen()
    // returns and the old buffer is reused for the next one.
    framebuffer_.swap(last_frame_);
    // Onto the completed frame, not the one starting: a byte written late in
    // the frame -- after the beam had already passed it -- still belongs to
    // the frame that wrote it. The next frame redraws every visible pixel from
    // scratch, so painting over this one costs nothing downstream.
    update_write_overlay();
    frame_count_++;
    if ((frame_count_ % 16) == 0) {
        flash_state = !flash_state; // ~1.56Hz, as on real hardware
    }
}

void Ula::update_write_overlay() {
    if (!write_overlay_.load(std::memory_order_relaxed)) {
        if (heat_active_) {
            // Switched off with heat still on the map. Wiped rather than left
            // to fade, so switching back on starts from what the program
            // draws NEXT -- otherwise a fade of 0, which never decays
            // anything, would replay everything drawn before it was switched
            // off.
            write_heat_.fill(0);
            heat_active_ = false;
        }
        return;
    }
    // One pass over the whole frame, border included: every pixel is dimmed
    // to PENDING_DIM_PERCENT and then lifted back towards its own full
    // brightness by however much heat its bitmap byte holds. Dimmed even when
    // nothing has been written, for the same reason draw_pending_writes is:
    // a frame with nothing lit has to look different from the overlay being
    // off, or every quiet frame reads as the feature not working.
    for (uint32_t line = 0; line < FULL_HEIGHT; line++) {
        const bool paper_line = line >= t_.paper_line_begin && line < t_.paper_line_end();
        // The bitmap row for this line, as an index into the heat map (see
        // pixel_addr for the layout being reproduced).
        uint32_t row = 0;
        if (paper_line) {
            const uint32_t y = line - t_.paper_line_begin;
            row = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2);
        }
        size_t idx = size_t(line) * FULL_WIDTH * 3;
        for (uint32_t dot = 0; dot < FULL_WIDTH; dot++, idx += 3) {
            uint32_t heat = 0;
            if (paper_line && dot >= PAPER_DOT_BEGIN && dot < PAPER_DOT_END) {
                heat = write_heat_[row + ((dot - PAPER_DOT_BEGIN) >> 3)];
            }
            for (uint32_t c = 0; c < 3; c++) {
                const uint32_t full = last_frame_[idx + c];
                const uint32_t dim = full * PENDING_DIM_PERCENT / PERCENT_MAX;
                last_frame_[idx + c] = uint8_t(dim + (full - dim) * heat / HEAT_MAX);
            }
        }
    }
    if (!heat_active_) {
        return;
    }
    // Then the heat fades on by one frame.
    const uint32_t keep = PERCENT_MAX - fade_percent_.load(std::memory_order_relaxed);
    bool any_left = false;
    for (uint32_t i = 0; i < BITMAP_BYTES; i++) {
        const uint8_t heat = uint8_t(write_heat_[i] * keep / PERCENT_MAX);
        write_heat_[i] = heat;
        if (heat != 0) {
            any_left = true;
        }
    }
    heat_active_ = any_left;
}

std::vector<uint8_t> Ula::screen_in_progress() const {
    // The previous frame underneath, then this frame's drawing painted over
    // as far as the beam has got. Copying the whole of last_frame_ first and
    // overwriting the drawn part is one pass more than strictly needed and far
    // simpler than stitching row ranges from two buffers.
    std::vector<uint8_t> out = last_frame_;
    const size_t whole_lines = size_t(line_) * FULL_WIDTH * 3;
    std::copy(framebuffer_.begin(), framebuffer_.begin() + whole_lines, out.begin());
    // ...and the part of the beam's own line that it has already emitted.
    // dot_ runs past the canvas during retrace, by which point the whole line
    // has been drawn.
    const size_t drawn = size_t(dot_ < FULL_WIDTH ? dot_ : FULL_WIDTH) * 3;
    std::copy(framebuffer_.begin() + whole_lines, framebuffer_.begin() + whole_lines + drawn,
              out.begin() + whole_lines);
    return out;
}

void Ula::draw_pending_writes(std::vector<uint8_t>& rgb) const {
    if (rgb.size() != size_t(FULL_WIDTH) * FULL_HEIGHT * 3) {
        return;
    }
    // Dimmed whether or not anything turns out to be pending. An empty map is
    // a real answer -- the beam has displayed everything written so far, which
    // for a game that draws in one burst is most of the pass -- and it has to
    // look different from the view being switched off, or every such moment
    // reads as the feature not working.
    //
    // The pending bytes are put back at full strength afterwards, so the
    // picture as it stands has to survive the dimming.
    const std::vector<uint8_t> bright = rgb;
    for (size_t i = 0; i < rgb.size(); i++) {
        rgb[i] = uint8_t(uint32_t(rgb[i]) * PENDING_DIM_PERCENT / PERCENT_MAX);
    }

    // How many paper rows the beam has already drawn this frame. Above the
    // paper it has drawn none; below it, all of them.
    const uint32_t paper_begin = t_.paper_line_begin;
    const uint32_t drawn_rows = line_ <= paper_begin
                                    ? 0
                                    : (line_ >= t_.paper_line_end() ? SCREEN_HEIGHT
                                                                    : line_ - paper_begin);

    for (uint32_t i = 0; i < DISPLAY_BYTES; i++) {
        if (pending_[i] == 0) {
            continue;
        }
        if (i < BITMAP_BYTES) {
            // Un-scramble the display file's layout (see pixel_addr): bits
            // 12-11 pick the third of the screen, 10-8 the pixel row within
            // the character cell, 7-5 the cell row within the third, and 4-0
            // the column. One byte is eight pixels of a single row.
            const uint32_t y = ((i >> 11) & 3) * 64 + ((i >> 5) & 7) * 8 + ((i >> 8) & 7);
            undim(rgb, bright, paper_begin, (i & 31) * 8, y, 8, 1);
        } else {
            // An attribute byte is a whole 8x8 cell, laid out linearly -- but
            // only the rows the beam has NOT yet drawn are still waiting for
            // it. Lighting all eight regardless made the cell snap from lit
            // to dim in a single step as the beam crossed its top row, which
            // reads as the picture updating eight rows at a time. It shrinks
            // a row at a time instead, which is what actually happens.
            const uint32_t a = i - BITMAP_BYTES;
            const uint32_t top = (a >> 5) * 8;
            const uint32_t first = top > drawn_rows ? top : drawn_rows;
            if (first < top + 8) {
                undim(rgb, bright, paper_begin, (a & 31) * 8, first, 8, top + 8 - first);
            }
        }
    }
}

void Ula::draw_raster_marker(std::vector<uint8_t>& rgb) const {
    if (rgb.size() != size_t(FULL_WIDTH) * FULL_HEIGHT * 3) {
        return; // not a frame -- nothing to annotate
    }
    // During retrace the beam is past the right-hand edge; the last visible dot
    // is the closest the picture can come to showing where it actually is.
    const uint32_t beam_x = dot_ < VISIBLE_DOTS ? dot_ : VISIBLE_DOTS - 1;

    // The line the beam is on, dashed, and skipping the beam's own column so
    // the tick below is not inverted twice back to what it started as.
    for (uint32_t x = 0; x < FULL_WIDTH; x++) {
        if (x == beam_x || (x % RASTER_DASH) >= RASTER_DASH / 2) {
            continue;
        }
        invert_pixel(rgb, x, line_);
    }

    // The beam itself, solid, standing out of the dashes.
    const int32_t reach = int32_t(RASTER_TICK_REACH);
    for (int32_t dy = -reach; dy <= reach; dy++) {
        const int32_t y = int32_t(line_) + dy;
        if (y < 0 || y >= int32_t(FULL_HEIGHT)) {
            continue;
        }
        invert_pixel(rgb, beam_x, uint32_t(y));
    }
}

#if ZX_REWIND
void Ula::save_state(State& s) const {
    s.timing = t_;
    s.border = border;
    s.flash_state = flash_state;
    s.screen_bank = screen_bank_;
    s.frame_hc = frame_hc_;
    s.fetch_count = fetch_count_;
    s.fetch_addr = fetch_addr_;
    s.fetch_data = fetch_data_;
    s.line = line_;
    s.dot = dot_;
    s.frame_count = frame_count_;
    s.pixel0 = pixel0_;
    s.attr0 = attr0_;
    s.pixel1 = pixel1_;
    s.attr1 = attr1_;
    s.border_latch = border_latch_;
}

void Ula::restore_state(const State& s) {
    t_ = s.timing;
    border = s.border;
    flash_state = s.flash_state;
    screen_bank_ = s.screen_bank;
    frame_hc_ = s.frame_hc;
    fetch_count_ = s.fetch_count;
    fetch_addr_ = s.fetch_addr;
    fetch_data_ = s.fetch_data;
    line_ = s.line;
    dot_ = s.dot;
    frame_count_ = s.frame_count;
    pixel0_ = s.pixel0;
    attr0_ = s.attr0;
    pixel1_ = s.pixel1;
    attr1_ = s.attr1;
    border_latch_ = s.border_latch;
}
#endif

} // namespace zx
