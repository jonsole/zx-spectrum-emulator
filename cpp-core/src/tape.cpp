#include "tape.h"

#include "spectrum.h"

#include <cstdio>

namespace zx {
namespace {

/// The format speaks T-states; the machine's clock is half-T-states.
uint64_t t_to_hc(uint32_t t) { return uint64_t(t) * HC_PER_TSTATE; }
uint64_t ms_to_hc(uint32_t ms) { return uint64_t(ms) * (HC_PER_SEC / 1000); }

/// The lead-out edge every block gets before its pause proper. See advance().
constexpr uint32_t TAPE_EDGE_PAUSE_MS = 1;

/// Enough to tell the user what a tape contains without letting a hostile or
/// simply strange file grow the status response without bound.
constexpr size_t MAX_WARNINGS = 16;

/// A ceiling on the block list after .tzx loops have been expanded. A real
/// image is a few hundred blocks; this is only here so a file claiming a
/// 65535-times loop around a large body cannot ask for gigabytes.
constexpr size_t MAX_BLOCKS = 65536;

std::string hex_byte(uint8_t v) {
    char buf[8];
    std::snprintf(buf, sizeof(buf), "0x%02X", unsigned(v));
    return buf;
}

/// A bounds-checked read cursor. Every .tzx block body is a run of fixed-width
/// little-endian fields, and a file that lies about one of its lengths must
/// produce an error rather than a read off the end -- so nothing here reads
/// without asking first.
class Reader {
public:
    Reader(const uint8_t* data, size_t len) : data_(data), len_(len) {}

    size_t pos() const { return pos_; }
    bool done() const { return pos_ >= len_; }
    size_t left() const { return len_ - pos_; }

    bool u8(uint8_t& out) {
        if (left() < 1) {
            return false;
        }
        out = data_[pos_++];
        return true;
    }
    bool u16(uint32_t& out) {
        if (left() < 2) {
            return false;
        }
        out = uint32_t(data_[pos_]) | (uint32_t(data_[pos_ + 1]) << 8);
        pos_ += 2;
        return true;
    }
    bool u24(uint32_t& out) {
        if (left() < 3) {
            return false;
        }
        out = uint32_t(data_[pos_]) | (uint32_t(data_[pos_ + 1]) << 8)
              | (uint32_t(data_[pos_ + 2]) << 16);
        pos_ += 3;
        return true;
    }
    bool u32(uint32_t& out) {
        if (left() < 4) {
            return false;
        }
        out = uint32_t(data_[pos_]) | (uint32_t(data_[pos_ + 1]) << 8)
              | (uint32_t(data_[pos_ + 2]) << 16) | (uint32_t(data_[pos_ + 3]) << 24);
        pos_ += 4;
        return true;
    }
    bool bytes(size_t n, std::vector<uint8_t>& out) {
        if (left() < n) {
            return false;
        }
        out.assign(data_ + pos_, data_ + pos_ + n);
        pos_ += n;
        return true;
    }
    bool skip(size_t n) {
        if (left() < n) {
            return false;
        }
        pos_ += n;
        return true;
    }
    /// True when every remaining byte is zero -- i.e. what is left is padding
    /// rather than data.
    bool rest_is_zero() const {
        for (size_t i = pos_; i < len_; i++) {
            if (data_[i] != 0) {
                return false;
            }
        }
        return true;
    }
    bool text(size_t n, std::string& out) {
        if (left() < n) {
            return false;
        }
        out.assign(reinterpret_cast<const char*>(data_ + pos_), n);
        pos_ += n;
        return true;
    }

private:
    const uint8_t* data_;
    size_t len_;
    size_t pos_ = 0;
};

uint64_t block_duration_hc(const TapeBlock& b) {
    uint64_t hc = 0;
    for (uint32_t p : b.pulses) {
        hc += t_to_hc(p);
    }
    if (b.pilot_pulses > 0) {
        hc += uint64_t(b.pilot_pulses) * t_to_hc(b.pilot_t);
        hc += t_to_hc(b.sync1_t) + t_to_hc(b.sync2_t);
    }
    for (size_t i = 0; i < b.data.size(); i++) {
        const uint8_t bits = (i + 1 == b.data.size()) ? b.last_byte_bits : 8;
        for (uint8_t k = 0; k < bits; k++) {
            const bool one = (b.data[i] & (0x80u >> k)) != 0;
            // Two pulses per bit.
            hc += 2 * t_to_hc(one ? b.bit1_t : b.bit0_t);
        }
    }
    if (b.pause_ms > 0) {
        hc += ms_to_hc(b.pause_ms);
    }
    return hc;
}

/// A standard header block, byte for byte: flag 0x00, type, a ten-character
/// filename, three 16-bit parameters and a checksum. Nineteen bytes exactly,
/// and anything else of that length with a zero flag would have to be a
/// deliberate forgery -- so the length and the flag together are the test.
constexpr size_t TAPE_HEADER_LEN = 19;

bool is_header(const TapeBlock& b) {
    return b.data.size() == TAPE_HEADER_LEN && b.data[0] == 0x00;
}

/// What a header says it is describing. The four types are the ones SAVE can
/// produce; a file with a fifth is malformed, and says so rather than being
/// silently reported as a Program.
std::string header_kind(uint8_t type) {
    if (type == 0) {
        return "Program";
    }
    if (type == 1) {
        return "Number array";
    }
    if (type == 2) {
        return "Character array";
    }
    if (type == 3) {
        return "Bytes";
    }
    return "Header (type " + std::to_string(unsigned(type)) + ")";
}

/// The ten filename characters, trailing spaces trimmed.
///
/// Filtered to printable ASCII because the field is fixed-width and NOT
/// required to hold text: a header saved by a machine-code loader routinely
/// carries whatever happened to be in memory, and the ZX character set puts
/// BASIC keywords above 0xA5, which would come out as mojibake in a JSON
/// string. A '?' per unprintable byte keeps the row's shape honest.
std::string header_name(const std::vector<uint8_t>& data) {
    std::string name;
    for (size_t i = 2; i < 12; i++) {
        const uint8_t c = data[i];
        name.push_back(c >= 0x20 && c < 0x7F ? char(c) : '?');
    }
    while (!name.empty() && name.back() == ' ') {
        name.pop_back();
    }
    return name;
}

constexpr uint32_t BOOT_FRAMES = 100; // ~2s: the RAM test and the (c) screen
constexpr uint32_t HOLD_FRAMES = 4;   // the ROM's debounce wants ~2 stable scans
constexpr uint32_t GAP_FRAMES = 4;    // and as long again to see the release
constexpr uint16_t SYSVAR_E_LINE = 0x5C59;

void run_frames(Spectrum48K& m, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        m.run_frame();
    }
}

/// The same, but instruction by instruction.
///
/// The distinction is not cosmetic. run_frame() drives clock() directly and so
/// never passes through step_instruction(), which is where the fast-load trap
/// lives -- and the interpreter reaches LD-BYTES within a frame or two of the
/// ENTER that commits the line. Running those particular frames the cheap way
/// hands the machine back from INSIDE LD-BYTES, by which point the trap has
/// missed its one chance and a block that could have been instant gets
/// pulse-loaded instead.
void step_frames(Spectrum48K& m, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        const uint64_t until = m.global_hc() + HC_PER_FRAME;
        while (m.global_hc() < until) {
            m.step_instruction();
        }
    }
}

