// Address expressions: the "0x8000 or INT_HANDLER+60" parsing that the trace
// flags and the start_trace/stop_trace tools all take their addresses through.
//
// The two radix rules are the point of most of these cases. They are not
// arbitrary -- each matches how that kind of value is PRINTED elsewhere, so
// anything the emulator shows can be pasted straight back into it:
//
//   a bare number is HEX     the trace's AB column, the disassembly, --trace-watch
//   an offset is DECIMAL     the trace's Symbol column, which writes "KEY_INT+9"
//
// Nothing here needs a machine or a ROM: a handful of SLD records is enough to
// give Sources something to resolve against.

#include "rom_source.h"
#include "test_main.h"

#include <cstdio>
#include <fstream>
#include <string>

using namespace zx;

namespace {

/// sjasmplus SLD, one record per line:
///   file|line|def_file|def_line|page|address|type|data
/// F records are global labels, which is all this needs. BED is deliberately a
/// name spelt entirely in hex digits, and deliberately NOT at 0x0BED.
const char* const SLD_TEXT =
    "test.asm|10|test.asm|10|0|32768|F|INT_HANDLER\n"
    "test.asm|20|test.asm|20|0|33000|F|SPRITE\n"
    "test.asm|30|test.asm|30|0|100|F|BED\n";

std::string write_sld() {
    const std::string path = "zx_test_symbols.sld";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << SLD_TEXT;
    return path;
}

/// Attaches the records above. Filled in place rather than returned: Sources
/// holds a mutex, so it is neither copyable nor movable.
void load_symbols(Sources& sources) {
    std::string error;
    CHECK(sources.load_debug_info(write_sld(), "test.asm", error));
}

/// A program built the way a real one is: an entry source that INCLUDEs
/// others, so the same line numbers recur in every file. T records this time
/// -- they are what carries address<->line, and what a single flat line map
/// gets wrong. Line 40 exists in all three files at three different
/// addresses; line 50 only in two of them.
const char* const MULTI_SLD_TEXT =
    "main.s|40|main.s|40|0|32768|T|\n"
    "sprite.s|40|sprite.s|40|0|40000|T|\n"
    "sprite.s|50|sprite.s|50|0|40010|T|\n"
    "object.s|40|object.s|40|0|50000|T|\n"
    "object.s|50|object.s|50|0|50010|T|\n";

std::string write_multi_sld() {
    const std::string path = "zx_test_multifile.sld";
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << MULTI_SLD_TEXT;
    return path;
}

/// The parse, or 0xFFFF plus a printed reason on failure -- so a case can be
/// written as one CHECK_EQ.
uint16_t parsed(const Sources& sources, const char* text) {
    uint16_t addr = 0;
    std::string error;
    if (!sources.parse_address(text, addr, error)) {
        std::printf("      (%s did not parse: %s)\n", text, error.c_str());
        return 0xFFFF;
    }
    return addr;
}

} // namespace

TEST(a_symbol_resolves_to_its_own_address) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    CHECK_EQ(parsed(sources, "INT_HANDLER"), uint16_t(0x8000));
    CHECK_EQ(parsed(sources, "SPRITE"), uint16_t(33000));
    // Whitespace around it is the caller's, not the symbol's.
    CHECK_EQ(parsed(sources, "  INT_HANDLER  "), uint16_t(0x8000));
    // Typing a label in the wrong case is not an interesting mistake.
    CHECK_EQ(parsed(sources, "int_handler"), uint16_t(0x8000));
    CHECK_EQ(parsed(sources, "Int_Handler"), uint16_t(0x8000));
}

