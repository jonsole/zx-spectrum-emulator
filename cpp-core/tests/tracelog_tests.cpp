// Trace-log tests, checked against visualz80remix's own output.
//
// tests/data/visualz80_reference.txt is a real capture from
// https://floooh.github.io/visualz80remix/ of the small demo program below,
// saved from its Trace Log panel. This test runs the SAME program on this core
// and requires the two tables to agree cell for cell -- which makes it a
// cycle-accuracy test of the CPU as much as a formatting test of the writer.
// Every column is load-bearing: M1/MREQ/RFSH/RD/WR say which machine cycle is
// happening and in which half of which T-state, AB and DB say what was on the
// bus, and DB in particular only lines up if the read data appears exactly one
// half-clock after the request, as on real hardware.
//
// The program, recovered from the reference trace:
//
//     0000: 31 30 00   LD SP,0030h
//     0003: CD 08 00   CALL 0008h
//     0006: 18 FB      JR 0003h
//     0008: 21 0D 00   LD HL,000Dh
//     000B: 34         INC (HL)
//     000C: C9         RET
//     000D: 40         (the byte INC (HL) increments)
//
// It runs from ROM here, where writes are discarded, which sounds fatal for a
// program that pushes a return address and increments a byte -- but is not.
// The write CYCLES still happen on the bus identically, which is all the trace
// records; only the values read back later would differ. So the two locations
// that get written and then read (the stack slots at 002E/002F, and 000D) are
// pre-seeded with the values the reference has by the time it reads them, and
// the whole 64-T-state window reproduces exactly.

#include "engine.h"
#include "spectrum.h"
#include "test_main.h"
#include "tracelog.h"

#include <cctype>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

using namespace zx;

namespace {

/// T-states the reference capture covers.
constexpr uint32_t REFERENCE_TSTATES = 64;

std::vector<uint8_t> reference_program() {
    std::vector<uint8_t> rom(ROM_SIZE, 0);
    const uint8_t code[] = {
        0x31, 0x30, 0x00, // 0000  LD SP,0030h
        0xCD, 0x08, 0x00, // 0003  CALL 0008h
        0x18, 0xFB,       // 0006  JR 0003h
        0x21, 0x0D, 0x00, // 0008  LD HL,000Dh
        0x34,             // 000B  INC (HL)
        0xC9,             // 000C  RET
        0x40,             // 000D  data
    };
    for (size_t i = 0; i < sizeof code; i++) {
        rom[i] = code[i];
    }
    // What CALL's push would have left on the stack, had the stack been in
    // RAM: the return address 0006. RET reads it back at cycle 53-58.
    rom[0x002E] = 0x06;
    rom[0x002F] = 0x00;
    return rom;
}

/// Captures are written beside the test executable rather than into a system
/// temp directory -- getenv trips MSVC's deprecation warnings, which are
/// errors here, and a failed run leaving its trace where it ran is convenient
/// rather than a problem.
std::string temp_path(const char* name) {
    return std::string("zx_test_") + name;
}

std::vector<std::string> read_lines(const std::string& path) {
    std::vector<std::string> lines;
    std::ifstream f(path, std::ios::binary);
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
    }
    return lines;
}

/// Splits a table row on the box-drawing verticals and trims each cell, so
/// comparisons are about content rather than padding. Returns an empty vector
/// for a border line, which callers skip.
std::vector<std::string> cells_of(const std::string& line) {
    const std::string bar = "\xE2\x94\x82"; // U+2502
    std::vector<std::string> cells;
    if (line.compare(0, bar.size(), bar) != 0) {
        return cells;
    }
    size_t pos = bar.size();
    for (;;) {
        const size_t next = line.find(bar, pos);
        if (next == std::string::npos) {
            break;
        }
        std::string cell = line.substr(pos, next - pos);
        const size_t first = cell.find_first_not_of(' ');
        const size_t last = cell.find_last_not_of(' ');
        cells.push_back(first == std::string::npos ? std::string()
                                                   : cell.substr(first, last - first + 1));
        pos = next + bar.size();
    }
    return cells;
}

/// The header row's cells, so a comparison can name a column rather than an
/// index.
std::vector<std::string> header_of(const std::vector<std::string>& lines) {
    for (size_t i = 0; i < lines.size(); i++) {
        std::vector<std::string> cells = cells_of(lines[i]);
        if (!cells.empty() && cells[0] == "Cycle/h") {
            return cells;
        }
    }
    return std::vector<std::string>();
}