/// Holds `key` (with `shift`, or null for none) long enough for the ROM's
/// interrupt-driven scan to see it, then releases it and waits again.
void press(Spectrum48K& m, const char* key, const char* shift) {
    if (shift != nullptr) {
        m.keyboard.key_down(shift);
    }
    m.keyboard.key_down(key);
    run_frames(m, HOLD_FRAMES);
    m.keyboard.key_up(key);
    if (shift != nullptr) {
        m.keyboard.key_up(shift);
    }
    run_frames(m, GAP_FRAMES);
}

} // namespace

// ---- parsing ---------------------------------------------------------------

std::string Tape::insert(const uint8_t* data, size_t len, const std::string& name) {
    if (data == nullptr || len == 0) {
        return "empty tape image";
    }

    // By contents, not by file name: people rename these constantly, and a
    // .tzx signature is eight unambiguous bytes.
    const bool is_tzx = len >= 10 && std::string(reinterpret_cast<const char*>(data), 7) == "ZXTape!"
                        && data[7] == 0x1A;

    // Parsed into locals first: a tape that fails to parse must leave whatever
    // was already loaded alone rather than half-replacing it.
    std::vector<TapeBlock> blocks;
    std::string description;
    std::vector<std::string> warnings;
    blocks_.swap(blocks);
    description_.swap(description);
    warnings_.swap(warnings);

    const std::string error = is_tzx ? parse_tzx(data, len) : parse_tap(data, len);
    if (!error.empty()) {
        blocks_.swap(blocks);
        description_.swap(description);
        warnings_.swap(warnings);
        return error;
    }

    name_ = name;
    total_hc_ = 0;
    for (TapeBlock& b : blocks_) {
        b.duration_hc = block_duration_hc(b);
        total_hc_ += b.duration_hc;
    }
    describe_blocks();
    generation_++;
    rewind();
    return {};
}

