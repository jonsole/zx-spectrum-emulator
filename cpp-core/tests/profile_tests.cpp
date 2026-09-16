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
    // CALL A, CALL A again from the next line, then NOP. A calls B and
    // returns; B is NOP, RET.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0xCD, 0x00, 0x81, 0x00});
    put(machine, ROUTINE_A, {0xCD, 0x00, 0x82, 0xC9});
    put(machine, ROUTINE_B, {0x00, 0xC9});
    Profile profile;
    machine.profile = &profile;
    run_to(machine, PROGRAM + 6);
    machine.step_instruction(); // the NOP, back at the root

    // The two CALLs of A are two paths, each with its own A and its own B.
    const std::vector<Profile::CallNode>& nodes = profile.call_nodes();
    CHECK_EQ(nodes.size(), size_t(5));
    const uint32_t a = child(profile, Profile::ROOT, ROUTINE_A);
    const uint32_t b = child(profile, a, ROUTINE_B);
    CHECK(a != 0);
    CHECK(b != 0);
    CHECK_EQ(int(nodes[a].site), int(PROGRAM));
    CHECK_EQ(int(nodes[b].site), int(ROUTINE_A));
    CHECK_EQ(nodes[a].calls, uint64_t(1));
    CHECK_EQ(nodes[b].calls, uint64_t(1));
    uint32_t second_a = 0;
    for (size_t i = 1; i < nodes.size(); i++) {
        if (nodes[i].parent == Profile::ROOT && nodes[i].site == PROGRAM + 3) {
            second_a = uint32_t(i);
        }
    }
    CHECK(second_a != 0);
    CHECK(second_a != a);
    // CALL is 17T, RET 10T, NOP 4T -- each charged where it ran: a CALL to
    // its caller, a RET to the routine it leaves.
    CHECK_EQ(nodes[Profile::ROOT].self_half_clocks, uint64_t((17 + 17 + 4) * 2));
    CHECK_EQ(nodes[a].self_half_clocks, uint64_t((17 + 10) * 2));
    CHECK_EQ(nodes[second_a].self_half_clocks, uint64_t((17 + 10) * 2));
    CHECK_EQ(nodes[b].self_half_clocks, uint64_t((4 + 10) * 2));
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

TEST(a_stack_pointer_borrowed_for_data_does_not_end_the_call) {
    // CALL A. A saves SP, points it at data far away (below the stack, the
    // way a sprite blit walks its bitmap), POPs twice, puts SP back, calls B
    // and returns. None of that is a return: A stays open throughout, and B
    // nests under it.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00});
    put(machine, ROUTINE_A, {
        0xED, 0x73, 0x00, 0x90, // LD (0x9000),SP
        0x31, 0x00, 0x60,       // LD SP,0x6000
        0xD1,                   // POP DE
        0xD1,                   // POP DE
        0xED, 0x7B, 0x00, 0x90, // LD SP,(0x9000)
        0xCD, 0x00, 0x82,       // CALL B
        0xC9,                   // RET
    });
    put(machine, ROUTINE_B, {0x00, 0xC9});
    Profile profile;
    machine.profile = &profile;

    machine.step_instruction(); // CALL A
    for (int i = 0; i < 4; i++) {
        machine.step_instruction(); // the save, the borrow, two POPs
        CHECK_EQ(profile.depth(), size_t(1));
    }
    run_to(machine, PROGRAM + 3);
    CHECK_EQ(profile.depth(), size_t(0));

    const uint32_t a = child(profile, Profile::ROOT, ROUTINE_A);
    CHECK(a != 0);
    CHECK(child(profile, a, ROUTINE_B) != 0);
    // Everything A did is A's: two 20T loads, a 10T load, two 10T POPs, the
    // CALL (17T) and the RET (10T). The root has only its own CALL.
    CHECK_EQ(profile.call_nodes()[a].self_half_clocks, uint64_t((20 + 10 + 10 + 10 + 20 + 17 + 10) * 2));
    CHECK_EQ(profile.call_nodes()[Profile::ROOT].self_half_clocks, uint64_t(17 * 2));
}

