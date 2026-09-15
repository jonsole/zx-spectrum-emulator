// The execution profile: how many times each address ran and what it cost.
//
// The costs checked here are worked out by hand from the Z80's documented
// timings, in uncontended memory where the ULA never holds the clock -- so a
// wrong number is a wrong profile, not a calibration drift. The other half is
// the accounting identity: every half-clock a profiled step takes is charged
// to exactly one place, an address or the interrupt bucket, and the total
// matches the machine's own clock.

#include "engine.h"
#include "spectrum.h"
#include "test_main.h"

#include <cstdint>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM = 0x8000;
constexpr uint16_t STACK_TOP = 0xFF00;
/// Where a 48K's interrupt goes -- IM 0 and IM 1 alike, since the bus floats
/// at 0xFF (RST 38).
constexpr uint16_t VECTOR = 0x0038;

void setup(Spectrum& machine, const std::vector<uint8_t>& code) {
    machine.write_memory(PROGRAM, code.data(), code.size());
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    machine.prime_cpu(regs);
}

/// A ROM of NOPs with an interrupt handler that re-enables and returns, so a
/// program can HALT and be woken every frame.
void load_handler_rom(Spectrum& machine) {
    std::vector<uint8_t> rom(0x4000, 0x00);
    rom[VECTOR] = 0xFB;     // EI
    rom[VECTOR + 1] = 0xC9; // RET
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());
}

} // namespace

TEST(each_instruction_is_charged_its_own_cost) {
    // LD B,3 / DJNZ $ / NOP. LD B,n is 7T; DJNZ is 13T taken and 8T not.
    Spectrum machine;
    setup(machine, {0x06, 0x03, 0x10, 0xFE, 0x00});
    Profile profile;
    machine.profile = &profile;
    for (int i = 0; i < 4; i++) {
        machine.step_instruction();
    }

    CHECK_EQ(profile.hits(PROGRAM), uint64_t(1));
    CHECK_EQ(profile.half_clocks(PROGRAM), uint64_t(7 * 2));
    CHECK_EQ(profile.hits(PROGRAM + 2), uint64_t(3));
    CHECK_EQ(profile.half_clocks(PROGRAM + 2), uint64_t((13 + 13 + 8) * 2));
    CHECK_EQ(profile.instructions(), uint64_t(4));
    CHECK_EQ(profile.total_half_clocks(), uint64_t((7 + 13 + 13 + 8) * 2));
    // Nothing is charged to an operand byte.
    CHECK_EQ(profile.hits(PROGRAM + 1), uint64_t(0));
    CHECK_EQ(profile.hits(PROGRAM + 3), uint64_t(0));
}

TEST(no_profile_counts_nothing_and_changes_nothing) {
    // The same program with and without a profile must end in the same place
    // at the same instant: profiling is an observer.
    Spectrum plain;
    setup(plain, {0x06, 0x03, 0x10, 0xFE, 0x00});
    Spectrum profiled;
    setup(profiled, {0x06, 0x03, 0x10, 0xFE, 0x00});
    Profile profile;
    profiled.profile = &profile;
    for (int i = 0; i < 4; i++) {
        plain.step_instruction();
        profiled.step_instruction();
    }
    CHECK_EQ(plain.global_hc(), profiled.global_hc());
    CHECK_EQ(int(plain.registers().pc), int(profiled.registers().pc));
}

TEST(a_halt_is_charged_to_itself_and_an_interrupt_to_its_own_bucket) {
    // EI / HALT / JR back to the HALT, woken each frame by EI;RET at 0x38.
    Spectrum machine;
    load_handler_rom(machine);
    setup(machine, {0xFB, 0x76, 0x18, 0xFD});
    Profile profile;
    machine.profile = &profile;

    const uint64_t start_hc = machine.global_hc();
    const uint64_t interrupts_before = machine.cpu.interrupt_count;
    while (machine.cpu.interrupt_count - interrupts_before < 3) {
        machine.step_instruction();
    }
    // Finish the handler and get back to the HALT, so every interrupt taken
    // has run its RET and its JR. (Accepting the interrupt cleared the latch.)
    while (!machine.cpu.halted) {
        machine.step_instruction();
    }

    const uint64_t interrupts = machine.cpu.interrupt_count - interrupts_before;
    CHECK_EQ(profile.interrupts(), interrupts);
    // An IM 1 (or IM 0 on a floating bus) acknowledge is 13T, with the stack
    // in uncontended memory.
    CHECK_EQ(profile.interrupt_half_clocks(), uint64_t(13 * 2) * interrupts);

    // Nearly a frame of waiting per interrupt, and all of it on the HALT --
    // none on the byte after it, which is the PC a halted CPU reports.
    CHECK(profile.hits(PROGRAM + 1) > 10000);
    CHECK_EQ(profile.hits(VECTOR), interrupts);         // EI
    CHECK_EQ(profile.hits(VECTOR + 1), interrupts);     // RET
    // The JR, once per wake -- except that the machine is primed at the very
    // top of a frame with INT still asserted, so the first wake is taken twice
    // back to back (the second straight off the handler's RET) and runs the JR
    // once for both. Its cost per run is still exactly a taken JR's 12T.
    CHECK(profile.hits(PROGRAM + 2) >= 1);
    CHECK(profile.hits(PROGRAM + 2) <= interrupts);
    CHECK_EQ(profile.half_clocks(PROGRAM + 2), uint64_t(12 * 2) * profile.hits(PROGRAM + 2));

    // Every half-clock is somewhere, exactly once.
    CHECK_EQ(profile.total_half_clocks(), machine.global_hc() - start_hc);
    uint64_t sum = profile.interrupt_half_clocks();
    for (size_t i = 0; i < Profile::ADDRESSES; i++) {
        sum += profile.half_clocks(uint16_t(i));
    }
    CHECK_EQ(sum, profile.total_half_clocks());
}

