// Flags 5 and 3 where they come from neither A nor the result: SCF and CCF,
// which read Q, and the block instructions as they repeat, which take them
// from the instruction's own address. ZEXALL masks both, so nothing else here
// checks them; the test collection's Z80 tests (Rak's z80test, Helcmanovsky's
// block flags test) do on a real machine.
//
// The rules, from which every expected value below is worked out by hand:
//   SCF/CCF: flags 5 and 3 are bits 5 and 3 of (Q ^ F) | A, where Q is the F
//     the previous instruction left if it computed flags, else 0 (Rak, 2012).
//   LDIR/LDDR/CPIR/CPDR going round again: flags 5 and 3 are bits 13 and 11
//     of the instruction's address (Banks, 2018).
//   INIR/INDR/OTIR/OTDR going round again: the same, and H and P/V change as
//     Banks's paper gives (here as redcode's Z80 library implements it).
//
// And, at the end, that INIR and OTIR move every byte: the last pass of INIR
// once skipped its write, which no flag shows.

#include "flags.h"
#include "memory.h"
#include "pins.h"
#include "test_main.h"
#include "z80.h"

#include <cstdint>
#include <initializer_list>
#include <vector>

using namespace zx;

namespace {

/// A Z80 on 64K of RAM whose ports all answer `port_byte`.
struct Bench {
    FlatMemory mem;
    Z80 cpu;
    uint64_t pins = 0;
    uint8_t port_byte = 0xFF;
    /// Bytes written to ports, one per I/O write cycle.
    std::vector<uint8_t> port_writes;

    void start(const Registers& r) {
        cpu.set_registers(r, mem);
        pins = cpu.pins();
    }

    void put(uint16_t addr, std::initializer_list<uint8_t> bytes) {
        for (uint8_t b : bytes) {
            mem.bytes[addr++] = b;
        }
    }

    /// Runs to the next instruction boundary; returns the T-states taken.
    uint32_t instruction() {
        bool writing = false;
        uint32_t halves = 0;
        do {
            pins = cpu.clock(pins);
            halves++;
            if (asserted(pins, MREQ) && asserted(pins, RD)) {
                pins = set_data(pins, mem.read(get_addr(pins)));
            } else if (asserted(pins, MREQ) && asserted(pins, WR)) {
                mem.write(get_addr(pins), get_data(pins));
            } else if (asserted(pins, IORQ) && asserted(pins, RD)) {
                pins = set_data(pins, port_byte);
            } else if (asserted(pins, IORQ) && asserted(pins, WR) && !writing) {
                port_writes.push_back(get_data(pins));
            }
            writing = asserted(pins, IORQ) && asserted(pins, WR);
        } while (!cpu.is_instruction_boundary());
        return halves / 2;
    }

    uint8_t f() const { return cpu.registers().f; }
};

Registers at(uint16_t pc) {
    Registers r;
    r.pc = pc;
    r.sp = 0xF000;
    r.a = 0;
    r.f = 0;
    return r;
}

} // namespace

TEST(scf_after_a_flag_instruction_takes_5_and_3_from_a) {
    // INC B, 0x27 -> 0x28: F = 0x28 (5 and 3 from the result, nothing else),
    // and Q = F. SCF: (Q ^ F) | A = 0, so 5 and 3 clear; C set: 0x01.
    Bench b;
    Registers r = at(0x8000);
    r.b = 0x27;
    b.start(r);
    b.put(0x8000, {0x04, 0x37}); // INC B; SCF
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x28));
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x01));
}

TEST(scf_after_an_instruction_that_leaves_the_flags_takes_them_from_f_too) {
    // The same, with a NOP between: Q = 0, so (0 ^ 0x28) | 0 = 0x28: 0x29.
    Bench b;
    Registers r = at(0x8000);
    r.b = 0x27;
    b.start(r);
    b.put(0x8000, {0x04, 0x00, 0x37}); // INC B; NOP; SCF
    b.instruction();
    b.instruction();
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x29));
}

TEST(pop_af_leaves_q_clear_for_ccf) {
    // POP AF loads F = 0x28, A = 0, and is no flag instruction: Q = 0. CCF:
    // 5 and 3 = 0x28; H = the old C, 0; C = not the old C, 1: 0x29.
    Bench b;
    Registers r = at(0x8000);
    r.sp = 0x9000;
    b.start(r);
    b.put(0x9000, {0x28, 0x00}); // F, then A
    b.put(0x8000, {0xF1, 0x3F}); // POP AF; CCF
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x28));
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x29));
}

// The block tests put the instruction at 0x27FE: bit 13 of that is set and
// bit 11 clear, so going round gives flag 5 alone. Its address plus 2, 0x2800,
// has both, which is what taking them from PC at the wrong moment would give.
constexpr uint16_t BLOCK_AT = 0x27FE;

TEST(ldir_going_round_takes_5_and_3_from_its_address) {
    // A = 0 and a 0 byte moved: the pass's own 5 and 3 (bits 1 and 3 of
    // A + byte) are clear. BC 2 -> 1: P/V set. Going round: 0x20 | 0x04.
    // The last pass, BC 1 -> 0, does not go round: P/V clear, 0x00.
    Bench b;
    Registers r = at(BLOCK_AT);
    r.set_hl(0x9000);
    r.set_de(0xA000);
    r.set_bc(2);
    b.start(r);
    b.put(BLOCK_AT, {0xED, 0xB0});
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x24));
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x00));
    CHECK_EQ(b.cpu.registers().pc, uint16_t(BLOCK_AT + 2));
}

