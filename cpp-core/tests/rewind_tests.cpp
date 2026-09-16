// Rewind: saving and restoring the machine, and the history built on that.
//
// Everything here rests on one property -- restore a state, feed the same
// inputs, and the machine runs exactly as it did -- so the first tests hold
// save/restore to it directly, comparing whole-state hashes. The rest check
// each backward operation against the run it goes back over: the test notes
// every instruction boundary as the program first runs, and a step back must
// land on exactly the boundary the operation's rule picks, with exactly the
// state the machine had there.
//
// Only built with ZX_REWIND (see CMakeLists.txt).

#include "rewind.h"
#include "spectrum.h"
#include "test_main.h"

#include <cstdint>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM = 0x8000;

// DI / LD SP,0xFF00 / then round and round:
//   0x8004  CALL 0x8100
//   0x8007  LD (0x9000),A
//   0x800A  INC A
//   0x800B  JR 0x8004
//   0x8100  LD B,5
//   0x8102  DJNZ 0x8102
//   0x8104  LD (0x9001),A
//   0x8107  RET
const std::vector<uint8_t> MAIN = {0xF3, 0x31, 0x00, 0xFF, 0xCD, 0x00, 0x81, 0x32,
                                   0x00, 0x90, 0x3C, 0x18, 0xF7};
const std::vector<uint8_t> SUB = {0x06, 0x05, 0x10, 0xFE, 0x32, 0x01, 0x90, 0xC9};

// DI / LD A,0xFE / IN A,(0xFE) / LD (0x9000),A / JR 0x8001 -- reads the
// keyboard's bottom-left half-row for ever.
const std::vector<uint8_t> READ_KEYS = {0xF3, 0x3E, 0xFE, 0xDB, 0xFE,
                                        0x32, 0x00, 0x90, 0x18, 0xF7};

/// A Spectrum is too big for the stack and not movable, so tests hold one
/// through a pointer.
std::unique_ptr<Spectrum> machine_running(const std::vector<uint8_t>& main,
                                          const std::vector<uint8_t>& sub = {}) {
    auto m = std::make_unique<Spectrum>();
    m->write_memory(PROGRAM, main.data(), main.size());
    if (!sub.empty()) {
        m->write_memory(0x8100, sub.data(), sub.size());
    }
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = 0xFF00;
    m->prime_cpu(regs);
    return m;
}

bool load_rom(Spectrum& m, const char* name) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/" + name, std::ios::binary);
    if (!f) {
        std::printf("  (skipped: roms/%s not found)\n", name);
        return false;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return m.load_rom(rom.data(), rom.size()).empty();
}

uint64_t hash_of(Spectrum& m) {
    Spectrum::State s;
    m.save_state(s);
    return Spectrum::state_hash(s);
}

void run_frames(Spectrum& m, int frames) {
    for (int i = 0; i < frames; i++) {
        m.run_frame();
    }
}

/// An instruction boundary as the program first ran through it.
struct Boundary {
    uint64_t hc;
    uint16_t pc;
    size_t depth;
};

/// Runs as the Engine will: the history told after every instruction.
/// Notes each boundary before its instruction runs.
void run(Spectrum& m, History& h, int instructions, std::vector<Boundary>* seen = nullptr) {
    for (int i = 0; i < instructions; i++) {
        if (seen) {
            seen->push_back({m.global_hc(), m.registers().pc, m.call_stack.size()});
        }
        m.step_instruction();
        h.on_instruction(m);
    }
}

/// Runs until PC reaches `pc`, as `run` does.
void run_to(Spectrum& m, History& h, uint16_t pc, std::vector<Boundary>* seen = nullptr) {
    run(m, h, 1, seen);
    while (m.registers().pc != pc) {
        run(m, h, 1, seen);
    }
}

RewindSettings small_history() {
    RewindSettings s;
    s.checkpoint_frames = 2;
    return s;
}

const auto never = [] { return false; };

} // namespace

// ---- save and restore -------------------------------------------------------------

