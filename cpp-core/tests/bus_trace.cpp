// Writes a half-clock bus trace without a server: the same table zx_server's
// --trace-log writes (docs/tracing.md), from a machine run headless here. For
// CI, and for retro-spectrum's FPGA work, whose Verilator simulation writes
// the same table so the two can be compared with diff.
//
//   bus_trace <out.zxtrace> <half-clocks> [program] [128] [tstate=N] [ula]
//
// With no program the machine boots from its ROM. A program is a .sna or
// .z80, loaded and run from where it was saved. The trace has the 48K columns
// (--trace-extra) always: the T-state column is what a comparison lines up
// on. tstate=N waits for that T-state of the frame before recording, as
// start_trace's tstate does; ula adds the ULA's own bus. The ROMs come from
// roms/, and without them it skips.

#include "snapshot.h"
#include "spectrum.h"
#include "tracelog.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// The exit code for a run that cannot happen here, for CTest's
/// SKIP_RETURN_CODE.
constexpr int SKIPPED = 77;

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr,
                     "usage: bus_trace <out.zxtrace> <half-clocks> [program] [128] [tstate=N] [ula]\n");
        return 2;
    }
    TraceOptions options;
    options.path = argv[1];
    options.limit = std::strtoull(argv[2], nullptr, 10);
    options.extra = true;
    std::string program;
    bool is128 = false;
    for (int i = 3; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "128") {
            is128 = true;
        } else if (a == "ula") {
            options.ula = true;
        } else if (a.compare(0, 7, "tstate=") == 0) {
            options.start_tstate = uint32_t(std::strtoul(a.c_str() + 7, nullptr, 10));
        } else {
            program = a;
        }
    }

    // A Spectrum holds all its memory inline: on the heap, not the stack.
    auto machine = std::make_unique<Spectrum>();
    Spectrum& m = *machine;
    const std::string root = ZX_PROJECT_ROOT;
    std::vector<uint8_t> data;
    for (const char* rom : {"/roms/48.rom", "/roms/128.rom"}) {
        if (read_file(root + rom, data)) {
            m.load_rom(data.data(), data.size());
        }
    }
    const Model model = is128 ? Model::Spectrum128 : Model::Spectrum48;
    if (!m.memory.has_rom(model)) {
        std::printf("skipped: no ROM for that model in roms/\n");
        return SKIPPED;
    }
    m.set_model(model);
    if (!program.empty()) {
        if (!read_file(program, data)) {
            std::printf("skipped: %s is not there\n", program.c_str());
            return SKIPPED;
        }
        const std::string error = load_snapshot(m, data.data(), data.size());
        if (!error.empty()) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
    }

    TraceLog trace;
    const std::string error = trace.open(options);
    if (!error.empty()) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }
    m.trace = &trace;
    // Clocked until the trace closes itself at its limit -- after waiting for
    // its T-state first, if it was given one, which is at most a frame.
    while (trace.active()) {
        m.clock();
    }
    m.trace = nullptr;
    trace.close();
    std::printf("wrote %llu half-clocks to %s\n", static_cast<unsigned long long>(trace.rows()),
                options.path.c_str());
    return 0;
}
