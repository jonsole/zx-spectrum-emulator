// Interrupt acceptance: the CPU must push the address of the instruction it
// was ABOUT to execute, whatever it just finished and whenever INT arrives.
//
// Nothing tested this before, and nothing could have: ZEXALL never enables
// interrupts, and the differential harness against z80.h does not drive INT.
// The gap let a real bug through -- Aquaplane derailed after ~240 frames
// because an interrupt arriving just as a NOT-TAKEN conditional CALL finished
// pushed a corrupt return address.
//
// Expectations are calibrated rather than hand-written: each instruction is
// first run with no interrupt to learn where PC legitimately ends up, then
// re-run with INT asserted at every half-clock offset across it. The pushed
// word must be either that address (the instruction finished) or the
// instruction's own address (the interrupt beat its fetch). Nothing else is a
// legal return address.

#include "memory.h"
#include "test_main.h"
#include "z80.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM_BASE = 0x8000;
constexpr uint16_t STACK_TOP = 0xFF00;
/// IM1 sends the CPU to 0x0038; the word it pushed is what this test is about.
constexpr uint16_t IM1_VECTOR = 0x0038;
/// Where the conditional branches under test aim.
constexpr uint16_t BRANCH_TARGET = 0x1234;

struct Case {
    const char* name;
    std::vector<uint8_t> code;
    uint8_t flags; ///< F before the instruction runs, to pick taken/not-taken
};

std::string hex16(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "%04X", v);
    return buf;
}

/// Lays out the case, with a two-byte self-loop (JR $) parked at every address
/// execution can legitimately reach afterwards. That keeps the CPU at a known
/// address instead of running off through uninitialised memory, without using
/// HALT -- whose own interrupt semantics (push halt_addr+1) would muddy what
/// is being measured.
void build(const Case& c, FlatMemory& mem) {
    for (size_t i = 0; i < c.code.size(); i++) {
        mem.bytes[PROGRAM_BASE + i] = c.code[i];
    }
    const uint16_t landings[] = {uint16_t(PROGRAM_BASE + c.code.size()), BRANCH_TARGET,
                                 uint16_t(PROGRAM_BASE + 7)};
    for (uint16_t addr : landings) {
        mem.bytes[addr] = 0x18; // JR
        mem.bytes[addr + 1] = 0xFE; // -2, i.e. back to itself
    }
}

void reset_cpu(Z80& cpu, FlatMemory& mem, const Case& c) {
    Registers regs;
    regs.pc = PROGRAM_BASE;
    regs.sp = STACK_TOP;
    regs.f = c.flags;
    regs.iff1 = true;
    regs.iff2 = true;
    regs.im = 1;
    cpu.set_registers(regs, mem);
}

/// Where PC ends up with no interrupt in play -- the ground truth this case's
/// pushed address is checked against.
uint16_t settled_pc(const Case& c) {
    FlatMemory mem;
    build(c, mem);
    Z80 cpu;
    reset_cpu(cpu, mem, c);
    cpu.step_instruction(mem);
    return cpu.registers().pc;
}

/// Runs the case with INT asserted from `int_at` half-clocks in, and returns
/// the word pushed when the interrupt is taken. 0xFFFF if it never was.
uint16_t pushed_return_address(const Case& c, uint32_t int_at) {
    FlatMemory mem;
    build(c, mem);
    Z80 cpu;
    reset_cpu(cpu, mem, c);

    uint64_t pins = cpu.pins();
    for (uint32_t half = 0; half < 600; half++) {
        pins = half >= int_at ? assert_pins(pins, INT) : release_pins(pins, INT);
        pins = Z80::service_memory(mem, cpu.clock(pins));

        const Registers now = cpu.registers();
        if (now.pc == IM1_VECTOR && cpu.is_instruction_boundary()) {
            return uint16_t(mem.bytes[now.sp] | (mem.bytes[uint16_t(now.sp + 1)] << 8));
        }
    }
    return 0xFFFF;
}

} // namespace

TEST(interrupt_pushes_a_legal_return_address) {
    // The conditional pairs matter most: taken and not-taken run different
    // numbers of T-states through different generated steps, and it was the
    // not-taken path that was broken.
    const std::vector<Case> cases = {
        {"NOP", {0x00}, 0x00},
        {"LD A,n", {0x3E, 0x42}, 0x00},
        {"LD BC,nn", {0x01, 0x34, 0x12}, 0x00},
        // FLAG_Z set => NZ false => not taken. This is the Aquaplane case.
        {"CALL NZ,nn (not taken)", {0xC4, 0x34, 0x12}, 0x40},
        {"CALL NZ,nn (taken)", {0xC4, 0x34, 0x12}, 0x00},
        {"CALL Z,nn (not taken)", {0xCC, 0x34, 0x12}, 0x00},
        {"CALL Z,nn (taken)", {0xCC, 0x34, 0x12}, 0x40},
        {"CALL nn", {0xCD, 0x34, 0x12}, 0x00},
        {"JP NZ,nn (not taken)", {0xC2, 0x34, 0x12}, 0x40},
        {"JP NZ,nn (taken)", {0xC2, 0x34, 0x12}, 0x00},
        {"JR NZ,d (not taken)", {0x20, 0x05}, 0x40},
        {"JR NZ,d (taken)", {0x20, 0x05}, 0x00},
        {"RET NZ (not taken)", {0xC0}, 0x40},
        {"RET Z (not taken)", {0xC8}, 0x00},
        {"DJNZ d (not taken)", {0x10, 0x05}, 0x00},
        {"LD A,(nn)", {0x3A, 0x00, 0x90}, 0x00},
        {"INC (HL)", {0x34}, 0x00},
        {"LD (IX+d),n", {0xDD, 0x36, 0x02, 0x99}, 0x00},
        {"BIT 3,(IX+d)", {0xDD, 0xCB, 0x02, 0x5E}, 0x00},
        {"LDIR", {0xED, 0xB0}, 0x00},
    };

    for (const Case& c : cases) {
        const uint16_t settled = settled_pc(c);
        // Sweep INT's arrival across the whole instruction and past it, so
        // acceptance is exercised at every alignment -- including the one
        // straddling the instruction boundary, which is what broke.
        const uint32_t span = uint32_t(c.code.size() * 8 + 48);
        for (uint32_t int_at = 0; int_at < span; int_at++) {
            const uint16_t pushed = pushed_return_address(c, int_at);
            if (pushed == 0xFFFF) {
                continue; // not taken at this alignment; nothing to check
            }
            const bool legal = pushed == settled || pushed == PROGRAM_BASE;
            const std::string what = std::string(c.name) + ", INT at half-clock "
                                     + std::to_string(int_at) + ": pushed 0x" + hex16(pushed)
                                     + ", legal values are 0x" + hex16(settled) + " or 0x"
                                     + hex16(PROGRAM_BASE);
            CHECK_EQ(legal ? what : what + "  <-- ILLEGAL", what);
        }
    }
}

RUN_TESTS()