void Tape::describe_blocks() {
    infos_.clear();
    infos_.reserve(blocks_.size());
    // Carried forward from the last header seen, because a header names the
    // block AFTER it -- "Bytes: MMCODE" is two blocks saying one thing, and a
    // list that shows only the header's name leaves the big block anonymous.
    std::string pending_name;
    for (const TapeBlock& b : blocks_) {
        TapeBlockInfo info;
        info.id = b.id;
        info.data_bytes = b.data.size();
        info.duration_ms = b.duration_hc / (HC_PER_SEC / 1000);
        info.standard_speed = b.standard_speed;
        info.stop_tape = b.stop_tape;
        info.pause_ms = b.pause_ms;

        if (is_header(b)) {
            info.kind = header_kind(b.data[1]);
            info.name = header_name(b.data);
            pending_name = info.name;
        } else if (!b.data.empty()) {
            info.kind = "Data";
            info.name = pending_name;
            pending_name.clear();
        } else if (!b.pulses.empty()) {
            info.kind = b.id == 0x12 ? "Pure tone" : "Pulses";
        } else if (b.stop_tape) {
            info.kind = "Stop the tape";
        } else {
            info.kind = "Pause";
        }
        infos_.push_back(std::move(info));
    }
}

std::string Tape::parse_tap(const uint8_t* data, size_t len) {
    auto warn = [this](const std::string& what) {
        if (warnings_.size() < MAX_WARNINGS) {
            warnings_.push_back(what);
        }
    };
    Reader r(data, len);
    while (!r.done()) {
        const size_t at = r.pos();
        uint32_t block_len = 0;
        if (!r.u16(block_len)) {
            return "truncated .tap: a block length is cut short at offset "
                   + std::to_string(at);
        }
        if (block_len == 0) {
            // Zero padding at the end of the image. Real tapes are routinely
            // padded out to a boundary -- hundreds of zero bytes is normal --
            // so the test is "is everything left zero", not "is this the very
            // last byte of the file". A zero length with real data after it is
            // a genuinely broken block and still an error.
            if (r.rest_is_zero()) {
                break;
            }
            return "empty .tap block at offset " + std::to_string(at);
        }
        if (block_len > r.left()) {
            // A final block that runs off the end. Tolerated once something
            // has already been parsed: an image truncated in transit still
            // loads everything up to the cut, which is far more use than
            // refusing the lot.
            if (!blocks_.empty()) {
                warn("the block at offset " + std::to_string(at) + " runs past the end of the "
                     + "file and was dropped");
                break;
            }
            return "truncated .tap: the block at offset " + std::to_string(at) + " claims "
                   + std::to_string(block_len) + " bytes but only " + std::to_string(r.left())
                   + " remain";
        }
        if (block_len < 2) {
            if (!blocks_.empty()) {
                warn("the block at offset " + std::to_string(at) + " is too short to load and "
                     + "was dropped");
                r.skip(block_len);
                continue;
            }
            return "the .tap block at offset " + std::to_string(at)
                   + " is too short to hold a flag byte and a checksum";
        }
        TapeBlock b;
        if (!r.bytes(block_len, b.data)) {
            return "truncated .tap at offset " + std::to_string(at);
        }
        // A header gets the long ~5s leader, a data block the short ~2s one.
        // The flag byte is the only thing distinguishing them.
        b.pilot_pulses = (b.data[0] & 0x80) != 0 ? TAPE_PILOT_DATA_PULSES
                                                 : TAPE_PILOT_HEADER_PULSES;
        blocks_.push_back(std::move(b));
    }
    if (blocks_.empty()) {
        return "no blocks in .tap image";
    }
    return {};
}

