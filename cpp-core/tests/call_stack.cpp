// The tracked call stack: what the debugger shows as "the frames you are in".
//
// It is inferred, not recorded -- the Z80 has no frame pointer and no notion
// of a call stack at all, so this is CALL and RET watched through SP. That
// works for well-behaved code and quietly fails for the rest: a program that
// discards a return address without a RET (a POP, an LD SP, a handler that
// unwinds by hand) would leave its entry stranded for ever.
//
// It is not a hypothetical. A minute of Cobra left 4412 stranded frames, and
// because VS Code repaints its call stack on every stop, clicking Pause then
// took over four seconds to come back. Hence prune_call_stack, and hence
// these tests.

#include "spectrum.h"
#include "test_main.h"

#include <cstdint>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t PROGRAM = 0x8000;
constexpr uint16_t SUBROUTINE = 0x8100;
constexpr uint16_t STACK_TOP = 0xFF00;

/// Puts `code` at PROGRAM and `subroutine` at SUBROUTINE, and primes the CPU
/// to run from PROGRAM with a known stack.
///
/// Fills a machine the caller owns rather than returning one: Spectrum
/// holds a thread's worth of state and is deliberately neither copyable nor
/// movable.
void setup(Spectrum& machine, const std::vector<uint8_t>& code,
           const std::vector<uint8_t>& subroutine = {}) {
    machine.write_memory(PROGRAM, code.data(), code.size());
    if (!subroutine.empty()) {
        machine.write_memory(SUBROUTINE, subroutine.data(), subroutine.size());
    }
    Registers regs{};
    regs.pc = PROGRAM;
    regs.sp = STACK_TOP;
    machine.prime_cpu(regs);
}

void step(Spectrum& machine, int instructions) {
    for (int i = 0; i < instructions; i++) {
        machine.step_instruction();
    }
}

} // namespace

TEST(a_call_pushes_its_return_address) {
    // CALL 0x8100 / NOP, with a NOP waiting at the subroutine.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00}, {0x00});
    step(machine, 1);

    CHECK_EQ(int(machine.call_stack.size()), 1);
    // The address after the CALL, which is what RET will jump back to.
    CHECK_EQ(int(machine.call_stack[0]), int(PROGRAM + 3));
}

TEST(a_ret_pops_it_again) {
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00}, {0xC9}); // ... / RET
    step(machine, 2);

    CHECK_EQ(int(machine.call_stack.size()), 0);
    CHECK_EQ(int(machine.registers().pc), int(PROGRAM + 3));
}

TEST(a_conditional_call_not_taken_pushes_nothing) {
    // XOR A (sets Z) / CALL NZ,0x8100 -- not taken, so the stack is untouched
    // and there is no frame to show.
    Spectrum machine;
    setup(machine, {0xAF, 0xC4, 0x00, 0x81}, {0x00});
    step(machine, 2);

    CHECK_EQ(int(machine.call_stack.size()), 0);
}

TEST(a_discarded_return_address_drops_its_frame) {
    // The failure this exists for: the subroutine pops its own return address
    // instead of returning through it -- a common way to read data inline
    // after a CALL, and a common way to jump somewhere else entirely.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00}, {0xE1, 0x18, 0xFE}); // POP HL / JR $
    step(machine, 1);
    CHECK_EQ(int(machine.call_stack.size()), 1);

    step(machine, 1); // POP HL
    // SP is back where it started, so the frame is gone -- no RET needed.
    CHECK_EQ(int(machine.call_stack.size()), 0);
}

TEST(abandoning_the_stack_wholesale_drops_every_frame) {
    // LD SP,nn above the frames: an interrupt handler or a loader resetting
    // the stack, which abandons everything on it at once.
    // 0x8000: CALL 0x8100.  0x8100: CALL 0x8110 -- a DIFFERENT address, or the
    // subroutine calls itself for ever and never reaches the LD SP at all.
    // 0x8110: LD SP,0xFF00 / JR $.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00}, {0xCD, 0x10, 0x81, 0x18, 0xFE});
    const uint8_t deeper[] = {0x31, 0x00, 0xFF, 0x18, 0xFE};
    machine.write_memory(0x8110, deeper, sizeof deeper);

    step(machine, 2); // the outer CALL, then the nested one
    CHECK_EQ(int(machine.call_stack.size()), 2);

    step(machine, 1); // LD SP,0xFF00 -- abandons both frames at once
    CHECK_EQ(int(machine.call_stack.size()), 0);
}

TEST(nesting_is_tracked_innermost_last) {
    // CALL 0x8100, and 0x8100 calls itself once more before returning twice.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x00},
                               {0xCD, 0x08, 0x81, 0xC9, 0x00, 0x00, 0x00, 0x00, 0xC9});
    step(machine, 1);
    CHECK_EQ(int(machine.call_stack.size()), 1);
    step(machine, 1);
    CHECK_EQ(int(machine.call_stack.size()), 2);
    // call_stack is oldest first, so the inner frame is last.
    CHECK_EQ(int(machine.call_stack[0]), int(PROGRAM + 3));
    CHECK_EQ(int(machine.call_stack[1]), int(SUBROUTINE + 3));

    step(machine, 1); // the inner RET
    CHECK_EQ(int(machine.call_stack.size()), 1);
    step(machine, 1); // the outer RET
    CHECK_EQ(int(machine.call_stack.size()), 0);
}

TEST(a_deep_run_of_discarded_frames_does_not_accumulate) {
    // The shape of the Cobra bug in miniature: a routine called over and over
    // that never returns through its return address. Without pruning this
    // grows by one frame per iteration for as long as the program runs.
    Spectrum machine;
    setup(machine, {0xCD, 0x00, 0x81, 0x18, 0xFB}, // CALL 0x8100 / JR -5
                               {0xE1, 0xC3, 0x00, 0x80});      // POP HL / JP 0x8000
    for (int i = 0; i < 200; i++) {
        machine.step_instruction();
        CHECK(machine.call_stack.size() <= 1);
    }
}

RUN_TESTS()