TEST(an_offset_after_a_symbol_is_decimal) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    // 60, not 0x60 -- this is the form the trace's Symbol column prints, and
    // it prints the offset in decimal.
    CHECK_EQ(parsed(sources, "INT_HANDLER+60"), uint16_t(0x8000 + 60));
    CHECK_EQ(parsed(sources, "INT_HANDLER-2"), uint16_t(0x8000 - 2));
    CHECK_EQ(parsed(sources, "INT_HANDLER + 60"), uint16_t(0x8000 + 60));
    // ...unless it says otherwise.
    CHECK_EQ(parsed(sources, "INT_HANDLER+0x60"), uint16_t(0x8060));
    CHECK_EQ(parsed(sources, "INT_HANDLER+$60"), uint16_t(0x8060));
    // Terms chain, which mostly falls out of the parser being a loop -- but
    // the distance between two labels is a genuinely useful thing to write.
    CHECK_EQ(parsed(sources, "INT_HANDLER+8-2"), uint16_t(0x8006));
    CHECK_EQ(parsed(sources, "SPRITE-INT_HANDLER"), uint16_t(33000 - 0x8000));
}

TEST(a_bare_number_is_hex) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    // Every one of these is 0x0038: the form the AB column prints, the form
    // the disassembler prints, and the form --trace-watch has always taken.
    CHECK_EQ(parsed(sources, "0038"), uint16_t(0x0038));
    CHECK_EQ(parsed(sources, "0x0038"), uint16_t(0x0038));
    CHECK_EQ(parsed(sources, "0X38"), uint16_t(0x0038));
    CHECK_EQ(parsed(sources, "$0038"), uint16_t(0x0038));
    // Not a symbol, so it falls through to being a number -- which is what
    // keeps a plain hex address working whatever letters it happens to have.
    CHECK_EQ(parsed(sources, "F000"), uint16_t(0xF000));
}

TEST(a_label_spelt_in_hex_digits_is_still_a_label) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    // BED is a symbol at 100, and the symbol table is asked first.
    CHECK_EQ(parsed(sources, "BED"), uint16_t(100));
    CHECK_EQ(parsed(sources, "BED+4"), uint16_t(104));
    // The number is still reachable, by saying so.
    CHECK_EQ(parsed(sources, "0xBED"), uint16_t(0x0BED));
}

TEST(arithmetic_wraps_at_64k_rather_than_failing) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    // Two bytes below 0x0000 is 0xFFFE, the same wrap the CPU does.
    CHECK_EQ(parsed(sources, "0x0000-2"), uint16_t(0xFFFE));
    CHECK_EQ(parsed(sources, "0xFFFF+1"), uint16_t(0x0000));
}

TEST(what_cannot_be_resolved_says_why) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    uint16_t addr = 0;
    std::string error;

    CHECK(!sources.parse_address("NOT_A_LABEL", addr, error));
    CHECK(error.find("NOT_A_LABEL") != std::string::npos);
    CHECK(error.find("no symbol named") != std::string::npos);

    // A dangling operator, rather than silently meaning the symbol itself.
    CHECK(!sources.parse_address("INT_HANDLER+", addr, error));
    CHECK(!sources.parse_address("", addr, error));

    // An offset written in hex without saying so. The message has to name the
    // fix, because the value LOOKS like it should work.
    CHECK(!sources.parse_address("INT_HANDLER+1A", addr, error));
    CHECK(error.find("0x1A") != std::string::npos);

    // Digits that are not even hex.
    CHECK(!sources.parse_address("0xZZ", addr, error));
}

TEST(with_no_debug_info_a_number_still_works_and_a_name_explains_itself) {
    Sources sources("no_such_directory");
    uint16_t addr = 0;
    std::string error;

    CHECK(sources.parse_address("0x4000", addr, error));
    CHECK_EQ(addr, uint16_t(0x4000));
    CHECK(sources.parse_address("4000", addr, error));
    CHECK_EQ(addr, uint16_t(0x4000));

    // "no symbol named X" would be misleading when there is no symbol table
    // at all: the fix is to load one, not to spell it differently.
    CHECK(!sources.parse_address("INT_HANDLER", addr, error));
    CHECK(error.find("no debug info loaded") != std::string::npos);
}