std::string Tape::parse_tzx(const uint8_t* data, size_t len) {
    Reader r(data, len);
    if (!r.skip(8)) {
        return "truncated .tzx header";
    }
    uint8_t major = 0;
    uint8_t minor = 0;
    if (!r.u8(major) || !r.u8(minor)) {
        return "truncated .tzx header";
    }
    if (major != 1) {
        return "unsupported .tzx major version " + std::to_string(major) + "."
               + std::to_string(minor) + " (only version 1.x is understood)";
    }

    auto warn = [this](const std::string& what) {
        if (warnings_.size() < MAX_WARNINGS) {
            warnings_.push_back(what);
        }
    };

    // .tzx loops (0x24/0x25) are EXPANDED here rather than executed at play
    // time: a loop only ever repeats the blocks between its two markers, so
    // duplicating them at parse time keeps playback -- and the block list a
    // viewer shows -- free of any notion of flow control, and keeps every
    // block's duration a fixed number the totals can be summed from.
    //
    // Not cosmetic. Speedlock and the loaders descended from it build their
    // multi-second leaders as a short tone/pulse pair looped a few dozen
    // times; skipping the loop leaves a leader a thirtieth of its real length,
    // which is far too short for such a loader to lock on to. That is the
    // whole reason Underwurlde and its siblings would not load.
    size_t loop_first = 0;   // index into blocks_ where the loop body started
    uint32_t loop_count = 0; // repetitions still to apply; 0 when outside a loop

    while (!r.done()) {
        const size_t at = r.pos();
        uint8_t id = 0;
        r.u8(id);
        const std::string where =
            " (block " + hex_byte(id) + " at offset " + std::to_string(at) + ")";
        auto truncated = [&where]() { return "truncated .tzx" + where; };

        if (id == 0x10) { // standard speed data
            TapeBlock b;
            uint32_t pause = 0;
            uint32_t block_len = 0;
            if (!r.u16(pause) || !r.u16(block_len) || !r.bytes(block_len, b.data)) {
                return truncated();
            }
            if (b.data.empty()) {
                return "empty standard-speed block" + where;
            }
            b.id = id;
            b.pause_ms = pause;
            b.pilot_pulses = (b.data[0] & 0x80) != 0 ? TAPE_PILOT_DATA_PULSES
                                                     : TAPE_PILOT_HEADER_PULSES;
            blocks_.push_back(std::move(b));

        } else if (id == 0x11) { // turbo speed data
            TapeBlock b;
            uint32_t pilot = 0;
            uint32_t sync1 = 0;
            uint32_t sync2 = 0;
            uint32_t zero = 0;
            uint32_t one = 0;
            uint32_t pilot_count = 0;
            uint8_t used_bits = 0;
            uint32_t pause = 0;
            uint32_t block_len = 0;
            if (!r.u16(pilot) || !r.u16(sync1) || !r.u16(sync2) || !r.u16(zero) || !r.u16(one)
                || !r.u16(pilot_count) || !r.u8(used_bits) || !r.u16(pause) || !r.u24(block_len)
                || !r.bytes(block_len, b.data)) {
                return truncated();
            }
            if (used_bits < 1 || used_bits > 8) {
                return "turbo block claims " + std::to_string(used_bits)
                       + " used bits in its last byte" + where;
            }
            b.id = id;
            b.pilot_t = pilot;
            b.pilot_pulses = pilot_count;
            b.sync1_t = sync1;
            b.sync2_t = sync2;
            b.bit0_t = zero;
            b.bit1_t = one;
            b.last_byte_bits = used_bits;
            b.pause_ms = pause;
            // A turbo block that happens to carry exactly the ROM's timings is
            // a standard block wearing a different hat, and plenty of images
            // are built that way. Checking is six comparisons and buys those
            // tapes the fast path.
            b.standard_speed = b.pilot_t == TAPE_PILOT_T && b.sync1_t == TAPE_SYNC1_T
                               && b.sync2_t == TAPE_SYNC2_T && b.bit0_t == TAPE_BIT0_T
                               && b.bit1_t == TAPE_BIT1_T && b.last_byte_bits == 8;
            blocks_.push_back(std::move(b));

        } else if (id == 0x12) { // pure tone
            uint32_t pulse = 0;
            uint32_t count = 0;
            if (!r.u16(pulse) || !r.u16(count)) {
                return truncated();
            }
            TapeBlock b;
            b.id = id;
            b.standard_speed = false;
            b.pilot_pulses = 0;
            b.pause_ms = 0;
            b.pulses.assign(count, pulse);
            blocks_.push_back(std::move(b));

        } else if (id == 0x13) { // pulse sequence
            uint8_t count = 0;
            if (!r.u8(count)) {
                return truncated();
            }
            TapeBlock b;
            b.id = id;
            b.standard_speed = false;
            b.pilot_pulses = 0;
            b.pause_ms = 0;
            for (uint8_t i = 0; i < count; i++) {
                uint32_t pulse = 0;
                if (!r.u16(pulse)) {
                    return truncated();
                }
                b.pulses.push_back(pulse);
            }
            blocks_.push_back(std::move(b));

        } else if (id == 0x14) { // pure data, no pilot or sync at all
            TapeBlock b;
            uint32_t zero = 0;
            uint32_t one = 0;
            uint8_t used_bits = 0;
            uint32_t pause = 0;
            uint32_t block_len = 0;
            if (!r.u16(zero) || !r.u16(one) || !r.u8(used_bits) || !r.u16(pause)
                || !r.u24(block_len) || !r.bytes(block_len, b.data)) {
                return truncated();
            }
            if (used_bits < 1 || used_bits > 8) {
                return "pure-data block claims " + std::to_string(used_bits)
                       + " used bits in its last byte" + where;
            }
            b.id = id;
            b.bit0_t = zero;
            b.bit1_t = one;
            b.last_byte_bits = used_bits;
            b.pause_ms = pause;
            b.pilot_pulses = 0; // no leader: whatever precedes it IS the leader
            b.standard_speed = false;
            blocks_.push_back(std::move(b));

        } else if (id == 0x20) { // pause, or stop the tape when zero
            uint32_t pause = 0;
            if (!r.u16(pause)) {
                return truncated();
            }
            TapeBlock b;
            b.id = id;
            b.standard_speed = false;
            b.pilot_pulses = 0;
            b.pause_ms = pause;
            b.stop_tape = pause == 0;
            blocks_.push_back(std::move(b));

        } else if (id == 0x2A) { // stop the tape if 48K -- and we always are
            uint32_t body = 0;
            if (!r.u32(body) || !r.skip(body)) {
                return truncated();
            }
            TapeBlock b;
            b.id = id;
            b.standard_speed = false;
            b.pilot_pulses = 0;
            b.pause_ms = 0;
            b.stop_tape = true;
            blocks_.push_back(std::move(b));

        } else if (id == 0x2B) { // set signal level
            uint32_t body = 0;
            if (!r.u32(body) || !r.skip(body)) {
                return truncated();
            }
            // Ignored rather than honoured: the level between blocks only
            // matters to a loader that is already mid-read, and every block
            // here starts by toggling anyway.
            warn("signal-level block" + where + " ignored");

        } else if (id == 0x15 || id == 0x16 || id == 0x17 || id == 0x18 || id == 0x19) {
            // These carry sampled or generalised signal data rather than
            // pulses. Rejected by name rather than skipped: their bodies are
            // the only thing that would tell us how long they are, so guessing
            // would desync every block after them and produce garbage that
            // looks like a tape that merely does not load.
            return "unsupported .tzx block " + hex_byte(id) + " at offset " + std::to_string(at)
                   + (id == 0x15 ? " (direct recording)"
                                 : id == 0x18 ? " (CSW recording)"
                                              : id == 0x19 ? " (generalized data)" : "");

        } else if (id == 0x21) { // group start
            uint8_t n = 0;
            if (!r.u8(n) || !r.skip(n)) {
                return truncated();
            }
        } else if (id == 0x22 || id == 0x27) { // group end, return
            // Bodyless.
        } else if (id == 0x24) { // loop start
            uint32_t count = 0;
            if (!r.u16(count)) {
                return truncated();
            }
            if (loop_count != 0) {
                // .tzx does not nest loops, and honouring the inner one would
                // silently drop the outer body's repetitions.
                warn("nested loop start" + where + " is ignored");
            } else {
                loop_first = blocks_.size();
                loop_count = count > 0 ? count : 1;
            }
        } else if (id == 0x25) { // loop end
            if (loop_count == 0) {
                warn("loop end" + where + " has no matching loop start");
            } else {
                const size_t body = blocks_.size() - loop_first;
                if (body > 0 && loop_count > 1) {
                    if (body * loop_count > MAX_BLOCKS) {
                        return "the loop ending" + where + " would expand to "
                               + std::to_string(body * loop_count) + " blocks";
                    }
                    // Copied out first: pushing into blocks_ from blocks_ walks
                    // off a reallocated buffer.
                    const std::vector<TapeBlock> once(blocks_.begin() + loop_first,
                                                      blocks_.end());
                    blocks_.reserve(loop_first + body * loop_count);
                    for (uint32_t rep = 1; rep < loop_count; rep++) {
                        blocks_.insert(blocks_.end(), once.begin(), once.end());
                    }
                }
                loop_count = 0;
            }
        } else if (id == 0x23) { // jump
            if (!r.skip(2)) {
                return truncated();
            }
            warn("flow-control block" + where + " is skipped, not executed");
        } else if (id == 0x26) { // call sequence
            uint32_t count = 0;
            if (!r.u16(count) || !r.skip(size_t(count) * 2)) {
                return truncated();
            }
            warn("flow-control block" + where + " is skipped, not executed");
        } else if (id == 0x28) { // select block
            uint32_t n = 0;
            if (!r.u16(n) || !r.skip(n)) {
                return truncated();
            }
            warn("select block" + where + " is skipped: the first option is assumed");
        } else if (id == 0x30) { // text description
            uint8_t n = 0;
            std::string text;
            if (!r.u8(n) || !r.text(n, text)) {
                return truncated();
            }
            if (description_.empty()) {
                description_ = text;
            }
        } else if (id == 0x31) { // message
            uint8_t n = 0;
            if (!r.skip(1) || !r.u8(n) || !r.skip(n)) {
                return truncated();
            }
        } else if (id == 0x32) { // archive info
            uint32_t n = 0;
            if (!r.u16(n)) {
                return truncated();
            }
            // The body is a count byte then (id, length, text) triples; the
            // one with id 0 is the full title. Worth pulling out, since it is
            // what makes a status response say "Manic Miner" rather than
            // "block 3 of 11".
            const size_t end = r.pos() + n;
            uint8_t count = 0;
            if (n < 1 || !r.u8(count) || end > len) {
                return truncated();
            }
            for (uint8_t i = 0; i < count && r.pos() < end; i++) {
                uint8_t text_id = 0;
                uint8_t text_len = 0;
                std::string text;
                if (!r.u8(text_id) || !r.u8(text_len) || !r.text(text_len, text)) {
                    return truncated();
                }
                if (text_id == 0 && description_.empty()) {
                    description_ = text;
                }
            }
            if (r.pos() > end || !r.skip(end - r.pos())) {
                return truncated();
            }
        } else if (id == 0x33) { // hardware type
            uint8_t count = 0;
            if (!r.u8(count) || !r.skip(size_t(count) * 3)) {
                return truncated();
            }
        } else if (id == 0x35) { // custom info
            uint32_t n = 0;
            if (!r.skip(16) || !r.u32(n) || !r.skip(n)) {
                return truncated();
            }
        } else if (id == 0x5A) { // glue block, for concatenated tapes
            if (!r.skip(9)) {
                return truncated();
            }
        } else if (id == 0x00 && r.rest_is_zero()) {
            // Zero padding at the end of the image, same as .tap gets. There
            // is no block 0x00, so a run of zeros to EOF is padding and not
            // something to refuse the whole tape over.
            break;
        } else {
            // Same reasoning as 0x15 above: an unknown ID has an unknown
            // length, so continuing would be guessing.
            return "unknown .tzx block " + hex_byte(id) + " at offset " + std::to_string(at);
        }
    }

    if (loop_count != 0) {
        warn("a loop start is never closed; its body plays once");
    }
    if (blocks_.empty()) {
        return "no playable blocks in .tzx image";
    }
    return {};
}