TEST(a_restored_machine_runs_on_exactly_as_it_did) {
    auto m = machine_running(MAIN, SUB);
    run_frames(*m, 3);
    for (int i = 0; i < 1234; i++) {
        m->step_instruction(); // somewhere mid-frame
    }
    Spectrum::State saved;
    m->save_state(saved);
    const uint64_t at_save = Spectrum::state_hash(saved);
    run_frames(*m, 5);
    const uint64_t later = hash_of(*m);
    CHECK(later != at_save);

    m->restore_state(saved);
    CHECK_EQ(hash_of(*m), at_save);
    run_frames(*m, 5);
    CHECK_EQ(hash_of(*m), later);
}

TEST(a_restore_mid_instruction_carries_on_mid_instruction) {
    auto m = machine_running(MAIN, SUB);
    m->step_instruction();
    m->step_instruction();
    for (int i = 0; i < 5; i++) {
        m->clock(); // part-way through the CALL
    }
    Spectrum::State saved;
    m->save_state(saved);
    for (int i = 0; i < 1000; i++) {
        m->clock();
    }
    const uint64_t later = hash_of(*m);
    m->restore_state(saved);
    for (int i = 0; i < 1000; i++) {
        m->clock();
    }
    CHECK_EQ(hash_of(*m), later);
}

TEST(the_rom_booting_is_the_same_after_a_restore) {
    auto m = std::make_unique<Spectrum>();
    if (!load_rom(*m, "48.rom")) {
        return;
    }
    m->reset();
    run_frames(*m, 20); // part-way through the boot's RAM test
    Spectrum::State saved;
    m->save_state(saved);
    run_frames(*m, 40);
    const uint64_t booted = hash_of(*m);
    const std::vector<uint8_t> screen = m->screen();

    m->restore_state(saved);
    run_frames(*m, 40);
    CHECK_EQ(hash_of(*m), booted);
    CHECK(m->screen() == screen);
}

TEST(a_128k_restore_puts_the_paging_back) {
    auto m = std::make_unique<Spectrum>();
    m->set_model(Model::Spectrum128);
    if (!load_rom(*m, "128.rom")) {
        return;
    }
    m->reset();
    run_frames(*m, 30);
    Spectrum::State saved;
    m->save_state(saved);
    const uint8_t paging = saved.memory.paging;
    m->write_paging(uint8_t(paging ^ 0x07)); // a different bank at 0xC000
    run_frames(*m, 30);
    const uint64_t later = hash_of(*m);

    m->restore_state(saved);
    CHECK_EQ(int(m->memory.paging()), int(paging));
    m->write_paging(uint8_t(paging ^ 0x07));
    run_frames(*m, 30);
    CHECK_EQ(hash_of(*m), later);
}

// ---- determinism ------------------------------------------------------------------------
//
// The test the whole feature rests on. A real program runs -- the ROM booting,
// keys typed through the log, a tape loaded through the fast-load trap, a
// debugger's register edit sending it into code that borrows SP and HALTs
// under interrupts -- hashing the machine at every frame boundary. Then
// replays from checkpoints across the run must reproduce every hash. A member
// left out of a checkpoint shows up as a divergence at the frame it first
// mattered.

namespace {

struct FrameHash {
    uint64_t hc;
    uint64_t hash;
};

/// Drives a machine as the Engine does, recording through `h` and hashing at
/// each frame boundary before the instruction after it runs -- the same
/// instant a replay's per-instruction callback sees.
struct Recorder {
    Spectrum& m;
    History& h;
    Keyboard kb;
    std::vector<FrameHash> hashes;
    uint64_t last_frame;

    Recorder(Spectrum& machine, History& history)
        : m(machine), h(history), last_frame(machine.ula.frame_count()) {}

    void frames(int n) {
        const uint64_t end = m.ula.frame_count() + uint64_t(n);
        while (m.ula.frame_count() < end) {
            if (m.ula.frame_count() != last_frame) {
                last_frame = m.ula.frame_count();
                hashes.push_back({m.global_hc(), hash_of(m)});
            }
            m.step_instruction();
            h.on_instruction(m);
        }
    }

