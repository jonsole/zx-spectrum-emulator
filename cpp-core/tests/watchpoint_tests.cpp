// Watchpoints on the bus: what trips one and what deliberately does not.
//
// Two halves of docs/watchpoints-design.md. First the machine's: flags per
// address, checked where every CPU read and write already passes, and a hit
// record the driver reads between instructions. Then the Engine's, which owns
// the watchpoints themselves -- which one a hit belongs to, whether its value
// test is satisfied, and stopping a run.
//
// Every program here is hand-written and its answer worked out from what the
// Z80 does, not from what the emulator reports.

#include "engine.h"
#include "spectrum.h"
#include "test_main.h"

#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM = 0x8000;
constexpr uint16_t DATA = 0x9000;
constexpr uint16_t STACK_TOP = 0xFF00;

/// A machine primed to run `code` at PROGRAM with a known stack. Held through
/// a pointer: a Spectrum is too big for the stack and deliberately immovable.
std::unique_ptr<Spectrum> machine_running(const std::vector<uint8_t>& code) {
    auto m = std::make_unique<Spectrum>();
    m->write_memory(PROGRAM, code.data(), code.size());
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    m->prime_cpu(regs);
    return m;
}

/// Watches one address, or a range of `length` from it.
void watch(Spectrum& m, uint16_t addr, uint8_t flags, uint16_t length = 1) {
    std::vector<uint8_t> map(WATCH_ADDRESSES, 0);
    for (uint16_t i = 0; i < length; i++) {
        map[uint16_t(addr + i)] = flags;
    }
    m.set_watch_flags(std::move(map));
}

/// Steps `count` instructions, stopping at the first that trips a watch --
/// what a run loop does. Returns the hit, or one with `hit` false.
WatchHit step_until_hit(Spectrum& m, int count) {
    for (int i = 0; i < count; i++) {
        m.step_instruction();
        if (m.watch_hit.hit) {
            return m.watch_hit;
        }
    }
    return WatchHit();
}

} // namespace

TEST(a_write_trips_a_write_watch_and_reports_both_values) {
    // LD A,0x5A / LD (0x9000),A
    auto m = machine_running({0x3E, 0x5A, 0x32, 0x00, 0x90});
    const uint8_t before = 0x11;
    m->write_memory(DATA, &before, 1);
    watch(*m, DATA, WATCH_WRITE);

    const WatchHit hit = step_until_hit(*m, 2);
    CHECK(hit.hit);
    CHECK(hit.write);
    CHECK_EQ(int(hit.addr), int(DATA));
    CHECK_EQ(int(hit.old_value), 0x11);
    CHECK_EQ(int(hit.new_value), 0x5A);
    // The instruction that wrote, not the one after it.
    CHECK_EQ(int(hit.pc), int(PROGRAM + 2));
    // And it really did write: a watchpoint watches, it does not intervene.
    CHECK_EQ(int(m->read_memory(DATA, 1)[0]), 0x5A);
}

TEST(a_write_of_the_same_value_trips_write_but_not_change) {
    // LD A,0x5A / LD (0x9000),A, with 0x5A already there.
    const std::vector<uint8_t> code = {0x3E, 0x5A, 0x32, 0x00, 0x90};
    const uint8_t same = 0x5A;

    auto changing = machine_running(code);
    changing->write_memory(DATA, &same, 1);
    watch(*changing, DATA, WATCH_WRITE | WATCH_ON_CHANGE);
    CHECK(!step_until_hit(*changing, 2).hit);

    auto plain = machine_running(code);
    plain->write_memory(DATA, &same, 1);
    watch(*plain, DATA, WATCH_WRITE);
    CHECK(step_until_hit(*plain, 2).hit);
}

