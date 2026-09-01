#pragma once
// Spectrum48K: the whole machine -- Z80, ULA, memory and keyboard on one bus.
//
// clock() advances one HALF-T-STATE (7MHz). Within it the order is the same
// as the hardware's:
//
//   1. the ULA is clocked first -- it drives INT and (later) decides whether
//      the CPU may proceed at all;
//   2. the CPU is clocked, IF the ULA is letting its clock through;
//   3. this class decodes whatever the CPU put on the bus and services it.
//
// The machine owns the bus decode, not the CPU. That is both how the hardware
// works and what lets the ULA see a real address on a real clock edge, which
// is the entire point of the half-T-state model.

#include "beeper.h"
#include "keyboard.h"
#include "memory.h"
#include "tape.h"
#include "tracelog.h"
#include "ula.h"
#include "z80.h"

#include <cstdint>
#include <set>
#include <string>
#include <vector>

namespace zx {

class Spectrum48K {
public:
    Z80 cpu;
    Spectrum48KMemory memory;
    Ula ula;
    Beeper beeper;
    Keyboard keyboard;
    Tape tape;

    std::set<uint16_t> breakpoints;

    /// Optional cycle-by-cycle bus recorder, null when not tracing. Owned by
    /// whoever turned tracing on (the Engine), not by the machine -- a trace
    /// outlives individual run/step commands and has a file handle to close.
    TraceLog* trace = nullptr;

    /// Return addresses of CALL/RST frames currently open below the current
    /// PC, oldest first. Maintained by step_instruction(). Cleared whenever
    /// registers are set wholesale (reset, snapshot load, a debugger moving
    /// PC), since any of those can leave normal call/return flow and a stale
    /// chain is worse than none.
    std::vector<uint16_t> call_stack;

    Spectrum48K();

    /// Advances one half-T-state.
    void clock();

    /// Advances one whole T-state (two half-clocks). Convenience for callers
    /// that think in T-states, e.g. a debugger's "step N T-states".
    void tick() { clock(); clock(); }

    /// Runs until the current instruction completes.
    void step_instruction();

    /// Runs one whole video frame (to the next interrupt).
    void run_frame();

    /// Half-T-states since power-on. The ULA's frame counter and in-frame
    /// position combined into the one monotonic clock that anything outside
    /// the machine (pacing, progress reporting, audio timestamps) reasons in.
    uint64_t global_hc() const {
        return ula.frame_count() * uint64_t(HC_PER_FRAME) + ula.frame_hc();
    }

    Registers registers() const { return cpu.registers(); }
    void set_registers(const Registers& r);

    /// Loads registers and performs the CPU's priming half-clock, giving the
    /// ULA that same half-clock so the two stay in step. See the definition.
    void prime_cpu(const Registers& r);

    /// Empty string on success, else the error message.
    std::string load_rom(const uint8_t* data, size_t len);

    std::vector<uint8_t> read_memory(uint16_t addr, size_t length);
    void write_memory(uint16_t addr, const uint8_t* data, size_t length);

    /// Last completed frame, RGB, border included.
    const std::vector<uint8_t>& screen() const { return ula.screen(); }

    void reset();

private:
    uint64_t pins_ = PINS_IDLE;

    /// Decodes MREQ/IORQ and services memory or I/O.
    void service_bus();

    /// True when the bytes at LD_BYTES really are the stock ROM's loader.
    /// Without this check any program that happened to execute at 0x0556 --
    /// a different ROM, a snapshot that jumped there -- would be silently
    /// hijacked by the tape trap.
    bool stock_ld_bytes();
    /// Satisfies one standard-speed tape block in place of the ROM's LD-BYTES
    /// and returns as if from its final RET. False means "declined": the tape
    /// is stopped, finished, or the next block is not something the ROM loader
    /// could have read, so the real routine must run against real pulses.
    bool fast_load_block();
};

} // namespace zx
