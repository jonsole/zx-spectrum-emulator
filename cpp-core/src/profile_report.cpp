#include "profile_report.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <mutex>
#include <utility>

namespace zx {
namespace {

std::string hex4_dollar(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "$%04X", v);
    return buf;
}

/// "sprite_blit.loop" is part of sprite_blit.
std::string routine_of(const std::string& label) {
    const size_t dot = label.find('.');
    if (dot == std::string::npos || dot == 0) {
        return label;
    }
    return label.substr(0, dot);
}

/// The path a client can open: the SLD resolves an INCLUDE beside the entry
/// source, which may itself have been given relative to the server's working
/// directory. Cached, since every line of a file asks for the same one.
const std::string& absolute_path(const std::string& path,
                                 std::map<std::string, std::string>& cache) {
    auto found = cache.find(path);
    if (found != cache.end()) {
        return found->second;
    }
    std::error_code ec;
    const std::filesystem::path full = std::filesystem::weakly_canonical(path, ec);
    const std::string resolved = (ec || full.empty()) ? path : full.string();
    return cache.emplace(path, resolved).first->second;
}

double tstates(uint64_t half_clocks) {
    return double(half_clocks) / 2.0;
}

/// A page of unsourced code as the report names it, "$9000-$90FF".
bool parse_page_range(const std::string& text, uint16_t& first, uint16_t& last) {
    if (text.size() != 11 || text[0] != '$' || text[5] != '-' || text[6] != '$') {
        return false;
    }
    char* end = nullptr;
    const unsigned long a = std::strtoul(text.substr(1, 4).c_str(), &end, 16);
    if (end == nullptr || *end != '\0') {
        return false;
    }
    const unsigned long b = std::strtoul(text.substr(7, 4).c_str(), &end, 16);
    if (end == nullptr || *end != '\0' || b < a || b > 0xFFFF) {
        return false;
    }
    first = uint16_t(a);
    last = uint16_t(b);
    return true;
}

std::mutex settings_mutex;
ProfileSettings settings_applied;
std::vector<std::string> settings_unresolved;

/// Time at one address, however it was counted.
struct AddressCost {
    uint16_t addr = 0;
    uint64_t hits = 0;
    uint64_t half_clocks = 0;
    uint64_t idle_half_clocks = 0;
};

/// Folds address costs into source lines and routines, most expensive first.
/// Shared by the whole profile and each of its worst periods.
void fold_addresses(const std::vector<AddressCost>& costs, const std::vector<RomSourcePtr>& active,
                    std::map<std::string, std::string>& paths,
                    std::vector<ProfileReport::Line>& lines,
                    std::vector<ProfileReport::Routine>& routines, uint64_t& unmapped) {
    // Keyed by (source, file, line): two programs' line 40s are different
    // lines, and so are two files' within one program.
    std::map<std::pair<const RomSource*, std::pair<size_t, uint32_t>>, size_t> line_index;
    // Keyed by source too: the ROM and a program can both have a START.
    std::map<std::pair<const RomSource*, std::string>, size_t> routine_index;

    for (const AddressCost& cost : costs) {
        // The first source with an EXACT mapping for the address owns it --
        // the rule build_frame uses, for the same reason: a nearest-label
        // match alone would hand ROM code to the program's last label.
        const RomSource* owner = nullptr;
        SourceLoc loc;
        for (const RomSourcePtr& source : active) {
            auto it = source->addr_to_loc.find(cost.addr);
            if (it != source->addr_to_loc.end() && it->second.file < source->files.size()) {
                owner = source.get();
                loc = it->second;
                break;
            }
        }

        std::string routine;
        std::string routine_path;
        uint32_t routine_line = 0;
        std::string symbol;
        if (owner != nullptr) {
            std::string label;
            uint16_t offset = 0;
            if (owner->code_label_at(cost.addr, label, offset)) {
                symbol = offset == 0 ? label : label + "+" + std::to_string(offset);
                routine = routine_of(label);
                auto sym = owner->symbols.find(routine);
                if (sym != owner->symbols.end()) {
                    auto where = owner->addr_to_loc.find(sym->second);
                    if (where != owner->addr_to_loc.end()
                        && where->second.file < owner->files.size()) {
                        routine_path = absolute_path(owner->files[where->second.file].path, paths);
                        routine_line = where->second.line;
                    }
                }
            }

            const auto key = std::make_pair(owner, std::make_pair(loc.file, loc.line));
            auto found = line_index.find(key);
            if (found == line_index.end()) {
                ProfileReport::Line line;
                line.path = absolute_path(owner->files[loc.file].path, paths);
                line.line = loc.line;
                line.symbol = symbol;
                line_index.emplace(key, lines.size());
                lines.push_back(line);
                found = line_index.find(key);
            }
            ProfileReport::Line& line = lines[found->second];
            line.hits += cost.hits;
            line.half_clocks += cost.half_clocks;
            line.idle_half_clocks += cost.idle_half_clocks;
        } else {
            unmapped += cost.half_clocks;
        }

        if (routine.empty()) {
            const uint16_t page = uint16_t(cost.addr & 0xFF00);
            routine = hex4_dollar(page) + "-" + hex4_dollar(uint16_t(page | 0x00FF));
        }
        const auto routine_key = std::make_pair(owner, routine);
        auto found = routine_index.find(routine_key);
        if (found == routine_index.end()) {
            ProfileReport::Routine r;
            r.name = routine;
            r.path = routine_path;
            r.line = routine_line;
            routine_index.emplace(routine_key, routines.size());
            routines.push_back(r);
            found = routine_index.find(routine_key);
        }
        ProfileReport::Routine& r = routines[found->second];
        r.hits += cost.hits;
        r.half_clocks += cost.half_clocks;
        r.idle_half_clocks += cost.idle_half_clocks;
    }

    // Most expensive first; ties by where they are, so the order is stable
    // from one refresh to the next.
    std::sort(lines.begin(), lines.end(),
              [](const ProfileReport::Line& a, const ProfileReport::Line& b) {
                  if (a.half_clocks != b.half_clocks) {
                      return a.half_clocks > b.half_clocks;
                  }
                  if (a.path != b.path) {
                      return a.path < b.path;
                  }
                  return a.line < b.line;
              });
    std::sort(routines.begin(), routines.end(),
              [](const ProfileReport::Routine& a, const ProfileReport::Routine& b) {
                  if (a.half_clocks != b.half_clocks) {
                      return a.half_clocks > b.half_clocks;
                  }
                  return a.name < b.name;
              });
}

/// Adds each call's total -- given every node's own time -- to the line of the
/// CALL that made it. `parents`, `sites` and `interrupts` describe the tree;
/// `self` and `idle` are per node, from whichever span is being told (the
/// whole profile, or one period).
void charge_calls_to_lines(const std::vector<uint32_t>& parents, const std::vector<uint16_t>& sites,
                           const std::vector<bool>& interrupts, const std::vector<uint64_t>& self,
                           const std::vector<uint64_t>& idle, const std::vector<RomSourcePtr>& active,
                           std::map<std::string, std::string>& paths,
                           std::vector<ProfileReport::Line>& lines) {
    const size_t count = parents.size();
    std::vector<uint64_t> total(self);
    std::vector<uint64_t> total_idle(idle);
    // A child always follows its parent, so one backwards pass sums subtrees.
    for (size_t i = count; i-- > 1;) {
        if (parents[i] < count) {
            total[parents[i]] += total[i];
            total_idle[parents[i]] += total_idle[i];
        }
    }

    std::map<uint16_t, std::pair<uint64_t, uint64_t>> by_site;
    for (size_t i = 1; i < count; i++) {
        if (interrupts[i] || total[i] == 0) {
            continue;
        }
        // The outermost call through this site only: one further in, reached
        // by recursion through the same CALL, is already inside this total.
        bool nested = false;
        for (uint32_t up = parents[i]; up != 0 && up < count; up = parents[up]) {
            if (!interrupts[up] && sites[up] == sites[i]) {
                nested = true;
                break;
            }
        }
        if (nested) {
            continue;
        }
        std::pair<uint64_t, uint64_t>& site = by_site[sites[i]];
        site.first += total[i];
        site.second += total_idle[i];
    }

    std::map<std::pair<std::string, uint32_t>, size_t> line_index;
    for (size_t i = 0; i < lines.size(); i++) {
        line_index.emplace(std::make_pair(lines[i].path, lines[i].line), i);
    }
    for (const auto& entry : by_site) {
        for (const RomSourcePtr& source : active) {
            auto it = source->addr_to_loc.find(entry.first);
            if (it == source->addr_to_loc.end() || it->second.file >= source->files.size()) {
                continue;
            }
            const std::string& path = absolute_path(source->files[it->second.file].path, paths);
            auto found = line_index.find(std::make_pair(path, it->second.line));
            if (found != line_index.end()) {
                lines[found->second].calls_half_clocks += entry.second.first;
                lines[found->second].calls_idle_half_clocks += entry.second.second;
            }
            break;
        }
    }
}

nlohmann::json lines_json(const std::vector<ProfileReport::Line>& lines, size_t max_lines,
                          bool with_hits) {
    using json = nlohmann::json;
    json out = json::array();
    for (size_t i = 0; i < lines.size(); i++) {
        if (max_lines != 0 && i >= max_lines) {
            break;
        }
        const ProfileReport::Line& l = lines[i];
        json item{{"path", l.path},
                  {"line", l.line},
                  {"tstates", tstates(l.half_clocks)},
                  {"idle_tstates", tstates(l.idle_half_clocks)},
                  {"symbol", l.symbol}};
        if (l.calls_half_clocks != 0) {
            item["calls_tstates"] = tstates(l.calls_half_clocks);
            item["calls_idle_tstates"] = tstates(l.calls_idle_half_clocks);
        }
        if (with_hits) {
            item["hits"] = l.hits;
        }
        out.push_back(item);
    }
    return out;
}

nlohmann::json routines_json(const std::vector<ProfileReport::Routine>& routines,
                             size_t max_routines, bool with_hits) {
    using json = nlohmann::json;
    json out = json::array();
    for (size_t i = 0; i < routines.size(); i++) {
        if (max_routines != 0 && i >= max_routines) {
            break;
        }
        const ProfileReport::Routine& r = routines[i];
        json item{{"name", r.name},
                  {"tstates", tstates(r.half_clocks)},
                  {"idle_tstates", tstates(r.idle_half_clocks)}};
        if (with_hits) {
            item["hits"] = r.hits;
        }
        if (!r.path.empty()) {
            item["path"] = r.path;
            item["line"] = r.line;
        }
        out.push_back(item);
    }
    return out;
}

} // namespace