namespace {

constexpr uint16_t ROUTINE_A = 0x8100;
constexpr uint16_t ROUTINE_B = 0x8200;
constexpr uint16_t ROUTINE_C = 0x8300;

void put(Spectrum& machine, uint16_t addr, const std::vector<uint8_t>& code) {
    machine.write_memory(addr, code.data(), code.size());
}

/// Steps until PC reaches `addr` (not halted), with a bound so a broken test
/// program fails rather than hangs.
void run_to(Spectrum& machine, uint16_t addr) {
    for (int i = 0; i < 10000; i++) {
        if (machine.registers().pc == addr && !machine.cpu.halted) {
            return;
        }
        machine.step_instruction();
    }
    CHECK(false);
}

uint64_t sum_self(const Profile& profile) {
    uint64_t sum = 0;
    for (const Profile::CallNode& n : profile.call_nodes()) {
        sum += n.self_half_clocks;
    }
    return sum;
}

/// The child of `parent` that called `addr`, or 0 (the root, never a child).
uint32_t child(const Profile& profile, uint32_t parent, uint16_t addr) {
    const std::vector<Profile::CallNode>& nodes = profile.call_nodes();
    for (size_t i = 1; i < nodes.size(); i++) {
        if (nodes[i].parent == parent && nodes[i].addr == addr) {
            return uint32_t(i);
        }
    }
    return 0;
}

} // namespace

TEST(calls_nest_and_each_node_holds_its_own_time) {
    // CALL A twice, then NOP. A calls B and returns; B is NOP, RET.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0xCD, 0x00, 0x81, 0x00});
    put(machine, ROUTINE_A, {0xCD, 0x00, 0x82, 0xC9});
    put(machine, ROUTINE_B, {0x00, 0xC9});
    Profile profile;
    machine.profile = &profile;
    run_to(machine, PROGRAM + 6);
    machine.step_instruction(); // the NOP, back at the root

    const std::vector<Profile::CallNode>& nodes = profile.call_nodes();
    CHECK_EQ(nodes.size(), size_t(3));
    const uint32_t a = child(profile, Profile::ROOT, ROUTINE_A);
    const uint32_t b = child(profile, a, ROUTINE_B);
    CHECK(a != 0);
    CHECK(b != 0);
    CHECK_EQ(nodes[a].calls, uint64_t(2));
    CHECK_EQ(nodes[b].calls, uint64_t(2));
    // CALL is 17T, RET 10T, NOP 4T -- each charged where it ran: a CALL to
    // its caller, a RET to the routine it leaves.
    CHECK_EQ(nodes[Profile::ROOT].self_half_clocks, uint64_t((17 + 17 + 4) * 2));
    CHECK_EQ(nodes[a].self_half_clocks, uint64_t((17 + 10) * 2 * 2));
    CHECK_EQ(nodes[b].self_half_clocks, uint64_t((4 + 10) * 2 * 2));
    CHECK_EQ(sum_self(profile), profile.total_half_clocks());
    CHECK_EQ(profile.depth(), size_t(0));
}

TEST(one_routine_called_from_two_places_is_two_nodes) {
    // CALL A / CALL B / NOP, and both A and B call C.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0xCD, 0x00, 0x82, 0x00});
    put(machine, ROUTINE_A, {0xCD, 0x00, 0x83, 0xC9});
    put(machine, ROUTINE_B, {0xCD, 0x00, 0x83, 0x00, 0xC9});
    put(machine, ROUTINE_C, {0xC9});
    Profile profile;
    machine.profile = &profile;
    run_to(machine, PROGRAM + 6);

    const uint32_t a = child(profile, Profile::ROOT, ROUTINE_A);
    const uint32_t b = child(profile, Profile::ROOT, ROUTINE_B);
    const uint32_t c_from_a = child(profile, a, ROUTINE_C);
    const uint32_t c_from_b = child(profile, b, ROUTINE_C);
    CHECK_EQ(profile.call_nodes().size(), size_t(5));
    CHECK(c_from_a != 0);
    CHECK(c_from_b != 0);
    CHECK(c_from_a != c_from_b);
    CHECK_EQ(profile.call_nodes()[c_from_a].calls, uint64_t(1));
    // B's own code includes its extra NOP; A's does not.
    CHECK_EQ(profile.call_nodes()[b].self_half_clocks,
             profile.call_nodes()[a].self_half_clocks + uint64_t(4 * 2));
}