std::vector<std::vector<std::string>> data_rows(const std::vector<std::string>& lines) {
    std::vector<std::vector<std::string>> rows;
    for (size_t i = 0; i < lines.size(); i++) {
        std::vector<std::string> cells = cells_of(lines[i]);
        // Border lines give no cells; the header names columns rather than
        // carrying data and is recognisable by its first one.
        if (cells.empty() || cells[0] == "Cycle/h") {
            continue;
        }
        rows.push_back(cells);
    }
    return rows;
}

/// visualz80remix prints its operands as `0030h`; this disassembler prints
/// `0x0030`. Same value, same instruction -- normalising means the comparison
/// is of the two cores' behaviour rather than their punctuation.
std::string normalise_asm(const std::string& text) {
    std::string out;
    for (size_t i = 0; i < text.size(); i++) {
        if (text[i] == '0' && i + 1 < text.size() && (text[i + 1] == 'x' || text[i + 1] == 'X')) {
            i++; // skip the "0x"
            std::string digits;
            while (i + 1 < text.size() && std::isxdigit(uint8_t(text[i + 1])) != 0) {
                digits += text[++i];
            }
            out += digits + "h";
            continue;
        }
        out += text[i];
    }
    return out;
}

/// A cell this core is KNOWN to print differently from visualz80remix, keyed
/// by the reference's own cycle label and by column title.
///
/// Three things diverge, all of them sub-T-state and none observable to a
/// running program. Every one of M1, MREQ, IORQ, RD, WR, AB and the T-state
/// numbering itself agrees cell for cell across the whole capture, so the
/// machine-cycle structure is identical; what is left is WHEN, within a
/// T-state, three internal events happen:
///
///   RFSH  the real chip holds refresh asserted through T4L, this core
///         releases it half a T-state earlier at T4H. The one of the three
///         that is a genuine (if harmless today) inaccuracy: it shortens the
///         window in which a refresh address is live on the bus, which is
///         exactly the window 48K "snow" comes out of, so it will start to
///         matter once contention lands.
///   DB    on a memory WRITE the real chip drives the byte at T1L, this core
///         at T2H. Zilog's own timing diagram puts the data at the start of
///         T2, so the datasheet agrees with us and the die with neither.
///   PC    the real chip increments PC on the L phase, this core on the H
///         phase. Purely internal: PC is not a pin, and the ADDRESS it
///         produces reaches the bus at the same instant either way -- which
///         is why AB matches everywhere and PC does not.
///
/// Listed cell by cell rather than as a rule so that a change in EITHER
/// direction fails: a new divergence is not silently absorbed into a pattern,
/// and fixing one of these fails the test until its entries are removed.
struct KnownDifference {
    const char* cycle;
    const char* column;
};

constexpr KnownDifference KNOWN_DIFFERENCES[] = {
    {"4/1", "RFSH"},  {"14/1", "RFSH"}, {"31/1", "RFSH"}, {"41/1", "RFSH"},
    {"52/1", "RFSH"}, {"62/1", "RFSH"},

    {"25/1", "DB"},   {"28/0", "DB"},   {"28/1", "DB"},   {"46/1", "DB"},
    {"49/0", "DB"},   {"49/1", "DB"},

    {"5/0", "PC"},    {"8/0", "PC"},    {"11/0", "PC"},   {"15/0", "PC"},
    {"18/0", "PC"},   {"26/1", "PC"},   {"27/0", "PC"},   {"27/1", "PC"},
    {"28/0", "PC"},   {"32/0", "PC"},   {"35/0", "PC"},   {"38/0", "PC"},
    {"49/0", "PC"},   {"58/1", "PC"},   {"59/0", "PC"},   {"63/0", "PC"},
};

constexpr size_t KNOWN_DIFFERENCE_COUNT =
    sizeof KNOWN_DIFFERENCES / sizeof KNOWN_DIFFERENCES[0];

bool is_known_difference(const std::string& cycle, const std::string& column) {
    for (size_t i = 0; i < KNOWN_DIFFERENCE_COUNT; i++) {
        if (cycle == KNOWN_DIFFERENCES[i].cycle && column == KNOWN_DIFFERENCES[i].column) {
            return true;
        }
    }
    return false;
}

} // namespace