TEST(a_stack_abandoned_by_hand_ends_when_its_slot_is_used_again) {
    // CALL A; A CALLs B; B throws the whole chain away with LD SP back to
    // where it was before A was called, pushes a return address to after the
    // first CALL, and RETs through it. The LD SP alone ends nothing -- it is
    // what borrowing SP looks like too -- but the PUSH writes over the slot
    // A's call used, so A and B both end there.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00, 0x00});
    put(machine, ROUTINE_A, {0xCD, 0x00, 0x82});
    put(machine, ROUTINE_B, {
        0x31, 0x00, 0xFF,       // LD SP,STACK_TOP
        0x21, 0x03, 0x80,       // LD HL,PROGRAM+3
        0xE5,                   // PUSH HL
        0xC9,                   // RET
    });
    Profile profile;
    machine.profile = &profile;
    run_to(machine, ROUTINE_B + 6);
    CHECK_EQ(profile.depth(), size_t(2));
    machine.step_instruction(); // PUSH HL, over A's old slot
    CHECK_EQ(profile.depth(), size_t(0));
    machine.step_instruction(); // RET, at the root
    CHECK_EQ(profile.depth(), size_t(0));
    CHECK_EQ(int(machine.registers().pc), int(PROGRAM + 3));
}

TEST(a_loop_that_resets_the_stack_and_calls_again_stays_one_deep) {
    // loop: LD SP,0xFF00 / CALL A, and A pushes a word and jumps back to loop. No
    // return ever consumes a slot; each CALL overwrites the one before.
    Spectrum machine;
    setup(machine, {0x31, 0x00, 0xFF, 0xCD, 0x00, 0x81});
    put(machine, ROUTINE_A, {0xE5, 0xC3, 0x00, 0x80}); // PUSH HL / JP loop
    Profile profile;
    machine.profile = &profile;
    for (int i = 0; i < 300; i++) {
        machine.step_instruction();
        CHECK(profile.depth() <= 1);
    }
    CHECK_EQ(profile.call_nodes().size(), size_t(2));
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

TEST(an_address_marked_idle_counts_as_idle_everywhere) {
    // LD B,3 / DJNZ $ / NOP, with the DJNZ marked idle -- a pacing loop.
    Spectrum machine;
    setup(machine, {0x06, 0x03, 0x10, 0xFE, 0x00});
    Profile profile;
    std::vector<uint8_t> idle(Profile::ADDRESSES, 0);
    idle[PROGRAM + 2] = 1;
    profile.set_idle_map(idle);
    machine.profile = &profile;
    for (int i = 0; i < 5; i++) {
        machine.step_instruction();
    }
    const uint64_t djnz = uint64_t((13 + 13 + 8) * 2);
    CHECK_EQ(profile.idle_half_clocks(PROGRAM + 2), djnz);
    CHECK_EQ(profile.idle_half_clocks(PROGRAM), uint64_t(0));
    CHECK_EQ(profile.idle_total_half_clocks(), djnz);
    CHECK_EQ(profile.call_nodes()[Profile::ROOT].idle_half_clocks, djnz);
}

TEST(a_halt_waiting_is_idle_without_being_marked) {
    Spectrum machine;
    load_handler_rom(machine);
    setup(machine, {0xFB, 0x76, 0x18, 0xFD});
    Profile profile;
    machine.profile = &profile;
    const uint64_t interrupts_before = machine.cpu.interrupt_count;
    while (machine.cpu.interrupt_count - interrupts_before < 2) {
        machine.step_instruction();
    }
    // Every pass but the ones that halt is waiting: what is left over is a
    // whole number of 4T HALTs, one per time the CPU arrived at it.
    CHECK(profile.idle_half_clocks(PROGRAM + 1) > 10000);
    const uint64_t halting = profile.half_clocks(PROGRAM + 1) - profile.idle_half_clocks(PROGRAM + 1);
    CHECK_EQ(halting % uint64_t(4 * 2), uint64_t(0));
    CHECK(halting >= uint64_t(4 * 2) && halting <= uint64_t(4 * 2) * 3);
    CHECK_EQ(profile.idle_half_clocks(PROGRAM + 2), uint64_t(0));
    CHECK_EQ(profile.idle_total_half_clocks(), profile.idle_half_clocks(PROGRAM + 1));
}

TEST(periods_are_frames_by_default_and_the_first_is_not_ranked) {
    Spectrum machine;
    load_handler_rom(machine);
    setup(machine, {0xFB, 0x76, 0x18, 0xFD});
    Profile profile;
    machine.profile = &profile;
    const uint64_t first = machine.ula.frame_count();
    while (machine.ula.frame_count() < first + 6) {
        machine.step_instruction();
    }
    machine.step_instruction(); // the first instruction of frame +6 closes frame +5

    const Profile::PeriodSummary s = profile.summarize(400);
    // Frames +1 .. +5 are complete; the frame counting began in is not a period.
    CHECK_EQ(s.count, uint64_t(5));
    CHECK_EQ(s.strip.size(), size_t(5));
    CHECK_EQ(s.worst.size(), size_t(5));
    const uint64_t frame_hc = machine.ula.timing().hc_per_frame();
    for (const Profile::PeriodCost& p : profile.periods()) {
        // An instruction belongs to the frame it began in, so a period is a
        // frame give or take the instructions straddling its edges.
        CHECK(p.half_clocks + 40 >= frame_hc && p.half_clocks <= frame_hc + 40);
        // Almost all of it waiting on the HALT.
        CHECK(p.idle_half_clocks * 10 > p.half_clocks * 9);
    }
    CHECK(s.worst[0].cost.busy() >= s.worst[4].cost.busy());
    CHECK(!s.worst[0].nodes.empty());
}

TEST(a_marker_makes_each_turn_of_a_loop_a_period_and_the_busiest_keep_their_detail) {
    // loop: INC A / LD B,A / DJNZ $ / JP loop -- each turn spins once more
    // than the last.
    Spectrum machine;
    setup(machine, {0x3C, 0x47, 0x10, 0xFE, 0xC3, 0x00, 0x80});
    Profile profile;
    profile.set_period_marker(PROGRAM);
    machine.profile = &profile;
    for (int turn = 0; turn < 30; turn++) {
        run_to(machine, PROGRAM + 4);
        run_to(machine, PROGRAM);
    }

    const Profile::PeriodSummary s = profile.summarize(10);
    // Thirty arrivals at the marker. The first opens the period counting began
    // in, which the second closes unranked; the last turn is still open. So
    // turns 1..28 are the periods, turn k spinning with A = k+1.
    CHECK_EQ(s.count, uint64_t(28));
    CHECK_EQ(s.strip.size(), size_t(10));
    CHECK_EQ(s.bucket, uint64_t(3));
    CHECK_EQ(s.worst.size(), Profile::WORST_PERIODS);
    // A turn with A = n is INC (4T), LD (4T), n-1 taken DJNZs, one not, JP.
    const Profile::WorstPeriod& busiest = s.worst[0];
    const uint64_t n = 29;
    CHECK_EQ(busiest.cost.half_clocks, uint64_t((4 + 4 + (n - 1) * 13 + 8 + 10) * 2));
    CHECK_EQ(busiest.index, uint64_t(27));
    bool found_djnz = false;
    for (const Profile::WorstPeriod::Share& a : busiest.addresses) {
        if (a.id == PROGRAM + 2) {
            found_djnz = true;
            CHECK_EQ(a.half_clocks, uint64_t(((n - 1) * 13 + 8) * 2));
        }
    }
    CHECK(found_djnz);
    // Changing what a period is starts the periods again.
    profile.set_period_marker(Profile::FRAME_PERIODS);
    CHECK_EQ(profile.summarize(10).count, uint64_t(0));
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
