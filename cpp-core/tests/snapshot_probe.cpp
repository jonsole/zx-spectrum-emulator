// Drives a Spectrum from a line protocol on stdin, so that a test written in
// Python can load a snapshot, run it to a label, call one routine with chosen
// registers, and read memory back -- the way z80_com_runner lets a test
// written in Z80 run, but for checks whose expected values come from a model
// in Python. Written for examples/revs/tests/run_tests.py.
//
//   snapshot_probe
//
// One command a line; every command answers with exactly one line, so the
// script on the other end can read a reply per request. Addresses and
// register values are hex, counts decimal.
//
//   load <file>                     a .z80 or .sna         -> ok | error <why>
//   poke <addr> <hexbytes>                                 -> ok
//   peek <addr> <count>                                    -> <hexbytes>
//   runto <addr> <max frames>       run until PC is addr   -> pc=<addr> frame=<n> | timeout
//   call <addr> [AF BC DE HL IX IY] with interrupts off    -> <AF> <BC> <DE> <HL> <IX> <IY> <T> | timeout
//   beam <addr> <first row> <rows> <updates>
//   work <start> <halt> <updates> [budget]
//   profile <start> <halt> <updates> <file>
//
// `call` pushes a return address of $0000 onto the stack the snapshot has and
// runs until PC gets there, so the routine must return. T is the T-states it
// took.
//
// `beam` checks that a program which redraws part of the screen in place,
// with no back buffer, never lets the beam show half an update. It runs until
// PC has been at <addr> (where each update's drawing begins) <updates> + 1
// times, and for every write to the screen rows <first row> on works out the
// first frame able to show it: this one if the ULA has not yet fetched that
// row, else the next. All of one update's writes should come out in the same
// frame. Replies
//   updates=<n> writes=<n> split=<updates whose writes span two frames> start=<min>..<max>
// where start is the T-state within the frame each update began.
//
// `work` measures how much of the frame budget a program's main loop uses: the
// T-states from each frame interrupt to the HALT that waits for the next, over
// <updates> passes from <start> (the first instruction after the HALT) to
// <halt>. Counted from the interrupt rather than from <start>, since the time
// the interrupt routine and the HALT's wake-up take is spent all the same.
// Replies
//   updates=<n> min=<t> median=<t> p90=<t> p99=<t> max=<t> over=<n>
// where over is how many took longer than <budget> T-states (0 without one).
//
// `profile` says where that work goes: over the same <updates> passes as
// `work`, it counts every instruction executed between <start> and <halt> by
// the address it starts at, and writes one line per address to <file>,
//   <addr> <times run> <T-states>
// in hex, then decimal. An instruction is charged with what its step took,
// so the one the frame interrupt lands after is charged with the interrupt's
// acknowledge too; the handler's own instructions are counted at their own
// addresses. Replies
//   updates=<n> instructions=<n> tstates=<n>
//
// The 48K ROM is loaded from roms/48.rom when it is there; a program that
// never calls the ROM runs the same without it.

#include "snapshot.h"
#include "spectrum.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// Enough for any routine a test calls; a loop that never returns stops here.
constexpr uint64_t CALL_MAX_INSTRUCTIONS = 50'000'000ULL;

/// Where `call` returns to. The ROM's first byte, so nothing a program does
/// on its own is likely to bring PC there.
constexpr uint16_t CALL_RETURN = 0x0000;

/// T-states the ULA spends fetching the paper of one pixel row: 32 pairs of
/// bitmap and attribute bytes, four T-states a pair.
constexpr uint32_t ROW_FETCH_TSTATES = 128;

std::vector<uint8_t> read_file(const std::string& path, bool& ok) {
    std::ifstream f(path, std::ios::binary);
    ok = bool(f);
    if (!ok) return {};
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

/// The bitmap address of the first byte of pixel row y.
uint16_t row_address(int y) {
    return uint16_t(0x4000 | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2));
}

std::vector<uint8_t> parse_hex_bytes(const std::string& hex) {
    std::vector<uint8_t> bytes;
    for (size_t k = 0; k + 1 < hex.size(); k += 2) {
        bytes.push_back(uint8_t(std::stoul(hex.substr(k, 2), nullptr, 16)));
    }
    return bytes;
}