std::vector<std::string> apply_profile_settings(Engine& engine, const Sources& sources,
                                                const ProfileSettings& settings) {
    std::vector<std::string> unresolved;
    ProfileOptions options;
    options.idle_map.assign(Profile::ADDRESSES, 0);
    for (const std::string& name : settings.idle) {
        uint16_t first = 0;
        uint16_t last = 0;
        if (!sources.routine_range(name, first, last) && !parse_page_range(name, first, last)) {
            unresolved.push_back(name);
            continue;
        }
        for (uint32_t a = first; a <= last; a++) {
            options.idle_map[a] = 1;
        }
    }

    options.period_marker = Profile::FRAME_PERIODS;
    if (!settings.period.empty() && settings.period != "frame") {
        uint16_t addr = 0;
        std::string error;
        if (sources.symbol_value(settings.period, addr)
            || sources.parse_address(settings.period, addr, error)) {
            options.period_marker = int32_t(addr);
        } else {
            unresolved.push_back(settings.period);
        }
    }

    engine.set_profile_options(std::move(options));
    std::lock_guard<std::mutex> lock(settings_mutex);
    settings_applied = settings;
    settings_unresolved = unresolved;
    return unresolved;
}

ProfileSettings current_profile_settings() {
    std::lock_guard<std::mutex> lock(settings_mutex);
    return settings_applied;
}