TEST(matching_offers_names_by_prefix_ignoring_case) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    bool more = true;

    // Alphabetical within a source, which is the order they are offered in.
    std::vector<SymbolMatch> matches = sources.match_symbols("S", 10, more);
    CHECK_EQ(matches.size(), size_t(1));
    CHECK_EQ(matches[0].name, std::string("SPRITE"));
    CHECK_EQ(matches[0].addr, uint16_t(33000));
    CHECK(!more);

    // Typed in lower case, as anyone reaching for a completion would.
    matches = sources.match_symbols("int_h", 10, more);
    CHECK_EQ(matches.size(), size_t(1));
    CHECK_EQ(matches[0].name, std::string("INT_HANDLER"));

    // An empty prefix is every name, so a field just focused has a starting
    // point rather than nothing.
    matches = sources.match_symbols("", 10, more);
    CHECK_EQ(matches.size(), size_t(3));
    CHECK_EQ(matches[0].name, std::string("BED"));

    matches = sources.match_symbols("NOT_A_LABEL", 10, more);
    CHECK_EQ(matches.size(), size_t(0));
    CHECK(!more);
}

TEST(matching_stops_at_the_limit_and_says_there_was_more) {
    Sources sources("no_such_directory");
    load_symbols(sources);
    bool more = false;

    std::vector<SymbolMatch> matches = sources.match_symbols("", 2, more);
    CHECK_EQ(matches.size(), size_t(2));
    // The difference between a short list and a complete one -- a dropdown
    // that silently drops the name being typed is worse than one that says
    // "keep typing".
    CHECK(more);

    matches = sources.match_symbols("", 0, more);
    CHECK_EQ(matches.size(), size_t(0));
}

TEST(matching_with_no_debug_info_offers_nothing_rather_than_failing) {
    Sources sources("no_such_directory");
    bool more = true;
    CHECK_EQ(sources.match_symbols("", 10, more).size(), size_t(0));
    CHECK(!more);
}

TEST(a_line_number_resolves_against_the_file_it_was_clicked_in) {
    Sources sources("no_such_directory");
    std::string error;
    CHECK(sources.load_debug_info(write_multi_sld(), "src/main.s", error));

    // Three files each have a line 40. Before per-file line maps these all
    // collapsed into one entry and every one of them answered 0x8000.
    const struct {
        const char* path;
        uint16_t addr;
    } cases[] = {
        {"src/main.s", 32768},
        {"src/sprite.s", 40000},
        {"src/object.s", 50000},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        size_t file = 0;
        RomSourcePtr source = sources.source_for_path(cases[i].path, file);
        CHECK(source != nullptr);
        uint16_t addr = 0;
        uint32_t actual_line = 0;
        CHECK(source->addr_for_line(file, 40, addr, actual_line));
        CHECK_EQ(addr, cases[i].addr);
        CHECK_EQ(actual_line, uint32_t(40));
    }
}

TEST(an_address_reports_the_file_it_came_from) {
    Sources sources("no_such_directory");
    std::string error;
    CHECK(sources.load_debug_info(write_multi_sld(), "src/main.s", error));
    RomSourcePtr source = sources.debug_info();
    CHECK(source != nullptr);

    // What a stack frame is built from: an INCLUDEd file's address has to name
    // that file, not the entry source it was assembled through.
    auto it = source->addr_to_loc.find(uint16_t(50010));
    CHECK(it != source->addr_to_loc.end());
    CHECK_EQ(it->second.line, uint32_t(50));
    CHECK_EQ(source->files[it->second.file].sld_name, std::string("object.s"));

    // INCLUDEs are resolved beside the entry .asm, which is the only anchor
    // the SLD's bare file names have.
    CHECK_EQ(source->files[it->second.file].path, std::string("src/object.s"));

    // The entry source is files[0] even though sprite.s and object.s also
    // appear, and its path is exactly what the caller passed in.
    CHECK_EQ(source->files[0].path, std::string("src/main.s"));
    CHECK_EQ(source->instruction_count(), size_t(5));
}

TEST(a_file_the_program_does_not_include_resolves_to_nothing) {
    Sources sources("no_such_directory");
    std::string error;
    CHECK(sources.load_debug_info(write_multi_sld(), "src/main.s", error));

    // A breakpoint set in some other open file must come back unverified
    // rather than landing on whatever line 40 happened to map to.
    size_t file = 0;
    CHECK(sources.source_for_path("src/unrelated.s", file) == nullptr);
}

RUN_TESTS()