void load(Spectrum& m, std::istringstream& args) {
    std::string path;
    args >> path;
    bool ok = false;
    std::vector<uint8_t> rom = read_file(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", ok);
    if (ok) m.load_rom(rom.data(), rom.size());
    std::vector<uint8_t> snap = read_file(path, ok);
    if (!ok) {
        std::printf("error cannot read %s\n", path.c_str());
        return;
    }
    std::string error = load_snapshot(m, snap.data(), snap.size());
    if (!error.empty()) {
        std::printf("error %s\n", error.c_str());
        return;
    }
    std::printf("ok\n");
}

void runto(Spectrum& m, std::istringstream& args) {
    unsigned addr = 0;
    uint64_t max_frames = 0;
    args >> std::hex >> addr >> std::dec >> max_frames;
    uint64_t limit = m.ula.frame_count() + max_frames;
    // Always one step first, so that running to where PC already is goes
    // round the loop rather than stopping at once.
    do {
        m.step_instruction();
    } while (m.registers().pc != addr && m.ula.frame_count() < limit);
    if (m.registers().pc != addr) {
        std::printf("timeout\n");
        return;
    }
    std::printf("pc=%04X frame=%llu\n", m.registers().pc, (unsigned long long)m.ula.frame_count());
}

void call(Spectrum& m, std::istringstream& args) {
    unsigned addr = 0, af = 0, bc = 0, de = 0, hl = 0, ix = 0, iy = 0;
    args >> std::hex >> addr >> af >> bc >> de >> hl >> ix >> iy;
    Registers r = m.registers();
    r.a = uint8_t(af >> 8);
    r.f = uint8_t(af);
    r.b = uint8_t(bc >> 8);
    r.c = uint8_t(bc);
    r.d = uint8_t(de >> 8);
    r.e = uint8_t(de);
    r.h = uint8_t(hl >> 8);
    r.l = uint8_t(hl);
    r.ix = uint16_t(ix);
    r.iy = uint16_t(iy);
    r.sp = uint16_t(r.sp - 2);
    r.pc = uint16_t(addr);
    // A routine is called on its own, so the frame interrupt must not run
    // the rest of the program in the middle of it.
    r.iff1 = r.iff2 = false;
    uint8_t ret[2] = {uint8_t(CALL_RETURN & 0xFF), uint8_t(CALL_RETURN >> 8)};
    m.write_memory(r.sp, ret, 2);
    m.set_registers(r);

    uint64_t start = m.global_hc();
    for (uint64_t i = 0; i < CALL_MAX_INSTRUCTIONS && m.registers().pc != CALL_RETURN; i++) {
        m.step_instruction();
    }
    Registers q = m.registers();
    if (q.pc != CALL_RETURN) {
        std::printf("timeout\n");
        return;
    }
    std::printf("%04X %04X %04X %04X %04X %04X %llu\n", (q.a << 8) | q.f, (q.b << 8) | q.c,
                (q.d << 8) | q.e, (q.h << 8) | q.l, q.ix, q.iy,
                (unsigned long long)((m.global_hc() - start) / HC_PER_TSTATE));
}

void beam(Spectrum& m, std::istringstream& args) {
    unsigned begin = 0;
    int first_row = 0, rows = 0, updates = 0;
    args >> std::hex >> begin >> std::dec >> first_row >> rows >> updates;

    std::vector<uint8_t> flags(WATCH_ADDRESSES, 0);
    std::vector<int> row_of(WATCH_ADDRESSES, -1);
    for (int y = first_row; y < first_row + rows; y++) {
        uint16_t a = row_address(y);
        for (int b = 0; b < 32; b++) {
            flags[a + b] = WATCH_WRITE;
            row_of[a + b] = y;
        }
    }
    m.set_watch_flags(flags);

    const UlaTiming& timing = m.ula.timing();
    uint32_t line_tstates = timing.hc_per_line / HC_PER_TSTATE;
    int seen = 0, split = 0;
    long writes = 0;
    uint32_t start_min = UINT32_MAX, start_max = 0;
    bool in_update = false;
    uint64_t lo = 0, hi = 0;
    while (seen <= updates) {
        if (m.registers().pc == begin) {
            if (in_update && lo != hi) split++;
            // The first time round is only the start of the first update.
            if (seen > 0) {
                start_min = std::min(start_min, m.ula.tstate());
                start_max = std::max(start_max, m.ula.tstate());
            }
            in_update = true;
            lo = UINT64_MAX;
            hi = 0;
            seen++;
        }
        m.step_instruction();
        if (m.watch_hit.hit) {
            if (m.watch_hit.write && in_update) {
                uint32_t y = uint32_t(row_of[m.watch_hit.addr]);
                uint32_t fetched = (timing.paper_line_begin + y) * line_tstates + ROW_FETCH_TSTATES;
                uint64_t visible = m.ula.frame_count() + (m.ula.tstate() >= fetched ? 1 : 0);
                lo = std::min(lo, visible);
                hi = std::max(hi, visible);
                writes++;
            }
            m.watch_hit.hit = false;
        }
    }
    m.set_watch_flags({});
    std::printf("updates=%d writes=%ld split=%d start=%u..%u\n", updates, writes, split, start_min,
                start_max);
}

void work(Spectrum& m, std::istringstream& args) {
    unsigned start = 0, halt = 0;
    int updates = 0;
    uint64_t budget = UINT64_MAX;
    args >> std::hex >> start >> halt >> std::dec >> updates >> budget;
    if (updates <= 0) {
        std::printf("error no updates\n");
        return;
    }
    std::vector<uint64_t> spans;
    uint64_t began = 0;
    bool on = false;
    while ((int)spans.size() < updates) {
        uint16_t pc = m.registers().pc;
        if (pc == start) {
            // Back-dated to the interrupt: tstate() is how far into the frame
            // the program got before it reached `start`.
            began = m.global_hc() / HC_PER_TSTATE - m.ula.tstate();
            on = true;
        } else if (pc == halt && on) {
            spans.push_back(m.global_hc() / HC_PER_TSTATE - began);
            on = false;
        }
        m.step_instruction();
    }
    std::sort(spans.begin(), spans.end());
    size_t n = spans.size();
    size_t over = 0;
    for (uint64_t span : spans) {
        if (span > budget) over++;
    }
    std::printf("updates=%zu min=%llu median=%llu p90=%llu p99=%llu max=%llu over=%zu\n", n,
                (unsigned long long)spans[0], (unsigned long long)spans[n / 2],
                (unsigned long long)spans[n * 9 / 10], (unsigned long long)spans[n * 99 / 100],
                (unsigned long long)spans[n - 1], over);
}

void profile(Spectrum& m, std::istringstream& args) {
    unsigned start = 0, halt = 0;
    int updates = 0;
    std::string path;
    args >> std::hex >> start >> halt >> std::dec >> updates >> path;
    if (updates <= 0 || path.empty()) {
        std::printf("error profile wants <start> <halt> <updates> <file>\n");
        return;
    }
    std::vector<uint64_t> runs(0x10000, 0);
    std::vector<uint64_t> hcs(0x10000, 0);
    int done = 0;
    bool on = false;
    uint64_t instructions = 0, total = 0;
    while (done < updates) {
        uint16_t pc = m.registers().pc;
        // While halted PC already reads as <start>, the address after the
        // HALT, so the wait for the interrupt would otherwise count as work.
        bool idle = m.cpu.halted;
        if (pc == start && !idle) {
            on = true;
        } else if (pc == halt && on) {
            on = false;
            done++;
        }
        uint64_t before = m.global_hc();
        m.step_instruction();
        if (on && !idle) {
            uint64_t took = m.global_hc() - before;
            runs[pc]++;
            hcs[pc] += took;
            instructions++;
            total += took;
        }
    }
    std::ofstream f(path);
    if (!f) {
        std::printf("error cannot write %s\n", path.c_str());
        return;
    }
    char row[64];
    for (uint32_t a = 0; a < 0x10000; a++) {
        if (runs[a]) {
            std::snprintf(row, sizeof row, "%04X %llu %llu\n", a, (unsigned long long)runs[a],
                          (unsigned long long)(hcs[a] / HC_PER_TSTATE));
            f << row;
        }
    }
    std::printf("updates=%d instructions=%llu tstates=%llu\n", updates,
                (unsigned long long)instructions, (unsigned long long)(total / HC_PER_TSTATE));
}

} // namespace

