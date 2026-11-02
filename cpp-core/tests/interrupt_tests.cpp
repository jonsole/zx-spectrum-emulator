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

#include "flags.h"
#include "memory.h"
#include "pins.h"
#include "test_main.h"
#include "z80.h"

#include <cstdint>
#include <memory>
#include <vector>

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
    /// IM 0's further bytes, which the device answers memory reads at PC
    /// with while there are any; memory answers once they run out.
    std::vector<uint8_t> device;
    size_t device_next = 0;
    /// The addresses those reads were made at, and whether each was an M1.
    std::vector<uint16_t> device_addr;
    std::vector<bool> device_m1;
    uint8_t device_byte = 0;
    bool device_reading = false;
    /// The device answers only once it has been acknowledged.
    bool acked = false;

    explicit Bench(const Registers& r) {
        cpu.set_registers(r, mem);
        pins = cpu.pins();
    }

    /// One half-clock: the CPU's, then the bus's answer to it.
    void half() {
        const uint64_t previous = pins;
        uint64_t in = release_pins(pins, INT | NMI);
        if (int_line) {
            in = assert_pins(in, INT);
        }
        if (nmi_line) {
            in = assert_pins(in, NMI);
        }
        pins = cpu.clock(in);
        if (asserted(pins, MREQ) && asserted(pins, RD)) {
            // A read lasts several half-clocks. While the device has bytes
            // left it answers every read, taking its next byte at each read's
            // first half-clock -- when MREQ and RD come down together.
            const bool first = !(asserted(previous, MREQ) && asserted(previous, RD));
            if (first && acked && device_next < device.size()) {
                device_addr.push_back(get_addr(pins));
                device_m1.push_back(asserted(pins, M1));
                device_byte = device[device_next++];
                device_reading = true;
            } else if (first) {
                device_reading = false;
            }
            pins = set_data(pins, device_reading ? device_byte : mem.read(get_addr(pins)));
        } else if (asserted(pins, MREQ) && asserted(pins, WR)) {
            mem.write(get_addr(pins), get_data(pins));
        } else if (asserted(pins, IORQ) && asserted(pins, M1)) {
            pins = set_data(pins, ack);
            acked = true;
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

TEST(registers_set_over_a_halt_run_from_their_pc) {
    // A snapshot loaded, or registers written, while the CPU sits in a HALT:
    // the new PC is fetched from, so the CPU is not halted any more. Left
    // halted, it reported a PC one too high and the interrupt's undoing of
    // HALT's decrement returned one byte past the new PC -- 0x8102 here.
    auto b = std::make_unique<Bench>(start(1));
    b->mem.bytes[CODE] = 0x76;
    b->instruction(); // HALT
    b->instruction(); // a halted NOP
    CHECK(b->cpu.halted);
    Registers r = start(1);
    r.pc = CODE + 0x100; // NOPs
    b->cpu.set_registers(r, b->mem);
    b->pins = b->cpu.pins();
    CHECK(!b->cpu.halted);
    CHECK_EQ(b->cpu.registers().pc, uint16_t(CODE + 0x100));
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 13u); // the NOP at 0x8100, then IM 1
    CHECK_EQ(b->stacked(), uint16_t(CODE + 0x101));
}

TEST(im0_call_reads_its_operand_at_the_unchanged_pc) {
    // CALL 1234h from the device: the acknowledge (6) is its fetch; the two
    // operand bytes come by ordinary memory reads at PC, which stays at
    // 0x8001, then CALL's internal T-state and two pushes: 6 + 3 + 3 + 1 +
    // 3 + 3 = 19. The interrupted PC is what is pushed.
    auto b = std::make_unique<Bench>(start(0));
    b->ack = 0xCD;
    b->device = {0x34, 0x12};
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 19u);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x1234));
    CHECK_EQ(b->stacked(), uint16_t(0x8001));
    CHECK(b->device_addr == std::vector<uint16_t>({0x8001, 0x8001}));
    CHECK(b->device_m1 == std::vector<bool>({false, false}));
}

TEST(im0_ld_hl_nn_carries_on_where_it_was_interrupted) {
    // LD HL,nn: 6 + 3 + 3 = 12. Afterwards PC moves again, from 0x8001.
    auto b = std::make_unique<Bench>(start(0));
    b->ack = 0x21;
    b->device = {0xCD, 0xAB};
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 12u);
    CHECK_EQ(int(b->cpu.regs.hl()), 0xABCD);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
}

