#pragma once
// Profile: where the CPU's time goes, by address and by call path.
//
// For every address an instruction starts at, how many times it ran and how
// many half-clocks it took. Measured off the machine's own clock rather than
// looked up from an opcode's nominal length, so what it counts is what the
// instruction really cost on that run: the ULA holding the clock for a
// contended address is in there, and so is a DJNZ taken versus not.
//
// Alongside that, a calling-context tree: one node per distinct call path,
// holding how often that path was entered and the half-clocks spent in its
// own code. sprite_blit called from objects_draw_all and sprite_blit called
// from redraw_view are two nodes, so a caller's subtree says what its calls
// really cost it -- not what those routines cost the whole program, which is
// all a call graph read off the source could say. A node's total is its own
// time plus its children's.
//
// Filled by Spectrum::step_instruction(), which every run, step and step-over
// goes through. step_tstates() and run_frame() clock the machine directly and
// are not counted -- they are for looking inside an instruction, not for
// measuring a program.
//
// Two things would land on the wrong line if they were simply charged to the
// instruction they happened in, so they are not:
//
//   * An interrupt's acknowledge sequence. It is accepted at the end of
//     whatever instruction happened to be running when INT arrived, and runs
//     as part of that step -- charging it there would make a line hot for no
//     better reason than being where the beam caught it. It gets its own
//     bucket, and the handler it enters gets its own node in the tree, under
//     whatever it interrupted.
//   * A HALT waiting for its interrupt. Each pass re-executes the HALT, but
//     the PC a halted CPU reports is one past it; the time is charged to the
//     HALT itself, where it shows as the frame's slack.
//
// How the tree knows a call has ended: its return address is gone from the
// stack. An instruction that moves SP by one or two bytes reads those bytes
// off the stack (RET, RETI, POP, INC SP) or writes them onto it (CALL, PUSH,
// DEC SP); a call whose return address sat in them is over, and so is every
// call made inside it that is still open. Reading covers a return and a return
// address thrown away; writing covers a stack reset by LD SP and then used
// again, which overwrites the abandoned calls' slots. Measured modulo 64K, so a
// stack starting at 0x0000 (its first push lands at 0xFFFE) works like any
// other. The debugger's call stack (Spectrum::call_stack) follows the same rule.
//
// What does NOT end a call is SP merely moving. Spectrum code borrows SP as a
// fast data pointer -- LD SP,HL, then PUSH to fill a buffer or POP to walk a
// bitmap -- and a rule of "SP has risen past the slot" reads that as every
// open call returning at once, leaving the rest of the frame charged to no
// call at all. Nor does borrowed SP reach the real stack's slots, so its reads
// and writes end nothing either.
//
// IDLE TIME AND PERIODS
//
// Every video frame is the same length -- 69,888 T-states on a 48K -- so what
// a frame "costs" is only meaningful as the part of it that was not waiting.
// Time is idle when the CPU is halted, or when it is running an address the
// caller has marked idle (a busy-wait pacing loop, say). Idle time is counted
// separately everywhere: per address, per call node, per period.
//
// A period is the unit the program's own work repeats in. By default that is
// the video frame; given a marker address instead, a period runs from one
// arrival there to the next -- one turn of a game loop that takes one and a
// half frames a turn. Every completed period's total and idle time is kept,
// and the WORST_PERIODS with the most busy time are kept in detail: their own
// time per address and per call node, which is what "what went wrong in that
// frame" is answered from. The period counting began in is never ranked,
// since it did not begin at a period boundary.
//
// Addresses are 16-bit: on a 128K, code in two different pages at the same
// address shares one count.
//
// Not thread-safe. The Engine owns one and only touches it on the emulator
// thread; anything outside reads a copy.

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace zx {

class Profile {
public:
    static constexpr size_t ADDRESSES = 0x10000;
    /// The tree's root: whatever was running outside any call seen since
    /// counting began. A profile started mid-routine counts that routine here
    /// until it returns, and its caller after that.
    static constexpr uint32_t ROOT = 0;
    static constexpr uint32_t NO_PARENT = 0xFFFFFFFF;
    /// Bounds on the tree, so a runaway recursion or a program calling
    /// through an ever-changing jump table cannot eat the host's memory. Past
    /// either, a call is still tracked (so its return still balances) but its
    /// time is charged to its caller's node.
    static constexpr size_t MAX_NODES = 100000;
    static constexpr size_t MAX_DEPTH = 1024;
    /// Periods kept in detail, and periods kept at all: ten hours of frames.
    /// Past that they are still counted and ranked, just not listed.
    static constexpr size_t WORST_PERIODS = 10;
    static constexpr size_t MAX_PERIODS = 1800000;
    /// No marker: a period is a video frame.
    static constexpr int32_t FRAME_PERIODS = -1;

    struct CallNode {
        uint32_t parent = NO_PARENT;
        /// The address the call went to -- a routine's entry point. For an
        /// interrupt node, the handler's first instruction.
        uint16_t addr = 0;
        bool interrupt = false;
        /// Times this path was entered.
        uint64_t calls = 0;
        /// Half-clocks spent in this node's own code, not its children's.
        uint64_t self_half_clocks = 0;
        /// The idle part of self_half_clocks.
        uint64_t idle_half_clocks = 0;
    };

    struct PeriodCost {
        /// The video frame the period began in.
        uint64_t start_frame = 0;
        uint64_t half_clocks = 0;
        uint64_t idle_half_clocks = 0;
        uint64_t busy() const { return half_clocks - idle_half_clocks; }
    };

    /// One of the busiest periods, with where its time went.
    struct WorstPeriod {
        /// Its position among completed periods, from 0.
        uint64_t index = 0;
        PeriodCost cost;
        struct Share {
            uint32_t id = 0; // an address, or a call node
            uint64_t half_clocks = 0;
            uint64_t idle_half_clocks = 0;
        };
        std::vector<Share> addresses;
        std::vector<Share> nodes;
    };

    /// Every completed period, reduced to what can be shown: totals, a strip
    /// of busy time (each bucket the busiest period in it), and the worst.
    struct PeriodSummary {
        int32_t marker = FRAME_PERIODS;
        uint64_t count = 0;
        uint64_t half_clocks = 0;
        uint64_t idle_half_clocks = 0;
        uint64_t busiest = 0;
        /// Periods with no idle time at all: ones the program's work filled,
        /// so it overran whatever it was pacing itself to.
        uint64_t without_idle = 0;
        /// How many periods each strip entry covers.
        uint64_t bucket = 1;
        std::vector<uint64_t> strip;
        /// Busiest first.
        std::vector<WorstPeriod> worst;
    };

    Profile();

    /// One instruction starting at `pc` that took `half_clocks`, charged to
    /// that address and to the call path it ran on. `frame` is the video frame
    /// it began in and `halted` whether it was a HALT waiting -- which is idle
    /// time whatever the idle map says.
    void record(uint16_t pc, uint64_t half_clocks, uint64_t frame, bool halted) {
        if (!period_open_) {
            open_period(frame);
        } else if (period_marker_ == FRAME_PERIODS ? frame != period_.start_frame
                                                   : (pc == uint16_t(period_marker_) && !halted)) {
            close_period();
            open_period(frame);
        }
        hits_[pc]++;
        half_clocks_[pc] += half_clocks;
        instructions_++;
        total_half_clocks_ += half_clocks;
        period_.half_clocks += half_clocks;
        const uint32_t node = current_node();
        nodes_[node].self_half_clocks += half_clocks;

        const bool idle = halted || idle_map_[pc] != 0;
        uint64_t idle_part = 0;
        if (idle) {
            idle_part = half_clocks;
            idle_half_clocks_[pc] += half_clocks;
            idle_total_ += half_clocks;
            nodes_[node].idle_half_clocks += half_clocks;
            period_.idle_half_clocks += half_clocks;
        }
        note(period_addresses_, addr_stamp_, pc, half_clocks, idle_part);
        note(period_nodes_, node_stamp_, node, half_clocks, idle_part);
    }

    /// One interrupt acknowledge sequence that took `half_clocks`. Call after
    /// enter_interrupt, so it is charged to the handler's node.
    void record_interrupt(uint64_t half_clocks) {
        interrupts_++;
        interrupt_half_clocks_ += half_clocks;
        total_half_clocks_ += half_clocks;
        period_.half_clocks += half_clocks;
        const uint32_t node = current_node();
        nodes_[node].self_half_clocks += half_clocks;
        note(period_nodes_, node_stamp_, node, half_clocks, 0);
    }

    /// The stack bytes an instruction read off or wrote onto, given SP before
    /// and after it: `count` bytes from `first`. None when SP moved by
    /// anything but one or two bytes -- a jump of the stack pointer, which
    /// touches no stack at all.
    static uint16_t stack_bytes(uint16_t sp_before, uint16_t sp_after, uint16_t& first) {
        const uint16_t rise = uint16_t(sp_after - sp_before);
        if (rise == 1 || rise == 2) {
            first = sp_before;
            return rise;
        }
        const uint16_t fall = uint16_t(sp_before - sp_after);
        if (fall == 1 || fall == 2) {
            first = sp_after;
            return fall;
        }
        return 0;
    }

    /// The first of `slots` (where each open call's return address was pushed,
    /// outermost first) that an instruction moving SP from `sp_before` to
    /// `sp_after` read off or wrote over, or slots.size() for none. That call
    /// and every one after it are over. Outermost first, because a slot
    /// reused after an LD SP threw a chain away belongs to both.
    template <typename Slots, typename SlotOf>
    static size_t first_frame_reached(const Slots& slots, SlotOf slot_of, uint16_t sp_before,
                                      uint16_t sp_after) {
        uint16_t first = 0;
        const uint16_t count = stack_bytes(sp_before, sp_after, first);
        if (count != 0) {
            for (size_t i = 0; i < slots.size(); i++) {
                if (uint16_t(slot_of(slots[i]) - first) < count) {
                    return i;
                }
            }
        }
        return slots.size();
    }

    /// Ends the calls whose return address an instruction read off or wrote
    /// over. Call after each instruction, once its time has been recorded --
    /// a RET belongs to the routine it returns from -- and before following
    /// a CALL, whose own push may overwrite an abandoned call's slot.
    void stack_moved(uint16_t sp_before, uint16_t sp_after) {
        frames_.resize(first_frame_reached(
            frames_, [](const Frame& f) { return f.sp; }, sp_before, sp_after));
    }

    /// A CALL or RST to `target` whose return address now sits at `sp`.
    void enter_call(uint16_t target, uint16_t sp) { enter(target, sp, false); }
    /// An interrupt accepted into the handler at `target`, its return address
    /// at `sp`.
    void enter_interrupt(uint16_t target, uint16_t sp) { enter(target, sp, true); }

    /// Starts again from nothing. The idle map and the period marker are
    /// settings, not counts, and are kept.
    void clear();

    /// Which addresses are idle: ADDRESSES bytes, nonzero for idle. Applies
    /// from the next instruction; what was already counted stays as it was.
    void set_idle_map(const std::vector<uint8_t>& map);
    /// FRAME_PERIODS, or the address whose arrival starts each period.
    /// Changing it discards the periods counted so far, which were periods of
    /// something else.
    void set_period_marker(int32_t marker);
    int32_t period_marker() const { return period_marker_; }

    uint64_t hits(uint16_t pc) const { return hits_[pc]; }
    uint64_t half_clocks(uint16_t pc) const { return half_clocks_[pc]; }
    uint64_t idle_half_clocks(uint16_t pc) const { return idle_half_clocks_[pc]; }
    uint64_t instructions() const { return instructions_; }
    uint64_t interrupts() const { return interrupts_; }
    uint64_t interrupt_half_clocks() const { return interrupt_half_clocks_; }
    /// Everything counted: every instruction plus every acknowledge sequence.
    uint64_t total_half_clocks() const { return total_half_clocks_; }
    uint64_t idle_total_half_clocks() const { return idle_total_; }
    /// The tree, root first. A node's parent always comes before it.
    const std::vector<CallNode>& call_nodes() const { return nodes_; }
    /// How deep the call chain currently being run is, root excluded.
    size_t depth() const { return frames_.size(); }
    /// Every completed period, in order (up to MAX_PERIODS).
    const std::vector<PeriodCost>& periods() const { return periods_; }
    /// The periods, reduced to at most `max_strip` strip entries.
    PeriodSummary summarize(size_t max_strip) const;

private:
    struct Frame {
        uint32_t node = ROOT;
        /// Where the return address was pushed: SP just after the call.
        uint16_t sp = 0;
    };

    /// Time spent this period, per address or per node, kept sparse: a stamp
    /// says whether an entry has been touched this period, so starting a new
    /// one costs nothing but a new stamp value.
    struct PeriodShares {
        std::vector<uint64_t> half_clocks;
        std::vector<uint64_t> idle_half_clocks;
        std::vector<uint32_t> touched;
    };

    void note(PeriodShares& shares, std::vector<uint64_t>& stamps, uint32_t id,
              uint64_t half_clocks, uint64_t idle) {
        if (id >= stamps.size()) {
            return;
        }
        if (stamps[id] != period_stamp_) {
            stamps[id] = period_stamp_;
            shares.half_clocks[id] = 0;
            shares.idle_half_clocks[id] = 0;
            shares.touched.push_back(id);
        }
        shares.half_clocks[id] += half_clocks;
        shares.idle_half_clocks[id] += idle;
    }

    uint32_t current_node() const { return frames_.empty() ? ROOT : frames_.back().node; }
    void enter(uint16_t target, uint16_t sp, bool interrupt);
    void open_period(uint64_t frame);
    void close_period();
    void reset_periods();

    std::vector<uint64_t> hits_;
    std::vector<uint64_t> half_clocks_;
    std::vector<uint64_t> idle_half_clocks_;
    uint64_t instructions_ = 0;
    uint64_t interrupts_ = 0;
    uint64_t interrupt_half_clocks_ = 0;
    uint64_t total_half_clocks_ = 0;
    uint64_t idle_total_ = 0;

    std::vector<CallNode> nodes_;
    /// (parent, interrupt, address) -> child node, so re-entering a path
    /// finds the node it had last time.
    std::unordered_map<uint64_t, uint32_t> children_;
    std::vector<Frame> frames_;

    std::vector<uint8_t> idle_map_;
    int32_t period_marker_ = FRAME_PERIODS;
    bool period_open_ = false;
    /// The period counting began in, which did not begin at a boundary.
    bool period_partial_ = true;
    PeriodCost period_;
    uint64_t period_stamp_ = 1;
    PeriodShares period_addresses_;
    std::vector<uint64_t> addr_stamp_;
    PeriodShares period_nodes_;
    std::vector<uint64_t> node_stamp_;
    std::vector<PeriodCost> periods_;
    uint64_t period_count_ = 0;
    std::vector<WorstPeriod> worst_;
};

} // namespace zx