std::vector<std::string> unresolved_profile_settings() {
    std::lock_guard<std::mutex> lock(settings_mutex);
    return settings_unresolved;
}

ProfileReport build_profile_report(const ProfileSnapshot& snapshot, const Sources& sources) {
    ProfileReport report;
    report.totals = snapshot;
    report.totals.entries.clear();
    report.totals.call_nodes.clear();
    report.totals.periods.worst.clear();
    report.settings = current_profile_settings();
    report.unresolved = unresolved_profile_settings();

    const std::vector<RomSourcePtr> active = sources.active();
    std::map<std::string, std::string> paths;

    std::vector<AddressCost> costs;
    costs.reserve(snapshot.entries.size());
    for (const ProfileSnapshot::Entry& entry : snapshot.entries) {
        costs.push_back(AddressCost{entry.addr, entry.hits, entry.half_clocks, entry.idle_half_clocks});
    }
    fold_addresses(costs, active, paths, report.lines, report.routines, report.unmapped_half_clocks);

    // The call tree: each node named by the routine its call went to, and its
    // total added up from the leaves. A child always follows its parent, so
    // one backwards pass has every child's total ready before its parent's.
    report.call_nodes.reserve(snapshot.call_nodes.size());
    for (size_t i = 0; i < snapshot.call_nodes.size(); i++) {
        const Profile::CallNode& from = snapshot.call_nodes[i];
        ProfileReport::CallNode node;
        node.parent = from.parent;
        node.addr = from.addr;
        node.interrupt = from.interrupt;
        node.site = from.site;
        node.calls = from.calls;
        node.self_half_clocks = from.self_half_clocks;
        node.idle_half_clocks = from.idle_half_clocks;
        node.total_half_clocks = from.self_half_clocks;
        node.total_idle_half_clocks = from.idle_half_clocks;
        if (i == Profile::ROOT) {
            node.name = "(outside any call)";
        } else {
            node.name = hex4_dollar(from.addr);
            for (const RomSourcePtr& source : active) {
                auto it = source->addr_to_loc.find(from.addr);
                if (it == source->addr_to_loc.end() || it->second.file >= source->files.size()) {
                    continue;
                }
                std::string label;
                uint16_t offset = 0;
                if (source->code_label_at(from.addr, label, offset)) {
                    // A call lands on a routine's first line, which often
                    // carries a local label too (vid_buff_copy: / .row:) -- and
                    // it is the routine being called, not its loop.
                    if (offset == 0) {
                        const std::string routine = routine_of(label);
                        auto sym = source->symbols.find(routine);
                        if (sym != source->symbols.end() && sym->second == from.addr) {
                            label = routine;
                        }
                    }
                    node.name = offset == 0 ? label : label + "+" + std::to_string(offset);
                }
                node.path = absolute_path(source->files[it->second.file].path, paths);
                node.line = it->second.line;
                break;
            }
        }
        report.call_nodes.push_back(node);
    }
    for (size_t i = report.call_nodes.size(); i-- > 1;) {
        const uint32_t parent = report.call_nodes[i].parent;
        if (parent < report.call_nodes.size()) {
            report.call_nodes[parent].total_half_clocks += report.call_nodes[i].total_half_clocks;
            report.call_nodes[parent].total_idle_half_clocks +=
                report.call_nodes[i].total_idle_half_clocks;
        }
    }

    // The tree's shape, for charging calls to their CALL lines -- once with
    // the whole profile's time, and again below with each worst period's.
    const size_t node_count = snapshot.call_nodes.size();
    std::vector<uint32_t> parents(node_count);
    std::vector<uint16_t> sites(node_count);
    std::vector<bool> interrupts(node_count);
    std::vector<uint64_t> self(node_count);
    std::vector<uint64_t> idle(node_count);
    for (size_t i = 0; i < node_count; i++) {
        parents[i] = snapshot.call_nodes[i].parent;
        sites[i] = snapshot.call_nodes[i].site;
        interrupts[i] = snapshot.call_nodes[i].interrupt;
        self[i] = snapshot.call_nodes[i].self_half_clocks;
        idle[i] = snapshot.call_nodes[i].idle_half_clocks;
    }
    charge_calls_to_lines(parents, sites, interrupts, self, idle, active, paths, report.lines);

    // The busiest periods, each folded the same way.
    for (const Profile::WorstPeriod& w : snapshot.periods.worst) {
        ProfileReport::Period period;
        period.index = w.index;
        period.start_frame = w.cost.start_frame;
        period.half_clocks = w.cost.half_clocks;
        period.idle_half_clocks = w.cost.idle_half_clocks;
        std::vector<AddressCost> period_costs;
        period_costs.reserve(w.addresses.size());
        for (const Profile::WorstPeriod::Share& share : w.addresses) {
            period_costs.push_back(
                AddressCost{uint16_t(share.id), 0, share.half_clocks, share.idle_half_clocks});
        }
        fold_addresses(period_costs, active, paths, period.lines, period.routines,
                       period.unmapped_half_clocks);
        std::vector<uint64_t> period_self(node_count, 0);
        std::vector<uint64_t> period_idle(node_count, 0);
        for (const Profile::WorstPeriod::Share& share : w.nodes) {
            if (share.id < node_count) {
                period_self[share.id] = share.half_clocks;
                period_idle[share.id] = share.idle_half_clocks;
            }
        }
        charge_calls_to_lines(parents, sites, interrupts, period_self, period_idle, active, paths,
                              period.lines);
        period.nodes = w.nodes;
        report.worst.push_back(std::move(period));
    }
    return report;
}

