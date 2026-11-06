// The Manic Miner lab: how fast the game runs headless, and how a player does
// in each cavern.
//
//   mm_lab bench [seconds] [threads]
//       Random play in cavern 0 for a while: passes a second, on one thread
//       and on several at once (each its own machine).
//   mm_lab play <route file>...
//       Replays each route from its cavern's start: the outcome, the passes
//       it took, the items and the air left.
//   mm_lab film <route file> <out.rgb>
//       Replays a route and writes the screen after every pass as raw frames,
//       256x192 RGB24, for ffmpeg (README.md has the command for a GIF).
//   mm_lab random <cavern> [tries] [seed]
//       The random player's baseline: how far random moves get.
//
// Options before the command: --rom <file> (default roms/48.rom), --game
// <file> (default agents/manicminer/game/mm.bin, or a .sna/.z80), --slow
// (every LDIR run by the emulated Z80: see Game::set_fast).

#include "mm_game.h"
#include "mm_player.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

using namespace mm;

namespace {

using Clock = std::chrono::steady_clock;

struct Files {
    std::vector<uint8_t> rom, game;
    std::string game_name;
};

bool boot(Game& g, const Files& f) {
    const std::string err = g.boot(f.rom, f.game, f.game_name);
    if (!err.empty()) {
        std::fprintf(stderr, "mm_lab: %s\n", err.c_str());
        return false;
    }
    return true;
}

struct Result {
    Outcome outcome = Outcome::Running;
    size_t passes = 0;
    View end;
};

/// Plays one cavern from its start until it ends or `max_passes` go by.
Result play(Game& g, Player& p, int cavern, size_t max_passes) {
    g.enter_cavern(cavern);
    p.start(g);
    Result r;
    while (r.passes < max_passes) {
        r.end = g.view();
        r.outcome = g.step(p.move(g));
        r.passes++;
        if (r.outcome != Outcome::Running) break;
    }
    if (r.outcome == Outcome::Running) r.end = g.view();
    return r;
}

int bench(const Files& f, double seconds, unsigned threads, bool fast) {
    auto run = [&](unsigned n) {
        std::atomic<uint64_t> total{0};
        std::vector<std::thread> pool;
        const auto stop = Clock::now() + std::chrono::duration<double>(seconds);
        for (unsigned t = 0; t < n; t++) {
            pool.emplace_back([&, t] {
                Game g;
                if (!boot(g, f)) return;
                g.set_fast(fast);
                RandomPlayer p(1234 + t);
                const uint64_t before = g.steps();
                while (Clock::now() < stop) {
                    if (g.step(p.move(g)) != Outcome::Running) g.enter_cavern(0);
                }
                total += g.steps() - before;
            });
        }
        for (auto& th : pool) th.join();
        return double(total) / seconds;
    };
    const double one = run(1);
    // A pass in cavern 0 is about 219,000 T-states: some 16 a second on a
    // real 48K's 3.5 MHz.
    std::printf("1 thread:   %8.0f passes/s  (%.0fx a real 48K's ~16 a second)\n", one, one / 16.0);
    if (threads > 1) {
        const double many = run(threads);
        std::printf("%u threads: %8.0f passes/s  (%.1fx one thread)\n", threads, many, many / one);
    }
    return 0;
}

int play_routes(const Files& f, const std::vector<std::string>& paths) {
    Game g;
    if (!boot(g, f)) return 2;
    int cleared = 0;
    for (const std::string& path : paths) {
        std::vector<uint8_t> bytes;
        Route route;
        std::string err;
        if (!read_file(path, bytes) ||
            !route_from_text(std::string(bytes.begin(), bytes.end()), route, err)) {
            std::printf("%s: %s\n", path.c_str(), err.empty() ? "can't read it" : err.c_str());
            continue;
        }
        RoutePlayer p(route);
        const Result r = play(g, p, route.cavern, route.moves.size() + 1);
        if (r.outcome == Outcome::CavernComplete) cleared++;
        std::printf("cavern %2d  %-8s  %5zu passes  items %d/%d  air %3d  (%s)\n", route.cavern,
                    outcome_name(r.outcome), r.passes, r.end.items_total - r.end.items_left,
                    r.end.items_total, r.end.air, path.c_str());
    }
    std::printf("%d of %zu routes clear their cavern\n", cleared, paths.size());
    return cleared == int(paths.size()) ? 0 : 1;
}

int film(const Files& f, const std::string& route_path, const std::string& out_path) {
    Game g;
    if (!boot(g, f)) return 2;
    std::vector<uint8_t> bytes;
    Route route;
    std::string err;
    if (!read_file(route_path, bytes) ||
        !route_from_text(std::string(bytes.begin(), bytes.end()), route, err)) {
        std::fprintf(stderr, "mm_lab: %s: %s\n", route_path.c_str(), err.empty() ? "can't read it" : err.c_str());
        return 2;
    }
    FILE* out = std::fopen(out_path.c_str(), "wb");
    if (!out) {
        std::fprintf(stderr, "mm_lab: can't write %s\n", out_path.c_str());
        return 2;
    }
    g.enter_cavern(route.cavern);
    std::vector<uint8_t> rgb;
    size_t frames = 0;
    Outcome o = Outcome::Running;
    for (size_t i = 0; i < route.moves.size() && o == Outcome::Running; i++) {
        o = g.step(route.moves[i]);
        if (o != Outcome::Running) break;  // the last picture is the one before the portal
        g.render(rgb, (i / 8) % 2 == 1);
        std::fwrite(rgb.data(), 1, rgb.size(), out);
        frames++;
    }
    std::fclose(out);
    std::printf("%zu frames of 256x192 RGB24 -> %s (%s)\n", frames, out_path.c_str(), outcome_name(o));
    return 0;
}

int random_baseline(const Files& f, int cavern, int tries, uint32_t seed) {
    Game g;
    if (!boot(g, f)) return 2;
    int best_items = 0, cleared = 0;
    size_t total_passes = 0;
    for (int t = 0; t < tries; t++) {
        RandomPlayer p(seed + uint32_t(t));
        const Result r = play(g, p, cavern, 20000);
        total_passes += r.passes;
        const int items = r.end.items_total - r.end.items_left;
        if (items > best_items) best_items = items;
        if (r.outcome == Outcome::CavernComplete) cleared++;
    }
    std::printf("cavern %d, %d random tries: cleared %d, best %d items, %.0f passes a try on average\n",
                cavern, tries, cleared, best_items, double(total_passes) / tries);
    return 0;
}

int usage() {
    std::fprintf(stderr,
                 "usage: mm_lab [--rom f] [--game f] bench [seconds] [threads]\n"
                 "       mm_lab [--rom f] [--game f] play <route>...\n"
                 "       mm_lab [--rom f] [--game f] film <route> <out.rgb>\n"
                 "       mm_lab [--rom f] [--game f] random <cavern> [tries] [seed]\n");
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    std::string rom_path = default_rom_path(), game_path = default_game_path();
    bool slow = false;
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        const std::string opt = argv[i];
        if (opt == "--slow") slow = true;
        else if (opt == "--rom" && i + 1 < argc) rom_path = argv[++i];
        else if (opt == "--game" && i + 1 < argc) game_path = argv[++i];
        else return usage();
    }
    if (i >= argc) return usage();
    Files f;
    f.game_name = game_path;
    if (!read_file(rom_path, f.rom)) {
        std::fprintf(stderr, "mm_lab: no ROM at %s\n", rom_path.c_str());
        return 2;
    }
    if (!read_file(game_path, f.game)) {
        std::fprintf(stderr, "mm_lab: no game at %s (agents/manicminer/make_game.py builds it)\n",
                     game_path.c_str());
        return 2;
    }
    const std::string cmd = argv[i++];
    auto arg = [&](int n, double dflt) { return i + n < argc ? std::atof(argv[i + n]) : dflt; };
    if (cmd == "bench") {
        const unsigned hw = std::thread::hardware_concurrency();
        return bench(f, arg(0, 5.0), unsigned(arg(1, hw ? hw : 1)), !slow);
    }
    if (cmd == "play") return play_routes(f, std::vector<std::string>(argv + i, argv + argc));
    if (cmd == "film" && i + 2 == argc) return film(f, argv[i], argv[i + 1]);
    if (cmd == "random") return random_baseline(f, int(arg(0, 0)), int(arg(1, 20)), uint32_t(arg(2, 1)));
    return usage();
}
