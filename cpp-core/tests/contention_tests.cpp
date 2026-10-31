// Memory and I/O contention: how long instructions take when the ULA holds the
// CPU's clock (docs/contention.md).
//
// Every expected count here is worked out by hand from that document -- the
// contention start, the 6,5,4,3,2,1,0,0 pattern, and the two rules for when
// the ULA checks -- and from the instruction's documented uncontended timing,
// never read off this code's own output. The working is beside each one.
//
// Each test places an instruction's opcode fetch so its T1 begins at a chosen
// frame T-state, runs that one instruction, and counts the T-states it took.
// The code sits at 0x8000, which is never contended, so only the accesses the
// test is about can be held.

#include "memory.h"
#include "spectrum.h"
#include "test_main.h"
#include "ula.h"

#include <cstdint>
#include <memory>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t CODE = 0x8000;

/// 48K: the first contended T-state, and a line.
constexpr uint32_t C48 = 14335;
constexpr uint32_t LINE48 = 224;
/// 128K: the same.
constexpr uint32_t C128 = 14362;

/// Runs `code` at `at` (CODE unless given) as one instruction whose opcode
/// fetch begins its T1 at frame T-state `m1`, with registers `r` (PC is set
/// here), and returns the T-states it took.
uint32_t tstates_at(Spectrum& m, uint32_t m1, Registers r, const std::vector<uint8_t>& code,
                    uint16_t at = CODE) {
    // The CPU primes T1H of its fetch on the half-clock the ULA is at, so
    // the ULA is brought to the even half-clock that starts T-state m1.
    while (m.ula.frame_hc() != m1 * HC_PER_TSTATE) {
        m.clock();
    }
    m.write_memory(at, code.data(), code.size());
    r.pc = at;
    m.set_registers(r);
    const uint64_t before = m.global_hc();
    m.step_instruction();
    return uint32_t((m.global_hc() - before) / HC_PER_TSTATE);
}

/// A fresh machine of the given model, on the heap: a Spectrum holds all its
/// memory inline, and a test with several on the stack overflows it.
std::unique_ptr<Spectrum> machine(Model model = Model::Spectrum48) {
    auto m = std::make_unique<Spectrum>();
    if (model != Model::Spectrum48) {
        m->set_model(model);
    }
    return m;
}

Registers with_hl(uint16_t hl) {
    Registers r;
    r.set_hl(hl);
    return r;
}

} // namespace

// ---- memory: rule 4.1, a memory cycle checked at its T1 -------------------

TEST(ld_a_hl_held_six_at_the_start_of_a_group) {
    // LD A,(HL) is pc:4, hl:3 = 7. Fetch at 14331: the read's T1 at 14335 is
    // the group's first T-state, held 6 -> 13.
    auto m = machine();
    CHECK_EQ(tstates_at(*m, C48 - 4, with_hl(0x4000), {0x7E}), 13u);
}

TEST(ld_a_hl_held_four_two_into_a_group) {
    // The read's T1 at 14337 is G + 2, held 4 -> 11.
    auto m = machine();
    CHECK_EQ(tstates_at(*m, C48 - 2, with_hl(0x4000), {0x7E}), 11u);
}

TEST(each_position_of_a_group) {
    // The read's T1 at G + k is held 6 - k for k = 0..5, and not at all for
    // k = 6 and 7: 7 + the pattern.
    const uint32_t expected[8] = {13, 12, 11, 10, 9, 8, 7, 7};
    for (uint32_t k = 0; k < 8; k++) {
        auto m = machine();
        CHECK_EQ(tstates_at(*m, C48 + k - 4, with_hl(0x4000), {0x7E}), expected[k]);
    }
}

TEST(uncontended_memory_is_never_held) {
    // HL in 0x8000-0xFFFF, or the ROM: 7, whatever the T-state.
    auto m = machine();
    CHECK_EQ(tstates_at(*m, C48 - 4, with_hl(0x8000), {0x7E}), 7u);
    auto n = machine();
    CHECK_EQ(tstates_at(*n, C48 - 4, with_hl(0x1000), {0x7E}), 7u);
}

TEST(contention_off_holds_nothing) {
    auto m = machine();
    m->set_contention(false);
    CHECK_EQ(tstates_at(*m, C48 - 4, with_hl(0x4000), {0x7E}), 7u);
}

// ---- the window's edges ----------------------------------------------------

