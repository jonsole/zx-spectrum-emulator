// Boots the real ROM (or a .sna) and dumps the rendered canvas as a raw RGB
// file, for eyeballing. Not a test -- a diagnostic, because "does the screen
// look right" is a question no assertion answers as well as looking does.
//
//   screenshot <out.rgb> [frames]
//
// Output is FULL_WIDTH x FULL_HEIGHT x 3 bytes, no header.

#include "spectrum.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

int main(int argc, char** argv) {
    std::string out_path = argc > 1 ? argv[1] : "screen.rgb";
    int frames = argc > 2 ? std::atoi(argv[2]) : 12;

    Spectrum48K m;
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "roms/48.rom not found\n");
        return 2;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    std::string err = m.load_rom(rom.data(), rom.size());
    if (!err.empty()) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 2;
    }

    Registers regs;
    m.set_registers(regs);
    for (int i = 0; i < frames; i++) {
        m.run_frame();
    }

    std::ofstream out(out_path, std::ios::binary);
    const std::vector<uint8_t>& s = m.screen();
    out.write(reinterpret_cast<const char*>(s.data()), std::streamsize(s.size()));
    std::printf("wrote %s (%ux%u) after %d frames; PC=%04X\n", out_path.c_str(),
                FULL_WIDTH, FULL_HEIGHT, frames, m.registers().pc);
    return 0;
}
