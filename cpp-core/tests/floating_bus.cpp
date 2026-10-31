// The floating bus: what a read of a port nothing decodes actually returns.
//
// Nothing drives the data bus for an odd port on a 48K, so the CPU latches
// whatever the ULA's screen read has left there -- bitmap and attribute bytes
// in turn while the beam is over paper, and nothing at all everywhere else.
// Returning a fixed 0xFF instead is a silent trap: it looks like a harmless
// default until a program uses the effect as a raster clock, at which point it
// hangs. Cobra's loader is one --
//
//     LD A,C / IN A,(0xFF) / CP B / JR NC,-6
//
// -- spinning at 0x9602 until the byte it reads drops below 0x3F, which with a
// constant 0xFF never happens.
//
// The rule, from docs/contention.md section 7: in each 8 T-state group from
// the contention start (14335 on the 48K, 14362 on the 128K; 16 groups a
// line, 192 lines), an IN whose T3 falls in T-states 3, 4, 5 and 6 of the
// group gets the first cell's bitmap, its attribute, the second cell's bitmap
// and its attribute; anywhere else, 0xFF. Every expected byte below is worked
// out from that, and the public tests (Floating Spy's self-test, Float48K)
// check the same thing on the real programs.

#include "memory.h"
#include "spectrum.h"
#include "test_main.h"
#include "ula.h"

#include <cstdint>
#include <memory>

using namespace zx;

namespace {

/// One past the last byte of the display file: 768 attributes after
/// ATTR_BASE, one per 8x8 cell.
constexpr uint16_t DISPLAY_FILE_END = uint16_t(ATTR_BASE + (SCREEN_WIDTH / 8) * (SCREEN_HEIGHT / 8));

// Distinguishable values in the two cells of a group, so a wrong pick shows up
// as the wrong one of the four rather than as a plausible-looking byte.
constexpr uint8_t BITMAP_0 = 0x11;
constexpr uint8_t ATTR_0 = 0x22;
constexpr uint8_t BITMAP_1 = 0x33;
constexpr uint8_t ATTR_1 = 0x44;

constexpr uint32_t C48 = 14335;
constexpr uint32_t LINE48 = 224;
constexpr uint32_t C128 = 14362;
constexpr uint32_t LINE128 = 228;

/// An IN A,(n) takes its byte in T3 of its I/O cycle: 4 T-states of opcode
/// fetch, 3 of operand, then T1, T2, TW -- T3 is the eleventh T-state.
constexpr uint32_t IN_T3 = 10;

/// Puts the two cells of group `group` on pixel line `y` into `mem`.
void fill_group(Memory& mem, uint32_t group, uint32_t y) {
    const uint16_t x = uint16_t(group * 16);
    mem.write(pixel_addr(x, uint16_t(y)), BITMAP_0);
    mem.write(attr_addr(x, uint16_t(y)), ATTR_0);
    mem.write(pixel_addr(uint16_t(x + 8), uint16_t(y)), BITMAP_1);
    mem.write(attr_addr(uint16_t(x + 8), uint16_t(y)), ATTR_1);
}

/// What a bare ULA with the given timing has on the bus at frame T-state t.
uint8_t bus_at(const UlaTiming& timing, uint32_t group, uint32_t y, uint32_t tstate) {
    FlatMemory mem;
    fill_group(mem, group, y);
    Ula ula;
    ula.set_timing(timing);
    uint64_t pins = 0;
    while (ula.frame_hc() != tstate * HC_PER_TSTATE) {
        ula.clock(pins, mem.bytes.data() + BITMAP_BASE);
        ula.advance();
    }
    return ula.floating_bus(mem.bytes.data() + BITMAP_BASE);
}

/// The 8 values of the group starting at frame T-state g.
void check_group(const UlaTiming& timing, uint32_t group, uint32_t y, uint32_t g) {
    const uint8_t expected[8] = {0xFF, 0xFF, 0xFF, BITMAP_0, ATTR_0, BITMAP_1, ATTR_1, 0xFF};
    for (uint32_t k = 0; k < 8; k++) {
        CHECK_EQ(int(bus_at(timing, group, y, g + k)), int(expected[k]));
    }
}

} // namespace

TEST(the_first_group_of_the_frame) {
    // Line 0, group 0: G = 14335.
    check_group(TIMING_48K, 0, 0, C48);
}

TEST(a_group_mid_screen) {
    // Line 100, group 9: G = 14335 + 100 x 224 + 9 x 8 = 36807. Line 100 is
    // in the second third, which the display file's layout makes a different
    // address from line 100 counted linearly -- pixel_addr() is the layout.
    check_group(TIMING_48K, 9, 100, C48 + 100 * LINE48 + 9 * 8);
}

TEST(the_last_group_of_the_frame) {
    // Line 191, group 15: G = 14335 + 191 x 224 + 120 = 57239.
    check_group(TIMING_48K, 15, 191, C48 + 191 * LINE48 + 120);
}

