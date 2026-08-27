#include "spectrum.h"

namespace zx {
namespace {

/// The byte the CPU reads during an interrupt-acknowledge cycle. On a real
/// 48K nothing drives the bus then, so the CPU sees the floating bus, which
/// idles at 0xFF -- which is why IM0 and IM1 behave identically here (0xFF
/// decodes as RST 38h) and why IM2 vectors through 0xNNFF.
constexpr uint8_t INT_ACK_BYTE = 0xFF;

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
}

void Spectrum48K::set_registers(const Registers& r) {
    cpu.set_registers(r, memory);
    pins_ = cpu.pins();
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
    clock();
    while (!cpu.is_instruction_boundary()) {
        clock();
    }
}

void Spectrum48K::run_frame() {
    uint64_t target = ula.frame_count() + 1;
    while (ula.frame_count() < target) {
        clock();
    }
}

} // namespace zx
