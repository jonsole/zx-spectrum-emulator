#include "profile.h"

#include <algorithm>

namespace zx {

Profile::Profile()
    : hits_(ADDRESSES, 0),
      half_clocks_(ADDRESSES, 0),
      idle_half_clocks_(ADDRESSES, 0),
      idle_map_(ADDRESSES, 0),
      addr_stamp_(ADDRESSES, 0) {
    period_addresses_.half_clocks.assign(ADDRESSES, 0);
    period_addresses_.idle_half_clocks.assign(ADDRESSES, 0);
    clear();
}

void Profile::clear() {
    for (size_t i = 0; i < ADDRESSES; i++) {
        hits_[i] = 0;
        half_clocks_[i] = 0;
        idle_half_clocks_[i] = 0;
    }
    instructions_ = 0;
    interrupts_ = 0;
    interrupt_half_clocks_ = 0;
    total_half_clocks_ = 0;
    idle_total_ = 0;

    nodes_.clear();
    nodes_.push_back(CallNode{});
    node_stamp_.assign(1, 0);
    period_nodes_.half_clocks.assign(1, 0);
    period_nodes_.idle_half_clocks.assign(1, 0);
    children_.clear();
    frames_.clear();

    reset_periods();
}

void Profile::set_idle_map(const std::vector<uint8_t>& map) {
    for (size_t i = 0; i < ADDRESSES; i++) {
        idle_map_[i] = i < map.size() ? map[i] : 0;
    }
}

void Profile::set_period_marker(int32_t marker) {
    if (marker != period_marker_) {
        period_marker_ = marker;
        reset_periods();
    }
}

void Profile::reset_periods() {
    periods_.clear();
    period_count_ = 0;
    worst_.clear();
    period_open_ = false;
    period_partial_ = true;
    period_ = PeriodCost{};
    // A new stamp retires every entry touched so far without visiting them.
    period_stamp_++;
    period_addresses_.touched.clear();
    period_nodes_.touched.clear();
}

void Profile::open_period(uint64_t frame) {
    period_open_ = true;
    period_ = PeriodCost{};
    period_.start_frame = frame;
    period_stamp_++;
    period_addresses_.touched.clear();
    period_nodes_.touched.clear();
}

void Profile::close_period() {
    if (period_partial_) {
        period_partial_ = false;
        return;
    }
    const uint64_t index = period_count_++;
    if (periods_.size() < MAX_PERIODS) {
        periods_.push_back(period_);
    }

    // Ranked by busy time. The worst list is short, so a linear look for its
    // least busy member costs less than keeping it ordered.
    const uint64_t busy = period_.busy();
    size_t least = 0;
    for (size_t i = 1; i < worst_.size(); i++) {
        if (worst_[i].cost.busy() < worst_[least].cost.busy()) {
            least = i;
        }
    }
    const bool full = worst_.size() >= WORST_PERIODS;
    if (full && busy <= worst_[least].cost.busy()) {
        return;
    }

    WorstPeriod w;
    w.index = index;
    w.cost = period_;
    w.addresses.reserve(period_addresses_.touched.size());
    for (uint32_t id : period_addresses_.touched) {
        w.addresses.push_back(WorstPeriod::Share{id, period_addresses_.half_clocks[id],
                                                 period_addresses_.idle_half_clocks[id]});
    }
    w.nodes.reserve(period_nodes_.touched.size());
    for (uint32_t id : period_nodes_.touched) {
        w.nodes.push_back(WorstPeriod::Share{id, period_nodes_.half_clocks[id],
                                             period_nodes_.idle_half_clocks[id]});
    }
    if (full) {
        worst_[least] = std::move(w);
    } else {
        worst_.push_back(std::move(w));
    }
}

void Profile::enter(uint16_t target, uint16_t sp, bool interrupt, uint16_t site) {
    const uint32_t parent = current_node();
    uint32_t node = parent;
    if (frames_.size() < MAX_DEPTH) {
        // 17 bits of parent (MAX_NODES fits), a flag, 16 of site, 16 of target.
        const uint64_t key = (uint64_t(parent) << 33) | (uint64_t(interrupt ? 1 : 0) << 32)
                             | (uint64_t(site) << 16) | target;
        auto found = children_.find(key);
        if (found != children_.end()) {
            node = found->second;
        } else if (nodes_.size() < MAX_NODES) {
            CallNode n;
            n.parent = parent;
            n.addr = target;
            n.interrupt = interrupt;
            n.site = site;
            node = uint32_t(nodes_.size());
            nodes_.push_back(n);
            node_stamp_.push_back(0);
            period_nodes_.half_clocks.push_back(0);
            period_nodes_.idle_half_clocks.push_back(0);
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

Profile::PeriodSummary Profile::summarize(size_t max_strip) const {
    PeriodSummary s;
    s.marker = period_marker_;
    s.count = period_count_;
    for (const PeriodCost& p : periods_) {
        s.half_clocks += p.half_clocks;
        s.idle_half_clocks += p.idle_half_clocks;
        if (p.busy() > s.busiest) {
            s.busiest = p.busy();
        }
        if (p.idle_half_clocks == 0) {
            s.without_idle++;
        }
    }
    if (max_strip == 0) {
        max_strip = 1;
    }
    s.bucket = (periods_.size() + max_strip - 1) / max_strip;
    if (s.bucket == 0) {
        s.bucket = 1;
    }
    for (size_t i = 0; i < periods_.size(); i += s.bucket) {
        uint64_t most = 0;
        for (size_t j = i; j < periods_.size() && j < i + s.bucket; j++) {
            most = std::max(most, periods_[j].busy());
        }
        s.strip.push_back(most);
    }
    s.worst = worst_;
    std::sort(s.worst.begin(), s.worst.end(), [](const WorstPeriod& a, const WorstPeriod& b) {
        if (a.cost.busy() != b.cost.busy()) {
            return a.cost.busy() > b.cost.busy();
        }
        return a.index < b.index;
    });
    return s;
}

} // namespace zx
