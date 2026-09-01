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
/// The trace writes its numeric columns in plain decimal; this is just
/// std::to_string, named so a CHECK_EQ against a cell reads as a comparison of
/// what the column should say.
std::string decimal_string(uint32_t value) {
    return std::to_string(value);
}

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

// The two address gates, on the reference program's subroutine:
//
//     0008: LD HL,000Dh
//     000B: INC (HL)
//     000C: RET
//
// Starting at 0008 and stopping at 000C should leave a file holding those two
// instructions and nothing else -- not the CALL that got there, and not the
// RET that leaves. The program loops, so both addresses are reached over and
// over: what is being checked is that the FIRST arrival at each is the one
// that counts.
TEST(address_gates_capture_exactly_the_window_between_them) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_window.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 0; // the stop address is what ends this one
    options.start_pc = 0x0008;
    options.stop_pc = 0x000C;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    // Open, but recording nothing: the file exists and holds its header.
    CHECK(log.active());
    CHECK(log.waiting());
    CHECK_EQ(log.rows(), uint64_t(0));

    machine.trace = &log;
    // The whole loop is 60 T-states, so this is several laps of it -- the
    // capture has to close itself somewhere in the first one regardless.
    for (uint32_t i = 0; i < 400; i++) {
        machine.clock();
    }
    CHECK(!log.active());
    CHECK(!log.waiting());

    // LD HL,nn is 10 T-states and INC (HL) is 11, and the capture opens on the
    // first's T1H and closes before the second's successor is fetched: 21
    // T-states, two half-clocks each.
    CHECK_EQ(log.rows(), uint64_t(42));

    const std::vector<std::vector<std::string>> rows = data_rows(read_lines(path));
    CHECK_EQ(rows.size(), size_t(42));
    // First row: the fetch of the instruction AT the start address, numbered
    // from 1 as though the machine had just been switched on.
    CHECK_EQ(rows[0][0], std::string("1/0"));
    CHECK_EQ(rows[0][7], std::string("0008"));
    CHECK_EQ(normalise_asm(rows[0][11]), std::string("LD HL,000Dh"));
    // Last row: still inside INC (HL). RET lives at the stop address and is
    // never fetched, so it cannot appear anywhere.
    CHECK_EQ(rows[41][11], std::string("INC (HL)"));
    for (size_t i = 0; i < rows.size(); i++) {
        CHECK(rows[i][11] != std::string("RET"));
    }
}

// stop_trace(pc) aimed at a capture the emulator thread is already writing:
// the request returns straight away, leaving the capture recording, and the
// arrival at the address is what closes it. This is the thing a plain
// stop_trace cannot do -- stopping AT a place rather than at a moment -- and
// like every other trace command it has to work with a run in flight.
TEST(a_stop_address_can_be_aimed_at_a_running_capture) {
    Engine engine;
    CHECK_EQ(engine.load_rom(reference_program()), std::string());
    engine.set_speed(Speed::Uncapped);

    std::thread runner([&engine] { engine.run(); });

    TraceOptions options;
    options.path = temp_path("tracelog_stop_pc.txt");
    options.limit = 0; // only the address below can end this
    CHECK_EQ(engine.start_trace(options), std::string());

    // 000C is the RET, reached once per 60-T-state lap: whatever the run got
    // through before the capture landed, it arrives within one lap.
    const TraceStatus aimed = engine.stop_trace(0x000C);
    CHECK(aimed.has_stop_pc);
    CHECK_EQ(aimed.stop_pc, uint16_t(0x000C));
    CHECK(!aimed.has_start_pc);

    // Closed by the machine reaching the address, not by anyone asking. A
    // failure here hangs rather than fails, so it is bounded.
    TraceStatus done;
    for (int i = 0; i < 1000; i++) {
        done = engine.trace_status();
        if (!done.active) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    engine.pause();
    runner.join();

    CHECK(!done.active);
    CHECK(done.rows > 0);
    CHECK(done.has_stop_pc);
    // Closed properly, mid-run, by the gate: borders and header intact, and
    // the last instruction recorded is the one BEFORE the stop address.
    const std::vector<std::string> lines = read_lines(options.path);
    CHECK_EQ(lines.size(), size_t(done.rows) + 4);
    const std::vector<std::vector<std::string>> rows = data_rows(lines);
    CHECK_EQ(rows.back()[11], std::string("INC (HL)"));
    std::remove(options.path.c_str());
}

// The other start gate: a point in the FRAME rather than a point in the code.
// Nothing about it involves a fetch -- T-state 100 lands wherever it lands,
// usually mid-instruction -- which is exactly why an address gate cannot
// answer questions about raster position.
TEST(a_t_state_gate_starts_at_that_point_in_the_frame) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_tstate.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 8;
    options.start_tstate = 100;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    CHECK(log.active());
    CHECK(log.waiting());

    machine.trace = &log;
    // Where the first row actually landed, rather than a count of how many
    // half-clocks it took to get there. Sampled BEFORE each clock: the
    // counters describe the half-clock being processed, so the values going
    // into the clock that produces the first row are that row's own.
    uint32_t first_row_tstate = 0xFFFFFFFF;
    uint32_t first_row_hc = 0xFFFFFFFF;
    for (uint32_t i = 0; i < 400; i++) {
        const uint32_t tstate = machine.ula.tstate();
        const uint32_t hc = machine.ula.frame_hc();
        machine.clock();
        if (log.rows() > 0) {
            first_row_tstate = tstate;
            first_row_hc = hc;
            break;
        }
    }
    CHECK_EQ(first_row_tstate, uint32_t(100));
    // The FIRST half of T-state 100, not the second half of 99. Half a
    // T-state is a whole contended cycle, so this is pinned exactly.
    CHECK_EQ(first_row_hc, uint32_t(200));
    CHECK(!log.waiting());

    // Still bounded by the limit like any other capture.
    for (uint32_t i = 0; i < 100; i++) {
        machine.clock();
    }
    CHECK(!log.active());
    CHECK_EQ(log.rows(), uint64_t(8));
    std::remove(path.c_str());
}

