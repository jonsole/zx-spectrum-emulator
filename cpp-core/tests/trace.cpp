// Diagnostic, not a test: runs a snapshot until PC hits a target address and
// prints the instructions that led there.
//
// For the class of bug where a guest program derails -- it ends up somewhere
// impossible and the question is what the last few things it did were. Doing
// this over DAP/MCP is impractical (one round trip per instruction), so this
// keeps a ring buffer locally and dumps it at the moment of failure.
//
//   trace <snapshot.sna> [target-hex] [max-frames]
//
// Default target is 0x0000, the reset vector, which a healthy program never
// reaches.

#include "disassembler.h"
#include "snapshot.h"
#include "spectrum.h"
#include "ula.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr size_t HISTORY = 48;

struct Entry {
    uint16_t pc;
    uint16_t sp;
    uint16_t af, bc, de, hl;
    uint64_t frame;
    uint32_t tstate;
    bool in_interrupt;
};

bool load(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: trace <snapshot.sna> [target-hex] [max-frames]\n");
        return 2;
    }
    const std::string sna_path = argv[1];
    const uint16_t target =
        argc > 2 ? uint16_t(std::strtoul(argv[2], nullptr, 16)) : uint16_t(0x0000);
    const uint64_t max_frames = argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 2000;

    Spectrum48K m;
    std::vector<uint8_t> rom;
    if (!load(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", rom)) {
        std::fprintf(stderr, "roms/48.rom not found\n");
        return 1;
    }
    std::string err = m.load_rom(rom.data(), rom.size());
    if (!err.empty()) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }
    std::vector<uint8_t> sna;
    if (!load(sna_path, sna)) {
        std::fprintf(stderr, "couldn't read %s\n", sna_path.c_str());
        return 1;
    }
    err = load_sna(m, sna.data(), sna.size());
    if (!err.empty()) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }

    std::vector<Entry> ring(HISTORY);
    size_t next = 0;
    uint64_t executed = 0;

    // Interrupt bookkeeping: every time execution arrives at the IM2 handler,
    // the word on top of the stack should be the address of the instruction
    // that was about to run. Recording both catches a bad push directly
    // rather than by its eventual downstream symptom.
    struct IntEntry {
        uint64_t frame;
        uint32_t tstate;
        uint16_t expected_pc;
        uint16_t pushed;
        uint16_t sp;
    };
    std::vector<IntEntry> ints;
    const uint16_t handler = argc > 4 ? uint16_t(std::strtoul(argv[4], nullptr, 16)) : 0xFFFF;
    uint16_t prev_pc = 0;
    bool have_prev = false;
    bool dump_now = false;

    ReadFn read = [&m](uint16_t a) { return m.memory.read(a); };

    while (m.ula.frame_count() < max_frames) {
        const Registers r = m.registers();
        Entry e;
        e.pc = r.pc;
        e.sp = r.sp;
        e.af = r.af();
        e.bc = r.bc();
        e.de = r.de();
        e.hl = r.hl();
        e.frame = m.ula.frame_count();
        e.tstate = m.ula.tstate();
        e.in_interrupt = false;
        ring[next % HISTORY] = e;
        next++;
        executed++;

        if (handler != 0xFFFF && r.pc == handler && have_prev) {
            const uint16_t pushed =
                uint16_t(m.memory.read(r.sp) | (m.memory.read(uint16_t(r.sp + 1)) << 8));
            ints.push_back({e.frame, e.tstate, prev_pc, pushed, r.sp});
            // A return address of zero is never legitimate: stop here, where
            // the history still shows what was running when the interrupt
            // was taken, rather than at the eventual crash.
            if (pushed == 0) {
                dump_now = true;
            }
        }
        prev_pc = r.pc;
        have_prev = true;

        if (dump_now || (r.pc == target && executed > 1)) {
            std::printf("Reached 0x%04X after %llu instructions, frame %llu, tstate %u\n\n",
                        target, (unsigned long long)executed, (unsigned long long)e.frame,
                        e.tstate);
            std::printf("%-6s %-6s %-22s %-6s %-6s %-6s %-6s %-6s\n", "frame", "tstate",
                        "pc: instruction", "sp", "af", "bc", "de/hl", "");
            if (!ints.empty()) {
                std::printf("Last interrupt entries (pushed should equal interrupted-pc):\n");
                const size_t first = ints.size() > 12 ? ints.size() - 12 : 0;
                for (size_t i = first; i < ints.size(); i++) {
                    const IntEntry& in = ints[i];
                    std::printf("  frame %-5llu tstate %-6u sp=0x%04X interrupted-pc=0x%04X "
                                "pushed=0x%04X%s\n",
                                (unsigned long long)in.frame, in.tstate, in.sp, in.expected_pc,
                                in.pushed, in.pushed == in.expected_pc ? "" : "   <-- MISMATCH");
                }
                std::printf("\n");
            }
            const size_t count = next < HISTORY ? next : HISTORY;
            for (size_t i = 0; i < count; i++) {
                const Entry& h = ring[(next - count + i) % HISTORY];
                const Instruction inst = disassemble_one(read, h.pc);
                char label[64];
                std::snprintf(label, sizeof label, "0x%04X: %s", h.pc, inst.text.c_str());
                std::printf("%-6llu %-6u %-22s 0x%04X 0x%04X 0x%04X 0x%04X 0x%04X\n",
                            (unsigned long long)h.frame, h.tstate, label, h.sp, h.af, h.bc, h.de,
                            h.hl);
            }
            return 0;
        }
        m.step_instruction();
    }

    std::printf("Ran %llu frames (%llu instructions) without reaching 0x%04X\n",
                (unsigned long long)m.ula.frame_count(), (unsigned long long)executed, target);
    // Not derailing is necessary but not sufficient -- dump the final
    // frame so it can be checked that the program is still drawing.
    const std::vector<uint8_t>& screen = m.screen();
    std::ofstream out("trace_screen.rgb", std::ios::binary);
    out.write(reinterpret_cast<const char*>(screen.data()), std::streamsize(screen.size()));
    std::printf("Wrote trace_screen.rgb\n");
    return 0;
}