// ---- transport -------------------------------------------------------------

void Tape::eject() {
    blocks_.clear();
    infos_.clear();
    generation_++;
    name_.clear();
    description_.clear();
    warnings_.clear();
    total_hc_ = 0;
    rewind();
}

void Tape::rewind() { seek(0); }

void Tape::seek(size_t index) {
    // Clamped rather than rejected: "past the end" is exactly where the cursor
    // sits after the last block has played, so it is a position the tape can
    // legitimately be in, not a caller error.
    block_ = index < blocks_.size() ? index : blocks_.size();
    phase_ = TapePhase::Idle;
    byte_ = 0;
    bit_ = 0;
    second_half_ = false;
    pulses_left_ = 0;
    level_ = false;
    playing_ = false;
    // Seeking past the last block IS the end of the tape, and reporting
    // anything else would leave a viewer showing a position it cannot play
    // from. An empty deck is not "at the end", it is simply empty -- which is
    // what rewind() on no tape has always reported.
    at_end_ = !blocks_.empty() && block_ >= blocks_.size();
    pulse_start_hc_ = 0;
    pulse_hc_ = 0;
    block_start_hc_ = 0;
}

void Tape::play(uint64_t now_hc) {
    if (block_ >= blocks_.size()) {
        return;
    }
    playing_ = true;
    at_end_ = false;
    // Whatever pulse was in flight when the motor stopped is abandoned rather
    // than resumed. That is what a real deck does, and the loader is looking
    // for edges, not for one particular pulse.
    pulse_start_hc_ = now_hc;
    pulse_hc_ = 0; // so the first ear_at() picks a pulse immediately
    // Starting HIGH means the first pulse comes out low, the usual convention.
    // Only the edges matter to a loader, but being consistent keeps the .tap
    // and .tzx paths byte-identical for the same content.
    level_ = true;
    if (phase_ == TapePhase::Idle) {
        block_start_hc_ = now_hc;
    }
}