int main() {
    Spectrum m;
    std::string line;
    while (std::getline(std::cin, line)) {
        std::istringstream args(line);
        std::string command;
        args >> command;
        if (command == "load") {
            load(m, args);
        } else if (command == "poke") {
            unsigned addr = 0;
            std::string hex;
            args >> std::hex >> addr >> hex;
            std::vector<uint8_t> bytes = parse_hex_bytes(hex);
            m.write_memory(uint16_t(addr), bytes.data(), bytes.size());
            std::printf("ok\n");
        } else if (command == "peek") {
            unsigned addr = 0;
            size_t count = 0;
            args >> std::hex >> addr >> std::dec >> count;
            std::vector<uint8_t> bytes = m.read_memory(uint16_t(addr), count);
            std::string hex;
            hex.reserve(bytes.size() * 2);
            static const char digits[] = "0123456789ABCDEF";
            for (uint8_t b : bytes) {
                hex += digits[b >> 4];
                hex += digits[b & 15];
            }
            std::printf("%s\n", hex.c_str());
        } else if (command == "runto") {
            runto(m, args);
        } else if (command == "call") {
            call(m, args);
        } else if (command == "beam") {
            beam(m, args);
        } else if (command == "work") {
            work(m, args);
        } else if (command == "profile") {
            profile(m, args);
        } else {
            std::printf("error unknown command %s\n", command.c_str());
        }
        std::fflush(stdout);
    }
    return 0;
}
