// Pin-level timing tests: what the bus actually looks like, half-clock by
// half-clock.
//
// Deliberately NOT written against vendor/chips/z80.h. Its pins are a per-tick
// "what is being requested" mask rather than wire state -- it asserts MREQ on
// T1 and T3 with T2 idle, and represents every control line active HIGH. Both
// are fine for what that core is for, and both are exactly what this core
// exists to stop doing. So these expectations come from the Z80 datasheet's
// own timing diagrams (cross-checked against SpecIde's state names), and this
// file is where a regression in the half-T-state model itself would show up.
//
// The single most important property here is the T1H..T1L gap on an opcode
// fetch and a memory read: address valid, MREQ still HIGH. That gap is the
// window a 48K ULA samples to decide whether to halt the CPU for contention,
// and it is the entire reason this core is clocked at half-T-states.

#include "memory.h"
#include "test_main.h"
#include "z80.h"

#include <string>
#include <vector>

using namespace zx;

namespace {

/// Runs the CPU one half-clock at a time, servicing memory, and records the
/// bus state after each. Index 0 is the state after the first half-clock
/// following set_registers()' priming (i.e. M1 T1L of the first instruction).
std::vector<uint64_t> trace(const std::vector<uint8_t>& program, int half_clocks,
                            const Registers& start) {
    Z80 cpu;
    FlatMemory mem;
    std::copy(program.begin(), program.end(), mem.bytes.begin());
    cpu.set_registers(start, mem);

    std::vector<uint64_t> out;
    uint64_t pins = cpu.pins();
    for (int i = 0; i < half_clocks; i++) {
        pins = Z80::service_memory(mem, cpu.clock(pins));
        out.push_back(pins);
    }
    return out;
}

Registers regs_at(uint16_t pc) {
    Registers r;
    r.pc = pc;
    r.sp = 0xFF00;
    return r;
}

} // namespace

TEST(bus_rests_with_every_control_line_released) {
    Z80 cpu;
    FlatMemory mem;
    cpu.set_registers(regs_at(0), mem);
    // After priming we are mid-fetch, so M1 is legitimately asserted -- but
    // nothing that should be idle is being driven.
    CHECK(!asserted(cpu.pins(), MREQ));
    CHECK(!asserted(cpu.pins(), WR));
    CHECK(!asserted(cpu.pins(), IORQ));
    CHECK(!asserted(cpu.pins(), HALT));
}

TEST(opcode_fetch_drives_the_datasheet_m1_sequence) {
    // NOP at 0x0000, so the whole 4-T-state M1 cycle is visible with nothing
    // else going on. set_registers() has already performed T1H (the overlapped
    // fetch), so the trace starts at T1L.
    std::vector<uint64_t> t = trace({0x00, 0x00}, 8, regs_at(0));

    // T1H happened during priming: address valid, M1 asserted, and crucially
    // MREQ still HIGH. This is the contention window.
    Z80 primed;
    FlatMemory mem;
    primed.set_registers(regs_at(0), mem);
    CHECK(asserted(primed.pins(), M1));
    CHECK(!asserted(primed.pins(), MREQ));
    CHECK_EQ(get_addr(primed.pins()), uint16_t(0x0000));

    // T1L: MREQ and RD join in, address unchanged.
    CHECK(asserted(t[0], M1));
    CHECK(asserted(t[0], MREQ));
    CHECK(asserted(t[0], RD));
    CHECK_EQ(get_addr(t[0]), uint16_t(0x0000));

    // T2H / T2L: held. WAIT would be sampled on T2L.
    CHECK(asserted(t[1], MREQ | RD));
    CHECK(asserted(t[2], MREQ | RD));

    // T3H: opcode latched, M1/MREQ/RD released, and the refresh address goes
    // out with RFSH asserted. R has incremented but the address carries the
    // PRE-increment value.
    CHECK(!asserted(t[3], M1));
    CHECK(!asserted(t[3], RD));
    CHECK(asserted(t[3], RFSH));
    CHECK_EQ(get_addr(t[3]), uint16_t(0x0000)); // I=0, R=0 before increment

    // T3L / T4H: refresh MREQ low. THIS is the window in which a refresh
    // address sits on the bus with MREQ asserted -- the mechanism behind the
    // "snow" artifact when I lands in the contended page.
    CHECK(asserted(t[4], MREQ));
    CHECK(asserted(t[4], RFSH));
    CHECK(asserted(t[5], MREQ | RFSH));

    // T4L: refresh over, everything released.
    CHECK(!asserted(t[6], MREQ));
    CHECK(!asserted(t[6], RFSH));
}

TEST(memory_read_exposes_the_address_before_mreq_asserts) {
    // LD A,(HL) with HL in the contended page. The mread's T1H must show
    // 0x4000 with MREQ still high -- if it did not, a ULA could not tell
    // which address it was about to contend on.
    Registers start = regs_at(0);
    start.set_hl(0x4000);
    std::vector<uint64_t> t = trace({0x7E}, 16, start);

    bool found_window = false;
    for (size_t i = 0; i + 1 < t.size(); i++) {
        if (get_addr(t[i]) == 0x4000 && !asserted(t[i], MREQ)
            && !asserted(t[i], RFSH) && !asserted(t[i], M1)) {
            // The very next half-clock must be the same address with MREQ|RD
            // driven -- i.e. this really was T1H of that read, not a stray
            // idle half-clock that happened to have the address lying around.
            if (get_addr(t[i + 1]) == 0x4000 && asserted(t[i + 1], MREQ | RD)) {
                found_window = true;
                break;
            }
        }
    }
    CHECK(found_window);
}

TEST(memory_write_asserts_wr_a_half_cycle_after_mreq) {
    // LD (HL),A -- on the real chip WR trails MREQ so the data bus has
    // settled before the write strobe. That ordering is only expressible at
    // half-T-state resolution.
    Registers start = regs_at(0);
    start.set_hl(0x8000);
    start.a = 0x5A;
    std::vector<uint64_t> t = trace({0x77}, 16, start);

    int mreq_only = -1;
    int mreq_and_wr = -1;
    for (size_t i = 0; i < t.size(); i++) {
        if (get_addr(t[i]) != 0x8000) {
            continue;
        }
        if (asserted(t[i], MREQ) && !asserted(t[i], WR) && mreq_only < 0) {
            mreq_only = int(i);
        }
        if (asserted(t[i], MREQ | WR) && mreq_and_wr < 0) {
            mreq_and_wr = int(i);
        }
    }
    CHECK(mreq_only >= 0);
    CHECK(mreq_and_wr >= 0);
    CHECK(mreq_only < mreq_and_wr); // MREQ first, WR strictly later
}

TEST(halt_drives_the_halt_pin_low) {
    std::vector<uint64_t> t = trace({0x76}, 24, regs_at(0));
    bool ever_halted = false;
    for (uint64_t p : t) {
        if (asserted(p, HALT)) {
            ever_halted = true;
        }
    }
    CHECK(ever_halted);
}

RUN_TESTS()
