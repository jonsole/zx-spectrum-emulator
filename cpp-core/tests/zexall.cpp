// Runs the real ZEXALL / ZEXDOC Z80 exercisers (github.com/agn453/ZEXALL,
// fetched by scripts/fetch_zexall.py) against our core, through a minimal
// CP/M BDOS shim -- only functions 2 (single char out) and 9 ($-terminated
// string out), the only two these programs use.
//
// This is the strongest correctness bar available, and complementary to
// differential.cpp rather than redundant with it. That test checks agreement
// with vendor/chips/z80.h; this one checks agreement with known-correct Z80
// semantics directly, via CRC-verified per-instruction test vectors. So it
// catches a bug the two cores happen to SHARE -- which a differential test
// against z80.h structurally cannot, since our dispatch is generated from the
// same z80_desc.yml that generates z80.h.
//
// Slow by nature, not by accident: the exercisers' own CRC verification is
// dominated by a per-bit updcrc loop, and the later groups sweep a large
// combinatorial register/flag space. A full run is well over a billion
// emulated instructions. MAX_INSTRUCTIONS below is a "something is actually
// stuck" backstop, not a completion estimate -- do not lower it and conclude
// the core hangs.
//
//   zexall_runner zexdoc [max_instructions]
//   zexall_runner zexall [max_instructions]
//
// Registered with CTest under the "slow" label, excluded from the default
// run. Use build.ps1 -Slow.

#include "memory.h"
#include "z80.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t WARM_BOOT = 0x0000;
constexpr uint16_t BDOS_ENTRY = 0x0005;
constexpr uint16_t LOAD_ADDR = 0x0100;
constexpr uint64_t DEFAULT_MAX_INSTRUCTIONS = 20'000'000'000ULL;

/// ifstream rather than fopen: MSVC deprecates the latter, and suppressing
/// that warning project-wide to keep one convenience call would be the wrong
/// trade.
std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "couldn't open %s -- run `python scripts/fetch_zexall.py` first\n",
                     path.c_str());
        std::exit(2);
    }
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f),
                                std::istreambuf_iterator<char>());
}

/// Emulates the one BDOS call the exercisers make, then the RET that would
/// normally follow their `CALL 5`.
void handle_bdos(Z80& cpu, FlatMemory& mem, std::string& output) {
    Registers r = cpu.registers();
    if (r.c == 2) {
        std::fputc(char(r.e), stdout);
        output.push_back(char(r.e));
    } else if (r.c == 9) {
        uint16_t addr = r.de();
        while (mem.bytes[addr] != '$') {
            std::fputc(char(mem.bytes[addr]), stdout);
            output.push_back(char(mem.bytes[addr]));
            addr = uint16_t(addr + 1);
        }
    } else {
        std::fprintf(stderr, "\nunhandled BDOS function %u at PC %04X\n", r.c, r.pc);
        std::exit(2);
    }
    std::fflush(stdout);

    uint16_t ret = uint16_t(mem.bytes[r.sp] | (mem.bytes[uint16_t(r.sp + 1)] << 8));
    r.sp = uint16_t(r.sp + 2);
    r.pc = ret;
    cpu.set_registers(r, mem);
}

std::string run(const std::string& com_path, uint64_t max_instructions) {
    std::vector<uint8_t> program = read_file(com_path);

    FlatMemory mem;
    mem.bytes[WARM_BOOT] = 0x76; // HALT, marking CP/M's warm boot vector

    // The exercisers open with `LD HL,(6); LD SP,HL` -- the standard CP/M
    // idiom for "top of TPA into SP". Leaving 6-7 at zero makes them set SP
    // to 0x0000 before reaching their own test loop, regardless of what SP is
    // initialised to here, which presents as an unexplained hang. 0xFE00
    // leaves headroom above the loaded code.
    mem.bytes[6] = 0x00;
    mem.bytes[7] = 0xFE;
    std::copy(program.begin(), program.end(), mem.bytes.begin() + LOAD_ADDR);

    Z80 cpu;
    Registers regs;
    regs.pc = LOAD_ADDR;
    cpu.set_registers(regs, mem);

    std::string output;
    uint64_t instructions = 0;
    for (;;) {
        uint16_t pc = cpu.registers().pc;
        if (pc == WARM_BOOT) {
            break;
        }
        if (pc == BDOS_ENTRY) {
            handle_bdos(cpu, mem, output);
            continue;
        }
        cpu.step_instruction(mem);
        if (++instructions >= max_instructions) {
            std::fprintf(stderr,
                         "\nexceeded %llu instructions without reaching warm boot -- "
                         "probably stuck, not just slow\n",
                         (unsigned long long)max_instructions);
            std::exit(1);
        }
    }
    std::printf("\n[%llu instructions]\n", (unsigned long long)instructions);
    return output;
}

} // namespace

int main(int argc, char** argv) {
    std::string which = argc > 1 ? argv[1] : "zexdoc";
    uint64_t max_instructions =
        argc > 2 ? std::strtoull(argv[2], nullptr, 10) : DEFAULT_MAX_INSTRUCTIONS;

    std::string path = std::string(ZX_PROJECT_ROOT) + "/.zexall-src/" + which + ".com";
    std::printf("running %s (cap %llu instructions)\n", path.c_str(),
                (unsigned long long)max_instructions);
    std::fflush(stdout);

    std::string output = run(path, max_instructions);

    if (output.find("ERROR") != std::string::npos) {
        std::fprintf(stderr, "\n%s reported at least one ERROR\n", which.c_str());
        return 1;
    }
    std::printf("\n%s: no errors\n", which.c_str());
    return 0;
}
