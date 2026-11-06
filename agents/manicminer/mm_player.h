#pragma once
// A Manic Miner player: told when a cavern starts, then asked for a move at
// the top of every pass of the main loop. It may read anything in the game
// (Game::view(), Game::peek()); it plays only by the move it returns. The same
// shape as elite-agent's player_frame(), one call a pass instead of a frame.

#include "mm_game.h"

#include <cstdint>
#include <random>

namespace mm {

class Player {
public:
    virtual ~Player() = default;
    virtual const char* name() const = 0;
    /// A cavern has just started (Game::enter_cavern).
    virtual void start(Game& game) { (void)game; }
    /// The move for the next pass.
    virtual Action move(Game& game) = 0;
};

/// Plays a route found earlier: its moves in order, then nothing.
class RoutePlayer : public Player {
public:
    explicit RoutePlayer(const Route& r) : route_(r) {}
    const char* name() const override { return "route"; }
    void start(Game&) override { next_ = 0; }
    Action move(Game&) override { return next_ < route_.moves.size() ? route_.moves[next_++] : NONE; }

private:
    Route route_;
    size_t next_ = 0;
};

/// Random moves, each held for a while: the baseline anything else must beat.
class RandomPlayer : public Player {
public:
    explicit RandomPlayer(uint32_t seed) : rng_(seed) {}
    const char* name() const override { return "random"; }
    Action move(Game&) override {
        if (std::uniform_int_distribution<int>(0, 3)(rng_) == 0) {
            held_ = Action(std::uniform_int_distribution<int>(0, ACTION_COUNT - 1)(rng_));
        }
        return held_;
    }

private:
    std::mt19937 rng_;
    Action held_ = NONE;
};

}  // namespace mm
