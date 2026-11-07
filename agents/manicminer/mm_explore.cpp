// Finds a route through a cavern by search, the way Go-Explore beat
// Montezuma's Revenge: keep an archive of the places Willy has stood, with
// the game saved there; pick one, put the game back as it was, try random
// moves from it, and keep any new place reached (or an old one reached
// sooner). Manic Miner has no randomness, so a route found this way replays
// exactly.
//
// A place ("cell") is where Willy stands on the ground, to 8 pixels, and
// which of the cavern's items he has: that is what progress is. Where timing
// decides, the guardian's phase is part of it too (guardian_phase). Of two ways
// to the same cell the one with more air left is kept, then the shorter.
//
//   mm_explore [options] <cavern>|all
//     --threads n   searches at once, each with its own archive (default: cores)
//     --passes n    the most passes each search may play (default 400000)
//     --seed n      (default 1)
//     --out dir     where the routes go (default agents/manicminer/routes)
//     --collected m an experiment: items in mask m are taken before the search
//                   starts; prints what it finds and keeps nothing
//     --rom f, --game f   as mm_lab
//
// Writes <out>/cavern<nn>.route on success, after replaying it from the
// cavern's start to check it.

#include "mm_game.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace mm;

namespace {

using Clock = std::chrono::steady_clock;

struct Options {
    std::string rom = default_rom_path(), game = default_game_path();
    std::string out = default_routes_dir();
    unsigned threads = 0;
    uint64_t passes = 400000;
    uint32_t seed = 1;
    uint8_t collected = 0;  // items taken before the search starts (an experiment)
};

/// A saved game kept as the bytes that differ from the cavern's start: a
/// cell then costs a kilobyte or two rather than the slice's 16.
struct Diff {
    std::vector<uint16_t> at;
    std::vector<uint8_t> value;
    uint16_t sp = 0;
};

Diff make_diff(const Game::Saved& base, const Game::Saved& s) {
    Diff d;
    d.sp = s.sp;
    for (size_t i = 0; i < s.ram.size(); i++) {
        if (s.ram[i] != base.ram[i]) {
            d.at.push_back(uint16_t(i));
            d.value.push_back(s.ram[i]);
        }
    }
    return d;
}

void apply_diff(const Game::Saved& base, const Diff& d, Game::Saved& out) {
    out.ram = base.ram;
    for (size_t i = 0; i < d.at.size(); i++) out.ram[d.at[i]] = d.value[i];
    out.sp = d.sp;
}

struct Cell {
    Diff saved;
    std::vector<Action> path;  // the moves from the cavern's start
    int items = 0;
    int air = 0;  // air_left() when reached
    uint32_t chosen = 0;
    uint32_t fruitless = 0;  // times chosen in a row that found nothing new
};

/// In Eugene's Lair the portal is at the foot of a pit under Eugene's column.
/// Once the last item is taken Eugene heads down and stops at y = 87, in the
/// pit's mouth, for good (EUGENE, 36344), so Willy has to take it with
/// Eugene high up and get into the pit before he arrives. Where Eugene is
/// then is part of the place: his height to 16 pixels and his direction.
/// Only for the last item and after: before that his timing changes nothing,
/// and keeping it would multiply the cells sixteen times over.
///
/// Amoebatrons' Revenge (17): Willy climbs from the floor to the item at the
/// top, level by level, each with a guardian rolling along it to get past.
/// The guardian on his own level or the next one up, to 4 cells, and its
/// direction are part of the place, so a jump made at a good moment is kept
/// beside an earlier one made at a bad one.
uint32_t guardian_phase(const View& v) {
    if (v.cavern == 4 && v.items_left <= 1) return uint32_t(v.eugene_up) | uint32_t(v.eugene_y / 16) << 1;
    if (v.cavern == 17) {
        const int feet = v.y / 8 + 2;  // the row he stands on
        const View::Guardian* next = nullptr;
        for (int i = 0; i < v.guardian_count; i++) {
            const View::Guardian& g = v.guardians[i];
            // Its bottom row is row + 1; the one on his level or just above.
            if (g.row + 1 < feet && (!next || g.row > next->row)) next = &g;
        }
        if (next) return uint32_t(next->col / 4) | uint32_t(next->moving_left) << 3;
    }
    return 0;
}

/// What a player learns from watching someone else play: an item that must
/// be taken last. Taking it earlier is treated as a dead end.
///
/// Eugene's Lair: item 5, at (12,9), on the ledge nearest the pit. Taken last
/// it leaves the shortest dash to the portal, the only one quick enough to
/// beat Eugene down (mm_explore --collected 0x0F 4 finds a way; with any other
/// item left till last, no way turned up in 480,000 passes). Item 4 lies
/// just past it, so walking from the right takes item 5 first: unhinted, the
/// search nearly always took them in the wrong order and never recovered.
int last_item(int cavern) { return cavern == 4 ? 4 : -1; }

bool breaks_hint(const View& v) {
    const int last = last_item(v.cavern);
    return last >= 0 && (v.items_mask & (1 << last)) && v.items_left > 0;
}

/// Air and clock together: what is left of the air, finer than the bar.
int air_left(const View& v) { return v.air * 256 + v.clock; }

uint32_t cell_key(const View& v) {
    return uint32_t(v.x / 8) | uint32_t(v.y / 8) << 5 | uint32_t(v.items_mask) << 9 |
           guardian_phase(v) << 14;
}

struct Shared {
    std::atomic<bool> found{false};
    std::atomic<uint64_t> passes{0};
    std::atomic<int> best_items{0};
    std::atomic<int> highest{255};  // the smallest y Willy has stood at
    std::atomic<size_t> cells{0};
    std::mutex lock;
    Route route;
};

void search(const Options& o, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& game,
            int cavern, uint32_t seed, Shared& shared) {
    Game g;
    if (!g.boot(rom, game, o.game).empty()) return;
    std::mt19937 rng(seed);
    g.enter_cavern(cavern);
    const uint8_t taken = 0;
    for (int i = 0; i < 5; i++) {
        if (o.collected & (1 << i)) g.machine().write_memory(uint16_t(addr::ITEMS + 5 * i), &taken, 1);
    }
    Game::Saved base, scratch;
    g.save(base);

    std::unordered_map<uint32_t, Cell> archive;
    const View start = g.view();
    archive[cell_key(start)] = Cell{make_diff(base, base), {}, 0, air_left(start)};
    std::vector<uint32_t> keys;
    std::vector<double> weights;
    uint64_t passes = 0;

    while (passes < o.passes && !shared.found) {
        // Choose a cell: ones further on (more items) more likely, and ones
        // tried often less so -- above all ones that keep leading nowhere new,
        // such as all the items taken too late to reach the portal.
        keys.clear();
        weights.clear();
        for (const auto& [key, c] : archive) {
            keys.push_back(key);
            weights.push_back(std::pow(4.0, c.items) / std::sqrt(1.0 + c.chosen) / (1.0 + c.fruitless));
        }
        std::discrete_distribution<size_t> pick(weights.begin(), weights.end());
        Cell& from = archive[keys[pick(rng)]];  // stays valid as cells are added
        from.chosen++;
        bool fruitful = false;
        apply_diff(base, from.saved, scratch);
        g.restore(scratch);
        std::vector<Action> path = from.path;

        // Explore from it: random moves, each held for a while.
        Action held = Action(rng() % ACTION_COUNT);
        const int length = 20 + int(rng() % 60);
        int taken = 0;
        for (int i = 0; i < length; i++) {
            if (rng() % 4 == 0) held = Action(rng() % ACTION_COUNT);
            const Outcome out = g.step(held);
            passes++;
            taken++;
            path.push_back(held);
            if (out == Outcome::CavernComplete) {
                std::lock_guard<std::mutex> l(shared.lock);
                if (!shared.found || path.size() < shared.route.moves.size()) {
                    shared.route.cavern = cavern;
                    shared.route.moves = path;
                }
                shared.found = true;
                break;
            }
            if (out != Outcome::Running) break;
            const View v = g.view();
            if (breaks_hint(v)) break;
            if (v.airborne != 0) continue;  // only places he stands on count
            const uint32_t key = cell_key(v);
            auto it = archive.find(key);
            // Of two ways to a place keep the one with more air left: in
            // Solar Power Generator the light beam drains air, so a quicker
            // way through it can leave less. Then the shorter way.
            const int air = air_left(v);
            if (it == archive.end() || air > it->second.air ||
                (air == it->second.air && path.size() < it->second.path.size())) {
                g.save(scratch);
                Cell& c = archive[key];
                c.saved = make_diff(base, scratch);
                c.path = path;
                c.items = v.items_total - v.items_left;
                c.air = air;
                if (c.items > shared.best_items) shared.best_items = c.items;
                if (v.y < shared.highest) shared.highest = v.y;
                fruitful = true;
            }
        }
        from.fruitless = fruitful ? 0 : from.fruitless + 1;
        shared.passes += uint64_t(taken);
        if (archive.size() > shared.cells) shared.cells = archive.size();
    }
}

/// Replays a route from the cavern's start: CavernComplete on its last move?
bool verify(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& game,
            const std::string& game_name, const Route& r, View& end) {
    Game g;
    if (!g.boot(rom, game, game_name).empty()) return false;
    g.enter_cavern(r.cavern);
    for (size_t i = 0; i < r.moves.size(); i++) {
        end = g.view();
        const Outcome o = g.step(r.moves[i]);
        if (o != Outcome::Running) return o == Outcome::CavernComplete && i + 1 == r.moves.size();
    }
    return false;
}

bool explore(const Options& o, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& game,
             int cavern) {
    Shared shared;
    std::vector<std::thread> pool;
    const auto t0 = Clock::now();
    for (unsigned t = 0; t < o.threads; t++) {
        pool.emplace_back(search, std::cref(o), std::cref(rom), std::cref(game), cavern,
                          o.seed * 1000 + t, std::ref(shared));
    }
    // Progress every ten seconds until every search has stopped.
    std::atomic<bool> done{false};
    std::thread progress([&] {
        int ticks = 0;
        while (!done) {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            if (++ticks % 40 == 0 && !done) {
                const double s = std::chrono::duration<double>(Clock::now() - t0).count();
                std::printf("  cavern %2d  %4.0fs  %9llu passes  %6zu cells  best %d items  highest y %d\n",
                            cavern, s, (unsigned long long)shared.passes.load(), shared.cells.load(),
                            shared.best_items.load(), shared.highest.load());
                std::fflush(stdout);
            }
        }
    });
    for (auto& th : pool) th.join();
    done = true;
    progress.join();
    const double secs = std::chrono::duration<double>(Clock::now() - t0).count();

    if (!shared.found) {
        std::printf("cavern %2d  no route: %llu passes in %.0fs, best %d items\n", cavern,
                    (unsigned long long)shared.passes.load(), secs, shared.best_items.load());
        return false;
    }
    if (o.collected != 0) {
        // Not a route from the cavern's start: show it, keep nothing.
        std::printf("cavern %2d  with items 0x%02X taken first: reached the portal in %zu passes\n%s", cavern,
                    o.collected, shared.route.moves.size(), route_to_text(shared.route, "").c_str());
        return true;
    }
    View end;
    if (!verify(rom, game, o.game, shared.route, end)) {
        std::printf("cavern %2d  a route was found but does not replay -- a bug\n", cavern);
        return false;
    }
    char name[32];
    std::snprintf(name, sizeof name, "/cavern%02d.route", cavern);
    char comment[200];
    std::snprintf(comment, sizeof comment,
                  "Manic Miner cavern %d, found by mm_explore (seed %u, %llu passes searched)\n"
                  "%zu passes; %d air left as it enters the portal",
                  cavern, o.seed, (unsigned long long)shared.passes.load(), shared.route.moves.size(),
                  end.air);
    std::ofstream(o.out + name) << route_to_text(shared.route, comment);
    std::printf("cavern %2d  route of %zu passes, air left %d: %llu passes searched in %.0fs -> %s\n",
                cavern, shared.route.moves.size(), end.air, (unsigned long long)shared.passes.load(), secs,
                (o.out + name).c_str());
    return true;
}

int usage() {
    std::fprintf(stderr, "usage: mm_explore [--threads n] [--passes n] [--seed n] [--out dir] "
                         "[--rom f] [--game f] <cavern>|all\n");
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    Options o;
    int i = 1;
    for (; i + 1 < argc && argv[i][0] == '-'; i += 2) {
        const std::string opt = argv[i], val = argv[i + 1];
        if (opt == "--threads") o.threads = unsigned(std::atoi(val.c_str()));
        else if (opt == "--passes") o.passes = uint64_t(std::atoll(val.c_str()));
        else if (opt == "--collected") o.collected = uint8_t(std::strtol(val.c_str(), nullptr, 0));
        else if (opt == "--seed") o.seed = uint32_t(std::atoi(val.c_str()));
        else if (opt == "--out") o.out = val;
        else if (opt == "--rom") o.rom = val;
        else if (opt == "--game") o.game = val;
        else return usage();
    }
    if (i + 1 != argc) return usage();
    if (o.threads == 0) o.threads = std::max(1u, std::thread::hardware_concurrency());

    std::vector<uint8_t> rom, game;
    if (!read_file(o.rom, rom) || !read_file(o.game, game)) {
        std::fprintf(stderr, "mm_explore: needs %s and %s (make_game.py)\n", o.rom.c_str(), o.game.c_str());
        return 2;
    }
    {
        Game g;  // fail early, and once, on a wrong ROM or game
        const std::string err = g.boot(rom, game, o.game);
        if (!err.empty()) {
            std::fprintf(stderr, "mm_explore: %s\n", err.c_str());
            return 2;
        }
    }
    const std::string which = argv[i];
    int first = 0, last = 19;
    if (which != "all") first = last = std::atoi(which.c_str());
    int cleared = 0;
    for (int c = first; c <= last; c++) cleared += explore(o, rom, game, c) ? 1 : 0;
    if (first != last) std::printf("%d of %d caverns have a route\n", cleared, last - first + 1);
    return cleared == last - first + 1 ? 0 : 1;
}
