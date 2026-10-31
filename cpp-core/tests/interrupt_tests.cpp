// Interrupts on the bare Z80: the INT acknowledge in IM 0, 1 and 2, and the
// NMI -- their T-states, their pins and where they leave the machine.
//
// Every number is the datasheet's, worked out here, not read off the core:
// the acknowledge is an M1 cycle with two wait states (T1, T2, TW, TW, T3, T4:
// 6 T-states), with PC on the bus and M1 from T1, IORQ from the first wait
// state and the device's byte taken at T3. IM 1 adds a seventh T-state and
// two 3 T-state pushes -- 13; IM 2 then reads a 2-byte vector -- 19; IM 0
// runs the byte as an instruction, so RST p takes 6 + 7 = 13. An NMI is a
// 5 T-state dummy opcode fetch and the two pushes -- 11 -- to 0x0066.
//
// The core is retro-spectrum's oracle: its Verilog Z80 is run against this
// one in lockstep, so these pins matter as much as the totals.

#include "memory.h"
#include "pins.h"
#include "test_main.h"
#include "z80.h"

#include <cstdint>
#include <memory>

using namespace zx;

namespace {

constexpr uint16_t CODE = 0x8000;
constexpr uint16_t STACK = 0x9000;

/// A Z80 on 64K of RAM, with INT and NMI driven as asked and a device that
/// answers the acknowledge with `ack`.
struct Bench {
    FlatMemory mem;
    Z80 cpu;
    uint64_t pins = 0;
    bool int_line = false;
    bool nmi_line = false;
    uint8_t ack = 0xFF;

    explicit Bench(const Registers& r) {
        cpu.set_registers(r, mem);
        pins = cpu.pins();
    }

    /// One half-clock: the CPU's, then the bus's answer to it.
    void half() {
        uint64_t in = release_pins(pins, INT | NMI);
        if (int_line) {
            in = assert_pins(in, INT);
        }
        if (nmi_line) {
            in = assert_pins(in, NMI);
        }
        pins = cpu.clock(in);
        if (asserted(pins, MREQ) && asserted(pins, RD)) {
            pins = set_data(pins, mem.read(get_addr(pins)));
        } else if (asserted(pins, MREQ) && asserted(pins, WR)) {
            mem.write(get_addr(pins), get_data(pins));
        } else if (asserted(pins, IORQ) && asserted(pins, M1)) {
            pins = set_data(pins, ack);
        }
    }

    /// Runs to the next instruction boundary; returns the T-states taken. An
/// interrupt has no boundary of its own: it is accepted in the last half-state
/// of an instruction, its T1H, and runs as part of that instruction's step.
    uint32_t instruction() {
        uint32_t halves = 0;
        do {
            half();
            halves++;
        } while (!cpu.is_instruction_boundary());
        return halves / 2;
    }

    uint16_t stacked() const {
        return uint16_t(mem.bytes[STACK - 2] | (mem.bytes[STACK - 1] << 8));
    }
};

/// NOPs at CODE, interrupts enabled in mode `im`, SP at STACK.
Registers start(uint8_t im) {
    Registers r;
    r.pc = CODE;
    r.sp = STACK;
    r.im = im;
    r.iff1 = true;
    r.iff2 = true;
    return r;
}

} // namespace

TEST(im1_takes_13_and_goes_to_0x38) {
    auto b = std::make_unique<Bench>(start(1));
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 13u); // the NOP, then the acknowledge
    CHECK_EQ(get_addr(b->pins), uint16_t(0x0038)); // the next fetch's T1H
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
    CHECK(!b->cpu.regs.iff1);
    CHECK(!b->cpu.regs.iff2);
}

TEST(im2_takes_19_through_the_vector) {
    auto b = std::make_unique<Bench>([] {
        Registers r = start(2);
        r.i = 0x90;
        return r;
    }());
    b->ack = 0x20;
    b->mem.bytes[0x9020] = 0x34;
    b->mem.bytes[0x9021] = 0x12;
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 19u);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x1234));
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
}

TEST(im0_runs_rst_from_the_bus_in_13) {
    auto b = std::make_unique<Bench>(start(0));
    b->ack = 0xEF; // RST 28h
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 13u);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x0028));
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
}

TEST(im0_runs_any_single_byte_instruction) {
    // INC A on the bus: the acknowledge is its fetch, 6 T-states, and the
    // program carries on at 0x8001 with A one higher and INT masked.
    Registers r = start(0);
    r.a = 5;
    auto b = std::make_unique<Bench>(r);
    b->ack = 0x3C; // INC A
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 6u);
    CHECK_EQ(int(b->cpu.regs.a), 6);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
    CHECK(!b->cpu.regs.iff1);
}

