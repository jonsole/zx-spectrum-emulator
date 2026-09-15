#include "profile.h"

namespace zx {

Profile::Profile() : hits_(ADDRESSES, 0), half_clocks_(ADDRESSES, 0) {
    clear();
}

void Profile::clear() {
    for (size_t i = 0; i < ADDRESSES; i++) {
        hits_[i] = 0;
        half_clocks_[i] = 0;
    }
    instructions_ = 0;
    interrupts_ = 0;
    interrupt_half_clocks_ = 0;
    total_half_clocks_ = 0;

    nodes_.clear();
    nodes_.push_back(CallNode{});
    children_.clear();
    frames_.clear();
}

void Profile::enter(uint16_t target, uint16_t sp, bool interrupt) {
    const uint32_t parent = current_node();
    uint32_t node = parent;
    if (frames_.size() < MAX_DEPTH) {
        const uint64_t key = (uint64_t(parent) << 17) | (interrupt ? 0x10000u : 0u) | target;
        auto found = children_.find(key);
        if (found != children_.end()) {
            node = found->second;
        } else if (nodes_.size() < MAX_NODES) {
            CallNode n;
            n.parent = parent;
            n.addr = target;
            n.interrupt = interrupt;
            node = uint32_t(nodes_.size());
            nodes_.push_back(n);
            children_.emplace(key, node);
        }
    }
    // Pushed even when the tree is full, charging the caller: the frame is
    // what keeps the matching return from unwinding one call too many.
    if (node != parent) {
        nodes_[node].calls++;
    }
    frames_.push_back(Frame{node, sp});
}

} // namespace zx