TEST(a_read_watch_ignores_the_instruction_fetch_at_that_address) {
    // The program watches itself for reads and runs through the watched
    // address: executing is not reading.
    //
    // NOP / NOP / LD A,(0x8000)
    auto m = machine_running({0x00, 0x00, 0x3A, 0x00, 0x80});
    watch(*m, PROGRAM, WATCH_READ);

    // The two NOPs fetch from PROGRAM and PROGRAM+1 and must not trip it.
    m->step_instruction();
    CHECK(!m->watch_hit.hit);
    m->step_instruction();
    CHECK(!m->watch_hit.hit);

    // LD A,(0x8000) reads it as data, and does trip it.
    m->step_instruction();
    CHECK(m->watch_hit.hit);
    CHECK(!m->watch_hit.write);
    CHECK_EQ(int(m->watch_hit.addr), int(PROGRAM));
    CHECK_EQ(int(m->watch_hit.old_value), 0x00); // the NOP it read
    CHECK_EQ(int(m->watch_hit.new_value), 0x00);
    CHECK_EQ(int(m->watch_hit.pc), int(PROGRAM + 2));
}

TEST(a_write_watch_ignores_reads_and_a_read_watch_ignores_writes) {
    // LD A,(0x9000) / LD (0x9000),A
    const std::vector<uint8_t> code = {0x3A, 0x00, 0x90, 0x32, 0x00, 0x90};

    auto writes = machine_running(code);
    watch(*writes, DATA, WATCH_WRITE);
    writes->step_instruction(); // the read
    CHECK(!writes->watch_hit.hit);
    writes->step_instruction(); // the write
    CHECK(writes->watch_hit.hit);

    auto reads = machine_running(code);
    watch(*reads, DATA, WATCH_READ);
    reads->step_instruction();
    CHECK(reads->watch_hit.hit);
    reads->watch_hit = WatchHit();
    reads->step_instruction();
    CHECK(!reads->watch_hit.hit);
}

TEST(a_push_onto_a_watched_stack_slot_trips_it) {
    // What the call stack's own rule is about: something writing over a
    // return address. PUSH HL writes the two bytes below SP.
    //
    // LD HL,0x1234 / PUSH HL
    auto m = machine_running({0x21, 0x34, 0x12, 0xE5});
    watch(*m, uint16_t(STACK_TOP - 2), WATCH_WRITE);

    const WatchHit hit = step_until_hit(*m, 2);
    CHECK(hit.hit);
    CHECK_EQ(int(hit.addr), int(STACK_TOP - 2));
    CHECK_EQ(int(hit.new_value), 0x34); // L, the low byte
    CHECK_EQ(int(hit.pc), int(PROGRAM + 3));
}

TEST(a_call_trips_a_watch_on_the_slot_its_return_address_goes_to) {
    // CALL 0x8100 -- the return address is pushed like any other write.
    auto m = machine_running({0xCD, 0x00, 0x81});
    watch(*m, uint16_t(STACK_TOP - 1), WATCH_WRITE); // the high byte's slot

    const WatchHit hit = step_until_hit(*m, 1);
    CHECK(hit.hit);
    CHECK_EQ(int(hit.new_value), (PROGRAM + 3) >> 8);
    CHECK_EQ(int(hit.pc), int(PROGRAM));
}

TEST(a_range_is_watched_as_cheaply_as_one_address) {
    // LDIR copying four bytes into the middle of a watched eight-byte record:
    // the hit is the first byte written that is inside it.
    //
    // LD HL,0x8100 / LD DE,0x9002 / LD BC,4 / LDIR
    auto m = machine_running({0x21, 0x00, 0x81, 0x11, 0x02, 0x90, 0x01, 0x04, 0x00, 0xED, 0xB0});
    const std::vector<uint8_t> source = {0xAA, 0xBB, 0xCC, 0xDD};
    m->write_memory(0x8100, source.data(), source.size());
    watch(*m, DATA, WATCH_WRITE, 8);

    const WatchHit hit = step_until_hit(*m, 4);
    CHECK(hit.hit);
    CHECK_EQ(int(hit.addr), int(DATA + 2));
    CHECK_EQ(int(hit.new_value), 0xAA);
}

TEST(one_instruction_writing_two_watched_bytes_reports_the_first) {
    // LD HL,0x1234 / LD (0x9000),HL writes both halves; one instruction is
    // one stop, and the hit is the write that reached the watch first.
    auto m = machine_running({0x21, 0x34, 0x12, 0x22, 0x00, 0x90});
    watch(*m, DATA, WATCH_WRITE, 2);

    const WatchHit hit = step_until_hit(*m, 2);
    CHECK(hit.hit);
    CHECK_EQ(int(hit.addr), int(DATA));
    CHECK_EQ(int(hit.new_value), 0x34);
}

