#pragma once
// Manic Miner on the end of an API: the game booted past its title screen,
// parked at the top of its main loop in any cavern, and stepped one pass of
// that loop at a time with a chosen move held down.
//
// Every address here is from Richard Dymond's SkoolKit disassembly of the game
// (github.com/skoolkid/manicminer, sources/mm.skool), by its label there.
//
// One step is one pass of the main loop (LOOP, 34574): the guardians move,
// Willy moves, the items are collected, the screen is drawn. The game does
// not wait for the frame interrupt, so a pass is as long as its work takes
// (about one frame and a half on a real 48K). Nothing in the game depends on
// that timing, which is why it can run as fast as the emulator goes.

#include "spectrum.h"

#include <cstdint>
#include <string>
#include <vector>

namespace mm {

// ---- addresses (mm.skool labels) -------------------------------------------
namespace addr {
// Routines.
constexpr uint16_t BEGIN = 33792;      // where the game starts once loaded
constexpr uint16_t STARTGAME = 34436;  // a new game: the score zeroed
constexpr uint16_t NEWSHT = 34449;     // (re)start the cavern in SHEET
constexpr uint16_t LOOP = 34574;       // the top of the main loop
constexpr uint16_t MANDEAD = 35071;    // Willy died, or the air ran out
constexpr uint16_t NXSHEET = 36904;    // Willy went through the portal
constexpr uint16_t PLAYTUNE = 37596;   // the title screen's theme tune

// Every LDIR in the game (mm.skool): the cavern set-up's, the main loop's
// buffer copies and the screen effects.
constexpr uint16_t FAST_LDIRS[] = {34289, 34300, 34322, 34330, 34447, 34467, 34475,
                                   34491, 34537, 34632, 34643, 34731, 34758, 34769,
                                   35090, 35169, 35182, 35270, 35512, 37024};

// Game state.
constexpr uint16_t WILLY_Y = 32872;    // Willy's pixel y-coordinate, times 2
constexpr uint16_t FRAME = 32873;      // his animation frame, 0-3 (2 pixels each)
constexpr uint16_t DMFLAGS = 32874;    // bit 0 facing left, bit 1 moving
constexpr uint16_t AIRBORNE = 32875;   // 0 on the ground, 1 jumping, 2+ falling, 255 dead
constexpr uint16_t LOCATION = 32876;   // his top-left cell in the attribute buffer (word)
constexpr uint16_t JUMPING = 32878;    // jump animation counter
constexpr uint16_t ITEMS = 32885;      // 5 items of 5 bytes; first byte 0 collected, 255 the end
constexpr uint16_t PORTAL = 32911;     // the portal's attribute; bit 7 set when it flashes (open)
constexpr uint16_t EUGDIR = 32987;     // Eugene's direction: 0 down, 1 up (Eugene's Lair)
constexpr uint16_t EUGHGT = 32988;     // Eugene's pixel y-coordinate (the Kong Beast's too)
constexpr uint16_t AIR = 32956;        // the air bar's length in cells (36 when empty)
constexpr uint16_t CLOCK = 32957;      // the game clock; the air drops a step when it wraps
constexpr uint16_t SHEET = 33799;      // the current cavern, 0-19
constexpr uint16_t SCORE = 33829;      // 10 ASCII digits (4 overflow, then the 6 shown)
constexpr uint16_t NOMEN = 33879;      // lives left, besides the one being played
constexpr uint16_t DEMO = 33882;       // 0 when someone is playing
constexpr uint16_t MUSICFLAGS = 33884; // bit 1 set: the in-game tune is off

// The attribute buffer LOCATION points into.
constexpr uint16_t ATTR_BUFFER = 23552;
}  // namespace addr

/// All the game keeps that changes while a cavern is played, as it stands at
/// the top of the main loop: the cavern's own buffers (crumbled floors
/// included), the game status buffer, the variables and the stack. Restoring
/// this slice and the stack pointer is restoring the game -- see Game::save().
constexpr uint16_t SLICE_START = 24064;  // the empty cavern's attribute buffer
constexpr uint16_t SLICE_END = 40192;    // just above the stack (BEGIN puts it at 40190)

// ---- moves -------------------------------------------------------------------
/// What can be held down for one pass. Willy's own keys: O left, P right,
/// SPACE jump. A jump's direction is set by the move held as it starts.
enum Action : uint8_t { NONE, LEFT, RIGHT, JUMP, JUMP_LEFT, JUMP_RIGHT, ACTION_COUNT };

/// One character a move, for route files: . L R J < >
char action_char(Action a);
/// The move a route character stands for; false if it is not one.
bool action_from_char(char c, Action& a);

// ---- what a pass can end in --------------------------------------------------
enum class Outcome {
    Running,         // back at the top of the main loop
    Died,            // reached MANDEAD: a guardian, a nasty, a fall, or no air
    CavernComplete,  // reached NXSHEET: through the open portal
    Stuck,           // never came back to the loop (should not happen)
};
const char* outcome_name(Outcome o);

/// The game's state, read from its variables.
struct View {
    int cavern = 0;
    int x = 0;            // Willy's left edge in pixels, 0-255
    int y = 0;            // his top edge in pixels, 0-127
    int airborne = 0;     // AIRBORNE as it is
    bool facing_left = false;
    int air = 0;          // AIR - 36: 0 when it has run out
    int clock = 0;
    int items_total = 0;  // items this cavern has
    int items_left = 0;
    uint8_t items_mask = 0;  // bit n set: item n collected
    bool portal_open = false;
    int eugene_y = 0;     // EUGHGT: Eugene's pixel y in Eugene's Lair (cavern 4)
    bool eugene_up = false;
    int lives = 0;
    long score = 0;
};

/// A machine running Manic Miner, and the moves to drive it.
class Game {
public:
    /// The ROM (16 KB) and the game: a .sna or .z80 snapshot of it (from
    /// game-disassemblies' build_manicminer.py), or the raw bytes from 23552
    /// (from make_game.py). Leaves the game at the top of the main loop in
    /// cavern 0, with the music off. Returns "" or what went wrong.
    std::string boot(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& game,
                     const std::string& game_name);

