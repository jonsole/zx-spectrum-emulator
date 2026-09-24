// Logpoints: the message language, filling one in from a machine, and the
// Engine reporting them without stopping.
//
// The program the Engine runs is hand-written and every expected line worked
// out from what it does, not taken from what the emulator printed.

#include "engine.h"
#include "logpoint.h"
#include "spectrum.h"
#include "test_main.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM = 0x8000;
constexpr uint16_t DATA = 0x9000;
constexpr uint16_t STACK_TOP = 0xFF00;

/// Knows one symbol, COUNT, at DATA.
bool resolve(const std::string& name, uint16_t& addr) {
    if (name == "COUNT") {
        addr = DATA;
        return true;
    }
    return false;
}

std::vector<LogSegment> parsed(const std::string& text) {
    std::vector<LogSegment> out;
    std::string error;
    CHECK(parse_log_message(text, resolve, out, error));
    CHECK_EQ(error, std::string());
    return out;
}

std::string parse_error(const std::string& text) {
    std::vector<LogSegment> out;
    std::string error;
    CHECK(!parse_log_message(text, resolve, out, error));
    return error;
}

/// A machine with known registers and a few known bytes, for filling
/// messages in. Held through a pointer: a Spectrum is too big for the stack.
std::unique_ptr<Spectrum> machine() {
    auto m = std::make_unique<Spectrum>();
    const uint8_t bytes[] = {0x48, 0x69, 0x0D, 0x01};
    m->write_memory(DATA, bytes, sizeof bytes);
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    regs.a = 0x41;
    regs.h = 0x90;
    regs.l = 0x01;
    regs.ix = 0x8FFE;
    m->prime_cpu(regs);
    return m;
}

//   0x8000  DI
//   0x8001  LD SP,0xFF00
//   0x8004  LD HL,0x9000
//   0x8007  LD A,(HL)      <- the logpoint: the count before it goes up
//   0x8008  INC A
//   0x8009  LD (HL),A
//   0x800A  JR 0x8007
const std::vector<uint8_t> COUNTER = {0xF3, 0x31, 0x00, 0xFF, 0x21, 0x00, 0x90,
                                      0x7E, 0x3C, 0x77, 0x18, 0xFB};
constexpr uint16_t LOOP = 0x8007;

/// Collects what the Engine reports.
struct Collected {
    std::mutex mutex;
    std::vector<LogLine> lines;
    uint64_t dropped = 0;
};

void start_counter(Engine& engine, Collected& got) {
    engine.on_log([&got](const std::vector<LogLine>& lines, uint64_t dropped) {
        std::lock_guard<std::mutex> lock(got.mutex);
        got.lines.insert(got.lines.end(), lines.begin(), lines.end());
        got.dropped += dropped;
    });
    engine.set_speed(Speed::Uncapped);
    engine.write_memory(PROGRAM, COUNTER);
    engine.write_memory(DATA, {16});
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    engine.set_registers(regs);
}

Logpoint logpoint(uint16_t addr, const std::string& message) {
    Logpoint lp;
    lp.addr = addr;
    lp.message = parsed(message);
    return lp;
}

} // namespace

TEST(plain_text_is_one_segment_and_doubled_braces_are_braces) {
    const std::vector<LogSegment> m = parsed("x {{y}} z");
    CHECK_EQ(m.size(), size_t(1));
    CHECK(m[0].kind == LogSegment::Kind::Text);
    CHECK_EQ(m[0].text, std::string("x {y} z"));
}

TEST(holes_are_registers_or_memory_with_their_formats) {
    const std::vector<LogSegment> m = parsed("{A:c}{(HL)}{(COUNT+2):d}{($9000):w}{(IX-1)}");
    CHECK_EQ(m.size(), size_t(5));
    CHECK(m[0].kind == LogSegment::Kind::Register);
    CHECK_EQ(m[0].text, std::string("A"));
    CHECK_EQ(int(m[0].format), int('c'));
    CHECK(m[1].kind == LogSegment::Kind::Memory);
    CHECK_EQ(m[1].text, std::string("HL"));
    CHECK_EQ(int(m[1].addr), 0);
    // A symbol is resolved when parsed, so a hit has no lookup to do.
    CHECK(m[2].kind == LogSegment::Kind::Memory);
    CHECK_EQ(m[2].text, std::string());
    CHECK_EQ(int(m[2].addr), int(DATA + 2));
    CHECK_EQ(int(m[2].format), int('d'));
    CHECK(m[3].word);
    CHECK_EQ(int(m[3].addr), int(DATA));
    CHECK_EQ(m[4].text, std::string("IX"));
    CHECK_EQ(int(m[4].addr), 0xFFFF);
}

