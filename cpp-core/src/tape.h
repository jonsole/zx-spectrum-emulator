#pragma once
// Tape loading: .tap and .tzx images turned back into the signal a real
// cassette put on the EAR line of port 0xFE bit 6.
//
// The model is a PULL, and that is the whole design. Nothing here is clocked.
// A tape is a function from time to a one-bit level, so `ear_at(hc)` resolves
// that level only when the CPU actually reads the port -- which a loader does
// a few tens of thousands of times a second, against the seven million
// half-clocks that pass in the same second. `Spectrum48K::clock()` is
// untouched, exactly as it is by the Beeper (the mirror image of this: a
// latched WRITE integrated lazily, where this is a lazily-resolved READ).
//
// Playback is a state machine over parsed blocks rather than an expanded list
// of pulses. A 48K tape is roughly 800,000 pulses, which as a vector<uint32_t>
// is over 3MB per image for no gain -- and .tzx's tone and pulse-sequence
// blocks describe repetition that a flat list would only re-expand.
//
// TAPE SAVING IS NOT IMPLEMENTED. It would attach as a `record_edge(bool mic,
// uint64_t now_hc)` fed from the port 0xFE WRITE branch in
// Spectrum48K::service_bus(), plus a decoder turning recorded edges back into
// blocks -- a second subsystem larger than this one, for something .sna
// already covers. Note that the latch-not-an-edge rule below would apply there
// too: a single OUT calls that branch five times over.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zx {

class Spectrum48K;

/// Standard-speed timings, in T-states, as the 48K ROM's LD-EDGE loop expects
/// them. .tap has no timing information at all, so these ARE the format; .tzx
/// block 0x10 means "these", and 0x11 carries its own.
constexpr uint32_t TAPE_PILOT_T = 2168;
constexpr uint32_t TAPE_PILOT_HEADER_PULSES = 8063; // ~5s, before a header
constexpr uint32_t TAPE_PILOT_DATA_PULSES = 3223;   // ~2s, before a data block
constexpr uint32_t TAPE_SYNC1_T = 667;
constexpr uint32_t TAPE_SYNC2_T = 735;
constexpr uint32_t TAPE_BIT0_T = 855;  // twice per 0 bit
constexpr uint32_t TAPE_BIT1_T = 1710; // twice per 1 bit
constexpr uint32_t TAPE_TAP_PAUSE_MS = 1000;

/// The 48K ROM's LD-BYTES, the one entry point every stock-ROM loader goes
/// through. The fast-load trap watches for it; the tape needs the address, and
/// nothing else in the machine does.
constexpr uint16_t LD_BYTES = 0x0556;

/// The EAR level with no tape playing.
///
/// HIGH, matching what Keyboard::read_port returned before tape existed. That
/// makes "no tape inserted" bit-for-bit identical to the behaviour this file
/// replaced. A real machine's idle EAR is issue-dependent and partly a
/// function of the last port write; modelling that is a separate question and
/// nothing needs it.
constexpr bool TAPE_IDLE_EAR = true;

/// Where playback is within a block.
enum class TapePhase : uint8_t { Idle, Pilot, Sync1, Sync2, Data, Pulses, Pause, End };

/// One block, with its timings already resolved -- so playback never has to
/// know whether they came from .tap's fixed constants or a .tzx block's own
/// header.
struct TapeBlock {
    /// The .tzx block ID this came from. .tap synthesises 0x10, since a .tap
    /// block IS a standard-speed data block.
    uint8_t id = 0x10;
    /// Flag byte + payload + checksum, verbatim, as the ROM would read them.
    std::vector<uint8_t> data;

    uint32_t pilot_t = TAPE_PILOT_T;
    uint32_t pilot_pulses = TAPE_PILOT_HEADER_PULSES;
    uint32_t sync1_t = TAPE_SYNC1_T;
    uint32_t sync2_t = TAPE_SYNC2_T;
    uint32_t bit0_t = TAPE_BIT0_T;
    uint32_t bit1_t = TAPE_BIT1_T;
    /// Bits used from the LAST data byte. .tzx 0x11/0x14 can end mid-byte.
    uint8_t last_byte_bits = 8;
    uint32_t pause_ms = TAPE_TAP_PAUSE_MS;

