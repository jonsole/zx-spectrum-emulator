#include "mm_game.h"

#include "snapshot.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <sstream>
#include <utility>

namespace mm {

namespace {

/// The game's raw bytes start here (skool2bin's output for mm.skool).
constexpr uint16_t RAW_START = 23552;

/// Far more than any pass takes. A pass is around 100,000 T-states of
/// instructions averaging 8 or so; a cavern's start is the longest, drawing
/// the whole cavern.
constexpr uint64_t PASS_MAX_INSTRUCTIONS = 2'000'000;

bool ends_with(const std::string& s, const std::string& tail) {
    return s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

}  // namespace

char action_char(Action a) {
    static const char CHARS[ACTION_COUNT] = {'.', 'L', 'R', 'J', '<', '>'};
    return a < ACTION_COUNT ? CHARS[a] : '?';
}

bool action_from_char(char c, Action& a) {
    for (int i = 0; i < ACTION_COUNT; i++) {
        if (action_char(Action(i)) == c) {
            a = Action(i);
            return true;
        }
    }
    return false;
}

const char* outcome_name(Outcome o) {
    switch (o) {
    case Outcome::Running: return "running";
    case Outcome::Died: return "died";
    case Outcome::CavernComplete: return "complete";
    case Outcome::Stuck: return "stuck";
    }
    return "?";
}

std::string Game::boot(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& game,
                       const std::string& game_name) {
    std::string err = machine_.load_rom(rom.data(), rom.size());
    if (!err.empty()) return "ROM: " + err;

    if (ends_with(game_name, ".sna") || ends_with(game_name, ".z80")) {
        err = zx::load_snapshot(machine_, game.data(), game.size());
        if (!err.empty()) return "game: " + err;
    } else {
        if (game.size() != 0x10000 - RAW_START) {
            return "game: expected the " + std::to_string(0x10000 - RAW_START) +
                   " bytes from 23552 (make_game.py's mm.bin), got " +
                   std::to_string(game.size());
        }
        machine_.write_memory(RAW_START, game.data(), game.size());
    }
    // A sanity check that this is the game the addresses are for: BEGIN is
    // DI; LD SP,40190 (F3 31 FE 9C).
    const std::vector<uint8_t> begin = machine_.read_memory(addr::BEGIN, 4);
    if (begin != std::vector<uint8_t>{0xF3, 0x31, 0xFE, 0x9C}) {
        return "game: this is not the Manic Miner the addresses are for (no DI; LD SP,40190 at 33792)";
    }
    for (uint16_t a : addr::FAST_LDIRS) {
        if (machine_.memory.read(a) != 0xED || machine_.memory.read(uint16_t(a + 1)) != 0xB0) {
            return "game: no LDIR at " + std::to_string(a) + ", where the disassembly has one";
        }
        ldir_at_[a] = true;
    }

    // The game never turns the interrupts on and needs nothing from
    // contention, so the machine's timing has no say in what happens. Turning
    // contention off only makes it quicker.
    machine_.set_contention(false);
    zx::Registers r = machine_.registers();
    r.pc = addr::BEGIN;
    r.iff1 = r.iff2 = false;
    r.im = 1;
    machine_.set_registers(r);
    machine_.keyboard.clear();

    // To the title screen's tune, then straight into a game, as the title
    // screen does when ENTER is pressed, but with the demo flag clear.
    run_to(addr::PLAYTUNE, 5'000'000);
    if (machine_.registers().pc != addr::PLAYTUNE) return "game: never reached the title screen";
    r = machine_.registers();
    r.pc = addr::STARTGAME;
    r.sp = 40190;  // as BEGIN set it: the title screen's call is abandoned
    machine_.set_registers(r);
    const uint8_t zero = 0;
    machine_.write_memory(addr::DEMO, &zero, 1);
    run_to(addr::LOOP, 5'000'000);
    if (machine_.registers().pc != addr::LOOP) return "game: never reached the main loop";
    enter_cavern(0);
    return "";
}

void Game::enter_cavern(int cavern, int lives) {
    const uint8_t sheet = uint8_t(cavern);
    const uint8_t nomen = uint8_t(lives);
    const uint8_t music_off = 2;  // the tune costs a quarter of a pass, and changes nothing
    const uint8_t zero = 0;
    machine_.write_memory(addr::SHEET, &sheet, 1);
    machine_.write_memory(addr::NOMEN, &nomen, 1);
    machine_.write_memory(addr::MUSICFLAGS, &music_off, 1);
    machine_.write_memory(addr::DEMO, &zero, 1);
    zx::Registers r = machine_.registers();
    r.pc = addr::NEWSHT;
    r.sp = 40190;
    machine_.set_registers(r);
    machine_.keyboard.clear();
    run_to(addr::LOOP, 5'000'000);
}

void Game::run_to(uint16_t target, uint64_t max_instructions) {
    for (uint64_t i = 0; i < max_instructions; i++) {
        if (advance() == target) return;
    }
}

uint16_t Game::advance() {
    machine_.step_instruction();
    uint16_t pc = machine_.registers().pc;
    if (fast_ && ldir_at_[pc]) {
        host_ldir();
        pc = uint16_t(pc + 2);
    }
    return pc;
}

// LDIR as the Z80 finishes it: (DE) <- (HL), HL and DE up, BC down, until BC
// is 0 -- a byte at a time, so the overlapping fills the game does with it
// (HL, then DE = HL+1) come out the same. Flags: S, Z and C kept; H, N and
// P/V reset; bits 3 and 5 from A plus the last byte moved, bit 5 from its
// bit 1. BC = 0 at the start means 65,536 bytes, as on the Z80.
void Game::host_ldir() {
    zx::Registers r = machine_.registers();
    uint16_t hl = r.hl(), de = r.de(), bc = r.bc();
    uint8_t last = 0;
    do {
        last = machine_.memory.read(hl);
        machine_.memory.write(de, last);
        hl++;
        de++;
        bc--;
    } while (bc != 0);
    const uint8_t n = uint8_t(r.a + last);
    r.f = uint8_t((r.f & 0xC1) | (n & 0x08) | ((n & 0x02) << 4));
    r.set_hl(hl);
    r.set_de(de);
    r.set_bc(0);
    r.pc = uint16_t(r.pc + 2);
    machine_.set_registers(r);
}

Outcome Game::step(Action a) {
    zx::Keyboard& k = machine_.keyboard;
    k.clear();
    if (a == LEFT || a == JUMP_LEFT) k.key_down("O");
    if (a == RIGHT || a == JUMP_RIGHT) k.key_down("P");
    if (a == JUMP || a == JUMP_LEFT || a == JUMP_RIGHT) k.key_down("SPACE");
    steps_++;

    for (uint64_t i = 0; i < PASS_MAX_INSTRUCTIONS; i++) {
        const uint16_t pc = advance();
        if (pc == addr::LOOP) return Outcome::Running;
        if (pc == addr::MANDEAD) return Outcome::Died;
        if (pc == addr::NXSHEET) return Outcome::CavernComplete;
    }
    return Outcome::Stuck;
}

View Game::view() {
    View v;
    v.cavern = peek(addr::SHEET);
    const uint16_t loc = uint16_t(peek(addr::LOCATION) | (peek(addr::LOCATION + 1) << 8));
    v.x = ((loc - addr::ATTR_BUFFER) & 31) * 8 + peek(addr::FRAME) * 2;
    v.y = peek(addr::WILLY_Y) / 2;
    v.airborne = peek(addr::AIRBORNE);
    v.facing_left = (peek(addr::DMFLAGS) & 1) != 0;
    v.air = peek(addr::AIR) - 36;
    v.clock = peek(addr::CLOCK);
    for (int i = 0; i < 5; i++) {
        const uint8_t attr = peek(uint16_t(addr::ITEMS + 5 * i));
        if (attr == 255) break;
        v.items_total++;
        if (attr == 0) {
            v.items_mask = uint8_t(v.items_mask | (1 << i));
        } else {
            v.items_left++;
        }
    }
    v.portal_open = (peek(addr::PORTAL) & 0x80) != 0;
    v.lives = peek(addr::NOMEN);
    for (int i = 0; i < 10; i++) {
        v.score = v.score * 10 + (peek(uint16_t(addr::SCORE + i)) - '0');
    }
    return v;
}

void Game::render(std::vector<uint8_t>& rgb, bool flash) {
    // The usual Spectrum palette: 0xD7 for plain colours, 0xFF for BRIGHT.
    rgb.assign(256 * 192 * 3, 0);
    for (int y = 0; y < 192; y++) {
        // The display file's row order: third, pixel line in the cell, cell row.
        const uint16_t row = uint16_t(0x4000 | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2));
        for (int cx = 0; cx < 32; cx++) {
            const uint8_t bits = peek(uint16_t(row + cx));
            const uint8_t attr = peek(uint16_t(0x5800 + (y / 8) * 32 + cx));
            int ink = attr & 7, paper = (attr >> 3) & 7;
            if ((attr & 0x80) && flash) std::swap(ink, paper);
            const uint8_t level = (attr & 0x40) ? 0xFF : 0xD7;
            for (int b = 0; b < 8; b++) {
                const int colour = (bits & (0x80 >> b)) ? ink : paper;
                uint8_t* p = &rgb[size_t((y * 256 + cx * 8 + b) * 3)];
                p[0] = (colour & 2) ? level : 0;  // red is bit 1
                p[1] = (colour & 4) ? level : 0;  // green bit 2
                p[2] = (colour & 1) ? level : 0;  // blue bit 0
            }
        }
    }
}

void Game::save(Saved& s) {
    s.ram = machine_.read_memory(SLICE_START, SLICE_END - SLICE_START);
    s.sp = machine_.registers().sp;
}

void Game::restore(const Saved& s) {
    machine_.write_memory(SLICE_START, s.ram.data(), s.ram.size());
    zx::Registers r = machine_.registers();
    r.pc = addr::LOOP;
    r.sp = s.sp;
    machine_.set_registers(r);
}

std::string route_to_text(const Route& r, const std::string& comment) {
    std::ostringstream out;
    std::istringstream lines(comment);
    for (std::string line; std::getline(lines, line);) out << "# " << line << "\n";
    out << "cavern " << r.cavern << "\n";
    for (size_t i = 0; i < r.moves.size(); i++) {
        out << action_char(r.moves[i]);
        if (i % 64 == 63 || i + 1 == r.moves.size()) out << "\n";
    }
    return out.str();
}

bool route_from_text(const std::string& text, Route& r, std::string& error) {
    std::istringstream lines(text);
    bool have_cavern = false;
    r.moves.clear();
    for (std::string line; std::getline(lines, line);) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        if (line.rfind("cavern ", 0) == 0) {
            r.cavern = std::atoi(line.c_str() + 7);
            have_cavern = true;
            continue;
        }
        for (char c : line) {
            Action a;
            if (!action_from_char(c, a)) {
                error = std::string("not a move: '") + c + "'";
                return false;
            }
            r.moves.push_back(a);
        }
    }
    if (!have_cavern) {
        error = "no 'cavern <n>' line";
        return false;
    }
    return true;
}

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

std::string default_rom_path() { return std::string(ZX_PROJECT_ROOT) + "/roms/48.rom"; }
std::string default_routes_dir() { return std::string(ZX_PROJECT_ROOT) + "/agents/manicminer/routes"; }
std::string default_game_path() { return std::string(ZX_PROJECT_ROOT) + "/agents/manicminer/game/mm.bin"; }

}  // namespace mm