nlohmann::json profile_report_json(const ProfileReport& report, size_t max_lines,
                                   size_t max_routines, bool worst_nodes) {
    using json = nlohmann::json;
    const ProfileSnapshot& t = report.totals;

    json out{{"active", t.active},
             {"frames", t.frames},
             {"instructions", t.instructions},
             {"interrupts", t.interrupts},
             {"tstates", tstates(t.total_half_clocks)},
             {"idle_tstates", tstates(t.idle_half_clocks)},
             {"busy_tstates", tstates(t.total_half_clocks - t.idle_half_clocks)},
             {"interrupt_tstates", tstates(t.interrupt_half_clocks)},
             {"unmapped_tstates", tstates(report.unmapped_half_clocks)},
             {"frame_tstates", tstates(t.frame_half_clocks)},
             {"lines_total", report.lines.size()},
             {"routines_total", report.routines.size()},
             {"idle", report.settings.idle},
             {"unresolved", report.unresolved}};
    if (t.frames != 0) {
        out["tstates_per_frame"] = tstates(t.total_half_clocks) / double(t.frames);
        out["busy_tstates_per_frame"] =
            tstates(t.total_half_clocks - t.idle_half_clocks) / double(t.frames);
    }
    out["lines"] = lines_json(report.lines, max_lines, true);
    out["routines"] = routines_json(report.routines, max_routines, true);

    const Profile::PeriodSummary& p = t.periods;
    json strip = json::array();
    for (uint64_t busy : p.strip) {
        strip.push_back(tstates(busy));
    }
    json periods{{"by", p.marker == Profile::FRAME_PERIODS ? "frame" : "marker"},
                 {"count", p.count},
                 {"tstates", tstates(p.half_clocks)},
                 {"idle_tstates", tstates(p.idle_half_clocks)},
                 {"busiest_tstates", tstates(p.busiest)},
                 {"without_idle", p.without_idle},
                 {"bucket", p.bucket},
                 {"strip", strip}};
    if (p.marker != Profile::FRAME_PERIODS) {
        periods["marker"] = p.marker;
        periods["name"] = report.settings.period;
    }
    if (p.count != 0) {
        periods["busy_tstates_average"] = tstates(p.half_clocks - p.idle_half_clocks) / double(p.count);
    }

    json worst = json::array();
    for (const ProfileReport::Period& period : report.worst) {
        json item{{"index", period.index},
                  {"start_frame", period.start_frame},
                  {"tstates", tstates(period.half_clocks)},
                  {"idle_tstates", tstates(period.idle_half_clocks)},
                  {"busy_tstates", tstates(period.half_clocks - period.idle_half_clocks)},
                  {"unmapped_tstates", tstates(period.unmapped_half_clocks)},
                  {"lines_total", period.lines.size()},
                  {"lines", lines_json(period.lines, max_lines, false)},
                  {"routines", routines_json(period.routines, max_routines, false)}};
        if (t.frame_half_clocks != 0) {
            item["frames"] = double(period.half_clocks) / double(t.frame_half_clocks);
        }
        if (worst_nodes) {
            json nodes = json::array();
            for (const Profile::WorstPeriod::Share& share : period.nodes) {
                nodes.push_back(json::array(
                    {share.id, tstates(share.half_clocks), tstates(share.idle_half_clocks)}));
            }
            item["nodes"] = nodes;
        }
        worst.push_back(item);
    }
    periods["worst"] = worst;
    out["periods"] = periods;
    return out;
}

