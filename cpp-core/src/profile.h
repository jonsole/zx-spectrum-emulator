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
// How the tree knows a call has ended: not by watching for RET, but by the
// stack. A frame is over once SP has risen past the slot its return address
// was pushed into -- which a RET does, and so do a RETI, a POP that throws the
// address away, and an LD SP that abandons a whole chain. Compared modulo 64K
// within half the address space, because a stack that starts at 0x0000 (its
// first push lands at 0xFFFE) is a perfectly good stack.
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
    };

    Profile();

    /// One instruction starting at `pc` that took `half_clocks`, charged to
    /// that address and to the call path it ran on.
    void record(uint16_t pc, uint64_t half_clocks) {
        hits_[pc]++;
        half_clocks_[pc] += half_clocks;
        instructions_++;
        total_half_clocks_ += half_clocks;
        nodes_[current_node()].self_half_clocks += half_clocks;
    }

    /// One interrupt acknowledge sequence that took `half_clocks`. Call after
    /// enter_interrupt, so it is charged to the handler's node.
    void record_interrupt(uint64_t half_clocks) {
        interrupts_++;
        interrupt_half_clocks_ += half_clocks;
        total_half_clocks_ += half_clocks;
        nodes_[current_node()].self_half_clocks += half_clocks;
    }

    /// Ends every call whose return address the stack pointer has risen past.
    /// Call after each instruction, once its time has been recorded -- a RET
    /// belongs to the routine it returns from.
    void unwind(uint16_t sp) {
        while (!frames_.empty()) {
            const uint16_t risen = uint16_t(sp - frames_.back().sp);
            if (risen == 0 || risen >= 0x8000) {
                return;
            }
            frames_.pop_back();
        }
    }

    /// A CALL or RST to `target` whose return address now sits at `sp`.
    void enter_call(uint16_t target, uint16_t sp) { enter(target, sp, false); }
    /// An interrupt accepted into the handler at `target`, its return address
    /// at `sp`.
    void enter_interrupt(uint16_t target, uint16_t sp) { enter(target, sp, true); }

    void clear();

    uint64_t hits(uint16_t pc) const { return hits_[pc]; }
    uint64_t half_clocks(uint16_t pc) const { return half_clocks_[pc]; }
    uint64_t instructions() const { return instructions_; }
    uint64_t interrupts() const { return interrupts_; }
    uint64_t interrupt_half_clocks() const { return interrupt_half_clocks_; }
    /// Everything counted: every instruction plus every acknowledge sequence.
    uint64_t total_half_clocks() const { return total_half_clocks_; }
    /// The tree, root first. A node's parent always comes before it.
    const std::vector<CallNode>& call_nodes() const { return nodes_; }
    /// How deep the call chain currently being run is, root excluded.
    size_t depth() const { return frames_.size(); }

private:
    struct Frame {
        uint32_t node = ROOT;
        /// Where the return address was pushed: SP just after the call.
        uint16_t sp = 0;
    };

    uint32_t current_node() const { return frames_.empty() ? ROOT : frames_.back().node; }
    void enter(uint16_t target, uint16_t sp, bool interrupt);

    std::vector<uint64_t> hits_;
    std::vector<uint64_t> half_clocks_;
    uint64_t instructions_ = 0;
    uint64_t interrupts_ = 0;
    uint64_t interrupt_half_clocks_ = 0;
    uint64_t total_half_clocks_ = 0;

    std::vector<CallNode> nodes_;
    /// (parent, interrupt, address) -> child node, so re-entering a path
    /// finds the node it had last time.
    std::unordered_map<uint64_t, uint32_t> children_;
    std::vector<Frame> frames_;
};

} // namespace zx