TEST(a_debuggers_own_poke_trips_nothing) {
    // write_memory is the debugger writing, not the program: it changes the
    // screen overlay's idea of the world, but it is not what a watchpoint is
    // asking about.
    auto m = machine_running({0x00});
    watch(*m, DATA, WATCH_WRITE | WATCH_READ);
    const uint8_t value = 0x77;
    m->write_memory(DATA, &value, 1);
    CHECK(!m->watch_hit.hit);
    CHECK_EQ(int(m->read_memory(DATA, 1)[0]), 0x77);
    CHECK(!m->watch_hit.hit); // nor does reading it back
}

TEST(an_unwatched_machine_records_nothing) {
    auto m = machine_running({0x3E, 0x5A, 0x32, 0x00, 0x90});
    CHECK(m->watch_flags().empty());
    step_until_hit(*m, 2);
    CHECK(!m->watch_hit.hit);

    // Watching and then clearing puts it back exactly as it was.
    watch(*m, DATA, WATCH_WRITE);
    m->set_watch_flags({});
    CHECK(m->watch_flags().empty());
    auto again = machine_running({0x3E, 0x5A, 0x32, 0x00, 0x90});
    step_until_hit(*again, 2);
    CHECK(!again->watch_hit.hit);
}

TEST(a_hit_waits_to_be_read_rather_than_being_lost) {
    // The machine never clears a hit: a driver that only looks every few
    // instructions still sees it. Writes 0x9000 twice, and the first write is
    // the one reported until it is read.
    //
    // LD A,1 / LD (0x9000),A / LD A,2 / LD (0x9000),A
    auto m = machine_running({0x3E, 0x01, 0x32, 0x00, 0x90, 0x3E, 0x02, 0x32, 0x00, 0x90});
    watch(*m, DATA, WATCH_WRITE);
    for (int i = 0; i < 4; i++) {
        m->step_instruction();
    }
    CHECK(m->watch_hit.hit);
    CHECK_EQ(int(m->watch_hit.new_value), 0x01);
    CHECK_EQ(int(m->watch_hit.pc), int(PROGRAM + 2));
}

// ---- through the Engine ---------------------------------------------------------------