TEST(a_return_address_thrown_away_still_ends_the_call) {
    // CALL A; A does POP HL and jumps back to the NOP after the call -- no RET.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00, 0x00});
    put(machine, ROUTINE_A, {0xE1, 0xC3, 0x03, 0x80}); // POP HL / JP 0x8003
    Profile profile;
    machine.profile = &profile;
    run_to(machine, PROGRAM + 3);
    CHECK_EQ(profile.depth(), size_t(0));
    const uint64_t root_before = profile.call_nodes()[Profile::ROOT].self_half_clocks;
    machine.step_instruction();
    CHECK_EQ(profile.call_nodes()[Profile::ROOT].self_half_clocks, root_before + uint64_t(4 * 2));
}

TEST(a_stack_at_the_top_of_memory_unwinds_across_the_wrap) {
    // SP = 0x0000: the CALL's return address lands at 0xFFFE, and the RET
    // takes SP back to 0x0000 -- numerically below the slot it rose past.
    Spectrum machine;
    machine.write_memory(PROGRAM, std::vector<uint8_t>{0xCD, 0x00, 0x81, 0x00}.data(), 4);
    put(machine, ROUTINE_A, {0xC9});
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = 0x0000;
    machine.prime_cpu(regs);
    Profile profile;
    machine.profile = &profile;
    machine.step_instruction(); // CALL
    CHECK_EQ(profile.depth(), size_t(1));
    machine.step_instruction(); // RET
    CHECK_EQ(profile.depth(), size_t(0));
    machine.step_instruction(); // NOP, at the root again
    CHECK_EQ(profile.call_nodes()[Profile::ROOT].self_half_clocks, uint64_t((17 + 4) * 2));
}

TEST(an_interrupt_handler_is_a_node_of_its_own) {
    Spectrum machine;
    load_handler_rom(machine);
    setup(machine, {0xFB, 0x76, 0x18, 0xFD});
    Profile profile;
    machine.profile = &profile;
    const uint64_t interrupts_before = machine.cpu.interrupt_count;
    while (machine.cpu.interrupt_count - interrupts_before < 3) {
        machine.step_instruction();
    }
    while (!machine.cpu.halted) {
        machine.step_instruction();
    }

    const uint32_t handler = child(profile, Profile::ROOT, VECTOR);
    CHECK(handler != 0);
    const Profile::CallNode& node = profile.call_nodes()[handler];
    CHECK(node.interrupt);
    const uint64_t interrupts = machine.cpu.interrupt_count - interrupts_before;
    // The back-to-back first wake is the second interrupt arriving inside the
    // first's handler frame -- once its RET has left it -- so every wake is a
    // call of the same node.
    CHECK_EQ(node.calls, interrupts);
    // The acknowledge (13T), EI (4T) and RET (10T), every time.
    CHECK_EQ(node.self_half_clocks, uint64_t((13 + 4 + 10) * 2) * interrupts);
    CHECK_EQ(sum_self(profile), profile.total_half_clocks());
    CHECK_EQ(profile.depth(), size_t(0));
}

TEST(clearing_starts_again_from_nothing) {
    Spectrum machine;
    setup(machine, {0x00, 0x00});
    Profile profile;
    machine.profile = &profile;
    machine.step_instruction();
    profile.clear();
    CHECK_EQ(profile.call_nodes().size(), size_t(1));
    CHECK_EQ(profile.hits(PROGRAM), uint64_t(0));
    CHECK_EQ(profile.instructions(), uint64_t(0));
    CHECK_EQ(profile.total_half_clocks(), uint64_t(0));
}

TEST(the_engine_starts_stops_and_reports_only_what_ran) {
    Engine engine;
    engine.write_memory(PROGRAM, {0x06, 0x03, 0x10, 0xFE, 0x00, 0x00, 0x00});
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    engine.set_registers(regs);

    CHECK(!engine.profile_snapshot().active);
    engine.start_profile();
    engine.step(4);

    ProfileSnapshot s = engine.profile_snapshot();
    CHECK(s.active);
    CHECK_EQ(s.instructions, uint64_t(4));
    CHECK_EQ(s.entries.size(), size_t(2));
    CHECK_EQ(int(s.entries[0].addr), int(PROGRAM));
    CHECK_EQ(int(s.entries[1].addr), int(PROGRAM + 2));
    CHECK_EQ(s.entries[1].hits, uint64_t(3));

    // Stopped: the counts stay, and further steps add nothing.
    engine.stop_profile();
    engine.step(2);
    s = engine.profile_snapshot();
    CHECK(!s.active);
    CHECK_EQ(s.instructions, uint64_t(4));

    // Started again: from zero.
    engine.start_profile();
    engine.step(1);
    s = engine.profile_snapshot();
    CHECK_EQ(s.instructions, uint64_t(1));
    CHECK_EQ(int(s.entries[0].addr), int(PROGRAM + 6));
}

RUN_TESTS()
