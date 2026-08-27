// Throughput benchmark: can this core run a Spectrum at real time?
//
// The bar is concrete. A 48K Spectrum's Z80 runs at 3.5MHz, and this core is
// clocked at half-T-state resolution, so real time means 7,000,000 clock()
// calls per second sustained. Anything above 1.0x realtime here leaves
// headroom for the ULA, screen rendering and the server layer, all of which
// are still to come and none of which are free.
//
// Reports half-clocks/sec rather than instructions/sec deliberately:
// instructions/sec is not comparable to anything, because a Z80 instruction
// is anywhere from 4 to 23 T-states. Half-clocks map directly onto the
// hardware clock.
//
// Build RelWithDebInfo or Release. A Debug number here is meaningless.

#include "memory.h"
#include "z80.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace zx;

namespace {

struct Result {
    uint64_t half_clocks;
    double seconds;
};

/// Runs `program` in a loop for at least `min_half_clocks`, driving the CPU
/// one half-clock at a time exactly as a real machine would (the machine
/// layer will interleave the ULA here, so per-half-clock dispatch is the
/// shape that matters, not step_instruction()).
Result run(const std::vector<uint8_t>& program, uint16_t start_pc,
           uint64_t min_half_clocks) {
    FlatMemory mem;
    std::copy(program.begin(), program.end(), mem.bytes.begin());
    Z80 cpu;
    Registers regs;
    regs.pc = start_pc;
    regs.sp = 0xFF00;
    cpu.set_registers(regs, mem);

    uint64_t pins = cpu.pins();
    auto t0 = std::chrono::steady_clock::now();
    uint64_t n = 0;
    while (n < min_half_clocks) {
        // Chunked so the clock() call is not dominated by the loop condition.
        for (int i = 0; i < 4096; i++) {
            pins = Z80::service_memory(mem, cpu.clock(pins));
        }
        n += 4096;
    }
    auto t1 = std::chrono::steady_clock::now();
    return {n, std::chrono::duration<double>(t1 - t0).count()};
}

void report(const char* name, const Result& r) {
    double per_sec = double(r.half_clocks) / r.seconds;
    // 3.5MHz Z80 == 7M half-clocks/sec.
    double realtime = per_sec / 7'000'000.0;
    std::printf("  %-28s %8.1f M half-clocks/s   %6.2fx realtime\n", name,
                per_sec / 1e6, realtime);
}

} // namespace

int main() {
    const uint64_t budget = 200'000'000; // ~30s of emulated Spectrum time

    std::printf("Z80 core throughput (target: 7.0 M half-clocks/s == 1.00x realtime)\n\n");

    // Upper bound: nothing but 4-T-state opcode fetches, no operand reads.
    report("NOP stream (upper bound)", run(std::vector<uint8_t>(64, 0x00), 0, budget));

    // A tight loop of the kind real game code is full of: ALU on registers,
    // memory access through HL, and a taken conditional jump.
    std::vector<uint8_t> mixed = {
        0x21, 0x00, 0x90,        // LD HL,0x9000
        0x06, 0x40,              // LD B,0x40
        0x7E,                    // LD A,(HL)      <- loop
        0x87,                    // ADD A,A
        0x77,                    // LD (HL),A
        0x23,                    // INC HL
        0xB7,                    // OR A
        0x05,                    // DEC B
        0x20, 0xF7,              // JR NZ,loop
        0xC3, 0x03, 0x00,        // JP back to LD B
    };
    report("mixed ALU + memory + jumps", run(mixed, 0, budget));

    // Block copy -- LDIR is what a Spectrum game spends its screen-drawing
    // time in, and its repeating form is the densest memory traffic the chip
    // can generate.
    std::vector<uint8_t> ldir = {
        0x21, 0x00, 0x90,        // LD HL,0x9000
        0x11, 0x00, 0xA0,        // LD DE,0xA000
        0x01, 0x00, 0x10,        // LD BC,0x1000
        0xED, 0xB0,              // LDIR
        0xC3, 0x00, 0x00,        // JP 0
    };
    report("LDIR block copy", run(ldir, 0, budget));

    return 0;
}
