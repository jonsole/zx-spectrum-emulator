// The floating bus: what a read of a port nothing decodes actually returns.
//
// Nothing drives the data bus for an odd port on a 48K, so the CPU latches
// whatever the ULA is doing -- a display byte while the beam is over paper,
// and nothing at all everywhere else. Returning a fixed 0xFF instead is a
// silent trap: it looks like a harmless default until a program uses the
// effect as a raster clock, at which point it hangs. Cobra's loader is one --
//
//     LD A,C / IN A,(0xFF) / CP B / JR NC,-6
//
// -- spinning at 0x9602 until the byte it reads drops below 0x3F, which with a
// constant 0xFF never happens.
//
// Two levels here: the ULA's own answer at known raster positions, and the
// same thing through the CPU's IN instruction, which is what a program sees.

#include "memory.h"
#include "spectrum.h"
#include "test_main.h"
#include "ula.h"

#include <cstdint>

using namespace zx;

namespace {

// Distinguishable values in the first two cells of the top-left character
// row, so a wrong pick shows up as the wrong one of the four rather than as
// a plausible-looking byte.
/// One past the last byte of the display file: 768 attributes after
/// ATTR_BASE, one per 8x8 cell.
constexpr uint16_t DISPLAY_FILE_END = uint16_t(ATTR_BASE + (SCREEN_WIDTH / 8) * (SCREEN_HEIGHT / 8));

constexpr uint8_t BITMAP_0 = 0x11;
constexpr uint8_t ATTR_0 = 0x22;
constexpr uint8_t BITMAP_1 = 0x33;
constexpr uint8_t ATTR_1 = 0x44;

/// Canvas line the ULA is on, worked out from its frame position.
///
/// The two origins differ: frame_hc() counts from the interrupt, and the
/// canvas from the top-left of the picture, which happens CANVAS_LEAD_HC
/// half-clocks earlier. See the comment on that constant.
uint32_t line_of(uint32_t frame_hc) {
    return ((frame_hc + CANVAS_LEAD_HC) / HC_PER_LINE) % LINES_PER_FRAME;
}

uint32_t dot_of(uint32_t frame_hc) {
    return (frame_hc + CANVAS_LEAD_HC) % HC_PER_LINE;
}

/// Whether the beam is at exactly this canvas position.
bool beam_at(const Ula& ula, uint32_t line, uint32_t dot) {
    return line_of(ula.frame_hc()) == line && dot_of(ula.frame_hc()) == dot;
}

void fill_first_cells(Memory& mem) {
    mem.write(pixel_addr(0, 0), BITMAP_0);
    mem.write(attr_addr(0, 0), ATTR_0);
    mem.write(pixel_addr(8, 0), BITMAP_1);
    mem.write(attr_addr(8, 0), ATTR_1);
}

/// Runs a bare ULA up to (line, dot) and returns what it is driving there.
///
/// clock() then floating_bus() then advance(), which is the order
/// Spectrum48K::clock() uses -- the fetch for a group happens inside the
/// clock() of its first dot, so a value read before that call would be the
/// previous group's.
uint8_t bus_at(uint32_t line, uint32_t dot) {
    FlatMemory mem;
    fill_first_cells(mem);
    Ula ula;
    uint64_t pins = 0;
    for (;;) {
        ula.clock(pins, mem);
        if (beam_at(ula, line, dot)) {
            return ula.floating_bus();
        }
        ula.advance();
    }
}

} // namespace

TEST(paper_returns_the_four_bytes_of_the_group_then_idles) {
    // A 16-pixel group is 8 T-states: bitmap, attribute, bitmap, attribute,
    // then four T-states with nothing driving. Two half-clocks per T-state,
    // so each value is held for two dots.
    const uint8_t expected[16] = {
        BITMAP_0, BITMAP_0, ATTR_0, ATTR_0, BITMAP_1, BITMAP_1, ATTR_1, ATTR_1,
        0xFF,     0xFF,     0xFF,   0xFF,   0xFF,     0xFF,     0xFF,   0xFF,
    };
    for (uint32_t i = 0; i < 16; i++) {
        CHECK_EQ(int(bus_at(PAPER_LINE_BEGIN, PAPER_DOT_BEGIN + i)), int(expected[i]));
    }
}

TEST(borders_and_retrace_drive_nothing) {
    // Left border, right border and horizontal retrace on a paper line...
    CHECK_EQ(int(bus_at(PAPER_LINE_BEGIN, PAPER_DOT_BEGIN - 1)), 0xFF);
    CHECK_EQ(int(bus_at(PAPER_LINE_BEGIN, PAPER_DOT_END)), 0xFF);
    CHECK_EQ(int(bus_at(PAPER_LINE_BEGIN, VISIBLE_DOTS + 10)), 0xFF);
    // ...and the top and bottom borders, where the beam never crosses paper
    // however far along the line it is.
    CHECK_EQ(int(bus_at(PAPER_LINE_BEGIN - 1, PAPER_DOT_BEGIN)), 0xFF);
    CHECK_EQ(int(bus_at(PAPER_LINE_END, PAPER_DOT_BEGIN)), 0xFF);
}

