// Runs one program from the public timing test suites headless and saves the
// screen as a PNG: the diagnostic behind the suite tests (issue #30), and the
// way to look at what a test draws before deciding how to check it.
//
//   suite_shot <program> <frames> <out.png> [48|128|128in48] [KEY@frame ...]
//              [expect=TEXT ...]
//
// 128in48 is a 128K whose tape is loaded from the 128's own 48 BASIC, for
// the tests that say they must run in 48K mode. nocontention runs it with
// contention off, to compare.
//
// Each KEY@frame presses a key (a keyboard name: ENTER, SPACE, 1, A, ...) at
// that frame and lets it go KEY_HOLD_FRAMES later, for the tests that ask
// which test to run or wait for a key between pages.
//
// Each expect=TEXT makes it a test: it exits 1 unless TEXT appears in the
// screen's text at the end; each reject=TEXT, unless TEXT does not. A program that is not there -- the suites not
// fetched (scripts/fetch_timing_suites.py) -- exits SKIPPED, which CTest is
// told means skipped, not passed.
//
// The program is a .sna, .z80, .tap, .tzx or .wav. A snapshot is loaded and
// run; a tape is inserted with auto-start, so the machine resets, types
// LOAD "" and plays it, with standard blocks fast-loaded as in normal use.
// <frames> counts frames of emulated time from there, so a slow tape needs
// enough of them to finish loading. The machine is the 48K unless 128 is
// given, with the ROMs from roms/.
//
// Through the Engine and its run loop rather than the bare machine, because
// that is where the tape trap and the auto-start live -- what a person
// loading the test in VS Code would get.

#include "engine.h"
#include "ula.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

using namespace zx;

namespace {

/// The exit code for a program that has not been fetched; CMake's
/// SKIP_RETURN_CODE names the same number.
constexpr int SKIPPED = 77;

/// How often the wall clock checks how far the emulated one has got.
constexpr auto POLL = std::chrono::milliseconds(1);
/// How long a key is held: long enough for the ROM's and the tests' keyboard
/// scans, which look once a frame, to see it go down and come up.
constexpr long KEY_HOLD_FRAMES = 4;

/// A key pressed at one frame and let go KEY_HOLD_FRAMES later. The name
/// PLAY presses the tape's Play instead.
struct KeyPress {
    std::string key;
    long frame = 0;
};

/// From a 128K's reset: down three times to the menu's 48 BASIC (cursor down
/// is CAPS SHIFT and 6), ENTER, then LOAD "" -- J, SYMBOL SHIFT and P twice,
/// ENTER -- and Play. The frames leave the menu and 48 BASIC time to come up.
const KeyPress MENU_TO_48_BASIC_LOAD[] = {
    {"CAPS SHIFT", 100}, {"6", 100}, {"CAPS SHIFT", 120}, {"6", 120},
    {"CAPS SHIFT", 140}, {"6", 140}, {"ENTER", 160},
    {"J", 300}, {"SYM SHIFT", 320}, {"P", 320}, {"SYM SHIFT", 340}, {"P", 340},
    {"ENTER", 360}, {"PLAY", 370},
};

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

/// Where the 48K ROM keeps its character set: 96 characters from space, 8
/// bytes each, top row first.
constexpr size_t ROM_FONT = 0x3D00;
constexpr int FONT_FIRST = 0x20;
constexpr int FONT_CHARS = 96;
constexpr int TEXT_COLUMNS = 32;
constexpr int TEXT_ROWS = 24;

/// The screen's paper as text: each 8x8 cell matched against the ROM's
/// character set, plain or inverse, '?' where nothing matches and ' ' where
/// the cell is empty either way. What a test that prints its verdict prints.
std::vector<std::string> screen_text(const std::vector<uint8_t>& screen,
                                     const std::vector<uint8_t>& rom48) {
    std::vector<std::string> lines;
    for (int row = 0; row < TEXT_ROWS; row++) {
        std::string line;
        for (int col = 0; col < TEXT_COLUMNS; col++) {
            uint8_t cell[8];
            for (int y = 0; y < 8; y++) {
                const int py = row * 8 + y;
                // The display file's thirds, character rows and pixel rows.
                const size_t addr = size_t((py & 0xC0) << 5) | size_t((py & 0x07) << 8)
                                    | size_t((py & 0x38) << 2) | size_t(col);
                cell[y] = screen[addr];
            }
            char found = '?';
            for (int c = 0; c < FONT_CHARS && found == '?'; c++) {
                bool plain = true;
                bool inverse = true;
                for (int y = 0; y < 8; y++) {
                    const uint8_t glyph = rom48[ROM_FONT + size_t(c) * 8 + size_t(y)];
                    plain = plain && cell[y] == glyph;
                    inverse = inverse && cell[y] == uint8_t(~glyph);
                }
                if (plain || inverse) {
                    found = char(FONT_FIRST + c);
                }
            }
            line += found;
        }
        while (!line.empty() && line.back() == ' ') {
            line.pop_back();
        }
        lines.push_back(line);
    }
    return lines;
}

bool ends_with(const std::string& s, const char* suffix) {
    const std::string tail(suffix);
    if (s.size() < tail.size()) {
        return false;
    }
    for (size_t i = 0; i < tail.size(); i++) {
        const char c = s[s.size() - tail.size() + i];
        if (std::tolower(static_cast<unsigned char>(c)) != tail[i]) {
            return false;
        }
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr,
                     "usage: suite_shot <program> <frames> <out.png> [48|128] [KEY@frame ...]\n");
        return 2;
    }
    const std::string program = argv[1];
    const long frames = std::atol(argv[2]);
    const std::string out_path = argv[3];
    bool is128 = false;
    bool in48 = false;
    bool no_contention = false;
    std::vector<KeyPress> presses;
    std::vector<std::string> expects;
    std::vector<std::string> rejects;
    for (int i = 4; i < argc; i++) {
        const std::string a = argv[i];
        const size_t at = a.find('@');
        if (a == "128") {
            is128 = true;
        } else if (a == "128in48") {
            is128 = true;
            in48 = true;
        } else if (a == "nocontention") {
            no_contention = true;
        } else if (a.compare(0, 7, "expect=") == 0) {
            expects.push_back(a.substr(7));
        } else if (a.compare(0, 7, "reject=") == 0) {
            rejects.push_back(a.substr(7));
        } else if (at != std::string::npos) {
            KeyPress k;
            k.key = a.substr(0, at);
            k.frame = std::atol(a.c_str() + at + 1);
            presses.push_back(k);
        } else if (a != "48") {
            std::fprintf(stderr, "don't understand %s\n", a.c_str());
            return 2;
        }
    }

