#include "tracelog.h"

#include "disassembler.h"
#include "spectrum.h"
#include "ula.h"

#include <cstdio>

namespace zx {
namespace {

/// Box-drawing pieces, as UTF-8 literals rather than \u escapes so the layout
/// is legible in the source the way it is in the output.
const char* const BOX_H = "─";
const char* const BOX_V = "│";
const char* const BOX_TL = "┌";
const char* const BOX_TM = "┬";
const char* const BOX_TR = "┐";
const char* const BOX_ML = "├";
const char* const BOX_MM = "┼";
const char* const BOX_MR = "┤";
const char* const BOX_BL = "└";
const char* const BOX_BM = "┴";
const char* const BOX_BR = "┘";

/// Width of the Asm column. visualz80remix uses 12, which fits its own
/// `LD SP,0030h` style; ours prints `LD SP,0x0030` and the widest thing the
/// disassembler can emit is a DD CB form like `RES 0,(IX+0x00),B` at 17. 20
/// leaves headroom without making the table unwieldy.
constexpr int ASM_WIDTH = 20;

std::string hex16(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "%04X", v);
    return buf;
}

std::string hex8(uint8_t v) {
    char buf[4];
    std::snprintf(buf, sizeof buf, "%02X", v);
    return buf;
}

std::string decimal(uint64_t v) {
    char buf[24];
    std::snprintf(buf, sizeof buf, "%llu", static_cast<unsigned long long>(v));
    return buf;
}

/// A signal cell: the line's own name when it is asserted, blank otherwise.
/// pins.h's lines are active low, hence asserted() rather than a bit test.
std::string signal(uint64_t pins, uint64_t mask, const char* name) {
    return asserted(pins, mask) ? std::string(name) : std::string();
}

std::string pad(const std::string& text, int width, bool right_align) {
    std::string out = text;
    if (int(out.size()) > width) {
        out.resize(size_t(width));
    }
    const size_t fill = size_t(width) - out.size();
    return right_align ? std::string(fill, ' ') + out : out + std::string(fill, ' ');
}

} // namespace

TraceLog::~TraceLog() {
    close();
}

void TraceLog::build_columns() {
    // The first seven and the last five are visualz80remix's, in its order and
    // at its widths. Anything `extra` adds goes between them, so the reference
    // layout survives as the outer frame of a wider table.
    columns_.clear();
    columns_.push_back({"Cycle/h", 7, true});
    columns_.push_back({"M1", 2, false});
    columns_.push_back({"MREQ", 4, false});
    columns_.push_back({"IORQ", 4, false});
    columns_.push_back({"RFSH", 4, false});
    columns_.push_back({"RD", 2, false});
    columns_.push_back({"WR", 2, false});
    if (options_.extra) {
        columns_.push_back({"HALT", 4, false});
        columns_.push_back({"WAIT", 4, false});
        columns_.push_back({"INT", 3, false});
        columns_.push_back({"NMI", 3, false});
    }
    columns_.push_back({"AB", 4, false});
    columns_.push_back({"DB", 2, false});
    columns_.push_back({"PC", 4, false});
    if (options_.extra) {
        columns_.push_back({"Frame", 6, true});
        columns_.push_back({"TState", 6, true});
    }
    // Titling the Watch column with the address it is watching costs nothing
    // (an address is 4 characters, the reference's "Watch" is 5) and makes the
    // file self-describing -- otherwise the column is a row of bytes with no
    // record of where they came from.
    const bool watching = options_.watch != TRACE_NO_WATCH;
    columns_.push_back({watching ? hex16(uint16_t(options_.watch)) : "Watch", 5, false});
    columns_.push_back({"Asm", ASM_WIDTH, false});
}

void TraceLog::write_border(const char* left, const char* mid, const char* right) {
    std::string line = left;
    for (size_t i = 0; i < columns_.size(); i++) {
        if (i > 0) {
            line += mid;
        }
        // +2 for the space of padding either side of every cell.
        for (int j = 0; j < columns_[i].width + 2; j++) {
            line += BOX_H;
        }
    }
    line += right;
    line += "\n";
    out_ << line;
}

void TraceLog::write_row(const std::vector<std::string>& cells) {
    std::string line;
    line.reserve(160);
    for (size_t i = 0; i < columns_.size(); i++) {
        line += BOX_V;
        line += ' ';
        line += pad(i < cells.size() ? cells[i] : std::string(), columns_[i].width,
                    columns_[i].right_align);
        line += ' ';
    }
    line += BOX_V;
    line += "\n";
    out_ << line;
}

std::string TraceLog::open(const TraceOptions& options) {
    close();
    options_ = options;
    rows_ = 0;
    cycle_ = 1;
    current_asm_.clear();
    seen_first_row_ = false;
    last_was_h_ = false;
    last_interrupt_count_ = 0;

    if (options_.path.empty()) {
        return "trace path is empty";
    }
    // Binary, so Windows does not rewrite the line endings: the reference
    // files are LF-only and a capture should stay byte-comparable with them.
    out_.open(options_.path, std::ios::binary | std::ios::trunc);
    if (!out_.is_open()) {
        return "couldn't open trace file " + options_.path;
    }

    build_columns();
    write_border(BOX_TL, BOX_TM, BOX_TR);
    std::vector<std::string> titles;
    for (size_t i = 0; i < columns_.size(); i++) {
        titles.push_back(columns_[i].title);
    }
    write_row(titles);
    write_border(BOX_ML, BOX_MM, BOX_MR);
    return std::string();
}

