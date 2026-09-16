#pragma once
// Spectrum: the whole machine -- Z80, ULA, memory, keyboard and (on a 128K)
// the AY sound chip on one bus. Which machine it is -- a 48K or a 128K -- is
// a runtime choice, see set_model.
//
// clock() advances one HALF-T-STATE (7MHz on a 48K). Within it the order is
// the same as the hardware's:
//
//   1. the ULA is clocked first -- it drives INT and (later) decides whether
//      the CPU may proceed at all;
//   2. the CPU is clocked, IF the ULA is letting its clock through;
//   3. this class decodes whatever the CPU put on the bus and services it.
//
// The machine owns the bus decode, not the CPU. That is both how the hardware
// works and what lets the ULA see a real address on a real clock edge, which
// is the entire point of the half-T-state model.

#include "ay.h"
#include "beeper.h"
#include "keyboard.h"
#include "memory.h"
#include "profile.h"
#include "tape.h"
#include "tracelog.h"
#include "ula.h"
#include "z80.h"

#include <cstdint>
#include <set>
#include <string>
#include <vector>

namespace zx {

class Spectrum {
public:
    Z80 cpu;
    SpectrumMemory memory;
    Ula ula;
    Beeper beeper;
    /// Only wired to the bus on a 128K; a 48K's is never selected, written
    /// or mixed. Kept in the machine whatever the model so a model switch
    /// need not allocate anything.
    Ay ay;
    Keyboard keyboard;
    Tape tape;

    std::set<uint16_t> breakpoints;

    /// Optional cycle-by-cycle bus recorder, null when not tracing. Owned by
    /// whoever turned tracing on (the Engine), not by the machine -- a trace
    /// outlives individual run/step commands and has a file handle to close.
    TraceLog* trace = nullptr;

    /// Where each instruction's time goes, null when not profiling -- see
    /// profile.h. Owned by the Engine, for the same reason the trace is: it
    /// outlives any one run, and is read back after the machine stops.
    /// Counted in step_instruction(), which costs one pointer test per
    /// instruction while this is null.
    Profile* profile = nullptr;

    /// Return addresses of CALL/RST frames currently open below the current
    /// PC, oldest first. Maintained by step_instruction(). Cleared whenever
    /// registers are set wholesale (reset, snapshot load, a debugger moving
    /// PC), since any of those can leave normal call/return flow and a stale
    /// chain is worse than none.
    std::vector<uint16_t> call_stack;

#if ZX_REWIND
    /// An address whose CPU writes rewind is searching for, or -1. A write to
    /// it sets write_watch_hit; nothing else changes. Only compiled in with
    /// rewind, so the bus decode stays as it was without it.
    int32_t write_watch = -1;
    bool write_watch_hit = false;
#endif

    /// A 48K. See set_model for the 128K.
    Spectrum();

    /// Which Spectrum this is.
    Model model() const { return memory.model(); }
    /// Makes the machine the other model and resets it: the memory map, the
    /// ULA's frame timing, the beeper's clock and whether the AY answers the
    /// bus all follow. RAM and the loaded ROMs are kept, so a 128K's ROM pair
    /// loaded on a 48K is there the moment a 128K snapshot asks for it.
    void set_model(Model m);

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
        return ula.frame_count() * uint64_t(ula.timing().hc_per_frame()) + ula.frame_hc();
    }

    Registers registers() const { return cpu.registers(); }
    void set_registers(const Registers& r);

    /// Loads registers and performs the CPU's priming half-clock, giving the
    /// ULA that same half-clock so the two stay in step. See the definition.
    void prime_cpu(const Registers& r);

    /// Empty string on success, else the error message. A 16K image is the
    /// 48K's ROM, a 32K one the 128K's pair; see SpectrumMemory::load_rom.
    std::string load_rom(const uint8_t* data, size_t len);

    std::vector<uint8_t> read_memory(uint16_t addr, size_t length);
    void write_memory(uint16_t addr, const uint8_t* data, size_t length);

    /// Writes port 0x7FFD as a program would, paging included -- and tells
    /// the ULA which bank it is now displaying. What a snapshot loader and a
    /// debugger use rather than poking the memory map directly, so the two
    /// cannot disagree. Ignored on a 48K, as the port is.
    void write_paging(uint8_t value);

    /// Last completed frame, RGB, border included.
    const std::vector<uint8_t>& screen() const { return ula.screen(); }

    void reset();

#if ZX_REWIND
    /// The whole machine as far as anything the CPU can observe goes -- what a
    /// rewind checkpoint holds. See rewind.h, and docs/rewind-design.md for
    /// what is left out and why.
    struct State {
        Z80::State cpu;
        SpectrumMemory::State memory;
        Ula::State ula;
        uint8_t keys[8] = {};
        Ay ay;
        Tape::State tape;
        uint64_t pins = 0;
        std::vector<uint16_t> call_stack;
        std::vector<uint16_t> call_stack_sp;
    };
    /// Captures the machine. Not const: the tape's playback cursor is walked
    /// up to the present first, so the same instant always saves the same
    /// cursor however lazily it had been walked (see Tape::advance_to).
    void save_state(State& s);
    /// Puts the machine back as `s` had it. The picture and the audio are not
    /// in a State; the beeper restarts its clock from the restored instant.
    void restore_state(const State& s);
    /// A hash of everything in `s` the CPU can observe, for checking that two
    /// runs reached the same state.
    static uint64_t state_hash(const State& s);
    /// Approximate bytes a State of this machine takes.
    static size_t state_bytes(const State& s);
#endif

private:
    uint64_t pins_ = PINS_IDLE;

    /// Where each call_stack entry's return address was pushed -- SP just
    /// after the CALL. Parallel to call_stack, and private because it is
    /// bookkeeping rather than something a debugger asks for.
    ///
    /// Without it the chain only ever shrinks on a matching RET, and a
    /// program that discards a return address any other way (POP, LD SP, an
    /// interrupt handler that never returns) strands the entry for ever.
    /// A minute of Cobra left 4412 of them.
    std::vector<uint16_t> call_stack_sp_;

    /// Drops the frames whose return address an instruction moving SP from
    /// `sp_before` to `sp_after` read off or wrote over, and every frame after
    /// them -- the rule profile.h sets out.
    void drop_reached_frames(uint16_t sp_before, uint16_t sp_after);

    /// step_instruction's clock loop when a profile is attached: the same
    /// loop, timed, with an interrupt's acknowledge sequence split off, and
    /// the profile's call tree followed into calls, interrupts and back out.
    /// Kept out of line so the unprofiled loop stays exactly what it was.
    void clock_profiled(uint16_t pc_before, uint16_t sp_before, bool is_call);

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
