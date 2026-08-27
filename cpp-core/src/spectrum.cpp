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

void Spectrum48K::reset() {
    Registers regs;
    cpu.set_registers(regs, memory);
    pins_ = cpu.pins();
    ula.reset();
    keyboard.clear();
    call_stack.clear();
}

void Spectrum48K::set_registers(const Registers& r) {
    cpu.set_registers(r, memory);
    pins_ = cpu.pins();
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
    // through at all this half-cycle.
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
        uint8_t value = (addr & 1) == 0
                            ? keyboard.read_port(uint8_t(addr >> 8))
                            : 0xFF; // unmapped: floating bus, not modelled further
        pins_ = set_data(pins_, value);
    } else if (asserted(pins_, WR) && (addr & 1) == 0) {
        // Bits 0-2 border, 3 MIC, 4 speaker. No audio yet.
        ula.border = uint8_t(get_data(pins_) & 0x07);
    }
}

void Spectrum48K::step_instruction() {
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
