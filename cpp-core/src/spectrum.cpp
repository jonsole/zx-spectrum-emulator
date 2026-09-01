#include "spectrum.h"

namespace zx {
namespace {

/// The byte the CPU reads during an interrupt-acknowledge cycle. On a real
/// 48K nothing drives the bus then, so the CPU sees the floating bus, which
/// idles at 0xFF -- which is why IM0 and IM1 behave identically here (0xFF
/// decodes as RST 38h) and why IM2 vectors through 0xNNFF.
constexpr uint8_t INT_ACK_BYTE = 0xFF;

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
StepKind classify_step(Spectrum48KMemory& mem, uint16_t addr) {
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

Spectrum48K::Spectrum48K() {
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
void Spectrum48K::prime_cpu(const Registers& r) {
    cpu.set_registers(r, memory);
    pins_ = cpu.pins();
    // The ULA's own half-clock for the same instant. Given after the CPU's
    // rather than before it only because the priming clock starts from
    // PINS_IDLE and would discard anything the ULA drove -- and T1H samples
    // neither INT nor WAIT, so nothing observable turns on the order.
    ula.clock(pins_, memory);
    ula.advance();
}

void Spectrum48K::reset() {
    Registers regs;
    // Before priming, not after: reset() zeroes the ULA's counters, which
    // would otherwise throw away the half-clock just accounted for.
    ula.reset();
    prime_cpu(regs);
    beeper.reset();
    keyboard.clear();
    // The cassette stays in the deck and keeps its block position -- resetting
    // a Spectrum does not eject it. Only the motor stops, and it has to:
    // Ula::reset() zeroed the frame counter, so global_hc() has just restarted
    // at 0 and every pulse timestamp the tape holds is now in the future.
    tape.stop();
    call_stack.clear();
}

void Spectrum48K::set_registers(const Registers& r) {
    prime_cpu(r);
    // Any wholesale register write can leave normal call/return flow, so a
    // tracked chain is no longer meaningful. Cleared unconditionally rather
    // than trying to detect whether PC specifically moved.
    call_stack.clear();
}

std::string Spectrum48K::load_rom(const uint8_t* data, size_t len) {
    return memory.load_rom(data, len);
}

std::vector<uint8_t> Spectrum48K::read_memory(uint16_t addr, size_t length) {
    std::vector<uint8_t> out;
    out.reserve(length);
    for (size_t i = 0; i < length; i++) {
        out.push_back(memory.read(uint16_t(addr + i)));
    }
    return out;
}

void Spectrum48K::write_memory(uint16_t addr, const uint8_t* data, size_t length) {
    for (size_t i = 0; i < length; i++) {
        memory.write(uint16_t(addr + i), data[i]);
    }
}

void Spectrum48K::clock() {
    // The ULA goes first. It drives INT, does its own screen fetch, and --
    // once contention lands -- decides whether the CPU's clock is allowed
    // through at all this half-cycle. It does not move its counters on here;
    // ula.advance() at the bottom does, once everything below has had this
    // half-clock with the counters still describing it.
    ula.clock(pins_, memory);

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

void Spectrum48K::service_bus() {
    uint16_t addr = get_addr(pins_);

    if (asserted(pins_, MREQ)) {
        if (asserted(pins_, RD)) {
            pins_ = set_data(pins_, memory.read(addr));
        } else if (asserted(pins_, WR)) {
            memory.write(addr, get_data(pins_));
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
        uint8_t value = 0xFF; // unmapped: floating bus, not modelled further
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
        }
        pins_ = set_data(pins_, value);
    } else if (asserted(pins_, WR) && (addr & 1) == 0) {
        const uint8_t value = get_data(pins_);
        ula.border = uint8_t(value & 0x07);
        // Bits 3 (MIC) and 4 (speaker) drive the beeper. See
        // Beeper::write_port_fe for why this is a latch and not an edge.
        beeper.write_port_fe(value, global_hc());
    }
}

bool Spectrum48K::stock_ld_bytes() {
    // INC D / EX AF,AF' / DEC D / DI -- the first four bytes of the 48K ROM's
    // LD-BYTES.
    return memory.read(LD_BYTES) == 0x14 && memory.read(LD_BYTES + 1) == 0x08
           && memory.read(LD_BYTES + 2) == 0x15 && memory.read(LD_BYTES + 3) == 0xF3;
}

bool Spectrum48K::fast_load_block() {
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

void Spectrum48K::step_instruction() {
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

    clock();
    while (!cpu.is_instruction_boundary()) {
        clock();
    }

    if (kind == StepKind::Other) {
        return;
    }
    const uint16_t sp_after = registers().sp;
    if (kind == StepKind::Call && sp_after == uint16_t(sp_before - 2)) {
        // Confirmed by the SP delta, so a conditional CALL that was not taken
        // leaves the stack alone.
        uint16_t lo = memory.read(sp_after);
        uint16_t hi = memory.read(uint16_t(sp_after + 1));
        call_stack.push_back(uint16_t(lo | (hi << 8)));
    } else if (kind == StepKind::Ret && sp_after == uint16_t(sp_before + 2)
               && !call_stack.empty()) {
        call_stack.pop_back();
    }
}

void Spectrum48K::run_frame() {
    uint64_t target = ula.frame_count() + 1;
    while (ula.frame_count() < target) {
        clock();
    }
}

} // namespace zx