void Tape::stop() { playing_ = false; }

bool Tape::start_block() {
    if (block_ >= blocks_.size()) {
        return false;
    }
    const TapeBlock& b = blocks_[block_];
    byte_ = 0;
    bit_ = 0;
    second_half_ = false;
    pulses_left_ = 0;
    if (!b.pulses.empty()) {
        phase_ = TapePhase::Pulses;
        pulses_left_ = uint32_t(b.pulses.size());
    } else if (b.pilot_pulses > 0) {
        phase_ = TapePhase::Pilot;
        pulses_left_ = b.pilot_pulses;
    } else if (!b.data.empty()) {
        phase_ = TapePhase::Data; // a pure-data block has no leader of its own
    } else {
        phase_ = TapePhase::Pause;
    }
    return true;
}

bool Tape::advance() {
    for (;;) {
        if (phase_ == TapePhase::Idle) {
            if (!start_block()) {
                return false;
            }
            continue;
        }

        const TapeBlock& b = blocks_[block_];

        if (phase_ == TapePhase::Pulses) {
            if (pulses_left_ > 0) {
                const size_t i = b.pulses.size() - pulses_left_;
                pulses_left_--;
                level_ = !level_;
                pulse_hc_ = t_to_hc(b.pulses[i]);
                return true;
            }
            phase_ = TapePhase::Pause;
            continue;
        }

        if (phase_ == TapePhase::Pilot) {
            if (pulses_left_ > 0) {
                pulses_left_--;
                level_ = !level_;
                pulse_hc_ = t_to_hc(b.pilot_t);
                return true;
            }
            phase_ = TapePhase::Sync1;
            continue;
        }

        if (phase_ == TapePhase::Sync1) {
            phase_ = TapePhase::Sync2;
            level_ = !level_;
            pulse_hc_ = t_to_hc(b.sync1_t);
            return true;
        }

        if (phase_ == TapePhase::Sync2) {
            phase_ = b.data.empty() ? TapePhase::Pause : TapePhase::Data;
            level_ = !level_;
            pulse_hc_ = t_to_hc(b.sync2_t);
            return true;
        }

        if (phase_ == TapePhase::Data) {
            if (byte_ < b.data.size()) {
                const uint8_t bits = (byte_ + 1 == b.data.size()) ? b.last_byte_bits : 8;
                if (bit_ < bits) {
                    // MSB first, and each bit is TWO pulses of equal length --
                    // which is what makes the encoding self-clocking: the
                    // loader times the gap between edges, not a level.
                    const bool one = (b.data[byte_] & (0x80u >> bit_)) != 0;
                    level_ = !level_;
                    pulse_hc_ = t_to_hc(one ? b.bit1_t : b.bit0_t);
                    if (second_half_) {
                        second_half_ = false;
                        bit_++;
                    } else {
                        second_half_ = true;
                    }
                    return true;
                }
                byte_++;
                bit_ = 0;
                second_half_ = false;
                continue;
            }
            phase_ = TapePhase::Pause;
            continue;
        }

        if (phase_ == TapePhase::Pause) {
            if (b.pause_ms == 0) {
                phase_ = TapePhase::End;
                continue;
            }
            if (!second_half_) {
                // One short edge at the toggled level BEFORE the silence.
                // Without it the loader never sees the far end of the last
                // bit's second pulse, and drops the last bit -- the classic
                // "loads on every emulator except this one" bug.
                second_half_ = true;
                level_ = !level_;
                pulse_hc_ = ms_to_hc(TAPE_EDGE_PAUSE_MS);
                return true;
            }
            phase_ = TapePhase::End;
            if (b.pause_ms > TAPE_EDGE_PAUSE_MS) {
                level_ = false; // silence sits low
                pulse_hc_ = ms_to_hc(b.pause_ms - TAPE_EDGE_PAUSE_MS);
                return true;
            }
            continue;
        }

        // TapePhase::End
        const bool stop_here = b.stop_tape;
        block_++;
        phase_ = TapePhase::Idle;
        // Stamped HERE, where block_ actually changes, and nowhere else. The
        // Idle branch above is also reached after consume_block() has already
        // stamped it, and re-stamping there would move the origin forward
        // under a position readout that had already counted from the first
        // one -- which shows up as a progress figure ticking backwards.
        block_start_hc_ = pulse_start_hc_;
        if (stop_here) {
            // Not the end of the tape: the motor stops here and playback
            // resumes from the next block when something presses Play again.
            return false;
        }
    }
}

