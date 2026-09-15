#include "profile_report.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <map>
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

} // namespace

ProfileReport build_profile_report(const ProfileSnapshot& snapshot, const Sources& sources) {
    ProfileReport report;
    report.totals = snapshot;
    report.totals.entries.clear();
    report.totals.call_nodes.clear();

    const std::vector<RomSourcePtr> active = sources.active();

    // Keyed by (source, file, line): two programs' line 40s are different
    // lines, and so are two files' within one program.
    std::map<std::pair<const RomSource*, std::pair<size_t, uint32_t>>, size_t> line_index;
    // Keyed by source too: the ROM and a program can both have a START.
    std::map<std::pair<const RomSource*, std::string>, size_t> routine_index;
    std::map<std::string, std::string> paths;

    for (const ProfileSnapshot::Entry& entry : snapshot.entries) {
        // The first source with an EXACT mapping for the address owns it --
        // the rule build_frame uses, for the same reason: a nearest-label
        // match alone would hand ROM code to the program's last label.
        const RomSource* owner = nullptr;
        SourceLoc loc;
        for (const RomSourcePtr& source : active) {
            auto it = source->addr_to_loc.find(entry.addr);
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
            if (owner->code_label_at(entry.addr, label, offset)) {
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
                line_index.emplace(key, report.lines.size());
                report.lines.push_back(line);
                found = line_index.find(key);
            }
            ProfileReport::Line& line = report.lines[found->second];
            line.hits += entry.hits;
            line.half_clocks += entry.half_clocks;
        } else {
            report.unmapped_half_clocks += entry.half_clocks;
        }

        if (routine.empty()) {
            const uint16_t page = uint16_t(entry.addr & 0xFF00);
            routine = hex4_dollar(page) + "-" + hex4_dollar(uint16_t(page | 0x00FF));
        }
        const auto routine_key = std::make_pair(owner, routine);
        auto found = routine_index.find(routine_key);
        if (found == routine_index.end()) {
            ProfileReport::Routine r;
            r.name = routine;
            r.path = routine_path;
            r.line = routine_line;
            routine_index.emplace(routine_key, report.routines.size());
            report.routines.push_back(r);
            found = routine_index.find(routine_key);
        }
        ProfileReport::Routine& r = report.routines[found->second];
        r.hits += entry.hits;
        r.half_clocks += entry.half_clocks;
    }

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
        node.calls = from.calls;
        node.self_half_clocks = from.self_half_clocks;
        node.total_half_clocks = from.self_half_clocks;
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
        }
    }

    // Most expensive first; ties by where they are, so the order is stable
    // from one refresh to the next.
    std::sort(report.lines.begin(), report.lines.end(),
              [](const ProfileReport::Line& a, const ProfileReport::Line& b) {
                  if (a.half_clocks != b.half_clocks) {
                      return a.half_clocks > b.half_clocks;
                  }
                  if (a.path != b.path) {
                      return a.path < b.path;
                  }
                  return a.line < b.line;
              });
    std::sort(report.routines.begin(), report.routines.end(),
              [](const ProfileReport::Routine& a, const ProfileReport::Routine& b) {
                  if (a.half_clocks != b.half_clocks) {
                      return a.half_clocks > b.half_clocks;
                  }
                  return a.name < b.name;
              });
    return report;
}

nlohmann::json profile_report_json(const ProfileReport& report, size_t max_lines,
                                   size_t max_routines) {
    using json = nlohmann::json;
    const ProfileSnapshot& t = report.totals;

    json out{{"active", t.active},
             {"frames", t.frames},
             {"instructions", t.instructions},
             {"interrupts", t.interrupts},
             {"tstates", tstates(t.total_half_clocks)},
             {"interrupt_tstates", tstates(t.interrupt_half_clocks)},
             {"unmapped_tstates", tstates(report.unmapped_half_clocks)},
             {"lines_total", report.lines.size()},
             {"routines_total", report.routines.size()}};
    if (t.frames != 0) {
        out["tstates_per_frame"] = tstates(t.total_half_clocks) / double(t.frames);
    }

    json lines = json::array();
    for (size_t i = 0; i < report.lines.size(); i++) {
        if (max_lines != 0 && i >= max_lines) {
            break;
        }
        const ProfileReport::Line& l = report.lines[i];
        lines.push_back(json{{"path", l.path},
                             {"line", l.line},
                             {"hits", l.hits},
                             {"tstates", tstates(l.half_clocks)},
                             {"symbol", l.symbol}});
    }
    out["lines"] = lines;

    json routines = json::array();
    for (size_t i = 0; i < report.routines.size(); i++) {
        if (max_routines != 0 && i >= max_routines) {
            break;
        }
        const ProfileReport::Routine& r = report.routines[i];
        json item{{"name", r.name}, {"hits", r.hits}, {"tstates", tstates(r.half_clocks)}};
        if (!r.path.empty()) {
            item["path"] = r.path;
            item["line"] = r.line;
        }
        routines.push_back(item);
    }
    out["routines"] = routines;
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
                  {"interrupt", n.interrupt},
                  {"calls", n.calls},
                  {"self_tstates", tstates(n.self_half_clocks)},
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
