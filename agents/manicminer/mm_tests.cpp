// The Manic Miner player's game wrapper. Expected values are worked out from
// the game's disassembly (mm.skool), not captured from a run.
//
// Skips (77) unless roms/48.rom and the game (make_game.py) are there:
// neither is committed.

#include "mm_game.h"
#include "mm_player.h"
#include "test_main.h"

#include <cstdio>
#include <random>

using namespace mm;

namespace {

std::vector<uint8_t> g_rom, g_game;

void boot(Game& g) {
    const std::string err = g.boot(g_rom, g_game, default_game_path());
    if (!err.empty()) std::printf("    boot: %s\n", err.c_str());
}

bool same_game(Game& a, Game& b) {
    Game::Saved sa, sb;
    a.save(sa);
    b.save(sb);
    return sa.ram == sb.ram && sa.sp == sb.sp;
}

}  // namespace

// Central Cavern's definition (CAVERN0, 45056): Willy at attribute buffer
// 23970 = row 13, column 2, pixel y*2 = 208, frame 0; five items, the last
// byte after them 255; the portal shut (attribute 14, bit 7 clear); air 63
// (27 cells above the empty 36), clock 252.
TEST(boots_into_central_cavern) {
    Game g;
    boot(g);
    const View v = g.view();
    CHECK_EQ(v.cavern, 0);
    CHECK_EQ(v.x, 16);
    CHECK_EQ(v.y, 104);
    CHECK_EQ(v.airborne, 0);
    CHECK_EQ(v.items_total, 5);
    CHECK_EQ(v.items_left, 5);
    CHECK_EQ(int(v.items_mask), 0);
    CHECK(!v.portal_open);
    CHECK_EQ(v.air, 27);
    CHECK_EQ(v.clock, 252);
    CHECK_EQ(v.lives, 2);
    CHECK_EQ(v.score, 0L);
}

// Holding right moves Willy 2 pixels a pass (one animation frame). He starts
// at x = 16 facing right and still (DMFLAGS 0); right while facing right
// makes him move in the same pass (LRMOVEMENT, 33808), so four passes take
// him to x = 24.
TEST(holding_right_walks_two_pixels_a_pass) {
    Game g;
    boot(g);
    for (int i = 0; i < 4; i++) CHECK(g.step(RIGHT) == Outcome::Running);
    CHECK_EQ(g.view().x, 24);
    CHECK(!g.view().facing_left);
}

// DECAIR (35388) takes 4 off the clock every pass; when the clock has just
// gone from 0 to 252 it takes a cell of air, or, with the air at 36 already,
// returns Z and the main loop jumps to MANDEAD. From clock 252 the first
// wrap is on pass 64, so the air reaches 36 on pass 64 * 27 = 1728 and runs
// out on pass 64 * 28 = 1792. Willy standing at his start is out of every
// guardian's way.
TEST(standing_still_runs_out_of_air_on_pass_1792) {
    Game g;
    boot(g);
    int passes = 0;
    Outcome o = Outcome::Running;
    while (o == Outcome::Running && passes < 5000) {
        o = g.step(NONE);
        passes++;
        if (passes == 1728) CHECK_EQ(g.view().air, 0);
    }
    CHECK(o == Outcome::Died);
    CHECK_EQ(passes, 1792);
}

// Fast mode (the host does the LDIRs) must be the same game as the emulated
// Z80 doing them, pass by pass, in caverns with each kind of guardian
// routine: Eugene (4), the Kong Beast (7), the vertical guardians (8 on),
// the Skylabs (13), the light beam (18).
TEST(fast_mode_is_the_same_game) {
    Game fast;
    boot(fast);
    Game slow;
    boot(slow);
    slow.set_fast(false);
    for (int cavern : {0, 4, 7, 8, 13, 18}) {
        fast.enter_cavern(cavern);
        slow.enter_cavern(cavern);
        CHECK(same_game(fast, slow));
        RandomPlayer p(uint32_t(100 + cavern));
        bool ok = true;
        for (int i = 0; i < 150 && ok; i++) {
            const Action a = p.move(fast);
            const Outcome of = fast.step(a), os = slow.step(a);
            if (of != os || !same_game(fast, slow)) {
                std::printf("    cavern %d differs at pass %d\n", cavern, i + 1);
                ok = false;
            }
            if (of != Outcome::Running) {
                fast.enter_cavern(cavern);
                slow.enter_cavern(cavern);
            }
        }
        CHECK(ok);
    }
}

// Saving the slice at the top of the main loop and restoring it later is the
// same game as never having left: the same moves from there give the same
// outcome and the same state, even after other play in between.
TEST(save_and_restore_is_the_same_game) {
    Game g;
    boot(g);
    RandomPlayer warmup(7);
    for (int i = 0; i < 60; i++) {
        if (g.step(warmup.move(g)) != Outcome::Running) g.enter_cavern(0);
    }
    Game::Saved at;
    g.save(at);
    std::vector<Action> moves;
    std::mt19937 rng(9);
    for (int i = 0; i < 80; i++) moves.push_back(Action(rng() % ACTION_COUNT));

    auto play = [&](Game& game) {
        for (Action a : moves) {
            const Outcome o = game.step(a);
            if (o != Outcome::Running) return o;
        }
        return Outcome::Running;
    };
    const Outcome first = play(g);
    Game::Saved end_first;
    if (first == Outcome::Running) g.save(end_first);

    g.enter_cavern(3);  // somewhere else entirely
    for (int i = 0; i < 30; i++) g.step(RIGHT);
    g.restore(at);
    const Outcome second = play(g);
    CHECK(first == second);
    if (first == Outcome::Running && second == Outcome::Running) {
        Game::Saved end_second;
        g.save(end_second);
        CHECK(end_first.ram == end_second.ram);
    }
}

TEST(routes_round_trip_as_text) {
    Route r;
    r.cavern = 12;
    for (int i = 0; i < 150; i++) r.moves.push_back(Action(i % ACTION_COUNT));
    const std::string text = route_to_text(r, "found by a test\nsecond line");
    Route back;
    std::string err;
    CHECK(route_from_text(text, back, err));
    CHECK_EQ(back.cavern, 12);
    CHECK(back.moves == r.moves);
    CHECK(!route_from_text("cavern 1\nLRX\n", back, err));
    CHECK(!route_from_text("LR\n", back, err));
}

int main() {
    if (!read_file(default_rom_path(), g_rom) || !read_file(default_game_path(), g_game)) {
        std::printf("skipped: needs roms/48.rom and %s (make_game.py)\n", default_game_path().c_str());
        return 77;
    }
    return ::zxtest::run_all();
}