// A gate the machine is already past is a gate for the NEXT frame, not an
// instruction to start as soon as possible -- "T-state 100" has to mean the
// same half-clock however late the capture was set up.
TEST(a_t_state_gate_already_passed_waits_for_the_next_frame) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    // Run past T-state 100 with nothing recording.
    for (uint32_t i = 0; i < 400; i++) {
        machine.clock();
    }
    CHECK(machine.ula.tstate() > 100);
    const uint64_t frame_before = machine.ula.frame_count();

    TraceOptions options;
    options.path = temp_path("tracelog_tstate_wrap.txt");
    options.limit = 4;
    options.start_tstate = 100;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());

    machine.trace = &log;
    uint32_t first_row_tstate = 0xFFFFFFFF;
    uint64_t first_row_frame = 0;
    for (uint32_t i = 0; i < HC_PER_FRAME + 1000; i++) {
        const uint32_t tstate = machine.ula.tstate();
        const uint64_t frame = machine.ula.frame_count();
        machine.clock();
        if (log.rows() > 0) {
            first_row_tstate = tstate;
            first_row_frame = frame;
            break;
        }
    }
    CHECK_EQ(first_row_tstate, uint32_t(100));
    // A whole frame later, which is what "the next one" means.
    CHECK_EQ(first_row_frame, frame_before + 1);
    std::remove(options.path.c_str());
}

TEST(a_t_state_gate_that_cannot_mean_anything_is_refused) {
    const std::string path = temp_path("tracelog_tstate_bad.txt");
    std::remove(path.c_str());

    TraceOptions options;
    options.path = path;
    options.start_pc = 0x0008;
    options.start_tstate = 100;
    TraceLog both;
    // Two answers to "where does this begin" is a question, not a setting.
    CHECK(both.open(options).find("not both") != std::string::npos);

    options.start_pc = TRACE_NO_PC;
    options.start_tstate = TSTATES_PER_FRAME;
    TraceLog past_the_end;
    CHECK(past_the_end.open(options).find("within a frame") != std::string::npos);

    // Refused before the file is created, so a rejected capture leaves nothing
    // behind for the next one to find.
    std::ifstream leftover(path.c_str());
    CHECK(!leftover.is_open());

    // The last T-state of the frame is a real one, and interesting: it is the
    // half-clock before the interrupt.
    options.start_tstate = TSTATES_PER_FRAME - 1;
    TraceLog last;
    CHECK_EQ(last.open(options), std::string());
    std::remove(path.c_str());
}