TEST(bad_messages_say_what_is_wrong) {
    CHECK(parse_error("{A").find("no }") != std::string::npos);
    CHECK(parse_error("A}").find("no {") != std::string::npos);
    CHECK(parse_error("{Q}").find("not a register") != std::string::npos);
    CHECK(parse_error("{(NOWHERE)}").find("NOWHERE") != std::string::npos);
    CHECK(parse_error("{A:z}").find("not a format") != std::string::npos);
}

TEST(a_message_is_filled_in_from_the_machine) {
    auto m = machine();
    // A = 0x41 'A'; HL = 0x9001, holding 0x69 'i'; COUNT is 0x48 'H'; the
    // word at 0x9002 is 0x0D then 0x01, so 0x010D; IX+2 = 0x9000.
    CHECK_EQ(format_log_message(parsed("{A} {A:d} {A:c}"), *m), std::string("0x41 65 A"));
    CHECK_EQ(format_log_message(parsed("{HL} {(HL):c}"), *m), std::string("0x9001 i"));
    CHECK_EQ(format_log_message(parsed("{(COUNT):c}{(COUNT+1):c}{(COUNT+2):c}"), *m),
             std::string("Hi\n"));
    CHECK_EQ(format_log_message(parsed("{(COUNT+2):w} {(COUNT+2):wd}"), *m),
             std::string("0x010D 269"));
    CHECK_EQ(format_log_message(parsed("{(IX+2):c} {(COUNT+3):c}"), *m), std::string("H \\x01"));
}

TEST(the_engine_reports_each_time_round_and_does_not_stop) {
    Engine engine;
    Collected got;
    start_counter(engine, got);
    const uint32_t id = engine.set_logpoint(logpoint(LOOP, "count {(HL):d}"));

    // Three instructions to reach the loop, then four a time round it: eleven
    // reach LOOP three times, with the count 16, 17 and 18 as each arrives.
    engine.step(11);
    {
        std::lock_guard<std::mutex> lock(got.mutex);
        CHECK_EQ(got.lines.size(), size_t(3));
        CHECK_EQ(got.lines[0].text, std::string("count 16"));
        CHECK_EQ(got.lines[1].text, std::string("count 17"));
        CHECK_EQ(got.lines[2].text, std::string("count 18"));
        CHECK_EQ(int(got.lines[0].id), int(id));
        CHECK_EQ(int(got.lines[0].pc), int(LOOP));
        CHECK_EQ(got.dropped, uint64_t(0));
    }
    const std::vector<Logpoint> all = engine.logpoints();
    CHECK_EQ(all.size(), size_t(1));
    CHECK_EQ(all[0].hits, uint64_t(3));
    // It reported and let the machine go on: PC is back at LOOP, not held
    // there, and the count has gone up twice -- the third report is of the
    // 18 that LD A,(HL) is about to read, before anything adds to it.
    CHECK_EQ(int(engine.registers().pc), int(LOOP));
    CHECK_EQ(int(engine.read_memory(DATA, 1)[0]), 18);
}

TEST(a_cleared_logpoint_reports_nothing) {
    Engine engine;
    Collected got;
    start_counter(engine, got);
    const uint32_t id = engine.set_logpoint(logpoint(LOOP, "count {(HL):d}"));
    CHECK(engine.clear_logpoint(id));
    CHECK(engine.logpoints().empty());
    engine.step(11);
    std::lock_guard<std::mutex> lock(got.mutex);
    CHECK(got.lines.empty());
}

TEST(two_logpoints_at_one_address_both_report_in_the_order_set) {
    Engine engine;
    Collected got;
    start_counter(engine, got);
    engine.set_logpoint(logpoint(LOOP, "first"));
    engine.set_logpoint(logpoint(LOOP, "second {A}"));
    engine.step(3);
    std::lock_guard<std::mutex> lock(got.mutex);
    CHECK_EQ(got.lines.size(), size_t(2));
    CHECK_EQ(got.lines[0].text, std::string("first"));
    // A is still 0: LD A,(HL) is the instruction about to run, not one done.
    CHECK_EQ(got.lines[1].text, std::string("second 0x00"));
}

RUN_TESTS()