TEST(the_acknowledge_drives_the_datasheets_pins) {
    // Half-clock by half-clock from the acknowledge's T1H (the NOP's last
    // half-state): T1 PC and M1 without MREQ; IORQ from TW1's low half; at
    // T3H M1 and IORQ gone and the refresh address out with RFSH; MREQ at
    // T3L; MREQ gone at T4L with RFSH lasting to its end.
    auto b = std::make_unique<Bench>(start(1));
    b->int_line = true;
    for (int i = 0; i < 7; i++) {
        b->half(); // the NOP's first seven half-states
    }
    b->half(); // its last: begin_fetch, the acknowledge's T1H
    CHECK(asserted(b->pins, M1));
    CHECK(!asserted(b->pins, MREQ | IORQ));
    CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
    const uint64_t expected_iorq[] = {0, 0, 0, 0, 1, 1, 1}; // T1L T2H T2L TW1H TW1L TW2H TW2L
    for (uint64_t want : expected_iorq) {
        b->half();
        CHECK(asserted(b->pins, M1));
        CHECK(!asserted(b->pins, MREQ));
        CHECK_EQ(asserted(b->pins, IORQ) ? 1u : 0u, uint32_t(want));
        CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
    }
    b->half(); // T3H
    CHECK(!asserted(b->pins, M1 | IORQ | MREQ));
    CHECK(asserted(b->pins, RFSH));
    b->half(); // T3L
    CHECK(asserted(b->pins, MREQ | RFSH));
    b->half(); // T4H
    CHECK(asserted(b->pins, MREQ | RFSH));
    b->half(); // T4L
    CHECK(!asserted(b->pins, MREQ));
    CHECK(asserted(b->pins, RFSH));
    b->half(); // T5H, the seventh T-state
    CHECK(!asserted(b->pins, RFSH));
}

TEST(nmi_takes_11_and_goes_to_0x66) {
    // IFF2 keeps IFF1 for RETN; IFF1 is cleared. R counts the NOP's fetch and
    // the NMI's dummy one.
    auto b = std::make_unique<Bench>(start(1));
    b->nmi_line = true;
    CHECK_EQ(b->instruction(), 4u + 11u);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x0066));
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
    CHECK(!b->cpu.regs.iff1);
    CHECK(b->cpu.regs.iff2);
    CHECK_EQ(int(b->cpu.regs.r & 0x7F), 2);
}

TEST(nmi_dummy_fetch_reads_pc_and_refreshes) {
    auto b = std::make_unique<Bench>(start(1));
    b->nmi_line = true;
    for (int i = 0; i < 8; i++) {
        b->half(); // the NOP; its last half-state is the dummy fetch's T1H
    }
    CHECK(asserted(b->pins, M1));
    CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
    b->half(); // T1L
    CHECK(asserted(b->pins, M1 | MREQ | RD));
    b->half(); // T2H
    b->half(); // T2L
    b->half(); // T3H
    CHECK(!asserted(b->pins, M1 | RD));
    CHECK(asserted(b->pins, RFSH));
}

TEST(nmi_outranks_int) {
    auto b = std::make_unique<Bench>(start(1));
    b->int_line = true;
    b->nmi_line = true;
    CHECK_EQ(b->instruction(), 4u + 11u);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x0066));
}

TEST(nmi_is_edge_triggered) {
    // Held down for many instructions, it is taken once. Interrupts are
    // disabled so only the NMI can be counted.
    Registers r = start(1);
    r.iff1 = false;
    r.iff2 = false;
    auto b = std::make_unique<Bench>(r);
    b->nmi_line = true;
    const uint64_t before = b->cpu.interrupt_count;
    for (int i = 0; i < 20; i++) {
        b->instruction();
    }
    CHECK_EQ(b->cpu.interrupt_count - before, uint64_t(1));
    // Let go and press again: taken again.
    b->nmi_line = false;
    b->instruction();
    b->nmi_line = true;
    b->instruction();
    b->instruction();
    CHECK_EQ(b->cpu.interrupt_count - before, uint64_t(2));
}

TEST(nmi_leaves_halt_with_the_address_after_it) {
    // HALT at 0x8000: the NMI's return address is 0x8001.
    auto b = std::make_unique<Bench>(start(1));
    b->mem.bytes[CODE] = 0x76;
    b->instruction(); // HALT
    b->instruction(); // a halted NOP
    b->nmi_line = true;
    CHECK_EQ(b->instruction(), 4u + 11u); // a halted NOP, then the NMI
    CHECK(!b->cpu.halted);
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
}

RUN_TESTS()
