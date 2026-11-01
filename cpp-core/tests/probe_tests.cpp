// The bus probe (BusProbe in spectrum.h): what a hardware bench reads after
// each Spectrum::clock(). Every expected value is worked out from the frame's
// layout and the instruction's documented timing (docs/contention.md), not
// read off the probe.
//
// The machine has no ROM loaded, so the CPU runs NOPs up from 0: it is
// nowhere near the screen, nor writing anything, in the frame these look at.

#include "memory.h"
#include "spectrum.h"
#include "test_main.h"
#include "ula.h"

#include <cstdint>
#include <memory>

using namespace zx;

namespace {

/// 48K: the first contended T-state.
constexpr uint32_t C48 = 14335;
constexpr uint16_t CODE = 0x8000;

std::unique_ptr<Spectrum> machine() {
    return std::make_unique<Spectrum>();
}

/// Clocks until the half-clock about to run is `hc` of the frame.
void run_to(Spectrum& m, uint32_t hc) {
    while (m.ula.frame_hc() != hc) {
        m.clock();
    }
}

} // namespace

TEST(counters_are_the_half_clock_just_run) {
    // Clocking frame half-clock 1000 reports 1000, though the ULA has moved
    // to 1001 by the time clock() returns. On the 48K a line is 448
    // half-clocks, and the canvas's dots lead the frame's half-clocks by
    // CANVAS_LEAD_HC, 48: half-clock 1000 is dot 1048 of the canvas, line 2,
    // dot 152.
    auto m = machine();
    BusProbe p;
    m->probe = &p;
    run_to(*m, 1000);
    m->clock();
    CHECK_EQ(p.frame_hc, 1000u);
    CHECK_EQ(p.line, 2u);
    CHECK_EQ(p.dot, 152u);
    CHECK_EQ(m->ula.frame_hc(), 1001u);
}

TEST(int_for_the_first_32_tstates) {
    // The 48K's INT is down for the frame's first 32 T-states: half-clocks
    // 0-63.
    auto m = machine();
    BusProbe p;
    m->probe = &p;
    run_to(*m, 63);
    m->clock();
    CHECK(p.int_asserted);
    m->clock();
    CHECK_EQ(p.frame_hc, 64u);
    CHECK(!p.int_asserted);
}

TEST(a_paper_dot_as_a_colour_index_and_its_group_fetch) {
    // The paper's first dot: line 64, dot 48, which with the canvas's lead of
    // 48 dots is frame half-clock 64 x 448 -- T-state 14336. Its group fetches 0x4000,
    // 0x5800, 0x4001, 0x5801. 0x4000 = 0xFF (all ink), 0x5800 = 0x47 (bright,
    // white ink): the dot is colour 7 with bright, 0x0F. 0x4001 = 0x00 with
    // 0x5801 = 0x08 (blue paper, not bright): the second cell's first dot,
    // 8 on, is colour 1.
    auto m = machine();
    const uint8_t bitmap[2] = {0xFF, 0x00};
    const uint8_t attrs[2] = {0x47, 0x08};
    m->write_memory(0x4000, bitmap, 2);
    m->write_memory(0x5800, attrs, 2);
    BusProbe p;
    m->probe = &p;
    run_to(*m, 64 * 448);
    m->clock();
    CHECK(p.dot_kind == DotKind::Paper);
    CHECK_EQ(p.dot_colour, uint8_t(0x0F));
    CHECK_EQ(p.fetch_count, 4u);
    CHECK_EQ(p.fetch_addr[0], uint16_t(0x4000));
    CHECK_EQ(p.fetch_addr[1], uint16_t(0x5800));
    CHECK_EQ(p.fetch_addr[2], uint16_t(0x4001));
    CHECK_EQ(p.fetch_addr[3], uint16_t(0x5801));
    CHECK_EQ(p.fetch_data[0], uint8_t(0xFF));
    CHECK_EQ(p.fetch_data[1], uint8_t(0x47));
    CHECK_EQ(p.fetch_data[2], uint8_t(0x00));
    CHECK_EQ(p.fetch_data[3], uint8_t(0x08));
    // The next dot is no fetch.
    m->clock();
    CHECK_EQ(p.fetch_count, 0u);
    run_to(*m, 64 * 448 + 8);
    m->clock();
    CHECK(p.dot_kind == DotKind::Paper);
    CHECK_EQ(p.dot_colour, uint8_t(0x01));
}

TEST(border_and_retrace_dots) {
    // Line 10 is top border: dot 0 shows the latch, which takes the border
    // at every 8th dot, so at dot 0 itself; with the canvas's lead of 48 that
    // is frame half-clock 10 x 448 - 48. Dot 352 on, 352 half-clocks later, is
    // the retrace.
    auto m = machine();
    m->ula.border = 5;
    BusProbe p;
    m->probe = &p;
    run_to(*m, 10 * 448 - 48);
    m->clock();
    CHECK(p.dot_kind == DotKind::Border);
    CHECK_EQ(p.dot_colour, uint8_t(5));
    CHECK_EQ(p.border_latch, uint8_t(5));
    run_to(*m, 10 * 448 - 48 + 352);
    m->clock();
    CHECK(p.dot_kind == DotKind::Retrace);
    CHECK_EQ(p.dot_colour, uint8_t(0));
}

TEST(a_held_out_reports_the_hold_and_the_port_byte) {
    // OUT (0xFE),A with A = 0x12 (speaker on, border 2), fetched at 14327:
    // T2 at 14335, G + 0, held 6 T-states. Half-clock 2 x 14335 is T2H, the
    // CPU clocked; the next 12 are held; the 13th is T2L, clocked, and the
    // port has the byte from there on.
    auto m = machine();
    run_to(*m, (C48 - 8) * HC_PER_TSTATE);
    const uint8_t code[2] = {0xD3, 0xFE};
    m->write_memory(CODE, code, 2);
    Registers r;
    r.a = 0x12;
    r.pc = CODE;
    m->set_registers(r);
    BusProbe p;
    m->probe = &p;
    run_to(*m, C48 * HC_PER_TSTATE);
    m->clock();
    CHECK(p.cpu_clocked);
    CHECK_EQ(p.ula_port, uint8_t(0));
    uint32_t held = 0;
    for (uint32_t i = 0; i < 12; i++) {
        m->clock();
        if (!p.cpu_clocked) {
            held++;
        }
    }
    CHECK_EQ(held, 12u);
    CHECK_EQ(p.ula_port, uint8_t(0));
    m->clock();
    CHECK(p.cpu_clocked);
    CHECK_EQ(p.frame_hc, C48 * HC_PER_TSTATE + 13);
    CHECK_EQ(p.ula_port, uint8_t(0x12));
    CHECK_EQ(m->ula_port(), uint8_t(0x12));
    // The pins are the bus after the service: IORQ and WR down, the port on
    // the address lines, the byte on the data lines.
    CHECK(asserted(p.pins, IORQ));
    CHECK(asserted(p.pins, WR));
    CHECK_EQ(get_addr(p.pins), uint16_t(0x12FE));
    CHECK_EQ(get_data(p.pins), uint8_t(0x12));
}

RUN_TESTS()