    /// Starts `cavern` afresh, with `lives` lives in hand besides this one,
    /// and runs to the top of its first pass. Every start of a cavern is the
    /// same state, so a route found from here replays from here.
    void enter_cavern(int cavern, int lives = 2);

    /// Holds `a` down for one pass of the main loop. Ends at the top of the
    /// next pass, or where the pass died or went through the portal.
    Outcome step(Action a);

    View view();
    /// The screen as the display file has it now, 256x192, RGB, 3 bytes a
    /// pixel: the whole picture, since every pass copies it there. `flash`
    /// picks which phase FLASH attributes (the open portal) show.
    void render(std::vector<uint8_t>& rgb, bool flash = false);
    uint8_t peek(uint16_t address) { return machine_.memory.read(address); }

    /// The game state at the top of the main loop, and putting it back.
    /// Only valid between passes (after enter_cavern or a Running step).
    struct Saved {
        std::vector<uint8_t> ram;  // SLICE_START..SLICE_END
        uint16_t sp = 0;
    };
    void save(Saved& s);
    void restore(const Saved& s);

    /// Fast mode (the default): the game's LDIRs (FAST_LDIRS) are done in one
    /// go on the host rather than a byte at a time by the emulated Z80. They
    /// are seven eighths of a pass. Memory, BC, DE, HL, F and PC come out as
    /// the Z80 leaves them; only time and R do not, and the game reads
    /// neither. mm_tests checks both modes give the same game, pass by pass.
    void set_fast(bool on) { fast_ = on; }
    bool fast() const { return fast_; }

    /// Passes run since boot, for throughput figures.
    uint64_t steps() const { return steps_; }
    zx::Spectrum& machine() { return machine_; }

private:
    void run_to(uint16_t target, uint64_t max_instructions);
    /// One instruction, or a whole LDIR in fast mode. Returns the new PC.
    uint16_t advance();
    void host_ldir();
    zx::Spectrum machine_;
    std::vector<bool> ldir_at_ = std::vector<bool>(0x10000, false);
    bool fast_ = true;
    uint64_t steps_ = 0;
};

// ---- routes ------------------------------------------------------------------
/// A cavern played from its start: one move a pass.
struct Route {
    int cavern = 0;
    std::vector<Action> moves;
};
/// The text form: a line "cavern <n>", then the moves as characters, wrapped
/// at 64 a line. Lines starting with # are comments.
std::string route_to_text(const Route& r, const std::string& comment);
bool route_from_text(const std::string& text, Route& r, std::string& error);

// ---- files -------------------------------------------------------------------
bool read_file(const std::string& path, std::vector<uint8_t>& out);
/// The default ROM and game paths, and where routes go, under the project root.
std::string default_rom_path();
std::string default_game_path();
std::string default_routes_dir();

}  // namespace mm