TEST(cpir_going_round_takes_5_and_3_from_its_address) {
    // A = 1 against a 0 byte: 1 - 0 = 1, no half borrow, so the pass's 5 and
    // 3 (bits 1 and 3 of it) are clear. N set; BC 2 -> 1, P/V set. Going
    // round: 0x20 | 0x04 | 0x02.
    Bench b;
    Registers r = at(BLOCK_AT);
    r.a = 1;
    r.set_hl(0x9000);
    r.set_bc(2);
    b.start(r);
    b.put(BLOCK_AT, {0xED, 0xB1});
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x26));
}

TEST(otir_going_round_without_a_carry) {
    // 0x80 out: N set. B 2 -> 1, L 0 -> 1; T = 0x80 + 1, no carry. p = (T & 7)
    // ^ B = 0; going round, P/V is the parity of p ^ (B & 7) = 1, odd: clear.
    // 0x20 | N = 0x22. (OUTI alone would give P/V from p = 0, set: 0x06.)
    Bench b;
    Registers r = at(BLOCK_AT);
    r.set_hl(0x9000);
    r.set_bc(0x0200);
    b.start(r);
    b.put(0x9000, {0x80});
    b.put(BLOCK_AT, {0xED, 0xB3});
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x22));
}

TEST(otir_going_round_with_a_carry_and_n) {
    // 0xFF out: N set. B 0x11 -> 0x10, L 0 -> 1: T = 0x100, H and C set.
    // Carry and N: H = (B & 0x0F) == 0, set; p = (T & 7) ^ B = 0x10, P/V the
    // parity of p ^ ((B - 1) & 7) = 0x17, four bits, even: set. S from B, clear.
    // 0x20 | H | P/V | N | C = 0x37. (OUTI alone: H | N | C, and P/V from
    // p = 0x10, odd: 0x13.)
    Bench b;
    Registers r = at(BLOCK_AT);
    r.set_hl(0x9000);
    r.set_bc(0x1100);
    b.start(r);
    b.put(0x9000, {0xFF});
    b.put(BLOCK_AT, {0xED, 0xB3});
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x37));
}

TEST(inir_going_round_without_a_carry) {
    // 0x7F in from port C = 0: N clear. B 2 -> 1; T = 0x7F + (C + 1) = 0x80,
    // no carry. p = (T & 7) ^ B = 1; going round, P/V is the parity of
    // p ^ (B & 7) = 0, even: set. 0x20 | P/V = 0x24.
    Bench b;
    Registers r = at(BLOCK_AT);
    r.set_hl(0x9000);
    r.set_bc(0x0200);
    b.start(r);
    b.port_byte = 0x7F;
    b.put(BLOCK_AT, {0xED, 0xB2});
    b.instruction();
    CHECK_EQ(b.f(), uint8_t(0x24));
}

TEST(inir_moves_every_byte_and_ends_with_b_0) {
    // Rak's z80test INIR case: B = 3, C = 0xFE, HL = 0x880C, port 0xBF. Three
    // passes write 0xBF at 0x880C, 0x880D and 0x880E; B ends 0, HL 0x880F,
    // and the instruction after it runs. A pass that goes round is 21
    // T-states, the last 16 -- the datasheet's, and Butler's test 32 checks
    // them on a real 48K.
    Bench b;
    Registers r = at(0x8000);
    r.set_bc(0x03FE);
    r.set_hl(0x880C);
    b.start(r);
    b.port_byte = 0xBF;
    b.put(0x880C, {0x34, 0x12, 0x00, 0x00});
    b.put(0x8000, {0xED, 0xB2, 0x00});
    CHECK_EQ(b.instruction(), uint32_t(21));
    CHECK_EQ(b.instruction(), uint32_t(21));
    CHECK_EQ(b.instruction(), uint32_t(16));
    const Registers got = b.cpu.registers();
    CHECK_EQ(got.b, uint8_t(0));
    CHECK_EQ(got.c, uint8_t(0xFE));
    CHECK_EQ(got.hl(), uint16_t(0x880F));
    CHECK_EQ(got.pc, uint16_t(0x8002));
    CHECK_EQ(b.mem.bytes[0x880C], uint8_t(0xBF));
    CHECK_EQ(b.mem.bytes[0x880D], uint8_t(0xBF));
    CHECK_EQ(b.mem.bytes[0x880E], uint8_t(0xBF));
    CHECK_EQ(b.mem.bytes[0x880F], uint8_t(0x00));
}

TEST(otir_sends_every_byte) {
    // B = 2 from 0x9000: two passes, two OUTs, the last as well as the first.
    Bench b;
    Registers r = at(0x8000);
    r.set_bc(0x02FE);
    r.set_hl(0x9000);
    b.start(r);
    b.put(0x9000, {0x11, 0x22});
    b.put(0x8000, {0xED, 0xB3, 0x00});
    CHECK_EQ(b.instruction(), uint32_t(21));
    CHECK_EQ(b.instruction(), uint32_t(16));
    CHECK_EQ(b.port_writes.size(), size_t(2));
    CHECK_EQ(b.cpu.registers().pc, uint16_t(0x8002));
    if (b.port_writes.size() == 2) {
        CHECK_EQ(b.port_writes[0], uint8_t(0x11));
        CHECK_EQ(b.port_writes[1], uint8_t(0x22));
    }
}

RUN_TESTS()
