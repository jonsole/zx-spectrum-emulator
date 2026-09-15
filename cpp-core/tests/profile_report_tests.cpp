// A profile folded into source lines and routines -- what the editor's heat
// map and the MCP `profile` tool both show.
//
// No machine here: a handful of SLD records and a hand-made snapshot are the
// whole input, so each expected total can be added up by eye.

#include "profile_report.h"
#include "test_main.h"

#include <fstream>
#include <string>

using namespace zx;

namespace {

/// sjasmplus SLD: file|line|def_file|def_line|page|address|type|data.
///
///   32768 line 10  draw:        a routine
///   32770 line 11               inside it -- with an EQU (VIEW = 32769)
///                               sitting nearer below it than the label is,
///                               and another (KEYS = 32770) whose value is
///                               this very instruction's address
///   32772 line 12  draw.loop:   a local label, still part of draw
///   32800 line 20  other:       another routine, whose first line is also
///                  .top:        a local label
const char* const SLD_TEXT =
    "main.s|10|main.s|10|0|32768|T|\n"
    "main.s|10|main.s|10|0|32768|F|draw\n"
    "main.s|11|main.s|11|0|32770|T|\n"
    "main.s|5|main.s|5|0|32769|D|VIEW\n"
    "main.s|6|main.s|6|0|32770|D|KEYS\n"
    "main.s|12|main.s|12|0|32772|T|\n"
    "main.s|12|main.s|12|0|32772|F|draw.loop\n"
    "main.s|20|main.s|20|0|32800|T|\n"
    "main.s|20|main.s|20|0|32800|F|other\n"
    "main.s|20|main.s|20|0|32800|F|other.top\n";

void load(Sources& sources) {
    const std::string path = "zx_test_profile.sld";
    {
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        out << SLD_TEXT;
    }
    std::string error;
    CHECK(sources.load_debug_info(path, "main.s", error));
}

void add(ProfileSnapshot& s, uint16_t addr, uint64_t hits, uint64_t half_clocks) {
    ProfileSnapshot::Entry e;
    e.addr = addr;
    e.hits = hits;
    e.half_clocks = half_clocks;
    s.entries.push_back(e);
    s.instructions += hits;
    s.total_half_clocks += half_clocks;
}

ProfileSnapshot snapshot() {
    ProfileSnapshot s;
    s.active = true;
    s.frames = 2;
    add(s, 32768, 1, 14);
    add(s, 32770, 5, 40);
    add(s, 32772, 10, 260);
    add(s, 32800, 1, 20);
    // No source anywhere: grouped by page.
    add(s, 0x9005, 2, 30);
    add(s, 0x90F0, 1, 10);
    return s;
}

bool ends_with(const std::string& s, const std::string& tail) {
    return s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

} // namespace

TEST(lines_are_most_expensive_first_and_named_by_their_routine) {
    Sources sources("no-rom-here");
    load(sources);
    const ProfileReport report = build_profile_report(snapshot(), sources);

    CHECK_EQ(report.lines.size(), size_t(4));
    CHECK_EQ(report.lines[0].line, uint32_t(12));
    CHECK_EQ(report.lines[0].half_clocks, uint64_t(260));
    CHECK_EQ(report.lines[0].symbol, std::string("draw.loop"));
    CHECK_EQ(report.lines[1].line, uint32_t(11));
    // Not VIEW+1, nor KEYS: an EQU is a number, not a place in the code --
    // even when the number is this instruction's address.
    CHECK_EQ(report.lines[1].symbol, std::string("draw+2"));
    CHECK_EQ(report.lines[2].line, uint32_t(20));
    CHECK_EQ(report.lines[3].line, uint32_t(10));
    CHECK(ends_with(report.lines[0].path, "main.s"));
    CHECK_EQ(report.unmapped_half_clocks, uint64_t(40));
}

TEST(a_routine_adds_up_its_locals_and_unsourced_code_goes_by_page) {
    Sources sources("no-rom-here");
    load(sources);
    const ProfileReport report = build_profile_report(snapshot(), sources);

    CHECK_EQ(report.routines.size(), size_t(3));
    CHECK_EQ(report.routines[0].name, std::string("draw"));
    CHECK_EQ(report.routines[0].half_clocks, uint64_t(14 + 40 + 260));
    CHECK_EQ(report.routines[0].hits, uint64_t(16));
    CHECK_EQ(report.routines[0].line, uint32_t(10));
    CHECK_EQ(report.routines[1].name, std::string("$9000-$90FF"));
    CHECK_EQ(report.routines[1].half_clocks, uint64_t(40));
    CHECK(report.routines[1].path.empty());
    CHECK_EQ(report.routines[2].name, std::string("other"));
}

TEST(the_json_is_cut_but_says_how_much_there_was) {
    Sources sources("no-rom-here");
    load(sources);
    const nlohmann::json j =
        profile_report_json(build_profile_report(snapshot(), sources), 2, 1, false);

    CHECK_EQ(j["lines"].size(), size_t(2));
    CHECK_EQ(j["lines_total"].get<size_t>(), size_t(4));
    CHECK_EQ(j["routines"].size(), size_t(1));
    CHECK_EQ(j["routines_total"].get<size_t>(), size_t(3));
    CHECK_EQ(j["lines"][0]["tstates"].get<double>(), 130.0);
    CHECK_EQ(j["tstates"].get<double>(), 187.0);
    CHECK_EQ(j["tstates_per_frame"].get<double>(), 93.5);
    CHECK(!j["routines"][0]["path"].get<std::string>().empty());
}

namespace {

Profile::CallNode call_node(uint32_t parent, uint16_t addr, uint64_t calls, uint64_t self) {
    Profile::CallNode n;
    n.parent = parent;
    n.addr = addr;
    n.calls = calls;
    n.self_half_clocks = self;
    return n;
}

/// root (10) -> draw (100, x2) -> other (50)
///           -> $9005 (5), an interrupt handler with no source
ProfileSnapshot with_tree() {
    ProfileSnapshot s = snapshot();
    s.call_nodes.push_back(call_node(Profile::NO_PARENT, 0, 0, 10));
    s.call_nodes.push_back(call_node(0, 32768, 2, 100));
    s.call_nodes.push_back(call_node(1, 32800, 6, 50));
    Profile::CallNode handler = call_node(0, 0x9005, 3, 5);
    handler.interrupt = true;
    s.call_nodes.push_back(handler);
    return s;
}

} // namespace

TEST(call_nodes_are_named_by_routine_and_total_their_subtrees) {
    Sources sources("no-rom-here");
    load(sources);
    const ProfileReport report = build_profile_report(with_tree(), sources);

    CHECK_EQ(report.call_nodes.size(), size_t(4));
    CHECK_EQ(report.call_nodes[0].name, std::string("(outside any call)"));
    CHECK_EQ(report.call_nodes[0].total_half_clocks, uint64_t(10 + 100 + 50 + 5));
    CHECK_EQ(report.call_nodes[1].name, std::string("draw"));
    CHECK_EQ(report.call_nodes[1].total_half_clocks, uint64_t(150));
    CHECK_EQ(report.call_nodes[1].line, uint32_t(10));
    CHECK(ends_with(report.call_nodes[1].path, "main.s"));
    // Not other.top: a call goes to the routine, whatever else labels its first line.
    CHECK_EQ(report.call_nodes[2].name, std::string("other"));
    CHECK_EQ(report.call_nodes[3].name, std::string("$9005"));
    CHECK(report.call_nodes[3].path.empty());

    const nlohmann::json flat = profile_call_nodes_json(report);
    CHECK(flat[0]["parent"].is_null());
    CHECK_EQ(flat[2]["parent"].get<uint32_t>(), uint32_t(1));
    CHECK_EQ(flat[1]["tstates"].get<double>(), 75.0);
    CHECK_EQ(flat[1]["self_tstates"].get<double>(), 50.0);
    CHECK(flat[3]["interrupt"].get<bool>());
}

TEST(the_nested_tree_is_cut_to_what_matters_and_says_what_it_cut) {
    Sources sources("no-rom-here");
    load(sources);
    const ProfileReport report = build_profile_report(with_tree(), sources);
    // 10% of 165 half-clocks is 16.5: the handler's 5 goes.
    const nlohmann::json tree = profile_call_tree_json(report, 0.10, 12);

    CHECK_EQ(tree["name"].get<std::string>(), std::string("(outside any call)"));
    CHECK_EQ(tree["children"].size(), size_t(1));
    CHECK_EQ(tree["children"][0]["name"].get<std::string>(), std::string("draw"));
    CHECK_EQ(tree["children"][0]["children"][0]["name"].get<std::string>(), std::string("other"));
    CHECK_EQ(tree["other_calls_tstates"].get<double>(), 2.5);
    // And by depth: one level only.
    const nlohmann::json shallow = profile_call_tree_json(report, 0.0, 1);
    CHECK(!shallow["children"][0].contains("children"));
    CHECK_EQ(shallow["children"][0]["other_calls_tstates"].get<double>(), 25.0);
}

TEST(a_routine_covers_its_locals_up_to_the_next_routine) {
    Sources sources("no-rom-here");
    load(sources);
    uint16_t first = 0;
    uint16_t last = 0;
    // draw.loop at 32772 is draw's own; VIEW (32769) is an EQU, not code.
    CHECK(sources.routine_range("draw", first, last));
    CHECK_EQ(int(first), 32768);
    CHECK_EQ(int(last), 32799);
    // The last routine runs to the last instruction.
    CHECK(sources.routine_range("other", first, last));
    CHECK_EQ(int(first), 32800);
    CHECK_EQ(int(last), 32800);
    CHECK(!sources.routine_range("VIEW", first, last));
    CHECK(!sources.routine_range("nosuch", first, last));
}

TEST(settings_resolve_by_name_and_say_what_did_not) {
    Sources sources("no-rom-here");
    load(sources);
    Engine engine;
    ProfileSettings settings;
    settings.idle = {"draw", "$9000-$90FF", "nosuch"};
    settings.period = "other";
    const std::vector<std::string> unresolved = apply_profile_settings(engine, sources, settings);
    CHECK_EQ(unresolved.size(), size_t(1));
    CHECK_EQ(unresolved[0], std::string("nosuch"));
    CHECK_EQ(current_profile_settings().period, std::string("other"));

    // Idle addresses are counted as idle from then on.
    engine.write_memory(32768, {0x00, 0x00});
    Registers regs{};
    regs.pc = 32768;
    regs.sp = 0xFF00;
    engine.set_registers(regs);
    engine.start_profile();
    engine.step(2);
    const ProfileSnapshot s = engine.profile_snapshot();
    CHECK_EQ(s.idle_half_clocks, s.total_half_clocks);
    CHECK(s.total_half_clocks > 0);

    settings.period = "no_such_routine";
    settings.idle.clear();
    CHECK_EQ(apply_profile_settings(engine, sources, settings).size(), size_t(1));
}

TEST(idle_time_is_carried_into_lines_and_routines) {
    Sources sources("no-rom-here");
    load(sources);
    ProfileSnapshot s = snapshot();
    s.entries[2].idle_half_clocks = 200; // 32772, draw.loop
    s.idle_half_clocks = 200;
    const ProfileReport report = build_profile_report(s, sources);
    CHECK_EQ(report.lines[0].idle_half_clocks, uint64_t(200));
    CHECK_EQ(report.routines[0].idle_half_clocks, uint64_t(200));
    const nlohmann::json j = profile_report_json(report, 0, 0, false);
    CHECK_EQ(j["busy_tstates"].get<double>(), 87.0);
    CHECK_EQ(j["lines"][0]["idle_tstates"].get<double>(), 100.0);
}

TEST(the_worst_periods_are_told_in_their_own_lines_and_routines) {
    Sources sources("no-rom-here");
    load(sources);
    ProfileSnapshot s = snapshot();
    s.frame_half_clocks = 139776;
    s.periods.count = 3;
    s.periods.strip = {1000, 5000, 2000};
    Profile::WorstPeriod w;
    w.index = 1;
    w.cost.start_frame = 42;
    w.cost.half_clocks = 139776;
    w.cost.idle_half_clocks = 134776;
    w.addresses.push_back(Profile::WorstPeriod::Share{32772, 3000, 0});
    w.addresses.push_back(Profile::WorstPeriod::Share{32800, 2000, 0});
    w.nodes.push_back(Profile::WorstPeriod::Share{0, 5000, 0});
    s.periods.worst.push_back(w);

    const ProfileReport report = build_profile_report(s, sources);
    CHECK_EQ(report.worst.size(), size_t(1));
    CHECK_EQ(report.worst[0].lines[0].line, uint32_t(12));
    CHECK_EQ(report.worst[0].routines[0].name, std::string("draw"));

    const nlohmann::json j = profile_report_json(report, 0, 0, true);
    const nlohmann::json& p = j["periods"];
    CHECK_EQ(p["by"].get<std::string>(), std::string("frame"));
    CHECK_EQ(p["strip"][1].get<double>(), 2500.0);
    CHECK_EQ(p["worst"][0]["busy_tstates"].get<double>(), 2500.0);
    CHECK_EQ(p["worst"][0]["frames"].get<double>(), 1.0);
    CHECK_EQ(p["worst"][0]["start_frame"].get<uint64_t>(), uint64_t(42));
    CHECK_EQ(p["worst"][0]["nodes"][0][1].get<double>(), 2500.0);
    // The whole profile's report is unchanged by carrying them.
    CHECK_EQ(j["lines"].size(), size_t(4));
}

TEST(with_no_debug_info_everything_is_by_page) {
    Sources sources("no-rom-here");
    const ProfileReport report = build_profile_report(snapshot(), sources);
    CHECK_EQ(report.lines.size(), size_t(0));
    CHECK_EQ(report.unmapped_half_clocks, uint64_t(14 + 40 + 260 + 20 + 30 + 10));
    CHECK_EQ(report.routines[0].name, std::string("$8000-$80FF"));
}

RUN_TESTS()