nlohmann::json profile_call_nodes_json(const ProfileReport& report) {
    using json = nlohmann::json;
    json nodes = json::array();
    for (size_t i = 0; i < report.call_nodes.size(); i++) {
        const ProfileReport::CallNode& n = report.call_nodes[i];
        json item{{"id", i},
                  {"name", n.name},
                  {"addr", n.addr},
                  {"site", n.site},
                  {"interrupt", n.interrupt},
                  {"calls", n.calls},
                  {"self_tstates", tstates(n.self_half_clocks)},
                  {"idle_tstates", tstates(n.idle_half_clocks)},
                  {"tstates", tstates(n.total_half_clocks)}};
        item["parent"] = n.parent == Profile::NO_PARENT ? json(nullptr) : json(n.parent);
        if (!n.path.empty()) {
            item["path"] = n.path;
            item["line"] = n.line;
        }
        nodes.push_back(item);
    }
    return nodes;
}

namespace {

nlohmann::json call_subtree_json(const ProfileReport& report,
                                 const std::vector<std::vector<uint32_t>>& children,
                                 uint32_t id, uint64_t min_half_clocks, size_t depth_left) {
    using json = nlohmann::json;
    const ProfileReport::CallNode& n = report.call_nodes[id];
    json item{{"name", n.name},
              {"calls", n.calls},
              {"tstates", tstates(n.total_half_clocks)},
              {"self_tstates", tstates(n.self_half_clocks)}};
    if (n.idle_half_clocks != 0) {
        item["idle_tstates"] = tstates(n.idle_half_clocks);
    }
    if (n.interrupt) {
        item["interrupt"] = true;
    }
    std::vector<uint32_t> kids = children[id];
    std::sort(kids.begin(), kids.end(), [&report](uint32_t a, uint32_t b) {
        return report.call_nodes[a].total_half_clocks > report.call_nodes[b].total_half_clocks;
    });
    json list = json::array();
    uint64_t dropped = 0;
    for (uint32_t kid : kids) {
        const uint64_t cost = report.call_nodes[kid].total_half_clocks;
        if (depth_left == 0 || cost < min_half_clocks) {
            dropped += cost;
            continue;
        }
        list.push_back(call_subtree_json(report, children, kid, min_half_clocks, depth_left - 1));
    }
    if (!list.empty()) {
        item["children"] = list;
    }
    if (dropped != 0) {
        item["other_calls_tstates"] = tstates(dropped);
    }
    return item;
}

} // namespace

nlohmann::json profile_call_tree_json(const ProfileReport& report, double min_share,
                                      size_t max_depth) {
    if (report.call_nodes.empty()) {
        return nullptr;
    }
    std::vector<std::vector<uint32_t>> children(report.call_nodes.size());
    for (size_t i = 1; i < report.call_nodes.size(); i++) {
        const uint32_t parent = report.call_nodes[i].parent;
        if (parent < report.call_nodes.size()) {
            children[parent].push_back(uint32_t(i));
        }
    }
    const uint64_t min_half_clocks =
        uint64_t(double(report.call_nodes[Profile::ROOT].total_half_clocks) * min_share);
    return call_subtree_json(report, children, Profile::ROOT, min_half_clocks, max_depth);
}

} // namespace zx