    void keys() {
        RewindInput input;
        input.kind = RewindInputKind::Keys;
        std::copy(kb.rows(), kb.rows() + 8, input.keys);
        h.record(m, input);
    }

    /// Four frames down and four up, which the ROM's debounce is happy with.
    void press(const char* key, const char* shift = nullptr) {
        if (shift != nullptr) {
            kb.key_down(shift);
        }
        kb.key_down(key);
        keys();
        frames(4);
        kb.key_up(key);
        if (shift != nullptr) {
            kb.key_up(shift);
        }
        keys();
        frames(4);
    }
};

/// Replays from checkpoint `index` to `end_hc` and checks each frame hash the
/// replay passes against the recording.
void check_replay(Spectrum& m, History& h, const std::vector<FrameHash>& recorded, size_t index,
                  uint64_t end_hc) {
    const uint64_t from = h.checkpoints()[index].hc;
    uint64_t last = h.checkpoints()[index].state.ula.frame_count;
    std::vector<FrameHash> replayed;
    h.replay(m, index, end_hc, [&](Spectrum& r) {
        if (r.ula.frame_count() != last) {
            last = r.ula.frame_count();
            replayed.push_back({r.global_hc(), hash_of(r)});
        }
    });
    CHECK_EQ(m.global_hc(), end_hc);
    std::vector<FrameHash> expected;
    for (const FrameHash& f : recorded) {
        if (f.hc > from && f.hc < end_hc) {
            expected.push_back(f);
        }
    }
    CHECK_EQ(replayed.size(), expected.size());
    size_t mismatches = 0;
    for (size_t j = 0; j < replayed.size() && j < expected.size(); j++) {
        if (replayed[j].hc != expected[j].hc || replayed[j].hash != expected[j].hash) {
            if (mismatches == 0) {
                std::printf("    replay from checkpoint %zu first diverges at hc %llu\n", index,
                            (unsigned long long)replayed[j].hc);
            }
            mismatches++;
        }
    }
    CHECK_EQ(mismatches, size_t(0));
}

/// A .tap of one CODE file, as the ROM saves it: header block, data block.
std::vector<uint8_t> code_tap(const std::vector<uint8_t>& code, uint16_t start) {
    auto block = [](uint8_t flag, const std::vector<uint8_t>& payload) {
        std::vector<uint8_t> b;
        b.push_back(flag);
        b.insert(b.end(), payload.begin(), payload.end());
        uint8_t parity = 0;
        for (uint8_t v : b) {
            parity = uint8_t(parity ^ v);
        }
        b.push_back(parity);
        return b;
    };
    std::vector<uint8_t> header = {3, 't', 'e', 's', 't', ' ', ' ', ' ', ' ', ' ', ' '};
    header.push_back(uint8_t(code.size()));
    header.push_back(uint8_t(code.size() >> 8));
    header.push_back(uint8_t(start));
    header.push_back(uint8_t(start >> 8));
    header.push_back(0x00);
    header.push_back(0x80);
    std::vector<uint8_t> tap;
    for (const auto& b : {block(0x00, header), block(0xFF, code)}) {
        tap.push_back(uint8_t(b.size()));
        tap.push_back(uint8_t(b.size() >> 8));
        tap.insert(tap.end(), b.begin(), b.end());
    }
    return tap;
}

} // namespace