void TraceLog::close() {
    if (!out_.is_open()) {
        return;
    }
    write_border(BOX_BL, BOX_BM, BOX_BR);
    out_.close();
}

void TraceLog::record(Spectrum48K& machine, uint64_t pins) {
    if (!out_.is_open()) {
        return;
    }

    // ---- work out which instruction this half-clock belongs to -------------
    // Two things can start a group. An interrupt being accepted is checked
    // first and spotted through the CPU's own counter, which ticks in the very
    // half-clock the interrupt is taken; is_instruction_boundary() is
    // deliberately false there, because no instruction is being fetched.
    const bool interrupt_taken = machine.cpu.interrupt_count != last_interrupt_count_;
    const bool group_start = interrupt_taken || machine.cpu.is_instruction_boundary();
    if (interrupt_taken) {
        last_interrupt_count_ = machine.cpu.interrupt_count;
        current_asm_ = "INT ACK (IM" + decimal(machine.cpu.regs.im) + ")";
    } else if (machine.cpu.is_instruction_boundary()) {
        // This half-clock IS the fetch's T1H -- begin_fetch() ran during it,
        // putting the opcode's address on the bus. The ADDRESS BUS is the
        // right source for it, not PC: PC has already been incremented past
        // it, and while halted PC is parked somewhere else again.
        ReadFn read = [&machine](uint16_t a) { return machine.memory.read(a); };
        current_asm_ = disassemble_one(read, get_addr(pins)).text;
    } else if (!seen_first_row_) {
        // A capture almost always starts part-way through an instruction, and
        // that instruction's first fetch is already in the past. Name it from
        // PC so the opening rows are not blank.
        const Registers regs = machine.registers();
        const uint16_t addr = machine.cpu.halted ? uint16_t(regs.pc - 1) : regs.pc;
        ReadFn read = [&machine](uint16_t a) { return machine.memory.read(a); };
        current_asm_ = disassemble_one(read, addr).text;
    }

    // Which half of the T-state this is. Anchored to the fetch rather than
    // derived from the ULA's half-clock counter, and that is not a detail: an
    // overlapped fetch's T1H is by definition an H phase, but the CPU's very
    // first T1H is performed by set_registers()' priming clock, which runs
    // outside the machine's clock loop and so never reaches the ULA. The two
    // counters therefore sit half a T-state apart from power-on onwards.
    // Re-anchoring at every group start also keeps the phase honest across
    // anything that stalls the CPU's clock without stalling the ULA's.
    bool h_phase;
    if (group_start) {
        h_phase = true;
    } else if (seen_first_row_) {
        h_phase = !last_was_h_;
    } else {
        // The opening row of a capture, with no fetch yet to anchor to. Fall
        // back to the ULA's counter, which trails the CPU's phase by exactly
        // the one half-clock the priming fetch consumed -- so an EVEN
        // frame_hc_ (already advanced past this half-clock) is an H phase.
        h_phase = (machine.ula.frame_hc() % HC_PER_TSTATE) == 0;
    }
    if (seen_first_row_ && h_phase) {
        cycle_++;
    }
    last_was_h_ = h_phase;
    seen_first_row_ = true;
    const uint32_t half = h_phase ? 0u : 1u;

    std::vector<std::string> cells;
    cells.push_back(decimal(cycle_) + "/" + decimal(half));
    cells.push_back(signal(pins, M1, "M1"));
    cells.push_back(signal(pins, MREQ, "MREQ"));
    cells.push_back(signal(pins, IORQ, "IORQ"));
    cells.push_back(signal(pins, RFSH, "RFSH"));
    cells.push_back(signal(pins, RD, "RD"));
    cells.push_back(signal(pins, WR, "WR"));
    if (options_.extra) {
        cells.push_back(signal(pins, HALT, "HALT"));
        cells.push_back(signal(pins, WAIT, "WAIT"));
        cells.push_back(signal(pins, INT, "INT"));
        cells.push_back(signal(pins, NMI, "NMI"));
    }
    cells.push_back(hex16(get_addr(pins)));
    cells.push_back(hex8(get_data(pins)));
    cells.push_back(hex16(machine.cpu.regs.pc));
    if (options_.extra) {
        cells.push_back(decimal(machine.ula.frame_count()));
        cells.push_back(decimal(machine.ula.tstate()));
    }
    cells.push_back(options_.watch == TRACE_NO_WATCH
                        ? std::string("??")
                        : hex8(machine.memory.read(uint16_t(options_.watch))));
    cells.push_back(current_asm_);
    write_row(cells);

    rows_++;
    if (options_.limit != 0 && rows_ >= options_.limit) {
        close();
    }
}

} // namespace zx
