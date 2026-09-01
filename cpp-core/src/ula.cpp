#include "ula.h"

#include "pins.h"

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
}

void Ula::clock(uint64_t& pins, Memory& mem) {
    // Nothing fetched until proven otherwise. Read back by the trace later in
    // the same half-clock -- Spectrum48K::clock() runs the ULA first, then the
    // CPU, then record().
    fetch_count_ = 0;

    // ---- interrupt ---------------------------------------------------------
    // The ULA drives this line, not the CPU. Active low.
    if (frame_hc_ < INT_PULSE_HC) {
        pins = assert_pins(pins, INT);
    } else {
        pins = release_pins(pins, INT);
    }

    // ---- screen fetch ------------------------------------------------------
    const bool in_paper = line_ >= PAPER_LINE_BEGIN && line_ < PAPER_LINE_END
                          && dot_ >= PAPER_DOT_BEGIN && dot_ < PAPER_DOT_END;
    if (in_paper) {
        uint32_t px = dot_ - PAPER_DOT_BEGIN; // 0..255 across the paper
        if ((px & 15) == 0) {
            // Start of a 16-pixel group: fetch the two cells' bitmap and
            // attribute bytes. Real hardware staggers these across four
            // T-states and displays them a group late through a shift
            // register; fetching them together at the group's first dot is
            // equivalent for what is observable here (which byte value a
            // mid-frame write lands on) and avoids a pipeline whose only
            // visible effect would be a one-group display lag.
            uint16_t y = uint16_t(line_ - PAPER_LINE_BEGIN);
            uint16_t x = uint16_t(px);
            const uint16_t first = pixel_addr(x, y);
            pixel0_ = mem.read(first);
            attr0_ = mem.read(attr_addr(x, y));
            pixel1_ = mem.read(pixel_addr(uint16_t(x + 8), y));
            attr1_ = mem.read(attr_addr(uint16_t(x + 8), y));
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

    // Deliberately does NOT advance: see advance(), which Spectrum48K::clock()
    // calls once the CPU, the trace and the bus service have all had this same
    // half-clock at the counters describing it.
}

void Ula::advance() {
    if (++dot_ >= HC_PER_LINE) {
        dot_ = 0;
        if (++line_ >= LINES_PER_FRAME) {
            line_ = 0;
        }
    }
    if (++frame_hc_ >= HC_PER_FRAME) {
        frame_hc_ = 0;
        on_frame_boundary();
    }
}

void Ula::emit_pixel() {
    if (dot_ >= VISIBLE_DOTS) {
        return; // horizontal retrace -- nothing rendered
    }

    Rgb rgb;
    if (line_ >= PAPER_LINE_BEGIN && line_ < PAPER_LINE_END
        && dot_ >= PAPER_DOT_BEGIN && dot_ < PAPER_DOT_END) {
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
    // Swap rather than copy: the completed frame becomes what screen()
    // returns and the old buffer is reused for the next one.
    framebuffer_.swap(last_frame_);
    frame_count_++;
    if ((frame_count_ % 16) == 0) {
        flash_state = !flash_state; // ~1.56Hz, as on real hardware
    }
}

} // namespace zx