TEST(im0_prefix_fetches_its_next_opcode_at_the_unchanged_pc) {
    // CB C7, SET 0,A: the acknowledge brings CB, and the CPU fetches the
    // next opcode as it always does, an M1 cycle with refresh -- at 0x8001,
    // PC not moving. 6 + 4 = 10. R counts the NOP, the acknowledge and that
    // fetch.
    auto b = std::make_unique<Bench>(start(0));
    b->ack = 0xCB;
    b->device = {0xC7};
    b->int_line = true;
    CHECK_EQ(b->instruction(), 4u + 10u);
    CHECK_EQ(int(b->cpu.regs.a), 1);
    CHECK(b->device_addr == std::vector<uint16_t>({0x8001}));
    CHECK(b->device_m1 == std::vector<bool>({true}));
    CHECK_EQ(int(b->cpu.regs.r & 0x7F), 3);
    CHECK_EQ(get_addr(b->pins), uint16_t(0x8001));
}

TEST(a_halted_cpu_fetches_from_the_byte_after_the_halt) {
    // HALT at 0x8000 and INC A after it, interrupts off. Once halted, every
    // M1 puts 0x8001 on the bus -- not the HALT's own 0x8000 -- reads the
    // byte there and ignores it: A stays put, PC stays at 0x8001, and R
    // counts one a fetch, 4 T-states each. Woodmass's HALT2INT shows it on a
    // real 48K: a HALT at 0x7FFF is timed by the uncontended 0x8000.
    Registers r = start(1);
    r.iff1 = false;
    r.iff2 = false;
    r.a = 5;
    r.r = 0;
    auto b = std::make_unique<Bench>(r);
    b->mem.bytes[CODE] = 0x76;     // HALT
    b->mem.bytes[CODE + 1] = 0x3C; // INC A, never to run
    CHECK_EQ(b->instruction(), 4u); // the HALT itself
    for (int fetch = 0; fetch < 3; fetch++) {
        for (int half = 0; half < 8; half++) {
            b->half();
            if (asserted(b->pins, M1)) {
                CHECK_EQ(get_addr(b->pins), uint16_t(CODE + 1));
            }
        }
    }
    CHECK(b->cpu.halted);
    CHECK_EQ(int(b->cpu.regs.a), 5);
    CHECK_EQ(b->cpu.registers().pc, uint16_t(CODE + 1));
    CHECK_EQ(int(b->cpu.regs.r & 0x7F), 4); // the HALT's fetch and three more
    // An interrupt then returns to the byte after the HALT.
    b->cpu.regs.iff1 = true;
    b->int_line = true;
    b->instruction();
    CHECK_EQ(b->stacked(), uint16_t(CODE + 1));
}

namespace {

/// EI, then LD A,I or LD A,R (ED 57 / ED 5F) with IFF2 set by the EI, with
/// INT held from the start: the EI keeps it off for one instruction, so it
/// is taken straight after the load. Returns F as the acknowledge leaves it,
/// and where the load said it should return.
uint8_t f_after_ld_a_ir(uint8_t second_byte, bool interrupt, uint16_t& returns_to) {
    Registers r = start(1);
    r.iff1 = false;
    r.iff2 = false;
    r.i = 0x80; // S set, Z clear, whichever register is read
    r.r = 0x80;
    auto b = std::make_unique<Bench>(r);
    b->mem.bytes[CODE] = 0xFB; // EI
    b->mem.bytes[CODE + 1] = 0xED;
    b->mem.bytes[CODE + 2] = second_byte;
    b->int_line = interrupt;
    b->instruction(); // EI
    b->instruction(); // the load, and the acknowledge if INT is down
    returns_to = b->stacked();
    return b->cpu.regs.f;
}

} // namespace

TEST(nmos_ld_a_i_and_ld_a_r_lose_pv_to_an_interrupt_taken_at_once) {
    // P/V is IFF2, 1 after the EI -- unless the interrupt is accepted at the
    // very next fetch, when the NMOS Z80 leaves it 0 (the CMOS part fixed
    // it). Woodmass's IFF2 Bug test shows the 0 on a real 48K for the loads
    // that end at the last T-states of a frame. The interrupt itself clears
    // IFF2 too, so what tells the two apart is the flag the load left.
    for (uint8_t op : {uint8_t(0x57), uint8_t(0x5F)}) {
        uint16_t returns_to = 0;
        const uint8_t quiet = f_after_ld_a_ir(op, false, returns_to);
        CHECK((quiet & FLAG_PV) != 0);
        const uint8_t taken = f_after_ld_a_ir(op, true, returns_to);
        CHECK_EQ(returns_to, uint16_t(CODE + 3)); // taken after the load
        CHECK((taken & FLAG_PV) == 0);
        CHECK((taken & FLAG_S) != 0); // the rest of the load's flags stand
    }
}

RUN_TESTS()
