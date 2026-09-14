// Runs a Z80 program on the bare core, the way zexall.cpp runs ZEXALL: loaded
// at $0100 into flat RAM, with the two CP/M BDOS calls that print (2, one
// character in E; 9, a '$'-terminated string at DE) and a HALT at $0000 for the
// program to finish on.
//
// It exists for unit tests written in Z80 itself -- examples/filmation/tests --
// where the code under test is assembled into a .com alongside the checks. So
// the exit status is what the program says, not what it prints: A when it
// jumps to $0000, which a test suite sets to its failure count. Anything that
// runs away is caught by the instruction cap and fails too.
//
//   z80_com_runner program.com [max_instructions]

#include "memory.h"
#include "z80.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t WARM_BOOT = 0x0000;
constexpr uint16_t BDOS_ENTRY = 0x0005;
constexpr uint16_t LOAD_ADDR = 0x0100;
constexpr uint16_t TOP_OF_TPA = 0xFE00;
constexpr uint64_t DEFAULT_MAX_INSTRUCTIONS = 100'000'000ULL;

std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "couldn't open %s\n", path.c_str());
        std::exit(2);
    }
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f),
                                std::istreambuf_iterator<char>());
}

/// Prints for BDOS 2 or 9, then does the RET that follows the program's CALL 5.
void handle_bdos(Z80& cpu, FlatMemory& mem) {
    Registers r = cpu.registers();
    if (r.c == 2) {
        std::fputc(char(r.e), stdout);
    } else if (r.c == 9) {
        uint16_t addr = r.de();
        while (mem.bytes[addr] != '$') {
            std::fputc(char(mem.bytes[addr]), stdout);
            addr = uint16_t(addr + 1);
        }
    } else {
        std::fprintf(stderr, "\nunhandled BDOS function %u at PC %04X\n", r.c, r.pc);
        std::exit(2);
    }

    uint16_t ret = uint16_t(mem.bytes[r.sp] | (mem.bytes[uint16_t(r.sp + 1)] << 8));
    r.sp = uint16_t(r.sp + 2);
    r.pc = ret;
    cpu.set_registers(r, mem);
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: z80_com_runner program.com [max_instructions]\n");
        return 2;
    }
    uint64_t max_instructions =
        argc > 2 ? std::strtoull(argv[2], nullptr, 10) : DEFAULT_MAX_INSTRUCTIONS;

    std::vector<uint8_t> program = read_file(argv[1]);
    if (program.size() > size_t(TOP_OF_TPA - LOAD_ADDR)) {
        std::fprintf(stderr, "%s is too big to load at $0100\n", argv[1]);
        return 2;
    }

    FlatMemory mem;
    mem.bytes[WARM_BOOT] = 0x76; // HALT
    mem.bytes[6] = uint8_t(TOP_OF_TPA & 0xFF);
    mem.bytes[7] = uint8_t(TOP_OF_TPA >> 8);
    std::copy(program.begin(), program.end(), mem.bytes.begin() + LOAD_ADDR);

    Z80 cpu;
    Registers regs;
    regs.pc = LOAD_ADDR;
    regs.sp = TOP_OF_TPA;
    cpu.set_registers(regs, mem);

    uint64_t instructions = 0;
    for (;;) {
        uint16_t pc = cpu.registers().pc;
        if (pc == WARM_BOOT) {
            break;
        }
        if (pc == BDOS_ENTRY) {
            handle_bdos(cpu, mem);
            continue;
        }
        cpu.step_instruction(mem);
        if (++instructions >= max_instructions) {
            std::fflush(stdout);
            std::fprintf(stderr, "\nexceeded %llu instructions without returning to $0000 (PC %04X)\n",
                         (unsigned long long)max_instructions, cpu.registers().pc);
            return 1;
        }
    }
    std::fflush(stdout);
    return cpu.registers().a;
}