TEST(matches_visualz80_reference) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_reference.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 0; // bounded by the loop below instead
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;

    // One half-clock short of 64 whole T-states. Z80::set_registers() performs
    // the very first opcode fetch's T1H on a priming clock of its own, outside
    // the machine's clock loop, so that half-clock can never be recorded --
    // our table starts at the reference's SECOND row (1/1), and the counts
    // have to allow for it.
    for (uint32_t i = 0; i < REFERENCE_TSTATES * HC_PER_TSTATE - 1; i++) {
        machine.clock();
    }
    machine.trace = nullptr;
    log.close();

    const std::vector<std::string> our_lines = read_lines(path);
    const std::vector<std::string> their_lines =
        read_lines(std::string(ZX_PROJECT_ROOT)
                   + "/cpp-core/tests/data/visualz80_reference.txt");
    const std::vector<std::string> titles = header_of(their_lines);
    const std::vector<std::vector<std::string>> ours = data_rows(our_lines);
    const std::vector<std::vector<std::string>> theirs = data_rows(their_lines);
    CHECK(!theirs.empty());
    CHECK_EQ(titles.size(), size_t(12));
    CHECK_EQ(ours.size() + 1, theirs.size());

    size_t matched_known = 0;
    for (size_t i = 0; i < ours.size() && i + 1 < theirs.size(); i++) {
        const std::vector<std::string>& a = ours[i];
        const std::vector<std::string>& b = theirs[i + 1];
        CHECK_EQ(a.size(), b.size());
        if (a.size() != b.size()) {
            break;
        }
        for (size_t c = 0; c < a.size(); c++) {
            // The last column is the disassembly, the only one whose text
            // style differs between the two tools.
            const std::string mine = c + 1 == a.size() ? normalise_asm(a[c]) : a[c];
            if (is_known_difference(b[0], titles[c])) {
                matched_known++;
                if (mine == b[c]) {
                    std::printf("    %s / %s now AGREES with visualz80remix -- remove it "
                                "from KNOWN_DIFFERENCES\n",
                                b[0].c_str(), titles[c].c_str());
                }
                CHECK(mine != b[c]);
                continue;
            }
            if (mine != b[c]) {
                std::printf("    row %zu (cycle %s), column %s: ours '%s', theirs '%s'\n", i,
                            b[0].c_str(), titles[c].c_str(), mine.c_str(), b[c].c_str());
            }
            CHECK_EQ(mine, b[c]);
        }
    }
    // Every documented divergence was actually reached, so the list cannot rot
    // into entries that no longer name a real cell.
    CHECK_EQ(matched_known, KNOWN_DIFFERENCE_COUNT);
}

TEST(stops_itself_at_the_row_limit) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_limit.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 40;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;

    for (uint32_t i = 0; i < 500; i++) {
        machine.clock();
    }
    CHECK(!log.active()); // closed on its own, without anyone asking
    CHECK_EQ(log.rows(), uint64_t(40));

    // Three lines of table furniture (two borders and the header) before the
    // rows, and one closing border after them.
    const std::vector<std::string> lines = read_lines(path);
    CHECK_EQ(lines.size(), size_t(44));
    CHECK_EQ(data_rows(lines).size(), size_t(40));
}

TEST(extra_columns_add_the_48k_signals) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_extra.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 20;
    options.extra = true;
    options.watch = 0x000D; // the byte INC (HL) works on
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;
    for (uint32_t i = 0; i < 60; i++) {
        machine.clock();
    }

    const std::vector<std::string> lines = read_lines(path);
    const std::vector<std::string> header = header_of(lines);
    CHECK_EQ(header.size(), size_t(18));
    CHECK_EQ(header[7], std::string("HALT"));
    CHECK_EQ(header[10], std::string("NMI"));
    CHECK_EQ(header[14], std::string("Frame"));
    // A watched address titles its own column, so the file records where the
    // bytes came from.
    CHECK_EQ(header[16], std::string("000D"));

    const std::vector<std::vector<std::string>> rows = data_rows(lines);
    CHECK(!rows.empty());
    // The ULA holds INT low for the first 32 T-states of a frame, and this
    // capture starts at power-on -- so the very first rows must show it.
    CHECK_EQ(rows[0][9], std::string("INT"));
    CHECK_EQ(rows[0][16], std::string("40"));
}

