#pragma once
// Cycle-by-cycle bus trace, one row per HALF-T-STATE.
//
// The output is the box-drawn table visualz80remix's "Trace Log" panel
// produces (https://floooh.github.io/visualz80remix/), deliberately so: the
// default column set, widths and alignment are byte-for-byte its layout, so a
// capture from here can be put next to a capture from there and diffed. That
// is the whole point of the format choice -- it is a reference to check this
// core against, not just a log.
//
//   ┌─────────┬────┬──────┬──────┬──────┬────┬────┬──────┬────┬──────┬ ...
//   │ Cycle/h │ M1 │ MREQ │ IORQ │ RFSH │ RD │ WR │ AB   │ DB │ PC   │ ...
//   ├─────────┼────┼──────┼──────┼──────┼────┼────┼──────┼────┼──────┼ ...
//   │     1/0 │ M1 │      │      │      │    │    │ 0000 │ 00 │ 0000 │ ...
//
// A signal column holds its own name when the line is ASSERTED and blank when
// it is not -- so the table reads as a timing diagram in text, which is what
// makes it worth having over a CSV.
//
// WHERE THE SAMPLE IS TAKEN, and why it matters:
//
// record() must be called from Spectrum48K::clock() AFTER the CPU has been
// clocked but BEFORE the bus is serviced. That is not an arbitrary spot. Our
// memory responds instantly -- service_bus() puts the byte on D0-7 in the same
// half-clock that MREQ|RD asserts -- whereas real hardware takes until T2/T3,
// and the CPU does not latch until T3L either way. Sampling before the service
// therefore shows the data bus as the CPU actually sees it entering the
// half-clock, which is both the physically honest picture AND what
// visualz80remix prints. Sampling after would show every read byte a
// half-clock early and every trace would be misaligned against the reference.
//
// `extra` mode appends the lines and the raster position a 48K cares about
// (HALT/WAIT/INT/NMI, frame and T-state) that a bare Z80 visualiser has no
// reason to show. It breaks the byte-for-byte match on purpose; the viewer
// reads the header row to discover the columns, so it handles either.

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

namespace zx {

class Spectrum48K;

/// `TraceOptions::watch` when no address is being watched. Not a uint16_t, so
/// that "no watch" is representable without stealing a real address.
constexpr uint32_t TRACE_NO_WATCH = 0xFFFFFFFFu;

/// Rows a capture stops itself after when no limit is asked for. One 48K frame
/// is 139,776 half-clocks, so this is a little under a fifth of a frame -- big
/// enough to hold any plausible "what did those instructions do on the bus"
/// question, small enough that forgetting to stop costs a ~4MB file rather
/// than filling the disk.
constexpr uint64_t TRACE_DEFAULT_LIMIT = 25000;

struct TraceOptions {
    std::string path;
    /// Half-clocks to record before closing the file automatically. 0 means
    /// unlimited, which only a caller that will definitely call stop() should
    /// ask for -- this writes ~85 bytes per half-clock at 7MHz.
    uint64_t limit = TRACE_DEFAULT_LIMIT;
    /// Memory address sampled into the Watch column each half-clock, or
    /// TRACE_NO_WATCH for the reference's inert "??".
    uint32_t watch = TRACE_NO_WATCH;
    /// Adds the 48K-specific columns. See the note above.
    bool extra = false;
};

class TraceLog {
public:
    ~TraceLog();

    /// Opens the file and writes the top border and header. Returns an empty
    /// string on success, else the error message.
    std::string open(const TraceOptions& options);

    /// Writes the closing border and closes the file. Safe to call twice.
    void close();

    /// True while rows are still being written. Goes false on its own once
    /// the row limit is reached.
    bool active() const { return out_.is_open(); }

    uint64_t rows() const { return rows_; }
    const std::string& path() const { return options_.path; }
    const TraceOptions& options() const { return options_; }

    /// Records one half-clock. A no-op once the capture has finished, so the
    /// caller's hot loop needs no second check beyond the null test.
    void record(Spectrum48K& machine, uint64_t pins);

private:
    /// One output column. `width` is the inner width, excluding the single
    /// space of padding either side that the box drawing adds.
    struct Column {
        std::string title;
        int width = 0;
        bool right_align = false;
    };

    TraceOptions options_;
    std::ofstream out_;
    std::vector<Column> columns_;
    uint64_t rows_ = 0;

    /// Disassembly of the instruction currently in flight, repeated on every
    /// row belonging to it. Repeated rather than written once per group
    /// because the file's job is to be read raw as well as parsed.
    std::string current_asm_;
    /// Detects interrupt acceptance without needing to see inside the CPU:
    /// the counter ticks in the same half-clock the interrupt is taken.
    uint64_t last_interrupt_count_ = 0;
    bool seen_first_row_ = false;
    /// Phase of the previous row, so the next one can alternate off it. See
    /// the anchoring note in record().
    bool last_was_h_ = false;

    /// T-state number shown in the Cycle/h column, counting from 1 at the
    /// start of the capture.
    uint64_t cycle_ = 1;

    void build_columns();
    void write_border(const char* left, const char* mid, const char* right);
    void write_row(const std::vector<std::string>& cells);
};

} // namespace zx