TEST(window_edges) {
    // Line 191's last group starts at 14335 + 191 x 224 + 120 = 57239.
    const uint32_t last_group = C48 + 191 * LINE48 + 120;
    auto a = machine();
    CHECK_EQ(tstates_at(*a, last_group - 4, with_hl(0x4000), {0x7E}), 13u);
    // Its last T-state, G + 7: not held.
    auto b = machine();
    CHECK_EQ(tstates_at(*b, last_group + 7 - 4, with_hl(0x4000), {0x7E}), 7u);
    // Where a seventeenth group would start, 57247: past the paper, not held.
    auto c = machine();
    CHECK_EQ(tstates_at(*c, last_group + 8 - 4, with_hl(0x4000), {0x7E}), 7u);
    // Line 0's right border, where its seventeenth group would be.
    auto d = machine();
    CHECK_EQ(tstates_at(*d, C48 + 128 - 4, with_hl(0x4000), {0x7E}), 7u);
    // Eight T-states before the first group, where a group before it would
    // start: the top border, not held.
    auto e = machine();
    CHECK_EQ(tstates_at(*e, C48 - 8 - 4, with_hl(0x4000), {0x7E}), 7u);
    // Line 192 would start at 14335 + 192 x 224 = 57343: not held.
    auto f = machine();
    CHECK_EQ(tstates_at(*f, C48 + 192 * LINE48 - 4, with_hl(0x4000), {0x7E}), 7u);
}

// ---- internal T-states: rule 4.1 with no memory cycle ----------------------

TEST(inc_hl_internal_tstate_is_held) {
    // INC (HL) is pc:4, hl:3, hl:1, hl(write):3 = 11. Fetch at 14337; the
    // read's T1 at 14341 is G + 6, not held; it runs 14341-14343. The
    // internal T-state at 14344, with HL still on the bus, is the next
    // group's G + 1: held 5, to 14349. The write's T1 at 14350 is G + 7, not
    // held. 11 + 5 = 16.
    auto m = machine();
    CHECK_EQ(tstates_at(*m, C48 + 2, with_hl(0x4000), {0x34}), 16u);
}

TEST(ld_a_i_is_held_on_ir) {
    // LD A,I is pc:4, pc+1:4, ir:1 = 9. Fetches at 14327 and 14331; the
    // internal T-state at 14335 has IR on the bus, and I = 0x40 makes that
    // contended: G + 0, held 6. 9 + 6 = 15.
    auto m = machine();
    Registers r;
    r.i = 0x40;
    CHECK_EQ(tstates_at(*m, C48 - 8, r, {0xED, 0x57}), 15u);
}

TEST(ld_a_i_with_i_uncontended) {
    auto m = machine();
    Registers r;
    r.i = 0x3F;
    CHECK_EQ(tstates_at(*m, C48 - 8, r, {0xED, 0x57}), 9u);
}

// ---- I/O: rules 4.1 and 4.2 ------------------------------------------------

TEST(io_odd_port_uncontended_high_byte) {
    // IN A,(0xFF) with A = 0: port 0x00FF, N:4. pc:4, pc+1:3, then the I/O
    // cycle at 14335, not checked at all. 11.
    auto m = machine();
    Registers r;
    r.a = 0x00;
    CHECK_EQ(tstates_at(*m, C48 - 7, r, {0xDB, 0xFF}), 11u);
}

TEST(io_ula_port_uncontended_high_byte) {
    // OUT (0xFE),A with A = 0x07: port 0x07FE, N:1, C:3. Fetch and operand
    // 14328-14334. T1 at 14335 is not checked (0x07FE is not contended); T2
    // at 14336 is the ULA's port check at G + 1, held 5, so T2, TW and T3 run
    // 14341-14343. 11 + 5 = 16.
    auto m = machine();
    Registers r;
    r.a = 0x07;
    CHECK_EQ(tstates_at(*m, C48 - 7, r, {0xD3, 0xFE}), 16u);
}

TEST(io_ula_port_contended_high_byte) {
    // IN A,(0xFE) with A = 0x40: port 0x40FE, C:1, C:3. T1 at 14335 is an
    // address check at G + 0, held 6, to 14341. T2 at 14342 is the ULA's
    // port check at G + 7, not held. TW and T3 (14343, 14344) are not
    // checked, though T3 is the next group's G + 1. 11 + 6 = 17.
    auto m = machine();
    Registers r;
    r.a = 0x40;
    CHECK_EQ(tstates_at(*m, C48 - 7, r, {0xDB, 0xFE}), 17u);
}

TEST(io_odd_port_contended_high_byte) {
    // IN A,(0xFF) with A = 0x40: port 0x40FF, C:1 x 4. T1 at 14335, G + 0:
    // held 6, to 14341. T2 at 14342, G + 7: not held. TW at 14343 is the next
    // group's G + 0: held 6, to 14349. T3 at 14350, G + 7: not held. 11 + 12
    // = 23.
    auto m = machine();
    Registers r;
    r.a = 0x40;
    CHECK_EQ(tstates_at(*m, C48 - 7, r, {0xDB, 0xFF}), 23u);
}

// ---- indexed instructions: the internal T-states after d --------------------

/// Contended code, for the tests that need the instruction's own bytes, and so
/// the addresses left on the bus between its cycles, in contended memory.
constexpr uint16_t CONTENDED_CODE = 0x6000;