TEST(symbols_name_the_instruction_and_annotate_operands) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_symbols.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 0;
    // Stands in for the SLD layer, which lives in zx_server and is not linked
    // here. The contract is all TraceLog knows: address in, "LABEL+n" or an
    // empty string out.
    options.resolve_symbol = [](uint16_t addr) {
        if (addr == 0x0008) { return std::string("INC_CELL"); }
        if (addr == 0x000B) { return std::string("INC_CELL+3"); }
        if (addr == 0x0030) { return std::string("STACK_TOP"); }
        return std::string();
    };
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;
    for (uint32_t i = 0; i < REFERENCE_TSTATES * HC_PER_TSTATE - 1; i++) {
        machine.clock();
    }
    machine.trace = nullptr;
    log.close();

    const std::vector<std::string> lines = read_lines(path);
    const std::vector<std::string> header = header_of(lines);
    const std::vector<std::vector<std::string>> rows = data_rows(lines);
    CHECK_EQ(header.size(), size_t(13)); // the reference 12, plus Symbol
    CHECK_EQ(header[11], std::string("Symbol"));
    CHECK_EQ(header[12], std::string("Asm"));

    // `LD SP,0x0030` -- a 4-digit operand, so it annotates.
    CHECK_EQ(rows[0][12], std::string("LD SP,0x0030 (STACK_TOP)"));
    // ...and its own address has no symbol, so the Symbol column stays empty
    // rather than borrowing the nearest one.
    CHECK_EQ(rows[0][11], std::string());

    // The instruction at 0x0008 is named, and CALL 0x0008 annotates to it.
    bool saw_call = false;
    bool saw_named_instruction = false;
    for (size_t i = 0; i < rows.size(); i++) {
        if (rows[i][12] == "CALL 0x0008 (INC_CELL)") { saw_call = true; }
        if (rows[i][11] == "INC_CELL" && rows[i][12].compare(0, 5, "LD HL") == 0) {
            saw_named_instruction = true;
        }
    }
    CHECK(saw_call);
    CHECK(saw_named_instruction);
}

TEST(no_resolver_leaves_the_reference_layout_alone) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_nosymbols.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 8;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;
    for (uint32_t i = 0; i < 40; i++) {
        machine.clock();
    }

    // No Symbol column, and the Asm column back at the reference's own width --
    // a capture made without debug info stays byte-comparable with one from
    // visualz80remix.
    const std::vector<std::string> header = header_of(read_lines(path));
    CHECK_EQ(header.size(), size_t(12));
    CHECK_EQ(header[11], std::string("Asm"));
}

// The viewer's Record button is a start_trace on a machine that is already
// running, and its Stop a stop_trace on the same -- neither of which the
// command queue could serve, since a `run` owns the emulator thread until it
// stops and the program below never stops. Both requests are made here from
// another thread mid-run, exactly as a DAP connection makes them; routed
// through the queue this test would hang rather than fail.
TEST(a_capture_starts_and_stops_across_a_running_machine) {
    Engine engine;
    CHECK_EQ(engine.load_rom(reference_program()), std::string());
    engine.set_speed(Speed::Uncapped); // nothing to wait for between yields

    // Nothing is being traced yet -- and asking must not block on the run.
    CHECK(!engine.trace_status().active);

    std::thread runner([&engine] { engine.run(); });

    TraceOptions options;
    options.path = temp_path("tracelog_live.txt");
    options.limit = 0; // unlimited: nothing but the stop below can close it
    // Returns only once the emulator thread has taken the capture up, so the
    // stop cannot overtake the start and cancel it.
    CHECK_EQ(engine.start_trace(options), std::string());

    // Read while the run is still going, which is what the viewer's row
    // counter does on a timer.
    const TraceStatus live = engine.trace_status();
    CHECK(live.active);
    CHECK_EQ(live.path, options.path);

    // Each request lands at a yield, so what ends up in the file is whatever
    // the run got through in between -- which is the whole point: rows
    // recorded while a run was in flight, by a capture opened and closed
    // across it.
    const TraceStatus stopped = engine.stop_trace();
    engine.pause();
    runner.join();

    CHECK(stopped.rows > 0);
    CHECK(!stopped.active);
    CHECK_EQ(stopped.path, options.path);
    // Stopping mid-run closes the table properly, so what the viewer loads
    // next is a complete capture rather than a truncated one: two borders and
    // the header above the rows, and the closing border below them. Counted
    // rather than parsed -- there are thousands of rows here, and splitting
    // every one into cells costs more than the capture did.
    const std::vector<std::string> lines = read_lines(options.path);
    CHECK_EQ(lines.size(), size_t(stopped.rows) + 4);
    CHECK_EQ(header_of(lines)[0], std::string("Cycle/h"));

    // The stopped capture stays on record: its path and row count are exactly
    // what the viewer needs to go and load the file it has just finished.
    CHECK_EQ(engine.trace_status().rows, stopped.rows);
    CHECK(!engine.trace_status().active);

    // Removed, unlike the small captures above: an unlimited trace of a run
    // collects a yield's worth of half-clocks at once, which is megabytes.
    std::remove(options.path.c_str());
}

RUN_TESTS()