    /// True when this block is bit-for-bit what the ROM's LD-BYTES expects, so
    /// the fast-load trap may satisfy it instantly. Decided at PARSE time so
    /// the trap is a single bool test rather than a timing comparison in the
    /// middle of the instruction loop.
    bool standard_speed = true;

    /// Explicit pulse lengths in T-states, for the blocks that are pure signal
    /// with no data at all (.tzx 0x12 pure tone, 0x13 pulse sequence).
    std::vector<uint32_t> pulses;

    /// Stop the motor once this block has played (.tzx 0x20 with a zero pause,
    /// and 0x2A, which means "stop if this is a 48K" -- and it always is).
    /// Playback resumes from the FOLLOWING block, which is the point: it is
    /// how a multi-load tape waits for the game to ask for the next level.
    bool stop_tape = false;

    /// How long this block takes to play, half-clocks, pause included.
    /// Precomputed because it is only wanted for progress reporting and
    /// walking the bits to find out would be absurd.
    uint64_t duration_hc = 0;
};

/// One row of what a tape contains, for a viewer.
///
/// Fixed at PARSE time -- nothing here changes as the tape plays, which is
/// what lets the Engine cache the list rather than rebuild it at every yield
/// the way it does the position readout.
struct TapeBlockInfo {
    /// The .tzx block ID, as on TapeBlock. .tap synthesises 0x10 throughout.
    uint8_t id = 0x10;
    /// What this block IS, in the words a person would use: "Header", "Data",
    /// "Pure tone", "Pause". Not a format term -- the ID is there for that.
    std::string kind;
    /// The 10-character filename out of a standard header, when there is one.
    /// A data block inherits the name of the header in front of it, which is
    /// the whole point: it is the only thing that makes a multi-load tape
    /// readable as a list.
    std::string name;
    size_t data_bytes = 0;
    uint64_t duration_ms = 0;
    /// False for anything the fast-load trap will decline -- the answer to
    /// "why is this one loading at real speed".
    bool standard_speed = true;
    bool stop_tape = false;
    uint32_t pause_ms = 0;
};

/// What the tape is doing, for reporting back over MCP/DAP.
struct TapeStatus {
    bool inserted = false;
    bool playing = false;
    bool at_end = false;
    bool fast_load = true;
    std::string name;
    /// Text from .tzx description/archive-info blocks, when the image has any.
    std::string description;
    size_t block = 0;
    size_t blocks = 0;
    uint64_t position_ms = 0;
    uint64_t total_ms = 0;
    /// Blocks that were parsed but are not played (metadata, flow control).
    std::vector<std::string> warnings;
};

class Tape {
public:
    /// Parses `data` as .tap or .tzx -- decided by the contents, not the file
    /// name. Returns "" on success, else why it could not be understood.
    /// Leaves any previously inserted tape in place if it fails.
    std::string insert(const uint8_t* data, size_t len, const std::string& name);
    void eject();
    bool inserted() const { return !blocks_.empty(); }

    /// Starts playing from the current block. `now_hc` becomes the origin the
    /// first pulse is measured from.
    void play(uint64_t now_hc);
    /// Stops the motor, keeping the block position -- so play() resumes from
    /// the same block rather than rewinding.
    void stop();
    void rewind();
    /// Positions the tape at block `index`, clamped to the end, with the motor
    /// stopped -- so a following play() starts that block from its leader. The
    /// point is replaying one part of a multi-load tape without rewinding
    /// through the ones in front of it.
    void seek(size_t index);
    bool playing() const { return playing_; }
    bool at_end() const { return at_end_; }

    /// The EAR level (port 0xFE bit 6) at half-clock `hc`.
    ///
    /// A PURE PULL, and it has to be. Control lines are not auto-cleared, so
    /// service_bus() sees one IN assert IORQ/RD on five consecutive
    /// half-clocks and calls this five times over, all with the same `hc`.
    /// The cursor only ever moves FORWARD, and only past pulses that have
    /// genuinely elapsed, so repeated calls at one instant give the same
    /// answer -- the same idempotence Beeper::write_port_fe gets by being a
    /// latch rather than an edge count.
    ///
    /// Not const, and not const with a mutable cursor either: the cursor
    /// movement is the one thing a reader of this class has to know about.
    bool ear_at(uint64_t hc);