TEST(replays_reproduce_a_48k_loading_a_tape_and_running_what_it_loaded) {
    auto m = std::make_unique<Spectrum>();
    if (!load_rom(*m, "48.rom")) {
        return;
    }
    m->reset();
    // 0x8000  EI / LD HL,0 / ADD HL,SP / LD SP,0xC000 / LD B,16
    // 0x800A  PUSH BC / DJNZ 0x800A / LD SP,HL / HALT / JR 0x8000
    const std::vector<uint8_t> code = {0xFB, 0x21, 0x00, 0x00, 0x39, 0x31, 0x00, 0xC0, 0x06, 0x10,
                                       0xC5, 0x10, 0xFD, 0xF9, 0x76, 0x18, 0xEF};
    const std::vector<uint8_t> tap = code_tap(code, 0x8000);
    CHECK(m->tape.insert(tap.data(), tap.size(), "test").empty());

    run_frames(*m, 90); // most of the way to the copyright message
    History h;
    h.start(*m);
    Recorder run(*m, h);
    run.frames(10);
    run.press("J");                         // LOAD
    run.press("P", "SYM SHIFT");            // "
    run.press("P", "SYM SHIFT");            // "
    run.press("SYM SHIFT", "CAPS SHIFT");   // extended mode
    run.press("I");                         // CODE
    // Play before ENTER, so the tape is running when the ROM reaches LD-BYTES
    // and the fast-load trap takes it.
    RewindInput play;
    play.kind = RewindInputKind::TapePlay;
    h.record(*m, play);
    run.press("ENTER");
    run.frames(50);
    CHECK(m->read_memory(0x8000, code.size()) == code);

    RewindInput jump;
    jump.kind = RewindInputKind::Registers;
    jump.regs = m->registers();
    jump.regs.pc = 0x8000;
    h.record(*m, jump);
    run.frames(40);
    const uint64_t end_hc = m->global_hc();
    const uint64_t end_hash = hash_of(*m);
    const size_t checkpoints = h.checkpoint_count();
    CHECK(checkpoints > 12);

    // A few checkpoints' worth from every other one -- restores at every
    // stage of the run -- then one all the way from the start, for a missed
    // member that takes a while to matter.
    for (size_t i = 1; i + 2 < checkpoints; i += 2) {
        check_replay(*m, h, run.hashes, i, h.checkpoints()[i + 2].hc);
    }
    check_replay(*m, h, run.hashes, 0, end_hc);
    CHECK_EQ(hash_of(*m), end_hash);
}

TEST(replays_reproduce_a_128k_paging_its_roms_in_the_menu_and_editor) {
    auto m = std::make_unique<Spectrum>();
    m->set_model(Model::Spectrum128);
    if (!load_rom(*m, "128.rom")) {
        return;
    }
    m->reset();
    History h;
    h.start(*m); // from power-on, through the ROMs' own paging
    Recorder run(*m, h);
    run.frames(60);
    run.press("6", "CAPS SHIFT"); // down, to 128 BASIC
    run.press("ENTER");
    run.frames(20);
    const uint64_t end_hc = m->global_hc();
    const uint64_t end_hash = hash_of(*m);

    check_replay(*m, h, run.hashes, 3, h.checkpoints()[5].hc);
    check_replay(*m, h, run.hashes, 1, end_hc);
    CHECK_EQ(hash_of(*m), end_hash);
}

// ---- stepping back ------------------------------------------------------------------

TEST(step_back_into_lands_on_each_previous_instruction_in_turn) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    std::vector<Boundary> seen;
    // Far enough to cross several checkpoints on the way back.
    run(*m, h, 60000, &seen);
    CHECK(h.checkpoint_count() > 3);

    for (int back = 1; back <= 5; back++) {
        const auto r = h.go_back(*m, RewindOp::StepBackInto, 0, never);
        CHECK(r.moved);
        const Boundary& b = seen[seen.size() - back];
        CHECK_EQ(m->global_hc(), b.hc);
        CHECK_EQ(int(m->registers().pc), int(b.pc));
        CHECK_EQ(m->call_stack.size(), b.depth);
    }
    CHECK(!h.live());
}

TEST(a_step_back_restores_the_whole_state_the_machine_had_there) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 40000);
    const uint64_t before = hash_of(*m);
    const uint64_t before_hc = m->global_hc();
    run(*m, h, 1);

    h.go_back(*m, RewindOp::StepBackInto, 0, never);
    CHECK_EQ(m->global_hc(), before_hc);
    CHECK_EQ(hash_of(*m), before);
}

TEST(step_back_out_lands_on_the_call) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 30000);
    run_to(*m, h, 0x8102); // inside the subroutine's DJNZ loop
    CHECK_EQ(m->call_stack.size(), size_t(1));

    const auto r = h.go_back(*m, RewindOp::StepBackOut, 0, never);
    CHECK(r.moved);
    CHECK_EQ(int(m->registers().pc), 0x8004);
    CHECK_EQ(m->call_stack.size(), size_t(0));
}