TEST(nothing_outside_the_paper) {
    // Where a seventeenth group would be on line 0, its T-state 3; the same
    // place before the first line and after the last; and the border before
    // group 0 on line 0. All 0xFF, with every cell of the screen filled so
    // that a wrong address would show.
    const uint32_t positions[] = {C48 + 128 + 3, C48 - LINE48 + 3, C48 + 192 * LINE48 + 3,
                                  C48 - 8 + 3};
    for (uint32_t t : positions) {
        FlatMemory mem;
        for (uint16_t a = BITMAP_BASE; a < DISPLAY_FILE_END; a++) {
            mem.write(a, 0x5A);
        }
        Ula ula;
        uint64_t pins = 0;
        while (ula.frame_hc() != t * HC_PER_TSTATE) {
            ula.clock(pins, mem.bytes.data() + BITMAP_BASE);
            ula.advance();
        }
        CHECK_EQ(int(ula.floating_bus(mem.bytes.data() + BITMAP_BASE)), 0xFF);
    }
}

TEST(the_128ks_groups_follow_its_own_timing) {
    // 128K: G = 14362 on line 0, and lines of 228 T-states, so line 10's
    // group 3 is at 14362 + 2280 + 24 = 16666.
    check_group(TIMING_128K, 0, 0, C128);
    check_group(TIMING_128K, 3, 10, C128 + 10 * LINE128 + 24);
}

namespace {

/// Runs IN A,(0xFF) with A = 0, its opcode fetch starting at frame T-state
/// `fetch`, and returns what the CPU latched. Port 0x00FF is not contended
/// and the code is at 0x8000, so nothing is held and its T3 is fetch + 10.
uint8_t in_at(uint32_t fetch) {
    auto machine = std::make_unique<Spectrum>();
    fill_group(machine->memory, 0, 0);

    constexpr uint16_t PROGRAM = 0x8000;
    const uint8_t code[] = {0xDB, 0xFF}; // IN A,(0xFF)
    machine->write_memory(PROGRAM, code, sizeof code);

    while (machine->ula.frame_hc() != fetch * HC_PER_TSTATE) {
        machine->clock();
    }
    Registers regs{};
    regs.pc = PROGRAM;
    machine->set_registers(regs);
    machine->step_instruction();
    return machine->registers().a;
}

} // namespace

TEST(in_from_an_odd_port_reads_the_group_in_turn) {
    // T3 at 14335 + k for k = 0..7: 0xFF, 0xFF, 0xFF, then the four bytes,
    // then 0xFF.
    const uint8_t expected[8] = {0xFF, 0xFF, 0xFF, BITMAP_0, ATTR_0, BITMAP_1, ATTR_1, 0xFF};
    for (uint32_t k = 0; k < 8; k++) {
        CHECK_EQ(int(in_at(C48 + k - IN_T3)), int(expected[k]));
    }
}

TEST(in_from_an_even_port_still_reads_the_keyboard) {
    // The floating bus must not have swallowed the ULA's own port: an even
    // port is decoded, so it answers with the keyboard (no keys down, EAR
    // high) rather than with a display byte -- even with T3 on a bitmap read.
    auto machine = std::make_unique<Spectrum>();
    for (uint16_t addr = BITMAP_BASE; addr < DISPLAY_FILE_END; addr++) {
        machine->memory.write(addr, BITMAP_0);
    }

    constexpr uint16_t PROGRAM = 0x8000;
    const uint8_t code[] = {0xDB, 0xFE}; // IN A,(0xFE)
    machine->write_memory(PROGRAM, code, sizeof code);

    while (machine->ula.frame_hc() != (C48 + 3 - IN_T3) * HC_PER_TSTATE) {
        machine->clock();
    }
    Registers regs{};
    regs.pc = PROGRAM;
    regs.a = 0x7F; // half-row with SPACE on it
    machine->set_registers(regs);
    machine->step_instruction();
    // All five key bits high, and nothing of the display in it.
    CHECK_EQ(int(machine->registers().a & 0x1F), 0x1F);
    CHECK(machine->registers().a != BITMAP_0);
}

TEST(a_cobra_style_wait_loop_terminates) {
    // The actual failure this fixes: spin on IN A,(0xFF) until the value read
    // drops below a threshold. With a constant 0xFF this never leaves the
    // loop; with a floating bus it leaves as soon as the beam reaches a cell
    // whose bytes are low enough.
    auto machine = std::make_unique<Spectrum>();
    // Attributes of 0x38 (white paper, black ink) all over, which is below
    // the 0x3F Cobra tests against, and a blank bitmap.
    for (uint16_t addr = ATTR_BASE; addr < DISPLAY_FILE_END; addr++) {
        machine->memory.write(addr, 0x38);
    }

    constexpr uint16_t PROGRAM = 0x8000;
    const uint8_t code[] = {
        0x01, 0x28, 0x3F, // LD BC,0x3F28 -- B is Cobra's 0x3F threshold
        0x79,             // LD A,C
        0xDB, 0xFF,       // IN A,(0xFF)
        0xB8,             // CP B
        0x30, 0xFA,       // JR NC,-6
        0x76,             // HALT
    };
    machine->write_memory(PROGRAM, code, sizeof code);

    Registers regs{};
    regs.pc = PROGRAM;
    machine->set_registers(regs);

    // Two frames is far longer than the loop can legitimately need: the beam
    // crosses paper once per frame, so one pass is always enough.
    const uint16_t halt_at = PROGRAM + sizeof code - 1;
    bool escaped = false;
    for (uint32_t i = 0; i < 2 * HC_PER_FRAME && !escaped; i++) {
        machine->clock();
        escaped = machine->registers().pc > halt_at || machine->cpu.halted;
    }
    CHECK(escaped);
}

RUN_TESTS()