// The ULA's own bus. Everything above traces ONE bus master; the machine has
// two, and until these columns the second one fetched the whole screen without
// leaving any record of having done so. That traffic is what memory contention
// and the snow artifact are about, so it has to be visible before either can
// be reasoned about.
//
// Gated on a T-state inside the display area, because that is the only place
// the ULA reads anything at all.
TEST(ula_columns_show_the_display_fetch) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());
    // Something recognisable in the first screen cell, so the byte in the
    // ULA-DB column can be checked against what was put there rather than
    // just against itself.
    machine.memory.write(pixel_addr(0, 0), 0xA5);

    const std::string path = temp_path("tracelog_ula.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 0;
    options.ula = true;
    options.extra = true;
    // 14336 is the first paper T-state: the ULA's first fetch of the frame.
    options.start_tstate = 14336;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());

    machine.trace = &log;
    for (uint32_t i = 0; i < HC_PER_FRAME + 200 && log.rows() < 40; i++) {
        machine.clock();
    }
    log.close();

    const std::vector<std::string> lines = read_lines(path);
    const std::vector<std::string> titles = header_of(lines);
    const std::vector<std::vector<std::string>> rows = data_rows(lines);
    size_t ab = titles.size(), db = titles.size(), n = titles.size();
    for (size_t i = 0; i < titles.size(); i++) {
        if (titles[i] == "ULA-AB") { ab = i; }
        if (titles[i] == "ULA-DB") { db = i; }
        if (titles[i] == "n") { n = i; }
    }
    CHECK(ab < titles.size());
    CHECK(db < titles.size());
    CHECK(n < titles.size());

    // Row 0, not row 1. T-state 14336 is where the ULA's first fetch of the
    // frame happens, so a gate on it must open on the very half-clock that
    // fetch lands -- if this ever slips to row 1 again, the gate is reading a
    // counter that has already advanced past the half-clock being recorded.
    size_t first_fetch = rows.size();
    for (size_t i = 0; i < rows.size(); i++) {
        if (!rows[i][ab].empty()) {
            first_fetch = i;
            break;
        }
    }
    CHECK_EQ(first_fetch, size_t(0));

    // Four bytes at one instant, the reported address and byte being the
    // first of them. 0x4000 is the first screen cell, where the non-linear
    // layout puts paper row 0, column 0.
    CHECK_EQ(pixel_addr(0, 0), uint16_t(0x4000));
    CHECK_EQ(rows[first_fetch][ab], std::string("4000"));
    CHECK_EQ(rows[first_fetch][db], std::string("A5"));
    CHECK_EQ(rows[first_fetch][n], std::string("4"));

    // And blank in between: an idle ULA bus is not a read of 0x0000, and a
    // group is 16 pixels apart, so the next 15 half-clocks fetch nothing.
    size_t fetches = 0;
    for (size_t i = first_fetch + 1; i < rows.size() && i < first_fetch + 16; i++) {
        if (!rows[i][ab].empty()) { fetches++; }
    }
    CHECK_EQ(fetches, size_t(0));

    // ...and then the next group, exactly 16 half-clocks on.
    if (rows.size() > first_fetch + 16) {
        CHECK_EQ(rows[first_fetch + 16][n], std::string("4"));
    }
    std::remove(path.c_str());
}

// The default layout must not move: these columns are opt-in for the same
// reason `extra` is, so that a capture can still be diffed byte-for-byte
// against visualz80remix's own export.
TEST(ula_columns_are_absent_unless_asked_for) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_no_ula.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 8;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());
    machine.trace = &log;
    for (uint32_t i = 0; i < 40; i++) {
        machine.clock();
    }

    const std::vector<std::string> titles = header_of(read_lines(path));
    for (size_t i = 0; i < titles.size(); i++) {
        CHECK(titles[i] != "ULA-AB");
        CHECK(titles[i] != "ULA-DB");
    }
    std::remove(path.c_str());
}

// The frame and T-state columns label the half-clock they are ON. Both halves
// of a T-state therefore carry the same number, and the last half-clock of a
// frame belongs to that frame rather than to the one about to start -- neither
// of which was true while the columns read a counter that clock() had already
// advanced.
TEST(frame_and_tstate_columns_label_the_half_clock_they_are_on) {
    Spectrum48K machine;
    const std::vector<uint8_t> rom = reference_program();
    CHECK_EQ(machine.load_rom(rom.data(), rom.size()), std::string());

    const std::string path = temp_path("tracelog_tstate_pairs.txt");
    TraceOptions options;
    options.path = path;
    options.limit = 12;
    options.extra = true;
    options.start_tstate = 500;
    TraceLog log;
    CHECK_EQ(log.open(options), std::string());

    machine.trace = &log;
    for (uint32_t i = 0; i < 2000 && log.active(); i++) {
        machine.clock();
    }

    const std::vector<std::string> lines = read_lines(path);
    const std::vector<std::string> titles = header_of(lines);
    const std::vector<std::vector<std::string>> rows = data_rows(lines);
    size_t ts = titles.size();
    for (size_t i = 0; i < titles.size(); i++) {
        if (titles[i] == "TState") { ts = i; }
    }
    CHECK(ts < titles.size());
    CHECK_EQ(rows.size(), size_t(12));

    // Twelve half-clocks from the first half of T-state 500: 500 500 501 501
    // ... Each number appears exactly twice, in order.
    for (size_t i = 0; i < rows.size(); i++) {
        const uint32_t want = 500 + uint32_t(i / 2);
        CHECK_EQ(rows[i][ts], decimal_string(want));
    }
    std::remove(path.c_str());
}

RUN_TESTS()