TEST(step_back_over_passes_over_a_call_just_returned_from) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 30000);
    run_to(*m, h, 0x8007); // just back from the subroutine

    h.go_back(*m, RewindOp::StepBackOver, 0, never);
    CHECK_EQ(int(m->registers().pc), 0x8004);

    // Where Step Back Into goes instead: the RET.
    run_to(*m, h, 0x8007);
    h.go_back(*m, RewindOp::StepBackInto, 0, never);
    CHECK_EQ(int(m->registers().pc), 0x8107);
}

TEST(run_back_to_write_finds_the_instruction_that_wrote) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 30000);
    run_to(*m, h, 0x800B);

    h.go_back(*m, RewindOp::RunBackToWrite, 0x9001, never);
    CHECK_EQ(int(m->registers().pc), 0x8104);
    run_to(*m, h, 0x800B);
    h.go_back(*m, RewindOp::RunBackToWrite, 0x9000, never);
    CHECK_EQ(int(m->registers().pc), 0x8007);
}

TEST(reverse_continue_stops_at_a_breakpoint_or_the_start_of_the_history) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    const uint64_t start = m->global_hc();
    run(*m, h, 30000);
    run_to(*m, h, 0x800A);

    m->breakpoints.insert(0x8104);
    h.go_back(*m, RewindOp::ReverseContinue, 0, never);
    CHECK_EQ(int(m->registers().pc), 0x8104);

    m->breakpoints.clear();
    const auto r = h.go_back(*m, RewindOp::ReverseContinue, 0, never);
    CHECK(r.moved);
    CHECK_EQ(m->global_hc(), start);
}

TEST(run_back_to_an_address_searches_the_whole_history) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 1); // DI
    const uint64_t at_ld_sp = m->global_hc();
    run(*m, h, 80000);
    CHECK(h.checkpoint_count() > 5);

    h.go_back(*m, RewindOp::RunBackToAddress, 0x8001, never);
    CHECK_EQ(m->global_hc(), at_ld_sp);
    CHECK_EQ(int(m->registers().pc), 0x8001);
}

TEST(a_search_that_finds_nothing_leaves_the_machine_where_it_was) {
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 20000);
    const uint64_t here = hash_of(*m);

    const auto r = h.go_back(*m, RewindOp::RunBackToAddress, 0x1234, never);
    CHECK(!r.moved);
    CHECK_EQ(hash_of(*m), here);
    CHECK(h.live());
}

// ---- watchpoints ------------------------------------------------------------------------

namespace {

/// Watches one address for writes, as the Engine's watchpoints do.
void watch_writes(Spectrum& m, uint16_t addr) {
    std::vector<uint8_t> flags(WATCH_ADDRESSES, 0);
    flags[addr] = WATCH_WRITE;
    m.set_watch_flags(std::move(flags));
}

} // namespace

TEST(reverse_continue_stops_at_the_previous_watchpoint_hit) {
    // Running backwards stops where running forwards would. MAIN writes
    // 0x9000 from 0x8007 every time round its loop.
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 30000);
    run_to(*m, h, 0x800B); // just past the write
    watch_writes(*m, 0x9000);

    const auto r = h.go_back(*m, RewindOp::ReverseContinue, 0, never);
    CHECK(r.moved);
    // Before the instruction that wrote, so one step forward shows it happen.
    CHECK_EQ(int(m->registers().pc), 0x8007);
}

TEST(a_watchpoint_does_not_fire_while_the_past_replays) {
    // A replay runs thousands of instructions the program already ran; a
    // watchpoint firing there would stop the machine over and over on its way
    // back to a boundary it was asked for.
    auto m = machine_running(MAIN, SUB);
    History h(small_history());
    h.start(*m);
    run(*m, h, 30000);
    watch_writes(*m, 0x9000);
    m->watch_hit = WatchHit();

    h.go_back(*m, RewindOp::StepBackInto, 0, never);
    CHECK(!m->watch_hit.hit);
    // ...and the machine is still watching what it was told to watch.
    CHECK_EQ(m->watch_flags().size(), WATCH_ADDRESSES);
    CHECK_EQ(int(m->watch_flags()[0x9000]), int(WATCH_WRITE));
}