TEST(ld_a_ix_d_internal_tstates_hold_ds_address) {
    // LD A,(IX+0) is pc:4, pc+1:4, pc+2:3, pc+2:1 x 5, ii+n:3 = 19, with the
    // code at 0x6000 and IX at 0x8000 so only the code's own addresses are
    // contended. From 14341 (G + 6 of the first group):
    //   DD fetch    T1 at 14341, G + 6: not held               14341-14344
    //   7E fetch    T1 at 14345, G + 2: held 4                 14349-14352
    //   d read      T1 at 14353, G + 2: held 4                 14357-14359
    //   internal    14360 G + 1: 5 -> 14365; 14366 G + 7: 0;
    //               14367 G + 0: 6 -> 14373; 14374 G + 7: 0;
    //               14375 G + 0: 6 -> 14381
    //   (IX+0) read T1 at 14382, 0x8000: not contended         14382-14384
    // 19 + 4 + 4 + 5 + 6 + 6 = 44. I points at contended memory, which must
    // change nothing: IR is on the bus only during the fetches' refresh,
    // which is never checked. A core that read d a T-state late, as this one
    // once did, left IR on the bus for d's T1 instead and took 45.
    auto m = machine();
    Registers r;
    r.ix = 0x8000;
    r.i = 0x40;
    CHECK_EQ(tstates_at(*m, C48 + 6, r, {0xDD, 0x7E, 0x00}, CONTENDED_CODE), 44u);
}

TEST(bit_ix_d_internal_tstates_hold_the_opcodes_address) {
    // BIT 0,(IX+0) is pc:4, pc+1:4, pc+2:3, pc+3:3, pc+3:1 x 2, ii+n:3, ii+n:1
    // = 20, placed as above:
    //   DD fetch    T1 at 14341, G + 6: not held               14341-14344
    //   CB fetch    T1 at 14345, G + 2: held 4                 14349-14352
    //   d read      T1 at 14353, G + 2: held 4                 14357-14359
    //   op read     T1 at 14360, G + 1: held 5                 14365-14367
    //   internal    14368 G + 1: 5 -> 14373; 14374 G + 7: 0
    //   (IX+0) read T1 at 14375, 0x8000: not contended         14375-14377
    //   internal    14378, 0x8000 on the bus: not contended
    // 20 + 4 + 4 + 5 + 5 = 38.
    auto m = machine();
    Registers r;
    r.ix = 0x8000;
    CHECK_EQ(tstates_at(*m, C48 + 6, r, {0xDD, 0xCB, 0x00, 0x46}, CONTENDED_CODE), 38u);
}

// ---- the 128K --------------------------------------------------------------

TEST(spectrum128_paging_port) {
    // OUT (C),A with BC = 0x7FFD: pc:4, pc+1:4, then port 0x7FFD, C:1 x 4.
    // Fetches 14354-14361. T1 at 14362 = G + 0: held 6, to 14368. T2 at
    // 14369, G + 7: not held. TW at 14370, the next group's G + 0: held 6, to
    // 14376. T3 at 14377, G + 7: not held. 12 + 12 = 24.
    auto m = machine(Model::Spectrum128);
    Registers r;
    r.set_bc(0x7FFD);
    r.a = 0x00; // the paging the machine already has
    CHECK_EQ(tstates_at(*m, C128 - 8, r, {0xED, 0x79}), 24u);
}

TEST(spectrum128_contended_banks) {
    // LD A,(HL) with the read's T1 at the 128K's first contended T-state.
    // 0x4000 is bank 5, always contended: 13.
    auto a = machine(Model::Spectrum128);
    CHECK_EQ(tstates_at(*a, C128 - 4, with_hl(0x4000), {0x7E}), 13u);
    // 0xC000 with bank 1 paged there: contended, 13.
    auto b = machine(Model::Spectrum128);
    b->write_paging(1);
    CHECK_EQ(tstates_at(*b, C128 - 4, with_hl(0xC000), {0x7E}), 13u);
    // With bank 2 there: not, 7.
    auto c = machine(Model::Spectrum128);
    c->write_paging(2);
    CHECK_EQ(tstates_at(*c, C128 - 4, with_hl(0xC000), {0x7E}), 7u);
    // The 48K's contention start is not the 128K's: a read at 14335 on the
    // 128K falls on 14362 - 27, three groups and three T-states before its
    // first group -- the top border. 7.
    auto d = machine(Model::Spectrum128);
    CHECK_EQ(tstates_at(*d, C48 - 4, with_hl(0x4000), {0x7E}), 7u);
}

// ---- the CPU stays on the ULA's beat ----------------------------------------

TEST(re_priming_keeps_the_cpu_on_the_ulas_beat) {
    // At every instruction boundary the CPU has had T1H of its next fetch,
    // so the ULA is at an odd half-clock. A register write there -- the
    // debugger, a snapshot, a fast-loaded block -- must leave it so.
    auto m = machine();
    std::vector<uint8_t> nops(16, 0x00);
    m->write_memory(CODE, nops.data(), nops.size());
    Registers r;
    r.pc = CODE;
    m->set_registers(r);
    CHECK_EQ(m->ula.frame_hc() & 1, 1u);
    for (int i = 0; i < 4; i++) {
        m->step_instruction();
        CHECK_EQ(m->ula.frame_hc() & 1, 1u);
        m->set_registers(m->registers());
        CHECK_EQ(m->ula.frame_hc() & 1, 1u);
    }
}

RUN_TESTS()
