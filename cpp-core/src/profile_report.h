#pragma once
// A profile, told in source lines and routines rather than addresses.
//
// The Engine counts by address because that is all the machine knows. What a
// person optimising a program wants is "line 212 of sprite.s is a fifth of the
// frame" and "sprite_blit is 40% of it" -- so this folds a ProfileSnapshot
// through the loaded SLD debug info (the program's own, then the ROM's), the
// same way a stack frame is given its source line.
//
// It also owns the profile's settings as names -- which routines are idle,
// and which routine's arrival starts a period -- and resolves them into the
// addresses the Engine counts with. The names are kept server-wide, so a
// report says what it was measured against whichever client set them.
//
// Shared by the DAP `profile` request and the MCP `profile` tool, so both
// report one shape.

#include "engine.h"
#include "rom_source.h"

#include <nlohmann/json.hpp>

#include <cstdint>
#include <string>
#include <vector>

namespace zx {

/// What a profile treats as idle and counts in periods of, by name.
struct ProfileSettings {
    /// Routine names ("turn_pace"), or a page of unsourced code as the
    /// report names one ("$9000-$90FF").
    std::vector<std::string> idle;
    /// A routine name or address expression whose arrival starts each period,
    /// or empty for video frames.
    std::string period;
};

/// Resolves `settings` against the loaded debug info, hands the result to the
/// Engine, and remembers the names. Returns the names that resolved to
/// nothing, which are left out (an unresolvable period means frames).
std::vector<std::string> apply_profile_settings(Engine& engine, const Sources& sources,
                                                const ProfileSettings& settings);

/// The settings last applied, and what of them did not resolve.
ProfileSettings current_profile_settings();
std::vector<std::string> unresolved_profile_settings();

struct ProfileReport {
    /// One source line with code on it that ran.
    struct Line {
        /// Absolute, as the SLD's source resolves it -- the path a client opens.
        std::string path;
        uint32_t line = 0;
        uint64_t hits = 0;
        uint64_t half_clocks = 0;
        uint64_t idle_half_clocks = 0;
        /// For a CALL line, the time its calls took -- everything the routines
        /// it called did, down the whole call path -- on top of its own. A call
        /// that recurses back through the same line is counted once, from its
        /// outermost call, and a call still running counts what it has done.
        uint64_t calls_half_clocks = 0;
        uint64_t calls_idle_half_clocks = 0;
        /// The routine and offset of the line's first address, "sprite_blit+12".
        std::string symbol;
    };
    /// Every line of a routine, added up. A routine runs from its label to
    /// the next label on a line of code; a local label (.loop) belongs to the
    /// routine above it. Code with no source at all is grouped by 256-byte
    /// page, named "$8000-$80FF", so a program without an SLD still shows
    /// where its time goes.
    struct Routine {
        std::string name;
        /// Where the routine's label is, when it has a source line.
        std::string path;
        uint32_t line = 0;
        uint64_t hits = 0;
        uint64_t half_clocks = 0;
        uint64_t idle_half_clocks = 0;
    };

    /// One node of the calling-context tree (see profile.h), named.
    struct CallNode {
        uint32_t parent = Profile::NO_PARENT;
        /// The routine the call went to, "sprite_blit" -- or "$8123" with no
        /// source, and "(outside any call)" for the root.
        std::string name;
        uint16_t addr = 0;
        bool interrupt = false;
        /// The CALL that entered this path (see Profile::CallNode::site).
        uint16_t site = 0;
        /// Where the routine's label is, when it has a source line.
        std::string path;
        uint32_t line = 0;
        uint64_t calls = 0;
        uint64_t self_half_clocks = 0;
        uint64_t idle_half_clocks = 0;
        /// Its own time and all of its children's, and the idle part of that.
        uint64_t total_half_clocks = 0;
        uint64_t total_idle_half_clocks = 0;
    };

    /// One of the busiest periods, told the same way as the whole profile:
    /// its lines and routines (with no hit counts -- a period keeps only
    /// time), and its own time on each call node.
    struct Period {
        uint64_t index = 0;
        uint64_t start_frame = 0;
        uint64_t half_clocks = 0;
        uint64_t idle_half_clocks = 0;
        uint64_t unmapped_half_clocks = 0;
        std::vector<Line> lines;
        std::vector<Routine> routines;
        std::vector<Profile::WorstPeriod::Share> nodes;
    };

    ProfileSnapshot totals; // entries, nodes and worst emptied: the lists below replace them
    /// Time spent at addresses no loaded source maps to a line.
    uint64_t unmapped_half_clocks = 0;
    /// Both sorted by half_clocks, most expensive first.
    std::vector<Line> lines;
    std::vector<Routine> routines;
    /// Root first, each node after its parent, as the profile keeps them.
    std::vector<CallNode> call_nodes;
    /// Busiest first.
    std::vector<Period> worst;
    ProfileSettings settings;
    std::vector<std::string> unresolved;
};

ProfileReport build_profile_report(const ProfileSnapshot& snapshot, const Sources& sources);

/// The report as JSON, cut to the `max_lines` and `max_routines` most
/// expensive (0 for all) -- the whole profile's and each worst period's
/// alike. T-states are halved half-clocks and so can end in .5. `lines_total`
/// and `routines_total` say how many there were before the cut, so a truncated
/// list does not pass for a complete one. `worst_nodes` adds each worst
/// period's time per call node, as [id, tstates, idle_tstates] triples.
nlohmann::json profile_report_json(const ProfileReport& report, size_t max_lines,
                                   size_t max_routines, bool worst_nodes);

/// The call tree as a flat array, root first: { id, parent, name, addr, site,
/// interrupt, path, line, calls, self_tstates, idle_tstates, tstates }. Every
/// node -- what the editor's tree view builds its own groupings from.
nlohmann::json profile_call_nodes_json(const ProfileReport& report);

/// The call tree nested, children most expensive first, cut to the nodes
/// holding at least `min_share` of all profiled time and to `max_depth` levels
/// below the root -- a size a reader can take in. Each node says how much time
/// its dropped children held, so the cut is visible.
nlohmann::json profile_call_tree_json(const ProfileReport& report, double min_share,
                                      size_t max_depth);

} // namespace zx