// ---- forward again, and new timelines -------------------------------------------------

TEST(running_forward_from_the_past_replays_the_keys_and_reaches_the_head) {
    auto m = machine_running(READ_KEYS);
    History h(small_history());
    h.start(*m);
    run(*m, h, 20000);
    uint8_t rows[8] = {0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F};
    rows[0] = 0x1E; // CAPS SHIFT down
    RewindInput down;
    down.kind = RewindInputKind::Keys;
    std::copy(rows, rows + 8, down.keys);
    h.record(*m, down);
    run(*m, h, 20000);
    const uint8_t while_held = m->read_memory(0x9000, 1)[0];
    RewindInput up;
    up.kind = RewindInputKind::Keys;
    std::fill(up.keys, up.keys + 8, uint8_t(0x1F));
    h.record(*m, up);
    run(*m, h, 20000);
    const uint64_t head = hash_of(*m);
    const uint64_t head_hc = m->global_hc();
    CHECK_EQ(while_held & 0x1F, 0x1E);

    h.go_back(*m, RewindOp::ReverseContinue, 0, never); // to the start
    CHECK(!h.live());
    while (m->global_hc() < head_hc) {
        m->step_instruction();
        h.on_instruction(*m);
    }
    CHECK_EQ(m->global_hc(), head_hc);
    CHECK(h.live());
    CHECK_EQ(hash_of(*m), head);
}

TEST(a_key_pressed_in_the_past_starts_a_new_timeline) {
    auto m = machine_running(READ_KEYS);
    History h(small_history());
    h.start(*m);
    run(*m, h, 60000);
    const size_t checkpoints = h.checkpoint_count();

    // Back to the middle, and press a key there.
    h.go_back(*m, RewindOp::ReverseContinue, 0, never);
    run(*m, h, 30000);
    CHECK(!h.live());
    const uint64_t branch_hc = m->global_hc();
    RewindInput down;
    down.kind = RewindInputKind::Keys;
    std::fill(down.keys, down.keys + 8, uint8_t(0x1F));
    down.keys[0] = 0x1E;
    h.record(*m, down);

    CHECK(h.live());
    CHECK_EQ(h.head_hc(*m), branch_hc);
    CHECK(h.checkpoint_count() < checkpoints);
    CHECK(h.checkpoints().back().hc <= branch_hc);

    // The new timeline is recorded like the first: go back and forward over
    // it and the key is still held.
    run(*m, h, 10000);
    const uint64_t head = hash_of(*m);
    const uint64_t head_hc = m->global_hc();
    h.go_back(*m, RewindOp::RunBackToAddress, 0x8001, never);
    while (m->global_hc() < head_hc) {
        m->step_instruction();
        h.on_instruction(*m);
    }
    CHECK_EQ(hash_of(*m), head);
    CHECK_EQ(m->read_memory(0x9000, 1)[0] & 0x1F, 0x1E);
}

TEST(the_window_drops_the_oldest_checkpoints) {
    auto m = machine_running(MAIN, SUB);
    RewindSettings settings;
    settings.checkpoint_frames = 1;
    settings.max_seconds = 1;
    History h(settings);
    h.start(*m);
    // A second and a half, a frame at a time.
    for (int f = 0; f < 75; f++) {
        const uint64_t frame = m->ula.frame_count();
        while (m->ula.frame_count() == frame) {
            m->step_instruction();
            h.on_instruction(*m);
        }
    }
    const uint64_t window = m->ula.timing().hc_per_sec;
    CHECK(m->global_hc() - h.oldest_hc() >= window);
    CHECK(m->global_hc() - h.oldest_hc() < window + 2 * m->ula.timing().hc_per_frame());
    CHECK(h.checkpoint_count() <= 52);
    CHECK(h.checkpoint_count() >= 50);
}

RUN_TESTS()