namespace {

// DI / LD SP,0xFF00 / then round and round:
//   0x8004  LD A,(0x9001)     the counter
//   0x8007  INC A
//   0x8008  LD (0x9001),A     ...written back
//   0x800B  LD (0x9000),A     ...and to the watched byte
//   0x800E  JR 0x8004
const std::vector<uint8_t> COUNTER = {0xF3, 0x31, 0x00, 0xFF, 0x3A, 0x01, 0x90, 0x3C,
                                      0x32, 0x01, 0x90, 0x32, 0x00, 0x90, 0x18, 0xF4};

/// An Engine running COUNTER, uncapped so a test is not paced to 50Hz.
void start_counter(Engine& engine) {
    engine.set_speed(Speed::Uncapped);
    engine.write_memory(PROGRAM, COUNTER);
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    engine.set_registers(regs);
}

Watchpoint write_watch(uint16_t addr) {
    Watchpoint w;
    w.addr = addr;
    w.on_write = true;
    w.on_change = false;
    return w;
}

/// Runs, and gives up rather than hanging the suite if nothing stops it.
/// `wait_ms` is short where the test EXPECTS nothing to stop it: an uncapped
/// machine runs millions of instructions in that time, so a watchpoint that
/// was going to fire has long since fired.
MachineState run_guarded(Engine& engine, bool& timed_out, int wait_ms = 5000) {
    timed_out = false;
    std::thread watchdog([&engine, &timed_out, wait_ms] {
        for (int i = 0; i * 10 < wait_ms && engine.running(); i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (engine.running()) {
            timed_out = true;
            engine.pause();
        }
    });
    MachineState s = engine.run();
    watchdog.join();
    return s;
}

} // namespace

TEST(a_run_stops_at_a_watched_write_and_says_what_happened) {
    Engine engine;
    StopReason reason = StopReason::Entry;
    engine.on_stopped([&reason](StopReason r, uint16_t) { reason = r; });
    start_counter(engine);
    const uint32_t id = engine.set_watchpoint(write_watch(DATA));

    bool timed_out = false;
    const MachineState s = run_guarded(engine, timed_out);
    CHECK(!timed_out);
    CHECK(reason == StopReason::DataBreakpoint);
    CHECK(s.watch_stop.valid);
    CHECK_EQ(int(s.watch_stop.id), int(id));
    CHECK(s.watch_stop.write);
    CHECK_EQ(int(s.watch_stop.addr), int(DATA));
    CHECK_EQ(int(s.watch_stop.new_value), 1);
    // The LD (0x9000),A that did it, and the JR after it is where PC now is.
    CHECK_EQ(int(s.watch_stop.pc), int(PROGRAM + 11));
    CHECK_EQ(int(s.pc), int(PROGRAM + 14));

    // Running again carries on to the next time round the loop.
    const MachineState again = run_guarded(engine, timed_out);
    CHECK(!timed_out);
    CHECK_EQ(int(again.watch_stop.new_value), 2);
    CHECK_EQ(int(engine.watchpoints()[0].hits), 2);
}

TEST(a_cleared_watchpoint_stops_nothing) {
    Engine engine;
    start_counter(engine);
    const uint32_t id = engine.set_watchpoint(write_watch(DATA));
    CHECK(engine.clear_watchpoint(id));
    CHECK(engine.watchpoints().empty());

    bool timed_out = false;
    run_guarded(engine, timed_out, 300);
    CHECK(timed_out); // nothing to stop it: the watchdog did
}

TEST(a_value_test_only_stops_on_the_value_asked_for) {
    Engine engine;
    start_counter(engine);
    Watchpoint w = write_watch(DATA);
    w.test = Watchpoint::Test::Equals;
    w.value = 4;
    engine.set_watchpoint(w);

    bool timed_out = false;
    const MachineState s = run_guarded(engine, timed_out);
    CHECK(!timed_out);
    CHECK_EQ(int(s.watch_stop.new_value), 4);
}

TEST(on_change_passes_over_a_write_that_changes_nothing) {
    // The counter's byte is written every time round; a watch on 0x9000 that
    // only wants changes still stops (it counts up), but one on a byte
    // written with the same value for ever does not.
    //
    // DI / LD SP / LD A,0x5A / LD (0x9000),A / JR back to the store
    Engine engine;
    engine.set_speed(Speed::Uncapped);
    engine.write_memory(PROGRAM, {0xF3, 0x31, 0x00, 0xFF, 0x3E, 0x5A, 0x32, 0x00, 0x90, 0x18, 0xFB});
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    engine.set_registers(regs);
    Watchpoint w = write_watch(DATA);
    w.on_change = true;
    engine.set_watchpoint(w);

    bool timed_out = false;
    const MachineState first = run_guarded(engine, timed_out);
    CHECK(!timed_out); // the first write changes 0x00 to 0x5A
    CHECK_EQ(int(first.watch_stop.new_value), 0x5A);

    // Every write after that writes the same value again.
    run_guarded(engine, timed_out, 300);
    CHECK(timed_out);
}

TEST(a_watchpoint_set_on_a_running_machine_stops_it) {
    // Watchpoints are queued like breakpoints, and the run loop services the
    // queue at its yields -- so this has to reach a game already running.
    Engine engine;
    start_counter(engine);
    std::thread arm([&engine] {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        engine.set_watchpoint(write_watch(DATA));
    });
    bool timed_out = false;
    const MachineState s = run_guarded(engine, timed_out);
    arm.join();
    CHECK(!timed_out);
    CHECK(s.watch_stop.valid);
    CHECK_EQ(int(s.watch_stop.addr), int(DATA));
}

TEST(stepping_stops_at_a_watched_write_too) {
    Engine engine;
    start_counter(engine);
    engine.set_watchpoint(write_watch(DATA));
    // Far more instructions than the loop needs: the step stops early.
    engine.step(1000);
    const MachineState s = engine.state();
    CHECK(s.watch_stop.valid);
    CHECK_EQ(int(s.watch_stop.addr), int(DATA));
    CHECK_EQ(int(s.pc), int(PROGRAM + 14));
}

RUN_TESTS()