    /// The same walk with the level discarded. The run loop calls this at its
    /// yields so the cursor keeps up while nothing is reading the port --
    /// otherwise the first IN after a long silent run has to skip the whole
    /// tape in a single call.
    void advance_to(uint64_t hc);

    void set_fast_load(bool on) { fast_load_ = on; }
    bool fast_load() const { return fast_load_; }

    /// The next block IFF it is a whole, unstarted, standard-speed block the
    /// fast-load trap may satisfy instantly. Null when the tape is stopped, at
    /// the end, part-way through a block, or the next block is a turbo/tone/
    /// pure-data one -- in which case the caller must fall back to letting the
    /// real ROM loader run against real pulses.
    const TapeBlock* peek_standard_block() const;

    /// Consumes the block peek_standard_block() returned, re-originating
    /// playback at `now_hc` plus that block's pause -- so a NON-standard block
    /// following a fast-loaded one still starts its pulses at the right
    /// instant.
    void consume_block(uint64_t now_hc);

    TapeStatus status(uint64_t now_hc) const;

    /// What is on the tape, one entry per playable block. Built once by
    /// insert(), so this is a read of a stored vector rather than a walk.
    const std::vector<TapeBlockInfo>& block_infos() const { return infos_; }

    /// Bumped by every insert() and eject(). A cache of block_infos() only has
    /// to be rebuilt when this changes, which is what keeps the Engine's
    /// per-yield tape service from copying the whole list 1700 times a second.
    uint64_t generation() const { return generation_; }

private:
    std::vector<TapeBlock> blocks_;
    std::vector<TapeBlockInfo> infos_;
    uint64_t generation_ = 0;
    std::string name_;
    std::string description_;
    std::vector<std::string> warnings_;
    bool fast_load_ = true;
    bool playing_ = false;
    bool at_end_ = false;

    // ---- playback cursor ----
    size_t block_ = 0;
    TapePhase phase_ = TapePhase::Idle;
    size_t byte_ = 0;
    uint8_t bit_ = 0;
    /// Each data bit is TWO pulses of equal length; this is the second one.
    bool second_half_ = false;
    /// Pilot pulses, or entries in TapeBlock::pulses, still to play.
    uint32_t pulses_left_ = 0;
    bool level_ = false;
    /// Start of the pulse currently in flight, and its length. Both in
    /// half-clocks, converted from the format's T-states on the way in.
    uint64_t pulse_start_hc_ = 0;
    uint64_t pulse_hc_ = 0;
    /// When the current block started playing, for the position readout.
    uint64_t block_start_hc_ = 0;
    uint64_t total_hc_ = 0;

    std::string parse_tap(const uint8_t* data, size_t len);
    std::string parse_tzx(const uint8_t* data, size_t len);
    /// Fills infos_ from blocks_, once the durations are known.
    void describe_blocks();
    /// Positions the cursor at the start of block `block_` and returns false
    /// if there is no such block.
    bool start_block();
    /// Ends the pulse in flight and sets up the next one. False at end of tape.
    bool advance();
};

/// Resets `m`, waits for the ROM to reach the BASIC edit loop, and types
/// LOAD "" followed by ENTER on the real keyboard matrix. Returns "" on
/// success, else why it could not.
///
/// Keys rather than poking the ROM's edit buffer: committing a line the
/// editor's own way is a lot of system-variable state (E_PPC, WORKSP, STKEND)
/// and getting one of them wrong fails silently, in a way that looks exactly
/// like a tape bug. Typing goes through the ROM's own interrupt-driven key
/// scan, so if it works at all it works the way a human's keypress does.
///
/// Runs whole FRAMES rather than instructions, because that scan is driven by
/// the 50Hz interrupt and its debounce needs a key held stable across
/// consecutive scans -- frames are the only unit in which the timing means
/// anything.
///
/// Starts the motor itself, if a tape is inserted, just before it commits the
/// line -- see the comment at that point for why the order matters.
std::string type_load_command(Spectrum48K& m);

} // namespace zx