bool Tape::ear_at(uint64_t hc) {
    if (!playing_) {
        return TAPE_IDLE_EAR;
    }
    if (hc < pulse_start_hc_) {
        // The machine was reset out from under us: Ula::reset() zeroes the
        // frame counter, so global_hc() restarts at 0 and every absolute
        // timestamp the cursor holds is now in the future. Stop rather than
        // guess -- a real deck does not rewind itself when you hit reset
        // either. Spectrum48K::reset() calls stop() so this is a backstop.
        stop();
        return TAPE_IDLE_EAR;
    }
    while (hc >= pulse_start_hc_ + pulse_hc_) {
        pulse_start_hc_ += pulse_hc_;
        if (!advance()) {
            playing_ = false;
            at_end_ = block_ >= blocks_.size();
            return TAPE_IDLE_EAR;
        }
    }
    return level_;
}

void Tape::advance_to(uint64_t hc) {
    // The walk is the whole point; the level it lands on is not.
    ear_at(hc);
}

const TapeBlock* Tape::peek_standard_block() const {
    if (!playing_ || block_ >= blocks_.size()) {
        return nullptr;
    }
    // Anywhere in the leader is fair game: the pilot tone and sync carry no
    // information, so how far into them we are does not matter. Once a data
    // bit has gone out the loader has already seen part of the block, and
    // satisfying the rest from here would splice two different reads together.
    if (phase_ != TapePhase::Idle && phase_ != TapePhase::Pilot && phase_ != TapePhase::Sync1
        && phase_ != TapePhase::Sync2) {
        return nullptr;
    }
    const TapeBlock& b = blocks_[block_];
    if (!b.standard_speed || b.data.size() < 2) {
        return nullptr;
    }
    return &b;
}