namespace {

/// Runs one IN A,(0xFF) with the beam starting at `dot` on the first paper
/// line, and returns what the CPU latched.
///
/// The whole display file is filled, not just a cell or two: IN A,(n) takes 11
/// T-states and the CPU samples the bus at the last of them, so the byte it
/// gets belongs to a group well past wherever the instruction started. What
/// this can assert is which KIND of byte came back -- a display byte or the
/// idle 0xFF -- and that is exactly what the effect is about.
uint8_t in_at(uint32_t dot) {
    Spectrum48K machine;
    for (uint16_t addr = BITMAP_BASE; addr < ATTR_BASE; addr++) {
        machine.memory.write(addr, BITMAP_0);
    }
    for (uint16_t addr = ATTR_BASE; addr < DISPLAY_FILE_END; addr++) {
        machine.memory.write(addr, ATTR_0);
    }

    constexpr uint16_t PROGRAM = 0x8000;
    const uint8_t code[] = {0xDB, 0xFF, 0x18, 0xFE}; // IN A,(0xFF) / JR $
    machine.write_memory(PROGRAM, code, sizeof code);

    // Beam first, CPU second. prime_cpu() leaves the machine about to execute
    // the instruction, so priming before this loop would run the whole IN in
    // the top border -- where the answer is 0xFF whatever the fix does, which
    // is precisely the failure this test is meant to catch.
    while (!beam_at(machine.ula, PAPER_LINE_BEGIN, dot)) {
        machine.clock();
    }
    Registers regs{};
    regs.pc = PROGRAM;
    machine.prime_cpu(regs);
    machine.step_instruction();
    return machine.registers().a;
}

} // namespace

TEST(in_from_an_odd_port_reads_the_display) {
    // Swept across one 16-pixel group, because a single position proves less
    // than it looks: the answer depends on which T-state of the ULA's fetch
    // cycle the CPU samples on. Over a whole group both halves of that cycle
    // have to show up -- display bytes while the ULA is fetching, and the idle
    // 0xFF while it is not. Getting only display bytes would mean the idle
    // T-states were missing; only 0xFF would mean the fix does nothing.
    uint32_t display_bytes = 0;
    uint32_t idle = 0;
    for (uint32_t i = 0; i < 16; i++) {
        const uint8_t value = in_at(PAPER_DOT_BEGIN + i);
        if (value == BITMAP_0 || value == ATTR_0) {
            display_bytes++;
        } else if (value == FLOATING_BUS_IDLE) {
            idle++;
        } else {
            CHECK_EQ(int(value), int(FLOATING_BUS_IDLE)); // reports the odd one out
        }
    }
    CHECK(display_bytes > 0);
    CHECK(idle > 0);
}

TEST(in_from_an_even_port_still_reads_the_keyboard) {
    // The floating bus must not have swallowed the ULA's own port: an even
    // port is decoded, so it answers with the keyboard (no keys down, EAR
    // high) rather than with a display byte.
    Spectrum48K machine;
    for (uint16_t addr = BITMAP_BASE; addr < DISPLAY_FILE_END; addr++) {
        machine.memory.write(addr, BITMAP_0);
    }

    constexpr uint16_t PROGRAM = 0x8000;
    const uint8_t code[] = {0xDB, 0xFE, 0x18, 0xFE}; // IN A,(0xFE) / JR $
    machine.write_memory(PROGRAM, code, sizeof code);

    while (!beam_at(machine.ula, PAPER_LINE_BEGIN, PAPER_DOT_BEGIN)) {
        machine.clock();
    }
    Registers regs{};
    regs.pc = PROGRAM;
    regs.a = 0x7F; // half-row with SPACE on it
    machine.prime_cpu(regs);
    machine.step_instruction();
    // All five key bits high, and nothing of the display in it.
    CHECK_EQ(int(machine.registers().a & 0x1F), 0x1F);
    CHECK(machine.registers().a != BITMAP_0);
}

TEST(a_cobra_style_wait_loop_terminates) {
    // The actual failure this fixes: spin on IN A,(0xFF) until the value read
    // drops below a threshold. With a constant 0xFF this never leaves the
    // loop; with a floating bus it leaves as soon as the beam reaches a cell
    // whose bytes are low enough.
    Spectrum48K machine;
    // Attributes of 0x38 (white paper, black ink) all over, which is below
    // the 0x3F Cobra tests against, and a blank bitmap.
    for (uint16_t addr = ATTR_BASE; addr < DISPLAY_FILE_END; addr++) {
        machine.memory.write(addr, 0x38);
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
    machine.write_memory(PROGRAM, code, sizeof code);

    Registers regs{};
    regs.pc = PROGRAM;
    machine.prime_cpu(regs);

    // Two frames is far longer than the loop can legitimately need: the beam
    // crosses paper once per frame, so one pass is always enough.
    const uint16_t halt_at = PROGRAM + sizeof code - 1;
    bool escaped = false;
    for (uint32_t i = 0; i < 2 * HC_PER_FRAME && !escaped; i++) {
        machine.clock();
        escaped = machine.registers().pc > halt_at || machine.cpu.halted;
    }
    CHECK(escaped);
}

RUN_TESTS()