    Engine engine;
    const std::string root = ZX_PROJECT_ROOT;
    std::vector<uint8_t> data;
    std::vector<uint8_t> rom48;
    for (const char* rom : {"/roms/48.rom", "/roms/128.rom"}) {
        if (read_file(root + rom, data)) {
            if (rom48.empty()) {
                rom48 = data;
            }
            engine.load_rom(data);
        }
    }
    // No ROMs, or no suites, is a machine that cannot run the test rather
    // than one that fails it: skipped, as every test needing roms/ is.
    if (rom48.size() < ROM_FONT + size_t(FONT_CHARS) * 8) {
        std::printf("skipped: roms/48.rom is needed\n");
        return SKIPPED;
    }
    const Model model = is128 ? Model::Spectrum128 : Model::Spectrum48;
    if (!engine.has_rom(model)) {
        std::printf("skipped: no ROM for that model in roms/\n");
        return SKIPPED;
    }
    engine.set_model(model);
    engine.set_speed(Speed::Uncapped);
    if (no_contention) {
        engine.set_contention(false);
    }

    if (!read_file(program, data)) {
        std::printf("skipped: %s is not there -- run scripts/fetch_timing_suites.py\n",
                    program.c_str());
        return SKIPPED;
    }
    std::string error;
    if (ends_with(program, ".sna") || ends_with(program, ".z80")) {
        error = engine.load_snapshot(data);
    } else if (in48) {
        // A 128K test that must run in the 128's own 48 BASIC: the tape goes
        // in stopped, and the keys do what a person would -- the fourth item
        // of the menu, LOAD "", and Play. Pressed at the start of the run so
        // their frames count from the reset that set_model() made.
        error = engine.load_tape(data, program, /*auto_start=*/false);
        for (const KeyPress& k : MENU_TO_48_BASIC_LOAD) {
            presses.push_back(k);
        }
    } else {
        error = engine.load_tape(data, program, /*auto_start=*/true);
    }
    if (!error.empty()) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }

    const UlaTiming& t = is128 ? TIMING_128K : TIMING_48K;
    // Keys go down and up while the run is in flight: the Engine lets them
    // bypass its queue for exactly that. Their timing is as good as the poll,
    // well inside a frame, which is all a keyboard scan can tell apart.
    const uint64_t start = engine.emulated_half_clocks();
    const uint64_t target = start + uint64_t(frames) * t.hc_per_frame();
    std::vector<bool> down(presses.size(), false);
    std::vector<bool> up(presses.size(), false);
    std::thread runner([&engine] { engine.run(); });
    for (;;) {
        const uint64_t now = engine.emulated_half_clocks();
        if (now >= target) {
            break;
        }
        const long frame = long((now - start) / t.hc_per_frame());
        for (size_t i = 0; i < presses.size(); i++) {
            const bool play = presses[i].key == "PLAY";
            if (!down[i] && frame >= presses[i].frame) {
                if (play) {
                    engine.tape_play();
                } else {
                    engine.key_down(presses[i].key);
                }
                down[i] = true;
            }
            if (down[i] && !up[i] && frame >= presses[i].frame + KEY_HOLD_FRAMES) {
                if (!play) {
                    engine.key_up(presses[i].key);
                }
                up[i] = true;
            }
        }
        std::this_thread::sleep_for(POLL);
    }
    engine.pause();
    runner.join();

    const std::vector<uint8_t> rgb = engine.screen();
    if (stbi_write_png(out_path.c_str(), int(FULL_WIDTH), int(FULL_HEIGHT), 3, rgb.data(),
                       int(FULL_WIDTH) * 3) == 0) {
        std::fprintf(stderr, "couldn't write %s\n", out_path.c_str());
        return 1;
    }
    std::printf("wrote %s after %ld frames\n", out_path.c_str(), frames);
    // The screen as text, after the picture: bank 5's display file, which is
    // the screen shown unless a 128K program has switched to bank 7.
    const std::vector<uint8_t> screen = engine.read_memory(0x4000, BITMAP_BYTES);
    const std::vector<std::string> lines = screen_text(screen, rom48);
    for (const std::string& line : lines) {
        std::printf("|%s\n", line.c_str());
    }
    int missing = 0;
    for (const std::string& want : expects) {
        bool found = false;
        for (const std::string& line : lines) {
            found = found || line.find(want) != std::string::npos;
        }
        if (!found) {
            std::printf("FAIL: \"%s\" is not on the screen\n", want.c_str());
            missing++;
        }
    }
    for (const std::string& unwanted : rejects) {
        for (const std::string& line : lines) {
            if (line.find(unwanted) != std::string::npos) {
                std::printf("FAIL: \"%s\" is on the screen\n", unwanted.c_str());
                missing++;
                break;
            }
        }
    }
    return missing == 0 ? 0 : 1;
}
