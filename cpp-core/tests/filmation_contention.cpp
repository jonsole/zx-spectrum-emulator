// How much of a Knight Lore turn would go to ULA contention on a real 48K,
// room by room, split by where the contended memory is: the view buffer, the
// object pool, and everything else in $5B00-$7FFF. (The screen's own writes are
// contended too, but they have nowhere else to go, so they are not counted.)
//
// cpp-core does not model contention, so this estimates it. Every instruction
// that reads or writes a watched address counts once -- the machine records one
// watch hit per instruction, so a PUSH writing two bytes counts once and this
// is a LOWER bound -- and each is charged the delay a 48K's ULA would add at
// the T-state that instruction started: from 14,335 on, for 192 lines of 224 T,
// the first 128 T of each line delay by 6,5,4,3,2,1,0,0 in turn.
//
// The game is driven headless: 0 held through the menu, then every room number
// poked into room_number in turn, each given its steady turns. Lives are topped
// up so nothing restarts, every LD A,R gets the same sequence so two builds see
// the same rolls, and turn_pace is skipped so a turn measures its work alone.
// Symbols come from the SLD, so any build of the game will do.
//
// Written for examples/filmation's README, "The view buffer above $8000", which
// has what it found on 2026-09-17 and what a move would cost.
//
//   filmation_contention <knightlore.z80> <knightlore.sld> <48.rom> <out.csv> [steady turns]
//
// e.g. from the repository root, after build.ps1 -Release -Target filmation_contention:
//
//   cpp-core/build/RelWithDebInfo/filmation_contention.exe
//       examples/filmation/knightlore/output/knightlore.z80
//       examples/filmation/knightlore/output/knightlore.sld roms/48.rom contention.csv 20
//
// It prints the totals; the CSV has them room by room, per steady turn.

#include "snapshot.h"
#include "spectrum.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace zx;

static std::vector<uint8_t> read_file(const char* path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "couldn't open %s\n", path);
        std::exit(2);
    }
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

static std::map<std::string, uint16_t> read_sld(const char* path) {
    std::map<std::string, uint16_t> syms;
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        std::vector<std::string> fields;
        std::stringstream ss(line);
        std::string field;
        while (std::getline(ss, field, '|')) {
            fields.push_back(field);
        }
        if (fields.size() >= 8 && fields[6] == "F") {
            syms[fields[7]] = uint16_t(std::stoi(fields[5]));
        }
    }
    return syms;
}

static const int KINDS = 3;             // view buffer, pool, other
static const char* KIND_NAME[KINDS] = {"view", "pool", "other"};

struct Room {
    uint64_t turns = 0;
    uint64_t work = 0;
    uint64_t hits[KINDS] = {0, 0, 0};
    uint64_t delay[KINDS] = {0, 0, 0};
};

static int contention_delay(uint32_t t) {
    const uint32_t first = 14335;
    if (t < first || t >= first + 192 * 224) {
        return 0;
    }
    const uint32_t in_line = (t - first) % 224;
    if (in_line >= 128) {
        return 0;
    }
    static const int pattern[8] = {6, 5, 4, 3, 2, 1, 0, 0};
    return pattern[in_line % 8];
}

