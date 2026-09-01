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

#include <atomic>
#include <cstdint>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

namespace zx {

class Spectrum48K;

/// `TraceOptions::watch` when no address is being watched. Not a uint16_t, so
/// that "no watch" is representable without stealing a real address.
constexpr uint32_t TRACE_NO_WATCH = 0xFFFFFFFFu;

/// `TraceOptions::start_pc` / `TraceOptions::stop_pc` when the capture is not
/// gated on an address. Not a uint16_t, for the same reason: 0x0000 is a real
/// address (it is the reset vector, and a perfectly good place to start).
constexpr uint32_t TRACE_NO_PC = 0xFFFFFFFFu;

/// "No T-state gate", for TraceOptions::start_tstate. Distinct from T-state 0,
/// which is a real and interesting one -- the interrupt itself.
constexpr uint32_t TRACE_NO_TSTATE = 0xFFFFFFFFu;

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
    /// Adds the ULA's own bus: what the display fetch read this half-clock.
    /// Separate from `extra` because it is a different question -- `extra` is
    /// about the CPU's remaining pins, this is about the second bus master.
    bool ula = false;
    /// Where the capture BEGINS: nothing is written until the CPU fetches the
    /// instruction at this address, and the first row is that fetch's T1H.
    /// TRACE_NO_PC records from the very next half-clock, as a capture with
    /// nowhere to wait for always has.
    ///
    /// Both gates are tested at a fetch's T1H, the one half-clock in which the
    /// address of the instruction about to run is on the ADDRESS BUS -- PC
    /// itself has already moved past it, and while halted is parked somewhere
    /// else again, which is why neither is a comparison against PC despite
    /// what a caller naturally calls them.
    uint32_t start_pc = TRACE_NO_PC;
    /// Where the capture begins in TIME rather than in code: the T-state
    /// within the video frame, counted from the interrupt exactly as the
    /// `extra` T-state column prints it, so the first row of a capture gated
    /// here reads the number that was asked for.
    ///
    /// This is the gate for "what is on the bus at T-state 14336", which is a
    /// question about the ULA and not about the program -- the half-clock
    /// wanted is usually in the middle of an instruction, where no fetch is
    /// happening for a start_pc to match against. Arms for the next frame
    /// when the machine is already past it, so it always lands on the T-state
    /// named rather than on "as soon as possible".
    ///
    /// Mutually exclusive with start_pc: two answers to "where does this
    /// begin" is a question, not a configuration. TRACE_NO_TSTATE for none.
    uint32_t start_tstate = TRACE_NO_TSTATE;
    /// Where the capture ENDS: it closes itself on ARRIVING at this address,
    /// before the instruction there is fetched. So a gated capture covers
    /// [arrive at start_pc, arrive at stop_pc) -- the half-open interval, which
    /// is what makes "trace from A to B" and "trace from B to C" join up
    /// instead of overlapping. TRACE_NO_PC runs until the limit or an explicit
    /// stop.
    uint32_t stop_pc = TRACE_NO_PC;
    /// Resolves an address to a label, "MOVE_WILLY+3" style, or an empty
    /// string when nothing is known. Supplied by the server layer, which owns
    /// the SLD data -- zx_core deliberately never sees rom_source.h, so this
    /// callback is the whole seam between the two.
    ///
    /// When set, the table gains a Symbol column naming where the running
    /// instruction lives, and the Asm column annotates its 16-bit operands the
    /// same way. When null, neither happens and the layout stays byte-for-byte
    /// visualz80remix's.
    std::function<std::string(uint16_t)> resolve_symbol;
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
    ///
    /// Atomic, like rows(), and for the same reason: a capture is written by
    /// the emulator thread but watched from another -- the trace panel's row
    /// counter, and every trace_status caller behind it. Both are read while
    /// record() is running, so neither can be a plain member.
    bool active() const { return active_.load(std::memory_order_relaxed); }

    /// True while the capture is open but still waiting for `start_pc`: the
    /// file holds its header and nothing else, and rows() is 0. Atomic for the
    /// same reason active() is -- it is read by every status poller while the
    /// emulator thread is deciding to clear it.
    bool waiting() const { return waiting_.load(std::memory_order_relaxed); }

    uint64_t rows() const { return rows_.load(std::memory_order_relaxed); }
    const std::string& path() const { return options_.path; }
    const TraceOptions& options() const { return options_; }

    /// Arms, re-arms or (with TRACE_NO_PC) clears the address the capture
    /// closes itself on reaching. Safe to call from another thread WHILE the
    /// emulator thread is recording, which is the whole point of it being an
    /// atomic rather than just another field of options(): a stop_trace(pc)
    /// has to reach a capture that the emulator thread owns, and it must not
    /// wait for a run to yield to do it.
    void set_stop_pc(uint32_t pc) { stop_pc_.store(pc, std::memory_order_relaxed); }
    uint32_t stop_pc() const { return stop_pc_.load(std::memory_order_relaxed); }

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
    std::atomic<uint64_t> rows_{0};
    /// Mirrors out_.is_open() so a reader on another thread has something it
    /// can safely look at -- an ofstream is not that.
    std::atomic<bool> active_{false};
    /// Open but not yet triggered: see waiting(). Cleared by the half-clock
    /// that reaches options_.start_pc, and by close().
    std::atomic<bool> waiting_{false};
    /// options_.stop_pc, but writable from another thread. See set_stop_pc().
    std::atomic<uint32_t> stop_pc_{TRACE_NO_PC};

    /// Disassembly of the instruction currently in flight, repeated on every
    /// row belonging to it. Repeated rather than written once per group
    /// because the file's job is to be read raw as well as parsed.
    std::string current_asm_;
    /// Where the running instruction lives ("MOVE_WILLY+3"), and its address.
    /// Both follow current_asm_: resolved once per instruction, repeated on
    /// every row of it.
    std::string current_symbol_;
    uint16_t current_instr_addr_ = 0;
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

    /// Appends "(LABEL+n)" after each 16-bit hex operand in a disassembly.
    /// Done here rather than by calling rom_source.h's annotate_symbols so
    /// that zx_core keeps needing nothing but the one callback above.
    std::string annotate(const std::string& text) const;

    void build_columns();
    void write_border(const char* left, const char* mid, const char* right);
    void write_row(const std::vector<std::string>& cells);
};

} // namespace zx