void Tape::consume_block(uint64_t now_hc) {
    if (block_ >= blocks_.size()) {
        return;
    }
    const uint32_t pause_ms = blocks_[block_].pause_ms;
    block_++;
    phase_ = TapePhase::Idle;
    // Held as a pulse rather than by pushing the origin into the future,
    // because ear_at() reads an origin ahead of `now` as the clock having run
    // backwards. The tape is silent through it, and once it elapses advance()
    // starts the next block -- so a turbo block following a fast-loaded header
    // still begins its pulses where the tape would really have been.
    level_ = false;
    pulse_start_hc_ = now_hc;
    pulse_hc_ = ms_to_hc(pause_ms);
    block_start_hc_ = now_hc;
}

TapeStatus Tape::status(uint64_t now_hc) const {
    TapeStatus s;
    s.inserted = inserted();
    s.playing = playing_;
    s.at_end = at_end_;
    s.fast_load = fast_load_;
    s.name = name_;
    s.description = description_;
    s.block = block_ < blocks_.size() ? block_ : blocks_.size();
    s.blocks = blocks_.size();
    s.total_ms = total_hc_ / (HC_PER_SEC / 1000);
    s.warnings = warnings_;

    uint64_t hc = 0;
    for (size_t i = 0; i < block_ && i < blocks_.size(); i++) {
        hc += blocks_[i].duration_hc;
    }
    if (playing_ && now_hc > block_start_hc_ && block_ < blocks_.size()) {
        uint64_t into = now_hc - block_start_hc_;
        if (into > blocks_[block_].duration_hc) {
            into = blocks_[block_].duration_hc;
        }
        hc += into;
    }
    s.position_ms = hc / (HC_PER_SEC / 1000);
    return s;
}

// ---- auto-start ------------------------------------------------------------

std::string type_load_command(Spectrum48K& m) {
    m.reset();
    run_frames(m, BOOT_FRAMES);

    // In K mode the ROM expands J to the LOAD keyword, and SYM SHIFT + P is
    // the quote character. SYM SHIFT (half-row 7) and P (half-row 5) are on
    // different rows, so the matrix reports them together correctly.
    press(m, "J", nullptr);
    press(m, "P", "SYM SHIFT");
    press(m, "P", "SYM SHIFT");

    // Check before committing. A mistimed script types nothing at all, and
    // without this the failure surfaces much later as "the tape didn't load".
    // (E_LINE) points at the line being edited, which should now hold the LOAD
    // token, two quotes and the line terminator.
    const uint16_t e_line = uint16_t(uint16_t(m.memory.read(SYSVAR_E_LINE))
                                     | uint16_t(m.memory.read(SYSVAR_E_LINE + 1) << 8));
    const uint8_t expect[4] = {0xEF, 0x22, 0x22, 0x0D};
    for (uint16_t i = 0; i < 4; i++) {
        if (m.memory.read(uint16_t(e_line + i)) != expect[i]) {
            return "auto-start typed LOAD \"\" but the ROM's edit line did not accept it "
                   "-- is a stock 48K ROM loaded?";
        }
    }

    // Start the motor BEFORE committing the line -- press Play, then ENTER,
    // exactly the order a human uses on a real machine. It matters more here
    // than it does there: the interpreter reaches LD-BYTES within a frame or
    // two of ENTER being released, and the fast-load trap is a one-shot test
    // at that instant. A tape started after this call has already missed it,
    // and would fall back to pulses for a block that could have been instant.
    if (m.tape.inserted()) {
        m.tape.play(m.global_hc());
    }
    // Not press(): these frames have to be stepped, so the trap is live while
    // the interpreter walks into LD-BYTES. See step_frames.
    m.keyboard.key_down("ENTER");
    step_frames(m, HOLD_FRAMES);
    m.keyboard.key_up("ENTER");
    step_frames(m, GAP_FRAMES);
    return {};
}

} // namespace zx