int main(int argc, char** argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: turns_contend snapshot sld 48.rom out.csv [steady]\n");
        return 2;
    }
    const uint64_t steady_wanted = argc > 5 ? uint64_t(std::atoi(argv[5])) : 50;

    Spectrum m;
    std::vector<uint8_t> rom = read_file(argv[3]);
    if (!m.load_rom(rom.data(), rom.size()).empty()) {
        std::fprintf(stderr, "bad ROM\n");
        return 2;
    }
    std::vector<uint8_t> sna = read_file(argv[1]);
    std::string err = load_snapshot(m, sna.data(), sna.size());
    if (!err.empty()) {
        std::fprintf(stderr, "snapshot: %s\n", err.c_str());
        return 2;
    }
    auto syms = read_sld(argv[2]);
    for (const char* need : {"turn_pace", "room_shown", "player_lives", "move_tick", "sun_x", "night",
                             "days", "player_change", "room_number", "view_buffer", "room_objects",
                             "day_step"}) {
        if (!syms.count(need)) {
            std::fprintf(stderr, "no symbol %s\n", need);
            return 2;
        }
    }
    const uint16_t turn_pace = syms["turn_pace"];
    const uint16_t room_shown = syms["room_shown"];
    const uint16_t player_lives = syms["player_lives"];
    const uint16_t move_tick = syms["move_tick"], sun_x = syms["sun_x"], night = syms["night"],
                   days = syms["days"], player_change = syms["player_change"],
                   room_number = syms["room_number"];
    const uint16_t view_lo = syms["view_buffer"], view_hi = uint16_t(view_lo + 512);
    const uint16_t pool_lo = syms["room_objects"], pool_hi = syms["day_step"];

    // Watch the contended RAM that is not the screen.
    std::vector<uint8_t> flags(WATCH_ADDRESSES, 0);
    for (uint32_t a = 0x5B00; a < 0x8000; a++) {
        flags[a] = WATCH_READ | WATCH_WRITE;
    }
    m.set_watch_flags(flags);

    std::set<uint16_t> ld_a_r;
    {
        std::vector<uint8_t> code = m.read_memory(0x5B00, 0xA500);
        for (size_t i = 0; i + 1 < code.size(); i++) {
            if (code[i] == 0xED && code[i + 1] == 0x5F) {
                ld_a_r.insert(uint16_t(0x5B00 + i));
            }
        }
    }
    uint32_t lcg = 12345;
    int sun_start = -1;

    uint16_t back = 0;
    std::vector<uint8_t> ram = m.read_memory(0x8000, 0x8000);
    for (size_t i = 0; i + 2 < ram.size(); i++) {
        if (ram[i] == 0xCD && ram[i + 1] == (turn_pace & 0xFF) && ram[i + 2] == (turn_pace >> 8)) {
            back = uint16_t(0x8000 + i + 3);
            break;
        }
    }
    if (!back) {
        std::fprintf(stderr, "no CALL turn_pace found\n");
        return 2;
    }

    auto now_t = [&] { return m.global_hc() / 2; };
    auto peek = [&](uint16_t a) { return m.read_memory(a, 1)[0]; };

    std::map<int, Room> rooms;
    std::vector<int> order;
    int current = -1;
    uint64_t turn_start = 0;
    bool started = false;
    bool counting = false;      // only a steady turn's accesses are kept
    int next_room = 0;
    uint64_t turns = 0;
    uint64_t hits[KINDS] = {0, 0, 0};
    uint64_t delay[KINDS] = {0, 0, 0};
    const uint64_t max_turns = 400000;

    m.keyboard.key_down("0");

    while (turns < max_turns) {
        const uint16_t pc_before = m.registers().pc;
        const uint32_t t_before = uint32_t(m.ula.frame_hc() / 2);
        m.watch_hit.hit = false;
        m.step_instruction();
        if (m.watch_hit.hit && counting) {
            const uint16_t a = m.watch_hit.addr;
            const int kind = (a >= view_lo && a < view_hi) ? 0 : (a >= pool_lo && a < pool_hi) ? 1 : 2;
            hits[kind]++;
            delay[kind] += uint64_t(contention_delay(t_before));
        }
        m.watch_hit.hit = false;
        if (ld_a_r.count(pc_before)) {
            Registers r = m.registers();
            lcg = lcg * 1103515245u + 12345u;
            r.a = uint8_t(lcg >> 16);
            m.set_registers(r);
        }
        if (m.registers().pc != turn_pace) {
            continue;
        }
        const uint64_t t = now_t();
        turns++;
        const int shown = peek(room_shown);
        if (started) {
            const uint64_t work = t - turn_start;
            if (shown != current) {
                const uint8_t zero = 0, sun = uint8_t(sun_start);
                m.write_memory(move_tick, &zero, 1);
                m.write_memory(sun_x, &sun, 1);
                m.write_memory(night, &zero, 1);
                m.write_memory(days, &zero, 1);
                m.write_memory(player_change, &zero, 1);
                if (!rooms.count(shown)) {
                    rooms[shown];
                    order.push_back(shown);
                }
                current = shown;
            } else if (counting) {
                Room& room = rooms[current];
                room.turns++;
                room.work += work;
                for (int k = 0; k < KINDS; k++) {
                    room.hits[k] += hits[k];
                    room.delay[k] += delay[k];
                }
            }
        } else {
            m.keyboard.key_up("0");
            current = shown;
            started = true;
            sun_start = peek(sun_x);
            rooms[shown];
            order.push_back(shown);
        }
        for (int k = 0; k < KINDS; k++) {
            hits[k] = 0;
            delay[k] = 0;
        }

        uint8_t five = 5;
        m.write_memory(player_lives, &five, 1);

        if (rooms.count(current) && rooms[current].turns >= steady_wanted) {
            if (next_room > 255) {
                break;
            }
            const uint8_t n = uint8_t(next_room++);
            m.write_memory(room_number, &n, 1);
        }
        // The next turn counts if this room has been entered and settled.
        counting = rooms.count(current) && rooms[current].turns < steady_wanted;

        Registers r = m.registers();
        r.pc = back;
        r.sp = uint16_t(r.sp + 2);
        m.set_registers(r);
        turn_start = now_t();
    }

    std::ofstream out(argv[4]);
    out << "room,turns,mean_turn";
    for (int k = 0; k < KINDS; k++) {
        out << "," << KIND_NAME[k] << "_hits," << KIND_NAME[k] << "_delay";
    }
    out << "\n";
    uint64_t all_work = 0, all_turns = 0;
    uint64_t all_hits[KINDS] = {0, 0, 0}, all_delay[KINDS] = {0, 0, 0};
    for (int id : order) {
        const Room& room = rooms[id];
        if (!room.turns) {
            continue;
        }
        out << id << "," << room.turns << "," << double(room.work) / room.turns;
        for (int k = 0; k < KINDS; k++) {
            out << "," << double(room.hits[k]) / room.turns << "," << double(room.delay[k]) / room.turns;
            all_hits[k] += room.hits[k];
            all_delay[k] += room.delay[k];
        }
        out << "\n";
        all_work += room.work;
        all_turns += room.turns;
    }
    std::printf("%zu rooms, %llu steady turns, mean turn %.0f T\n", order.size(),
                (unsigned long long)all_turns, double(all_work) / all_turns);
    for (int k = 0; k < KINDS; k++) {
        std::printf("  %-5s %8.0f instructions a turn, %7.0f T of delay a turn (%.2f%% of a turn)\n",
                    KIND_NAME[k], double(all_hits[k]) / all_turns, double(all_delay[k]) / all_turns,
                    100.0 * double(all_delay[k]) / double(all_work));
    }
    return 0;
}
