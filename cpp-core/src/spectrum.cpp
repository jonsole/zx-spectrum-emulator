#include "spectrum.h"

namespace zx {
namespace {

/// The byte the CPU reads during an interrupt-acknowledge cycle. On a real
/// 48K nothing drives the bus then, so the CPU sees the floating bus, which
/// idles at 0xFF -- which is why IM0 and IM1 behave identically here (0xFF
/// decodes as RST 38h) and why IM2 vectors through 0xNNFF.
constexpr uint8_t INT_ACK_BYTE = 0xFF;

/// The 128K's paging port, 0x7FFD, is decoded on A15 low and A1 low only.
constexpr uint16_t PAGING_PORT_MASK = 0x8002;
/// The AY's two ports, 0xFFFD (select / read) and 0xBFFD (write), on A15,
/// A14 and A1: A15 high and A1 low reach the chip, A14 picks which.
constexpr uint16_t AY_PORT_MASK = 0xC002;
constexpr uint16_t AY_SELECT_PORT = 0xC000;
constexpr uint16_t AY_DATA_PORT = 0x8000;

// Opcodes that push a return address: CALL nn, CALL cc,nn, and every RST.
constexpr uint8_t CALL_OPCODES[] = {0xCD, 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC};
constexpr uint8_t RST_OPCODES[] = {0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF};
constexpr uint8_t RET_OPCODES[] = {0xC9, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8};

enum class StepKind { Other, Call, Ret };

bool contains(const uint8_t* set, size_t n, uint8_t v) {
    for (size_t i = 0; i < n; i++) {
        if (set[i] == v) {
            return true;
        }
    }
    return false;
}

/// Classifies the opcode at `addr` for call-stack tracking. Whether a
/// CONDITIONAL call/return actually did anything is confirmed afterwards from
/// the SP delta, not decided here.
///
/// RETI/RETN fall under the ED-prefixed "Other" case deliberately: they
/// return from an interrupt, and interrupt ENTRY does not push a tracked
/// frame either (it happens inside the CPU's own dispatch, invisible at the
/// opcode level this looks at). Treating both ends as untracked keeps the
/// stack correct for the CALL/RET pairs it does see, rather than popping a
/// frame that was never pushed.
StepKind classify_step(SpectrumMemory& mem, uint16_t addr) {
    uint16_t a = addr;
    uint8_t op = mem.read(a);
    while (op == 0xDD || op == 0xFD) { // skip redundant index prefixes
        a = uint16_t(a + 1);
        op = mem.read(a);
    }
    if (op == 0xED) {
        return StepKind::Other;
    }
    if (contains(CALL_OPCODES, sizeof CALL_OPCODES, op)
        || contains(RST_OPCODES, sizeof RST_OPCODES, op)) {
        return StepKind::Call;
    }
    if (contains(RET_OPCODES, sizeof RET_OPCODES, op)) {
        return StepKind::Ret;
    }
    return StepKind::Other;
}

} // namespace

Spectrum::Spectrum() {
    reset();
}

// Z80::set_registers() performs one priming half-clock -- T1H of the next
// opcode fetch, the overlapped half the pipeline needs in hand before machine
// clocking can begin. That is a real half-clock of machine time, so the ULA is
// given it too.
//
// Without this the CPU stays one half-clock ahead of the ULA for the rest of
// the machine's life: the start of every T-state would land on the CPU's L
// phase, and every contended access would be placed half a T-state from where
// the hardware puts it. Worse, it is not even a constant -- each re-prime
// (a snapshot load, a debugger register write, a fast-loaded tape block) shifts
// it again, so the error drifts rather than staying somewhere it could be
// corrected for.
void Spectrum::prime_cpu(const Registers& r) {
    cpu.set_registers(r, memory);
    pins_ = cpu.pins();
    // The ULA's own half-clock for the same instant. Given after the CPU's
    // rather than before it only because the priming clock starts from
    // PINS_IDLE and would discard anything the ULA drove -- and T1H samples
    // neither INT nor WAIT, so nothing observable turns on the order.
    ula.clock(pins_, memory.screen_bytes());
    ula.advance();
}

void Spectrum::set_model(Model m) {
    memory.set_model(m);
    const bool is128 = m == Model::Spectrum128;
    ula.set_timing(is128 ? TIMING_128K : TIMING_48K);
    beeper.set_clock(ula.timing().hc_per_sec);
    // A 48K has no AY: nothing answers its ports and nothing is mixed in.
    beeper.attach_ay(is128 ? &ay : nullptr);
    reset();
}

void Spectrum::write_paging(uint8_t value) {
    memory.write_paging(value);
    ula.set_screen_bank(memory.screen_bank());
}

void Spectrum::reset() {
    Registers regs;
    // Before priming, not after: reset() zeroes the ULA's counters, which
    // would otherwise throw away the half-clock just accounted for.
    ula.reset();
    // Paging goes back to ROM 0 / bank 0 / screen 5 -- the lock included,
    // which nothing but a reset clears. On a 48K this changes nothing.
    memory.reset_paging();
    ula.set_screen_bank(memory.screen_bank());
    ay.reset();
    prime_cpu(regs);
    beeper.reset();
    keyboard.clear();
    // The cassette stays in the deck and keeps its block position -- resetting
    // a Spectrum does not eject it. Only the motor stops, and it has to:
    // Ula::reset() zeroed the frame counter, so global_hc() has just restarted
    // at 0 and every pulse timestamp the tape holds is now in the future.
    tape.stop();
    call_stack.clear();
    call_stack_sp_.clear();
}

void Spectrum::set_registers(const Registers& r) {
    prime_cpu(r);
    // Any wholesale register write can leave normal call/return flow, so a
    // tracked chain is no longer meaningful. Cleared unconditionally rather
    // than trying to detect whether PC specifically moved.
    call_stack.clear();
    call_stack_sp_.clear();
}

std::string Spectrum::load_rom(const uint8_t* data, size_t len) {
    return memory.load_rom(data, len);
}

std::vector<uint8_t> Spectrum::read_memory(uint16_t addr, size_t length) {
    std::vector<uint8_t> out;
    out.reserve(length);
    for (size_t i = 0; i < length; i++) {
        out.push_back(memory.read(uint16_t(addr + i)));
    }
    return out;
}

void Spectrum::write_memory(uint16_t addr, const uint8_t* data, size_t length) {
    // Noted for the write overlay as well: a debugger poking the display file
    // has changed the screen just as much as a program doing it, and an
    // overlay that only showed one of the two would be lying about the other.
    for (size_t i = 0; i < length; i++) {
        const uint16_t a = uint16_t(addr + i);
        memory.write(a, data[i]);
        ula.note_write(memory.bank_of(a), uint16_t(a & (BANK_SIZE - 1)));
    }
}

void Spectrum::clock() {
    // The ULA goes first. It drives INT, does its own screen fetch, and --
    // once contention lands -- decides whether the CPU's clock is allowed
    // through at all this half-cycle. It does not move its counters on here;
    // ula.advance() at the bottom does, once everything below has had this
    // half-clock with the counters still describing it.
    ula.clock(pins_, memory.screen_bytes());

    pins_ = cpu.clock(pins_);

    // Sampled HERE, between the CPU's clock and the bus service, and not
    // after: our memory answers a read in the same half-clock the request is
    // made, which is a half-clock earlier than real hardware puts the byte on
    // D0-7. Recording first keeps the data bus honest. See tracelog.h.
    if (trace != nullptr) {
        trace->record(*this, pins_);
    }

    service_bus();

    // The half-clock is over: the ULA moves to the next one. Last, so that
    // everything above -- the trace especially -- sees frame_hc/tstate/frame
    // for the half-clock it was actually working on.
    ula.advance();
}

void Spectrum::set_watch_flags(std::vector<uint8_t> flags) {
    watch_flags_ = std::move(flags);
    // The pointer, not the vector, is what the bus tests -- and it is null
    // exactly when nothing is watched, so an unwatched machine pays one null
    // test per memory access and nothing more.
    watch_ = watch_flags_.empty() ? nullptr : watch_flags_.data();
}

void Spectrum::note_watch(uint16_t addr, uint8_t old_value, uint8_t new_value, bool write) {
    if (watch_hit.hit) {
        return; // one instruction, one stop
    }
    watch_hit.hit = true;
    watch_hit.write = write;
    watch_hit.addr = addr;
    watch_hit.old_value = old_value;
    watch_hit.new_value = new_value;
    watch_hit.pc = instruction_pc_;
}

void Spectrum::service_bus() {
    uint16_t addr = get_addr(pins_);

    if (asserted(pins_, MREQ)) {
        if (asserted(pins_, RD)) {
            const uint8_t value = memory.read(addr);
            // M1 is the opcode fetch: executing a watched address is not
            // reading it, which is what a breakpoint is for.
            if (watch_ != nullptr && (watch_[addr] & WATCH_READ) != 0
                && !asserted(pins_, M1)) {
                note_watch(addr, value, value, /*write=*/false);
            }
            pins_ = set_data(pins_, value);
        } else if (asserted(pins_, WR)) {
            const uint8_t value = get_data(pins_);
            // Before the write, while what is there is still the old value.
            if (watch_ != nullptr && (watch_[addr] & WATCH_WRITE) != 0) {
                const uint8_t old_value = memory.read(addr);
                if ((watch_[addr] & WATCH_ON_CHANGE) == 0 || old_value != value) {
                    note_watch(addr, old_value, value, /*write=*/true);
                }
            }
            memory.write(addr, value);
            // Every write the CPU makes passes here, which is the one place
            // that sees them all -- so it is where the ULA is told about the
            // ones that landed on the screen. As bank and offset, since on a
            // 128K the screen is a bank rather than an address range.
            ula.note_write(memory.bank_of(addr), uint16_t(addr & (BANK_SIZE - 1)));
        }
        // A bare MREQ with neither RD nor WR is the refresh cycle. Nothing to
        // service -- but note the address IS live on the bus, which is what
        // makes the snow artifact possible once contention exists.
        return;
    }

    if (!asserted(pins_, IORQ)) {
        return;
    }

    if (asserted(pins_, M1)) {
        // Interrupt acknowledge: nothing drives the bus, so the CPU reads the
        // floating bus.
        pins_ = set_data(pins_, INT_ACK_BYTE);
        return;
    }

    // Port decode is by address line, not by exact port number: ANY even port
    // (A0 low) reaches the ULA. That is real hardware behaviour -- the ULA
    // simply does not decode the upper bits -- and it is why programs can use
    // 0xFE, 0x00FE or any other even port interchangeably.
    if (asserted(pins_, RD)) {
        // An odd port reaches nothing at all in a 48K: no device answers, and
        // what the CPU latches is whatever the ULA happens to be driving --
        // the floating bus. Returning a fixed 0xFF instead looks harmless and
        // is not: a program using it as a raster clock waits for a value that
        // then never comes. See Ula::floating_bus.
        uint8_t value = ula.floating_bus();
        if ((addr & 1) == 0) {
            value = keyboard.read_port(uint8_t(addr >> 8));
            // Bit 6 is the EAR input. Resolved here rather than inside
            // Keyboard because it is the tape's line, not a key's -- the same
            // division that keeps the beeper's bits 3 and 4 in the write
            // branch below. Tape::ear_at is a pure read, which it has to be:
            // this single IN asserts IORQ and RD on five consecutive
            // half-clocks, so it runs five times with the same global_hc()
            // and must answer identically each time.
            const bool ear = tape.ear_at(global_hc());
            if (!ear) {
                value = uint8_t(value & ~0x40);
            }
            // The loading sound. The ULA mixes the EAR socket into the same
            // audio output as the speaker, which is the only reason a tape is
            // audible while it loads -- the ROM's loader never touches the
            // speaker bit, only the border (see EAR_LEVEL in beeper.h). Fed
            // from here rather than from the tape itself because this is where
            // the level is already being resolved, and because a loader polls
            // this port far more finely than the tone it is listening to.
            beeper.set_ear(tape.playing() && ear, global_hc());
        } else if (model() == Model::Spectrum128 && (addr & AY_PORT_MASK) == AY_SELECT_PORT) {
            // The AY answers reads of its select port with the selected
            // register. Like everything else on this bus it is decoded by
            // address line, not by the full port number: A15 and A14 high,
            // A1 low.
            value = ay.read();
        }
        pins_ = set_data(pins_, value);
    } else if (asserted(pins_, WR)) {
        const uint8_t value = get_data(pins_);
        if ((addr & 1) == 0) {
            ula.border = uint8_t(value & 0x07);
            // Bits 3 (MIC) and 4 (speaker) drive the beeper. See
            // Beeper::write_port_fe for why this is a latch and not an edge.
            beeper.write_port_fe(value, global_hc());
        }
        if (model() != Model::Spectrum128) {
            return;
        }
        // The 128K's ports, each as loosely decoded as the hardware does it.
        // Not an else-chain on the ULA's branch above: a port with A0 low
        // AND A15 low reaches both the ULA and the paging latch, exactly as
        // it does on the machine. Every one of these is a latch, for the
        // reason Beeper::write_port_fe gives -- the same OUT calls this on
        // five consecutive half-clocks -- and the AY data write integrates
        // the audio up to this instant first, so a register change lands on
        // the half-clock it happened.
        if ((addr & PAGING_PORT_MASK) == 0) {
            write_paging(value);
        }
        if ((addr & AY_PORT_MASK) == AY_SELECT_PORT) {
            ay.select(value);
        } else if ((addr & AY_PORT_MASK) == AY_DATA_PORT) {
            beeper.advance_to(global_hc());
            ay.write(value);
        }
    }
}

bool Spectrum::stock_ld_bytes() {
    // INC D / EX AF,AF' / DEC D / DI -- the first four bytes of the 48K ROM's
    // LD-BYTES.
    return memory.read(LD_BYTES) == 0x14 && memory.read(LD_BYTES + 1) == 0x08
           && memory.read(LD_BYTES + 2) == 0x15 && memory.read(LD_BYTES + 3) == 0xF3;
}

bool Spectrum::fast_load_block() {
    // Walk the tape up to now before asking where it is. The run loop walks it
    // at its yields, which fall at different instructions from run to run, and
    // whether a block can still be fast-loaded depends on how far into it the
    // walk has got -- so without this the trap's answer would depend on timing
    // outside the machine, and a replay could take a different path.
    tape.advance_to(global_hc());
    const TapeBlock* b = tape.peek_standard_block();
    if (b == nullptr) {
        return false;
    }

    // At LD-BYTES the entry EX AF,AF' has NOT run yet, so the documented
    // contract -- A = the expected flag byte, carry set to load and clear to
    // verify, DE = length, IX = destination -- is in the MAIN AF, not the
    // shadow.
    Registers r = registers();
    const uint8_t want_flag = r.a;
    const bool loading = (r.f & 0x01) != 0;
    uint16_t len = r.de();
    uint16_t dst = r.ix;
    const std::vector<uint8_t>& d = b->data;

    // The ROM reads the flag byte, folds it into H, stores DE bytes folding
    // each one in, then reads ONE more byte -- the checksum -- and folds that
    // in too, leaving H zero on a clean block. So a good load consumes DE + 2
    // bytes, which is why the parity starts at the flag and ends on d[len+1].
    bool ok = !d.empty() && d[0] == want_flag;
    uint8_t parity = 0;
    if (ok) {
        parity = d[0];
        size_t i = 1;
        for (; i < d.size() && len > 0; i++, len--, dst++) {
            parity = uint8_t(parity ^ d[i]);
            if (loading) {
                memory.write(dst, d[i]);
            } else if (memory.read(dst) != d[i]) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            // A verify mismatch: the ROM bails out of its loop the same way.
        } else if (len != 0 || i >= d.size()) {
            ok = false; // the block ran out before DE bytes had been read
        } else {
            parity = uint8_t(parity ^ d[i]);
            ok = parity == 0;
        }
    }

    r.ix = dst;
    r.set_de(len);
    // The ROM leaves the routine through CP $01 with A holding the running
    // parity, so on success A is 0 and 0 - 1 sets S, H, N and C together.
    // Nothing in the ROM reads more than the carry, but a truthful return
    // costs one constant and will not surprise a loader that does.
    r.a = parity;
    r.f = ok ? uint8_t(0x93) : uint8_t(r.f & ~0x01);

    // Interrupts are deliberately left exactly as the caller had them. The
    // real routine does DI on the way in and SA-LD-RET does EI on the way out,
    // so skipping both is a no-op -- it only looks like an omission.
    //
    // The border is left alone for the same kind of reason: the routine would
    // have flashed it and then restored BORDCR, and repainting a border we
    // never changed would be more surprising, not less. A fast load simply has
    // no loading stripes; fast_load(false) is the way to watch them.

    // LD-BYTES' final RET. SA-LD-RET has not been pushed at 0x0556 either, so
    // the top of the stack is the caller's own return address.
    r.pc = uint16_t(memory.read(r.sp) | (memory.read(uint16_t(r.sp + 1)) << 8));
    r.sp = uint16_t(r.sp + 2);

    // NOT set_registers(): that clears the whole call stack, and this is an
    // ordinary RET -- one frame, not all of them.
    //
    // prime_cpu() costs the machine ONE half-clock, where re-priming the CPU
    // alone would cost none. That is still the entire point of a fast load --
    // a block that takes five seconds of tape lands in 0.14 microseconds
    // instead -- and the half-clock buys something worth more than it costs:
    // the CPU and the ULA stay in step. Priming without it would slide the
    // two apart by half a T-state per block loaded.
    prime_cpu(r);
    if (!call_stack.empty()) {
        call_stack.pop_back();
    }

    // Consumed even when the flag did not match. That is deliberate: LD-LOOK-H
    // loops on a carry-clear return until a header matches, so consuming is
    // exactly what lets it walk forward -- the same thing a real tape running
    // past the block would do.
    tape.consume_block(global_hc());
    return true;
}

void Spectrum::step_instruction() {
    // The tape fast-load trap. Here rather than in clock(), which runs seven
    // million times a second and must not pay for this; and here rather than
    // in the Engine's run loop, because a plain step and a step-over should
    // hit it too -- stepping into the ROM loader and watching it take four
    // minutes is nobody's idea of debugging. step_tstates() and run_frame()
    // deliberately do NOT trap: sub-instruction stepping is what you reach for
    // when you want to watch the real LD-EDGE code work.
    if (tape.fast_load() && registers().pc == LD_BYTES && stock_ld_bytes()
        && fast_load_block()) {
        return;
    }

    // Classify BEFORE executing: by the time the instruction completes the
    // bytes at the old PC may no longer be what ran (self-modifying code).
    const uint16_t pc_before = registers().pc;
    const uint16_t sp_before = registers().sp;
    const StepKind kind = classify_step(memory, pc_before);
    // So that a watch tripped inside this instruction names the instruction
    // rather than wherever the CPU's fetch pointer has reached.
    instruction_pc_ = pc_before;

    if (profile == nullptr) {
        clock();
        while (!cpu.is_instruction_boundary()) {
            clock();
        }
    } else {
        clock_profiled(pc_before, sp_before, kind == StepKind::Call);
    }

    // Read straight off the CPU rather than through registers(), which
    // assembles a whole Registers struct: this now runs after EVERY
    // instruction, run() included, and not only after calls and returns.
    const uint16_t sp_after = cpu.regs.sp;
    // For every instruction, not just calls and returns: what strands a frame
    // is usually neither -- a POP that throws a return address away, a stack
    // reset by LD SP and then used again. Before the push, since a CALL's own
    // push can be what overwrites an abandoned frame's slot.
    drop_reached_frames(sp_before, sp_after);
    if (kind == StepKind::Call && sp_after == uint16_t(sp_before - 2)) {
        // Confirmed by the SP delta, so a conditional CALL that was not taken
        // leaves the stack alone.
        uint16_t lo = memory.read(sp_after);
        uint16_t hi = memory.read(uint16_t(sp_after + 1));
        call_stack.push_back(uint16_t(lo | (hi << 8)));
        call_stack_sp_.push_back(sp_after);
    }
}

void Spectrum::clock_profiled(uint16_t pc_before, uint16_t sp_before, bool is_call) {
    // A halted CPU reports the address after its HALT (see Z80::registers),
    // but each pass is the HALT executing again, and that is where the time
    // belongs. The first pass, the one that halts, is not yet halted and
    // reports the HALT's own address.
    const bool halted = cpu.halted;
    const uint16_t pc = halted ? uint16_t(pc_before - 1) : pc_before;
    // The frame the instruction began in, which is the period it belongs to
    // when periods are frames.
    const uint64_t frame = ula.frame_count();
    const uint64_t interrupts_before = cpu.interrupt_count;
    const uint64_t start = global_hc();

    // An interrupt is accepted in the instruction's final half-clock (the
    // overlapped fetch samples INT), and its whole acknowledge sequence then
    // runs before the next boundary -- inside this same step. So the step is
    // split where the count changes: the instruction up to there, the
    // acknowledge after. Each side keeps the same shape every other
    // instruction has, its own work plus the next fetch's first half-clock.
    bool interrupted = false;
    uint64_t split = 0;
    clock();
    for (;;) {
        if (!interrupted && cpu.interrupt_count != interrupts_before) {
            interrupted = true;
            split = global_hc();
        }
        if (cpu.is_instruction_boundary()) {
            break;
        }
        clock();
    }

    const uint64_t end = global_hc();
    const uint16_t sp_after = cpu.regs.sp;
    // Where execution goes next: a call's target, or an interrupt handler's
    // first instruction. Not halted by construction -- a call is not a HALT,
    // and accepting an interrupt clears the latch.
    const uint16_t pc_after = uint16_t(cpu.regs.pc - 1);

    // In this order: the instruction's time goes to the call path it ran on
    // (a RET to the routine it returns from, a CALL to its caller), then the
    // path moves.
    if (interrupted) {
        profile->record(pc, split - start, frame, halted);
        // The stack as the instruction left it, before the acknowledge pushed
        // its own return address -- so a RET the interrupt landed straight
        // after still ends its call.
        profile->stack_moved(sp_before, uint16_t(sp_after + 2));
        profile->stack_moved(uint16_t(sp_after + 2), sp_after);
        // A CALL the interrupt landed straight after is not followed into:
        // its target is no longer anywhere to be read. Its time goes to the
        // caller until its RET, which is rare enough to live with.
        profile->enter_interrupt(pc_after, sp_after);
        profile->record_interrupt(end - split);
    } else {
        profile->record(pc, end - start, frame, halted);
        profile->stack_moved(sp_before, sp_after);
        // Confirmed by the SP delta, as the call stack is: a conditional CALL
        // not taken went nowhere.
        if (is_call && sp_after == uint16_t(sp_before - 2)) {
            profile->enter_call(pc_after, sp_after, pc);
        }
    }
}

void Spectrum::drop_reached_frames(uint16_t sp_before, uint16_t sp_after) {
    // The profile's rule, for the same reasons: see profile.h. A frame is gone
    // once its return address has been read off the stack or written over --
    // not merely because SP has moved past it, which is also what a routine
    // borrowing SP as a data pointer does, and which used to empty the call
    // stack the moment one did.
    const size_t keep = Profile::first_frame_reached(
        call_stack_sp_, [](uint16_t sp) { return sp; }, sp_before, sp_after);
    call_stack.resize(keep);
    call_stack_sp_.resize(keep);
}

void Spectrum::run_frame() {
    uint64_t target = ula.frame_count() + 1;
    while (ula.frame_count() < target) {
        clock();
    }
}

#if ZX_REWIND
void Spectrum::save_state(State& s) {
    tape.advance_to(global_hc());
    cpu.save_state(s.cpu);
    memory.save_state(s.memory);
    ula.save_state(s.ula);
    const uint8_t* rows = keyboard.rows();
    for (int i = 0; i < 8; i++) {
        s.keys[i] = rows[i];
    }
    s.ay = ay;
    tape.save_state(s.tape);
    s.pins = pins_;
    s.call_stack = call_stack;
    s.call_stack_sp = call_stack_sp_;
}

void Spectrum::restore_state(const State& s) {
    cpu.restore_state(s.cpu);
    memory.restore_state(s.memory);
    ula.restore_state(s.ula);
    keyboard.set_rows(s.keys);
    ay = s.ay;
    tape.restore_state(s.tape);
    pins_ = s.pins;
    call_stack = s.call_stack;
    call_stack_sp_ = s.call_stack_sp;
    beeper.restart_at(global_hc());
}

namespace {

/// FNV-1a, fed field by field -- never whole structs, whose padding bytes are
/// whatever was on the stack.
struct Hasher {
    uint64_t h = 1469598103934665603ull;
    void byte(uint8_t b) {
        h ^= b;
        h *= 1099511628211ull;
    }
    void u64(uint64_t v) {
        for (int i = 0; i < 8; i++) {
            byte(uint8_t(v >> (i * 8)));
        }
    }
    void bytes(const uint8_t* p, size_t n) {
        for (size_t i = 0; i < n; i++) {
            byte(p[i]);
        }
    }
};

void hash_registers(Hasher& h, const Registers& r) {
    const uint8_t bytes8[] = {r.a, r.f, r.b, r.c, r.d, r.e, r.h, r.l,
                              r.a_, r.f_, r.b_, r.c_, r.d_, r.e_, r.h_, r.l_,
                              r.i, r.r, r.im};
    h.bytes(bytes8, sizeof bytes8);
    h.u64(r.ix);
    h.u64(r.iy);
    h.u64(r.sp);
    h.u64(r.pc);
    h.u64(r.wz);
    h.byte(r.iff1 ? 1 : 0);
    h.byte(r.iff2 ? 1 : 0);
}

} // namespace

uint64_t Spectrum::state_hash(const State& s) {
    Hasher h;
    hash_registers(h, s.cpu.regs);
    h.byte(s.cpu.halted ? 1 : 0);
    h.u64(s.cpu.interrupt_count);
    h.u64(s.cpu.step);
    h.byte(s.cpu.opcode);
    h.byte(s.cpu.dlatch);
    h.u64(s.cpu.addr);
    h.byte(s.cpu.prefix_active ? 1 : 0);
    h.byte(s.cpu.hlx_idx);
    h.u64(s.cpu.pins);

    h.byte(uint8_t(s.memory.model));
    h.byte(s.memory.paging);
    h.bytes(s.memory.ram.data(), s.memory.ram.size());

    h.byte(s.ula.border);
    h.byte(s.ula.flash_state ? 1 : 0);
    h.byte(s.ula.screen_bank);
    h.u64(s.ula.frame_hc);
    h.u64(s.ula.fetch_count);
    h.u64(s.ula.fetch_addr);
    h.byte(s.ula.fetch_data);
    h.u64(s.ula.line);
    h.u64(s.ula.dot);
    h.u64(s.ula.frame_count);
    h.byte(s.ula.pixel0);
    h.byte(s.ula.attr0);
    h.byte(s.ula.pixel1);
    h.byte(s.ula.attr1);
    h.byte(s.ula.border_latch);

    h.bytes(s.keys, sizeof s.keys);

    // The AY's registers and selection, which the CPU can read back -- not its
    // tone and envelope counters, which move only as audio is generated and
    // so depend on whether anything is listening.
    for (uint8_t i = 0; i < AY_REGISTERS; i++) {
        h.byte(s.ay.reg(i));
    }
    h.byte(s.ay.selected());

    h.byte(s.tape.fast_load ? 1 : 0);
    h.byte(s.tape.playing ? 1 : 0);
    h.byte(s.tape.at_end ? 1 : 0);
    h.u64(s.tape.block);
    h.byte(uint8_t(s.tape.phase));
    h.u64(s.tape.byte);
    h.byte(s.tape.bit);
    h.byte(s.tape.second_half ? 1 : 0);
    h.u64(s.tape.pulses_left);
    h.byte(s.tape.level ? 1 : 0);
    h.u64(s.tape.pulse_start_hc);
    h.u64(s.tape.pulse_hc);
    h.u64(s.tape.block_start_hc);
    h.u64(s.tape.total_hc);

    h.u64(s.pins);
    for (uint16_t v : s.call_stack) {
        h.u64(v);
    }
    for (uint16_t v : s.call_stack_sp) {
        h.u64(v);
    }
    return h.h;
}

size_t Spectrum::state_bytes(const State& s) {
    return sizeof(State) + s.memory.ram.size()
           + (s.call_stack.size() + s.call_stack_sp.size()) * sizeof(uint16_t);
}
#endif

} // namespace zx
