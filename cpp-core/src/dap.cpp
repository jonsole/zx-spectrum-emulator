// DAP (Debug Adapter Protocol) TCP server. First ported from the project's
// former Rust server.
//
// Real base-protocol framing (`Content-Length: N\r\n\r\n{json}`), a
// per-connection request loop, and `Engine` events forwarded to every open
// connection as unsolicited `stopped`/`continued` events. Responses and
// events share one write mutex per connection, so they are each written
// whole, but the two can legitimately interleave -- a client must tolerate
// that.
//
// Stack traces come from `Spectrum::call_stack` (frame 0 is PC, frames 1+
// are its tracked return addresses innermost-first), each labelled with the
// disassembled instruction at that address. Where SLD debug info covers an
// address -- the loaded program's own, attached via launch's sld/asm args or
// the MCP load_debug_info tool, or the ROM disassembly's, always available
// once built -- that frame also carries a source and line, and source-line
// breakpoints resolve to addresses through the same data. The loaded
// program's info takes priority, with the ROM as fallback, so a call from a
// program into a ROM routine still resolves.

#include "dap.h"

#include "base64.h"
#include "disassembler.h"
#include "file_io.h"
#include "log.h"
#include "net.h"
#include "profile_report.h"
#include "register_names.h"
#include "rom_source.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;

namespace zx {
namespace {

constexpr int64_t THREAD_ID = 1;

/// Reserved width (label name + ":" + a two-space gap) for the label column
/// folded into each disassembled line -- fixed regardless of whether that
/// particular line has a label, so mnemonics all start in the same column. 12
/// characters comfortably fits real ROM and game routine names ("START_NEW",
/// "LD_EDGE_1"); a longer one simply is not padded further.
constexpr size_t LABEL_COLUMN_WIDTH = 12 + 3; // 12 + strlen(":  ")

std::string file_name_of(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

/// A DAP client resolves `source.path` against nothing -- it has no idea what
/// directory this server was started in, so a relative path (the default
/// `rom_disassembly/rom.asm`) is one it cannot open. It then falls back to
/// asking the adapter for the text with a `source` request, which is served
/// below but hands back a read-only buffer. An absolute path instead lets the
/// client open the real file, which is what makes editing and breakpoints in
/// it work. Unresolvable paths are passed through untouched rather than
/// guessed at.
std::string absolute_source_path(const std::string& path) {
    std::error_code ec;
    const std::filesystem::path full = std::filesystem::weakly_canonical(path, ec);
    if (ec || full.empty()) {
        return path;
    }
    return full.string();
}

std::string hex4(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "0x%04X", v);
    return buf;
}

std::string hex2(uint8_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "0x%02X", v);
    return buf;
}

// ---- connections -----------------------------------------------------------

/// One DAP client. Per-connection because DAP says `setBreakpoints` and
/// `setInstructionBreakpoints` each replace only their own category, while
/// the engine has a single flat address set -- the two are reconciled here.
struct Connection {
    net::Socket sock;
    std::mutex write_mutex;
    std::atomic<int64_t> seq{1};

    std::map<std::string, std::set<uint16_t>> source_breakpoints;
    std::set<uint16_t> instruction_breakpoints;
    std::set<uint16_t> known_breakpoints;
    /// Watchpoints this connection asked for, by dataId, and the Engine id
    /// each became. Only these are touched by its setDataBreakpoints, so a
    /// watchpoint set over MCP -- or from the editor's own command -- is not
    /// swept away by a client that has none.
    std::map<std::string, uint32_t> data_breakpoints;
    /// Logpoints this connection set, as Engine ids: by source path, for the
    /// breakpoints with a logMessage that setBreakpoints replaces a source at
    /// a time, and by group, for the ones a program asked for with
    /// setLogpoints. Cleared when the connection goes.
    std::map<std::string, std::vector<uint32_t>> source_logpoints;
    std::map<std::string, std::vector<uint32_t>> group_logpoints;

    /// Buffered input, so header lines can be read a line at a time and the
    /// body a block at a time off the same stream.
    std::string inbox;
    bool eof = false;
};

/// Every open connection, so an Engine event can be fanned out to all of
/// them. The Engine only holds one stopped/continued handler, registered
/// once by serve_dap.
std::mutex g_connections_mutex;
std::vector<std::shared_ptr<Connection>> g_connections;

void send_message(Connection& conn, const json& message) {
    // `replace` rather than the default handler: text lifted from files the
    // user supplies -- a `source` response, a symbol name out of an SLD --
    // need not be valid UTF-8, and a throw here would take down the
    // connection's request loop rather than merely garbling a character.
    const std::string body = message.dump(-1, ' ', false, json::error_handler_t::replace);
    const std::string framed =
        "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    std::lock_guard<std::mutex> lock(conn.write_mutex);
    conn.sock.send_all(framed);
}

json envelope_event(Connection& conn, const std::string& event, const json& body) {
    return json{{"seq", conn.seq.fetch_add(1)},
                {"type", "event"},
                {"event", event},
                {"body", body}};
}

json envelope_response(Connection& conn, int64_t request_seq, const std::string& command,
                       bool success, const json& body) {
    json response{{"seq", conn.seq.fetch_add(1)},
                  {"type", "response"},
                  {"request_seq", request_seq},
                  {"success", success},
                  {"command", command},
                  {"body", body}};
    if (!success && body.is_object() && body.contains("message")
        && body["message"].is_string()) {
        // DAP carries the human-readable reason for a failure in the
        // response's TOP-LEVEL `message`, not in the body. That is where a
        // client reads it from -- VS Code builds the Error that customRequest
        // rejects with out of this field -- so a reason left only in the body
        // reaches the user as "undefined" and the real problem is lost.
        response["message"] = body["message"];
    }
    return response;
}

void broadcast_event(const std::string& event, const json& body) {
    std::vector<std::shared_ptr<Connection>> targets;
    {
        std::lock_guard<std::mutex> lock(g_connections_mutex);
        targets = g_connections;
    }
    for (auto& conn : targets) {
        send_message(*conn, envelope_event(*conn, event, body));
    }
}

// ---- framing ---------------------------------------------------------------

/// Fills `conn.inbox` until it holds at least `wanted` bytes. False at EOF.
bool fill(Connection& conn, size_t wanted) {
    char buf[4096];
    while (conn.inbox.size() < wanted) {
        int n = conn.sock.recv(buf, int(sizeof buf));
        if (n <= 0) {
            conn.eof = true;
            return false;
        }
        conn.inbox.append(buf, size_t(n));
    }
    return true;
}

/// Reads one CRLF-terminated header line (without its terminator). Returns
/// false at EOF.
bool read_line(Connection& conn, std::string& out) {
    size_t pos;
    while ((pos = conn.inbox.find('\n')) == std::string::npos) {
        if (!fill(conn, conn.inbox.size() + 1)) {
            return false;
        }
    }
    out = conn.inbox.substr(0, pos);
    conn.inbox.erase(0, pos + 1);
    while (!out.empty() && (out.back() == '\r' || out.back() == ' ')) {
        out.pop_back();
    }
    return true;
}

/// Reads one framed DAP message. False at EOF or on an unparseable message.
bool read_message(Connection& conn, json& out) {
    size_t content_length = 0;
    bool have_length = false;
    for (;;) {
        std::string line;
        if (!read_line(conn, line)) {
            return false;
        }
        if (line.empty()) {
            break;
        }
        const size_t colon = line.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        std::string name = line.substr(0, colon);
        for (char& c : name) {
            c = char(std::tolower(static_cast<unsigned char>(c)));
        }
        if (name == "content-length") {
            content_length = size_t(std::strtoul(line.c_str() + colon + 1, nullptr, 10));
            have_length = true;
        }
    }
    if (!have_length) {
        return false;
    }
    if (!fill(conn, content_length)) {
        return false;
    }
    const std::string body = conn.inbox.substr(0, content_length);
    conn.inbox.erase(0, content_length);
    out = json::parse(body, nullptr, /*allow_exceptions=*/false);
    return !out.is_discarded();
}

// ---- argument helpers ------------------------------------------------------

bool try_parse_hex_addr(std::string s, uint16_t& out) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) {
        s.erase(0, 1);
    }
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) {
        s.pop_back();
    }
    if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s.erase(0, 2);
    }
    if (s.empty()) {
        return false;
    }
    char* end = nullptr;
    unsigned long v = std::strtoul(s.c_str(), &end, 16);
    if (end == nullptr || *end != '\0') {
        return false;
    }
    out = uint16_t(v);
    return true;
}

/// A hex-string-or-int address plus a signed offset, wrapped to 16 bits.
/// False on a malformed/missing value -- `disassemble` depends on being able
/// to tell that apart (see its handler); other callers just default to 0.
bool as_addr(const json& value, int64_t offset, uint16_t& out) {
    int64_t base = 0;
    if (value.is_string()) {
        uint16_t parsed = 0;
        if (!try_parse_hex_addr(value.get<std::string>(), parsed)) {
            return false;
        }
        base = parsed;
    } else if (value.is_number_integer()) {
        base = value.get<int64_t>();
    } else {
        return false;
    }
    int64_t sum = (base + offset) % 0x10000;
    if (sum < 0) {
        sum += 0x10000;
    }
    out = uint16_t(sum);
    return true;
}

const json& arg(const json& arguments, const char* name) {
    static const json null_value;
    auto it = arguments.find(name);
    return it == arguments.end() ? null_value : *it;
}

int64_t arg_int(const json& arguments, const char* name, int64_t fallback) {
    const json& v = arg(arguments, name);
    return v.is_number_integer() ? v.get<int64_t>() : fallback;
}

std::string arg_str(const json& arguments, const char* name) {
    const json& v = arg(arguments, name);
    return v.is_string() ? v.get<std::string>() : std::string();
}

std::string trimmed_copy(const std::string& text) {
    size_t begin = 0;
    size_t end = text.size();
    while (begin < end && std::isspace(uint8_t(text[begin]))) {
        begin++;
    }
    while (end > begin && std::isspace(uint8_t(text[end - 1]))) {
        end--;
    }
    return text.substr(begin, end - begin);
}

/// "1"/"0"/"true"/"false", in any case and with surrounding spaces, as a
/// Variables-pane edit of a flag or flip-flop arrives.
bool parse_bool_or_bit(const std::string& text, bool& out) {
    std::string t;
    for (char c : text) {
        if (!std::isspace(uint8_t(c))) {
            t.push_back(char(std::tolower(uint8_t(c))));
        }
    }
    if (t == "1" || t == "true") {
        out = true;
        return true;
    }
    if (t == "0" || t == "false") {
        out = false;
        return true;
    }
    return false;
}

/// An OPTIONAL address argument, as an integer or as a symbol expression
/// ("KEY_INT+9", "0x0038", "0038"). `present` tells an omitted argument from a
/// real 0. Unlike as_addr above this resolves names, so it needs the symbol
/// tables -- which is why the trace requests take it and the DAP-standard ones
/// (whose addresses come from VS Code, already numeric) do not.
bool arg_opt_address(const json& arguments, const char* name, const Sources& sources,
                     bool& present, uint16_t& out, std::string& error) {
    const json& v = arg(arguments, name);
    present = false;
    if (v.is_null()) {
        return true;
    }
    if (v.is_number_integer()) {
        const int64_t n = v.get<int64_t>();
        if (n < 0 || n > 0xFFFF) {
            error = std::string("'") + name + "' must be a 16-bit address (0..65535)";
            return false;
        }
        out = uint16_t(n);
        present = true;
        return true;
    }
    if (!v.is_string()) {
        error = std::string("'") + name
                + "' must be a 16-bit address, or a symbol expression like \"KEY_INT+9\"";
        return false;
    }
    if (!sources.parse_address(v.get<std::string>(), out, error)) {
        error = std::string("'") + name + "': " + error;
        return false;
    }
    present = true;
    return true;
}

/// Most completions a `matchSymbols` request will answer with, however many
/// were asked for. A dropdown is read, not scrolled through: past this the
/// answer is "keep typing", which is what the `more` flag says.
const size_t SYMBOL_MATCH_LIMIT = 50;

// ---- trace ------------------------------------------------------------------

/// The one shape all three trace requests answer with, so the viewer only has
/// to learn it once. Field for field what the equivalent MCP tools report.
json trace_body(const TraceStatus& status) {
    json out{{"active", status.active},
             {"waiting", status.waiting},
             {"path", status.path},
             {"rows", status.rows},
             {"limit", status.limit},
             {"extra", status.extra},
             {"ula", status.ula}};
    if (status.watching) {
        out["watch"] = status.watch;
    }
    // Only when gated, so an ungated capture answers in the shape the viewer
    // has always read.
    if (status.has_start_pc) {
        out["startPc"] = status.start_pc;
    }
    if (status.has_start_tstate) {
        out["startTstate"] = status.start_tstate;
    }
    if (status.has_stop_pc) {
        out["stopPc"] = status.stop_pc;
    }
    return out;
}

/// The block list, in the shape the tape pane's tree reads. Sent with every
/// tape response rather than on request: it is a few hundred bytes for a whole
/// game, and a viewer that polls the status would otherwise have to track for
/// itself when the tape underneath it had been changed.
json tape_block_list(const std::vector<TapeBlockInfo>& blocks) {
    json out = json::array();
    for (size_t i = 0; i < blocks.size(); i++) {
        const TapeBlockInfo& b = blocks[i];
        out.push_back(json{{"index", i},
                           {"id", b.id},
                           {"kind", b.kind},
                           {"name", b.name},
                           {"dataBytes", b.data_bytes},
                           {"durationMs", b.duration_ms},
                           {"standardSpeed", b.standard_speed},
                           {"stopTape", b.stop_tape},
                           {"pauseMs", b.pause_ms}});
    }
    return out;
}

json tape_body(const TapeStatus& status, const std::vector<TapeBlockInfo>& blocks) {
    return json{{"inserted", status.inserted},   {"playing", status.playing},
                {"atEnd", status.at_end},        {"fastLoad", status.fast_load},
                {"name", status.name},           {"description", status.description},
                {"block", status.block},         {"blocks", status.blocks},
                {"positionMs", status.position_ms}, {"totalMs", status.total_ms},
                {"warnings", status.warnings},
                {"blockList", tape_block_list(blocks)}};
}

// ---- variables -------------------------------------------------------------

json register_variables(const Registers& r) {
    struct Entry {
        const char* name;
        uint32_t value;
    };
    const Entry entries[16] = {
        {"A", r.a},
        {"F", r.f},
        {"BC", r.bc()},
        {"DE", r.de()},
        {"HL", r.hl()},
        {"A'", r.a_},
        {"F'", r.f_},
        {"BC'", uint32_t((r.b_ << 8) | r.c_)},
        {"DE'", uint32_t((r.d_ << 8) | r.e_)},
        {"HL'", uint32_t((r.h_ << 8) | r.l_)},
        {"IX", r.ix},
        {"IY", r.iy},
        {"SP", r.sp},
        {"PC", r.pc},
        {"I", r.i},
        {"R", r.r},
    };
    json out = json::array();
    for (const Entry& e : entries) {
        char buf[16];
        std::snprintf(buf, sizeof buf, register_width(e.name) == 16 ? "0x%04X" : "0x%02X",
                      e.value);
        out.push_back(json{{"name", e.name},
                           {"value", buf},
                           {"variablesReference", 0},
                           {"memoryReference", hex4(uint16_t(e.value))}});
    }
    out.push_back(json{{"name", "IM"}, {"value", std::to_string(r.im)}, {"variablesReference", 0}});
    out.push_back(json{{"name", "IFF1"}, {"value", r.iff1 ? "true" : "false"}, {"variablesReference", 0}});
    out.push_back(json{{"name", "IFF2"}, {"value", r.iff2 ? "true" : "false"}, {"variablesReference", 0}});
    return out;
}

json flag_variables(const Registers& r) {
    struct Bit {
        const char* name;
        uint8_t mask;
    };
    const Bit bits[6] = {{"S", 0x80}, {"Z", 0x40}, {"H", 0x10},
                         {"P/V", 0x04}, {"N", 0x02}, {"C", 0x01}};
    json out = json::array();
    for (const Bit& b : bits) {
        out.push_back(json{{"name", b.name},
                           {"value", (r.f & b.mask) != 0 ? "1" : "0"},
                           {"variablesReference", 0}});
    }
    return out;
}

json debug_variables(const MachineState& state) {
    json out = json::array({json{{"name", "Model"},
                                 {"value", model_name(state.model)},
                                 {"variablesReference", 0}},
                            json{{"name", "T-states"},
                                 {"value", std::to_string(state.tstate)},
                                 {"variablesReference", 0}},
                            json{{"name", "Frame"},
                                 {"value", std::to_string(state.frame_count)},
                                 {"variablesReference", 0}},
                            json{{"name", "Interrupts"},
                                 {"value", std::to_string(state.interrupt_count)},
                                 {"variablesReference", 0}}});
    if (state.model == Model::Spectrum128) {
        // The paging register, decoded: which ROM and bank are in, which
        // screen is showing, and whether a program has locked it.
        char port[8];
        std::snprintf(port, sizeof port, "$%02X", unsigned(state.paging));
        out.push_back(json{{"name", "Paging"},
                           {"value", std::string(port) + " (" + describe_paging(state.paging) + ")"},
                           {"variablesReference", 0}});
    }
    return out;
}

// ---- memory-backed disassembly --------------------------------------------

/// A read callable over a 64K snapshot pulled from the engine in one go --
/// disassembly walks addresses unpredictably, and a queued read per byte
/// would be both slow and inconsistent if the machine moved underneath it.
struct MemorySnapshot {
    std::vector<uint8_t> bytes;

    explicit MemorySnapshot(Engine& engine) : bytes(engine.read_memory(0, 0x10000)) {}

    ReadFn reader() const {
        const std::vector<uint8_t>* data = &bytes;
        return [data](uint16_t a) { return (*data)[a]; };
    }
};

uint16_t find_aligned_backward_start(const ReadFn& read, uint16_t base_addr,
                                     uint32_t needed_before) {
    // Z80 instructions are 1-4 bytes; searching back needed_before * 4 bytes
    // comfortably covers every real instruction stream (capped so a huge
    // request -- e.g. VS Code paging in hundreds of instructions of context
    // -- can't make this pathologically slow).
    //
    // The 64K address space wraps, which every address computed here relies
    // on (uint16_t arithmetic), so a base_addr near 0x0000 still searches
    // correctly instead of silently finding nothing.
    uint32_t max_search = needed_before * 4 + 16;
    if (max_search > 2048) {
        max_search = 2048;
    }
    for (uint32_t back = 1; back <= max_search; back++) {
        const uint16_t candidate = uint16_t(base_addr - back);
        uint16_t addr = candidate;
        for (uint32_t i = 0; i < needed_before; i++) {
            addr = uint16_t(addr + disassemble_one(read, addr).length);
        }
        if (addr == base_addr) {
            return candidate;
        }
    }
    return base_addr;
}

json build_frame(const ReadFn& read, const Sources& sources, int64_t frame_id, uint16_t addr) {
    const Instruction inst = disassemble_one(read, addr);
    const std::string name = hex4(addr) + ": " + annotate_symbols(inst.text, sources);

    json frame{{"id", frame_id},
               {"name", name},
               {"instructionPointerReference", hex4(addr)},
               {"line", 0},
               {"column", 0}};

    // The first source (loaded program, then ROM) with an EXACT address match
    // wins. A nearest-symbol lookup alone would find some label from a source
    // that does not actually cover this address at all -- e.g. one whose
    // entries all sit far below PC -- and mislabel the frame rather than
    // simply showing no source for it.
    for (const RomSourcePtr& source : sources.active()) {
        auto it = source->addr_to_loc.find(addr);
        if (it == source->addr_to_loc.end()) {
            continue;
        }
        const SourceLoc& loc = it->second;
        if (loc.file >= source->files.size()) {
            continue;
        }
        const std::string& file_path = source->files[loc.file].path;
        std::string label;
        uint16_t offset = 0;
        if (source->symbol_at(addr, SYMBOL_MAX_OFFSET, label, offset)) {
            if (offset != 0) {
                label += "+" + std::to_string(offset);
            }
            frame["name"] = label + "  " + name;
        }
        frame["source"] = json{{"name", file_name_of(file_path)},
                               {"path", absolute_source_path(file_path)}};
        frame["line"] = loc.line;
        frame["column"] = 1;
        break;
    }
    return frame;
}

json do_disassemble(Engine& engine, const Sources& sources, const json& arguments,
                    uint16_t base_addr) {
    MemorySnapshot snapshot(engine);
    const ReadFn read = snapshot.reader();

    const int64_t instruction_offset = arg_int(arguments, "instructionOffset", 0);
    const int64_t requested = arg_int(arguments, "instructionCount", 0);
    const size_t count = requested > 0 ? size_t(requested) : 0;

    uint16_t start = base_addr;
    if (instruction_offset > 0) {
        // Walking forward is unambiguous -- unlike backwards, variable-length
        // decoding only needs a direction, not a search.
        for (int64_t i = 0; i < instruction_offset; i++) {
            start = uint16_t(start + disassemble_one(read, start).length);
        }
    } else if (instruction_offset < 0) {
        start = find_aligned_backward_start(read, base_addr, uint32_t(-instruction_offset));
    }

    json instructions = json::array();
    for (const Instruction& inst : disassemble_range(read, start, count)) {
        std::string bytes;
        for (uint8_t b : inst.raw) {
            char buf[4];
            std::snprintf(buf, sizeof buf, "%02x", b);
            bytes += buf;
        }
        std::string label;
        std::string prefix;
        if (sources.label_at(inst.addr, label)) {
            prefix = label + ":";
        }
        // DAP has a dedicated "symbol" field, which the spec says a client MAY
        // render as a heading above the line -- VS Code's Disassembly View, in
        // practice, does not. So the label is also folded into the instruction
        // text, which every client renders by definition. Every line gets the
        // same fixed-width column, labelled or not, so the mnemonics line up
        // instead of staggering only where a label happens to land.
        if (prefix.size() < LABEL_COLUMN_WIDTH) {
            prefix.resize(LABEL_COLUMN_WIDTH, ' ');
        }
        json entry{{"address", hex4(inst.addr)},
                   {"instructionBytes", bytes},
                   {"instruction", prefix + annotate_symbols(inst.text, sources)}};
        if (!label.empty()) {
            entry["symbol"] = label;
        }
        instructions.push_back(entry);
    }
    return json{{"instructions", instructions}};
}

// ---- breakpoints -----------------------------------------------------------

/// Reconciles this connection's two breakpoint categories down to the
/// engine's single flat set, so setting one kind doesn't wipe out the other.
/// A watchpoint as a DAP dataId: the address and how many bytes. Parsed back
/// by parse_data_id, so the two must agree.
std::string data_id(uint16_t addr, uint16_t length) {
    return "W:" + hex4(addr) + ":" + std::to_string(length);
}

bool parse_data_id(const std::string& id, uint16_t& addr, uint16_t& length) {
    if (id.rfind("W:", 0) != 0) {
        return false;
    }
    const size_t colon = id.find(':', 2);
    if (colon == std::string::npos) {
        return false;
    }
    const std::string addr_text = id.substr(2, colon - 2);
    const std::string length_text = id.substr(colon + 1);
    char* end = nullptr;
    const unsigned long parsed_addr = std::strtoul(addr_text.c_str(), &end, 0);
    if (end == addr_text.c_str() || parsed_addr > 0xFFFF) {
        return false;
    }
    const unsigned long parsed_length = std::strtoul(length_text.c_str(), &end, 10);
    if (parsed_length == 0 || parsed_length > 0x10000) {
        return false;
    }
    addr = uint16_t(parsed_addr);
    length = uint16_t(parsed_length);
    return true;
}

/// DAP's `condition` on a data breakpoint, as this adapter reads it: a test
/// on the value written. "= 0", "== 0", "<> 3", "!= 3", or a bare "0" meaning
/// equals. Anything else is refused rather than quietly ignored -- a
/// condition that does nothing is worse than one that will not take.
bool parse_watch_condition(const std::string& text, const Sources& sources, Watchpoint& w,
                           std::string& error) {
    w.test = Watchpoint::Test::None;
    std::string rest = text;
    while (!rest.empty() && std::isspace(static_cast<unsigned char>(rest.front()))) {
        rest.erase(rest.begin());
    }
    if (rest.empty()) {
        return true;
    }
    Watchpoint::Test test = Watchpoint::Test::Equals;
    for (const char* op : {"==", "=", "<>", "!=", "~="}) {
        const size_t n = std::strlen(op);
        if (rest.compare(0, n, op) == 0) {
            test = (op[0] == '<' || op[0] == '!' || op[0] == '~') ? Watchpoint::Test::NotEquals
                                                                 : Watchpoint::Test::Equals;
            rest = rest.substr(n);
            break;
        }
    }
    uint16_t value = 0;
    if (!sources.parse_address(rest, value, error)) {
        error = "a watchpoint condition is a value test like \"= 0\" or \"<> 3\": " + error;
        return false;
    }
    if (value > 0xFF) {
        error = "a watchpoint watches bytes, so its condition must be 0-255";
        return false;
    }
    w.test = test;
    w.value = uint8_t(value);
    return true;
}

json watchpoint_json(const Watchpoint& w, const Sources& sources) {
    // Named where possible: a watchpoints list reading "0xF6DA" says far less
    // than "room_shown", and only this side knows the names.
    std::string symbol;
    uint16_t offset = 0;
    std::string named;
    if (sources.resolve_symbol(w.addr, symbol, offset)) {
        named = symbol + (offset > 0 ? "+" + std::to_string(offset) : "");
    }
    return json{{"id", w.id},
                {"symbol", named},
                {"address", w.addr},
                {"length", w.length},
                {"onWrite", w.on_write},
                {"onRead", w.on_read},
                {"onChange", w.on_change},
                {"test", w.test == Watchpoint::Test::Equals
                             ? "="
                             : (w.test == Watchpoint::Test::NotEquals ? "<>" : "")},
                {"value", w.value},
                {"enabled", w.enabled},
                {"hits", w.hits}};
}

json watchpoints_json(Engine& engine, const Sources& sources) {
    json list = json::array();
    for (const Watchpoint& w : engine.watchpoints()) {
        list.push_back(watchpoint_json(w, sources));
    }
    return json{{"watchpoints", list}};
}

/// What a watchpoint stop is, in words: "player_x ($9C40) 3 -> 255, written by
/// sprite_move+7". The description a `stopped` event carries, and the line the
/// debug console gets.
std::string describe_watch_stop(const WatchStop& stop, const Sources& sources) {
    std::string name;
    uint16_t offset = 0;
    std::string where = hex4(stop.addr);
    if (sources.resolve_symbol(stop.addr, name, offset)) {
        where = name + (offset > 0 ? "+" + std::to_string(offset) : "") + " (" + where + ")";
    }
    std::string what = where;
    if (stop.write) {
        what += " " + hex2(stop.old_value) + " -> " + hex2(stop.new_value) + ", written by ";
    } else {
        what += " read as " + hex2(stop.new_value) + " by ";
    }
    std::string by = hex4(stop.pc);
    if (sources.resolve_symbol(stop.pc, name, offset)) {
        by = name + (offset > 0 ? "+" + std::to_string(offset) : "") + " (" + by + ")";
    }
    return what + by;
}

void sync_breakpoints(Engine& engine, Connection& conn) {
    std::set<uint16_t> desired = conn.instruction_breakpoints;
    for (const auto& entry : conn.source_breakpoints) {
        desired.insert(entry.second.begin(), entry.second.end());
    }
    for (uint16_t addr : desired) {
        if (conn.known_breakpoints.count(addr) == 0) {
            engine.set_breakpoint(addr);
        }
    }
    for (uint16_t addr : conn.known_breakpoints) {
        if (desired.count(addr) == 0) {
            engine.clear_breakpoint(addr);
        }
    }
    conn.known_breakpoints = std::move(desired);
}

// ---- logpoints --------------------------------------------------------------

/// Where a logpoint's reports go: the connection that set it, and within it
/// either the Debug Console -- an empty group, for a breakpoint with a
/// logMessage -- or a `zxLog` event naming the group a program set it under.
/// Keyed by the Engine's id. The connection is held as a plain pointer and
/// looked up among g_connections before anything is sent, so a report that
/// arrives as its connection closes goes nowhere rather than somewhere freed.
struct LogpointOwner {
    Connection* conn = nullptr;
    std::string group;
};
std::mutex g_logpoints_mutex;
std::map<uint32_t, LogpointOwner> g_logpoint_owners;

/// Sets a logpoint at `addr` for `conn`. False, with `error`, for a message
/// that does not parse -- a symbol in it is resolved now, against whatever
/// debug info is loaded, so a typo is caught when it is set and not silently
/// at every hit.
bool add_logpoint(Engine& engine, const Sources& sources, Connection& conn,
                  const std::string& group, uint16_t addr, const std::string& message,
                  uint32_t& id, std::string& error) {
    Logpoint lp;
    lp.addr = addr;
    lp.text = message;
    const SymbolResolver resolve = [&sources](const std::string& name, uint16_t& value) {
        return sources.symbol_value(name, value);
    };
    if (!parse_log_message(message, resolve, lp.message, error)) {
        return false;
    }
    id = engine.set_logpoint(lp);
    std::lock_guard<std::mutex> lock(g_logpoints_mutex);
    g_logpoint_owners[id] = LogpointOwner{&conn, group};
    return true;
}

/// Clears every logpoint in `ids` and forgets their owners.
void drop_logpoints(Engine& engine, std::vector<uint32_t>& ids) {
    for (uint32_t id : ids) {
        engine.clear_logpoint(id);
        std::lock_guard<std::mutex> lock(g_logpoints_mutex);
        g_logpoint_owners.erase(id);
    }
    ids.clear();
}

/// Hands a batch of reports to whoever set each logpoint: a console line for
/// a breakpoint's logMessage, a `zxLog` event per group for the rest, each
/// connection's reports in the order they happened.
void deliver_log(const std::vector<LogLine>& lines, uint64_t dropped) {
    std::map<Connection*, std::string> console;
    std::map<std::pair<Connection*, std::string>, json> groups;
    {
        std::lock_guard<std::mutex> lock(g_logpoints_mutex);
        for (const LogLine& line : lines) {
            auto owner = g_logpoint_owners.find(line.id);
            if (owner == g_logpoint_owners.end()) {
                continue; // cleared while its report was on its way
            }
            if (owner->second.group.empty()) {
                console[owner->second.conn] += line.text + "\n";
            } else {
                json& batch = groups[{owner->second.conn, owner->second.group}];
                if (batch.is_null()) {
                    batch = json::array();
                }
                batch.push_back(json{{"id", line.id}, {"pc", line.pc}, {"text", line.text}});
            }
        }
    }
    std::vector<std::shared_ptr<Connection>> open;
    {
        std::lock_guard<std::mutex> lock(g_connections_mutex);
        open = g_connections;
    }
    for (const std::shared_ptr<Connection>& conn : open) {
        auto text = console.find(conn.get());
        if (text != console.end()) {
            std::string out = text->second;
            if (dropped > 0) {
                out += "(" + std::to_string(dropped)
                       + " logpoint reports dropped: they came faster than they could be sent)\n";
            }
            send_message(*conn, envelope_event(*conn, "output",
                                               json{{"category", "console"}, {"output", out}}));
        }
        for (const auto& batch : groups) {
            if (batch.first.first == conn.get()) {
                send_message(*conn, envelope_event(*conn, "zxLog",
                                                   json{{"group", batch.first.second},
                                                        {"lines", batch.second},
                                                        {"dropped", dropped}}));
            }
        }
    }
}

// ---- step over -------------------------------------------------------------

/// Instructions a plain single step would step INTO (or, for the block-repeat
/// forms, only advance one iteration of) -- so `next` runs to the following
/// instruction rather than stepping.
bool is_step_over_as_run(const std::string& text) {
    static const char* const PREFIXES[] = {"CALL", "RST",  "LDIR", "LDDR", "CPIR",
                                           "CPDR", "INIR", "INDR", "OTIR", "OTDR"};
    for (const char* prefix : PREFIXES) {
        if (text.rfind(prefix, 0) == 0) {
            return true;
        }
    }
    return false;
}

/// A GraphicsView as the extension wants it. Field names are the server's own
/// (snake_case, as the MCP tool takes them); the extension maps the two that
/// its webview spells differently, which is the right place for that since the
/// webview's vocabulary is its business and not this file's.
json graphics_view_json(const GraphicsView& v, uint64_t version) {
    return json{{"version", version},
                {"source", v.source},
                {"address", v.address},
                {"file", v.file},
                {"offset", v.offset},
                {"format", v.format},
                {"width", v.width},
                {"height", v.height},
                {"count", v.count},
                {"columns", v.columns},
                {"header", v.header},
                {"first", v.first},
                {"interleave", v.interleave},
                {"invert_mask", v.invert_mask},
                {"flip", v.flip},
                {"ink", v.ink},
                {"paper", v.paper},
                {"zoom", v.zoom},
                {"grid", v.grid},
                {"labels", v.labels},
                {"pin", v.pin}};
}

// ---- request dispatch ------------------------------------------------------

/// Whether a request sets the machine moving -- and so will end in a stop
/// that this client asked for. See Engine::set_driver, and the stopped event
/// in serve_dap for what it changes.
bool moves_machine(const std::string& command) {
    for (const char* c : {"launch", "restart", "continue", "next", "stepIn", "stepOut",
                          "pause", "stepBack", "stepBackInto", "stepBackOut",
                          "reverseContinue", "runBackToAddress", "runBackToWrite",
                          "returnToLive", "loadTape"}) {
        if (command == c) {
            return true;
        }
    }
    return false;
}

/// A one-line summary of a request worth logging, or "" for the rest.
///
/// Stepping a program produces a constant stream of stackTrace, scopes,
/// variables, readMemory and disassemble requests -- VS Code refreshing its
/// panels after every stop -- and logging those would bury the few lines that
/// say what a person actually did. What is left is the deliberate acts: the
/// session lifecycle, run control, breakpoints and the tape.
std::string describe_request(const std::string& command, const json& arguments) {
    if (command == "launch" || command == "attach") {
        std::string summary = command;
        for (const char* key : {"rom", "snapshot", "tape", "sld"}) {
            const std::string value = arg_str(arguments, key);
            if (!value.empty()) {
                summary += " " + std::string(key) + "="
                           + std::filesystem::path(value).filename().string();
            }
        }
        return summary;
    }
    if (command == "continue" || command == "pause" || command == "next"
        || command == "stepIn" || command == "stepOut" || command == "disconnect"
        || command == "terminate" || command == "restart") {
        return command;
    }
    if (command == "setBreakpoints" || command == "setInstructionBreakpoints") {
        const json& list = arg(arguments, "breakpoints");
        const size_t count = list.is_array() ? list.size() : 0;
        return command + ": " + std::to_string(count)
               + (count == 1 ? " breakpoint" : " breakpoints");
    }
    if (command == "loadTape") {
        return "loadTape " + std::filesystem::path(arg_str(arguments, "path")).filename().string();
    }
    if (command == "tapeControl") {
        const std::string action = arg_str(arguments, "action");
        return "tapeControl" + (action.empty() ? "" : " " + action);
    }
    if (command == "startTrace" || command == "stopTrace") {
        return command;
    }
    if (command == "setWatchpoint") {
        const json& address = arg(arguments, "address");
        return "setWatchpoint "
               + (address.is_string() ? address.get<std::string>() : address.dump());
    }
    if (command == "clearWatchpoint") {
        return command;
    }
    if (command == "setDataBreakpoints") {
        const json& list = arg(arguments, "breakpoints");
        const size_t count = list.is_array() ? list.size() : 0;
        return command + ": " + std::to_string(count)
               + (count == 1 ? " watchpoint" : " watchpoints");
    }
    if (command == "stepBack" || command == "reverseContinue" || command == "stepBackInto"
        || command == "stepBackOut" || command == "returnToLive") {
        return command;
    }
    if (command == "runBackToAddress" || command == "runBackToWrite") {
        const json& address = arg(arguments, "address");
        if (address.is_null()) {
            return command + " line " + std::to_string(arg_int(arguments, "line", -1));
        }
        return command + " " + (address.is_string() ? address.get<std::string>() : address.dump());
    }
    if (command == "profile") {
        const std::string action = arg_str(arguments, "action");
        // "get" is what the editor asks on every stop; only the switches are acts.
        if (action == "start" || action == "stop") {
            return "profile " + action;
        }
    }

    return "";
}


#if ZX_REWIND
/// What a rewind request did, to every client: a `zxRewind` event the editor
/// uses for its status bar, and a line in the debug console when there is
/// something to say -- a search that found nothing leaves the machine where it
/// was, and without the line that looks like a button that did nothing.
void report_rewind(const std::string& command, const RewindOutcome& o) {
    std::string message;
    if (!o.error.empty()) {
        message = o.error;
    } else if (o.cancelled) {
        message = "cancelled -- the machine is where it was";
    } else if (!o.moved && command != "returnToLive") {
        message = "nothing earlier in the history matches -- the machine is where it was";
    }
    broadcast_event("zxRewind", json{{"command", command},
                                     {"moved", o.moved},
                                     {"cancelled", o.cancelled},
                                     {"error", o.error},
                                     {"message", message},
                                     {"inPast", o.state.in_past},
                                     {"behindHalfClocks", o.state.behind_hc}});
    if (!message.empty()) {
        broadcast_event("output", json{{"category", "console"},
                                       {"output", command + ": " + message + "\n"}});
        log("%s: %s", command.c_str(), message.c_str());
    }
}

json history_body(const RewindStatus& s) {
    return json{{"rewind", true},
                {"live", s.live},
                {"oldestHalfClock", s.oldest_hc},
                {"headHalfClock", s.head_hc},
                {"positionHalfClock", s.position_hc},
                {"halfClocksPerFrame", s.hc_per_frame},
                {"checkpoints", s.checkpoints},
                {"bytes", s.bytes}};
}
#endif

json handle_request(const json& req, Engine& engine, Sources& sources, Connection& conn) {
    const std::string command = req.value("command", std::string());
    const int64_t request_seq = req.value("seq", int64_t(0));
    static const json empty_args = json::object();
    const json& arguments = req.contains("arguments") && req["arguments"].is_object()
                                ? req["arguments"]
                                : empty_args;

    const std::string summary = describe_request(command, arguments);
    if (!summary.empty()) {
        log("DAP  %s", summary.c_str());
    }
    if (moves_machine(command)) {
        engine.set_driver(Driver::Dap);
    }

    bool success = true;
    json body = json::object();

    if (command == "initialize") {
        body = json{{"supportsConfigurationDoneRequest", true},
                    // Not a real exception -- DAP exception filters are
                    // simply its mechanism for "break when this happens",
                    // and this is the only one that gets a checkbox in VS
                    // Code BREAKPOINTS instead of a custom request.
                    {"exceptionBreakpointFilters",
                     json::array({json{{"filter", "interrupt"},
                                       {"label", "Interrupt accepted"},
                                       {"description",
                                        "Break at the first instruction of the interrupt "
                                        "handler, each time the CPU accepts an interrupt."},
                                       {"default", false}}})},
                    {"supportsInstructionBreakpoints", true},
                    {"supportsReadMemoryRequest", true},
                    {"supportsWriteMemoryRequest", true},
                    {"supportsDisassembleRequest", true},
                    {"supportsSetVariable", true},
                    {"supportsSteppingGranularity", false},
                    // Watchpoints. The bytes form is what lets VS Code's
                    // memory inspector offer "Break on Value Change" over a
                    // byte range, which is where one is usually wanted.
                    {"supportsDataBreakpoints", true},
                    {"supportsDataBreakpointBytes", true},
                    {"supportsLogPoints", true}};
#if ZX_REWIND
        // What makes VS Code show Step Back and Reverse Continue at all.
        body["supportsStepBack"] = true;
#endif

    } else if (command == "launch") {
        // Lets a launch config opt out of realtime pacing (the exercisers
        // want to finish as fast as the host can manage), without needing a
        // separately-configured server process.
        const json& uncapped = arg(arguments, "uncapped");
        if (uncapped.is_boolean()) {
            engine.set_speed(uncapped.get<bool>() ? Speed::Uncapped : Speed::Realtime);
        }
        const std::string rom_path = arg_str(arguments, "rom");
        if (!rom_path.empty()) {
            std::vector<uint8_t> data;
            if (!read_file(rom_path, data)) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", "couldn't read ROM " + rom_path}});
            }
            const std::string load_error = engine.load_rom(std::move(data));
            if (!load_error.empty()) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", load_error}});
            }
        }
        // Which Spectrum to be. After the ROM, so a 32K image is in place
        // before the 128K it belongs to is asked for; before the snapshot,
        // which may switch model again to whatever it was taken on.
        const json& machine = arg(arguments, "machine");
        if (!machine.is_null()) {
            const std::string name = machine.is_number_integer()
                                         ? std::to_string(machine.get<int64_t>())
                                         : arg_str(arguments, "machine");
            Model model = Model::Spectrum48;
            if (name == "128" || name == "128k" || name == "128K") {
                model = Model::Spectrum128;
            } else if (name != "48" && name != "48k" && name != "48K") {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", "'machine' must be \"48\" or \"128\""}});
            }
            if (!engine.has_rom(model)) {
                return envelope_response(
                    conn, request_seq, command, false,
                    json{{"message", std::string("no ") + model_name(model)
                                         + " ROM is loaded: point \"rom\" at a "
                                         + (model == Model::Spectrum128 ? "32K" : "16K")
                                         + " image (roms/"
                                         + (model == Model::Spectrum128 ? "128" : "48")
                                         + ".rom)"}});
            }
            engine.set_model(model);
        }
        const std::string snapshot_path = arg_str(arguments, "snapshot");
        if (!snapshot_path.empty()) {
            std::vector<uint8_t> data;
            if (!read_file(snapshot_path, data)) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", "couldn't read snapshot " + snapshot_path}});
            }
            const std::string load_error = engine.load_snapshot(std::move(data));
            if (!load_error.empty()) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", load_error}});
            }
        } else {
            engine.reset();
        }

        // After the snapshot branch, and after its reset: auto-start does a
        // reset of its own, and it has to be the LAST one, since a reset
        // zeroes global_hc() and would leave the tape's pulse timestamps in
        // the future.
        const std::string tape_path = arg_str(arguments, "tape");
        if (!tape_path.empty()) {
            std::vector<uint8_t> data;
            if (!read_file(tape_path, data)) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", "couldn't read tape " + tape_path}});
            }
            const json& fast = arg(arguments, "tapeFastLoad");
            engine.set_tape_fast_load(!fast.is_boolean() || fast.get<bool>());
            const json& start = arg(arguments, "tapeAutoStart");
            const std::string load_error = engine.load_tape(
                std::move(data), tape_path, !start.is_boolean() || start.get<bool>());
            if (!load_error.empty()) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", load_error}});
            }
        }

        // Leaves the machine sitting in the ROM loader with no tape, ready for
        // one to be inserted later. Skipped when a tape was inserted AND
        // auto-started, since that has already typed the command -- doing it
        // twice would reset the machine out from under a tape mid-load.
        const json& waiting = arg(arguments, "waitForTape");
        if (waiting.is_boolean() && waiting.get<bool>()
            && !(!tape_path.empty() && (!arg(arguments, "tapeAutoStart").is_boolean()
                                        || arg(arguments, "tapeAutoStart").get<bool>()))) {
            const std::string type_error = engine.wait_for_tape();
            if (!type_error.empty()) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", type_error}});
            }
        }

        // Source-level debug info for the loaded program, acted on only when
        // BOTH are present. Deliberately not auto-cleared by a later launch
        // that omits them: a fresh load_debug_info, or another launch that
        // does pass sld/asm, is what replaces it.
        const std::string sld_path = arg_str(arguments, "sld");
        const std::string asm_path = arg_str(arguments, "asm");
        if (!sld_path.empty() && !asm_path.empty()) {
            std::string load_error;
            if (!sources.load_debug_info(sld_path, asm_path, load_error)) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", load_error}});
            }
        }

    } else if (command == "setExceptionBreakpoints") {
        // The filter list is absolute, not a delta: anything not named is
        // off. VS Code sends this during setup and on every change.
        bool on_interrupt = false;
        const json& filters = arg(arguments, "filters");
        if (filters.is_array()) {
            for (const json& filter : filters) {
                if (filter.is_string() && filter.get<std::string>() == "interrupt") {
                    on_interrupt = true;
                }
            }
        }
        engine.set_break_on_interrupt(on_interrupt);
        body = json{{"breakpoints", json::array({json{{"verified", true}}})}};

    } else if (command == "attach") {
        // Attaching means joining a machine that is already running -- one
        // started by an MCP client, or left behind by an earlier session --
        // so unlike `launch` this deliberately touches no machine state at
        // all: no reset, no ROM, no snapshot, no tape. Doing any of those
        // would destroy the very thing being attached to.
        //
        // Debug info is the exception, because it is not machine state: it
        // says how to read the machine, and without it an attach session can
        // only step raw disassembly. Same pairing rule as launch -- acted on
        // only when both halves are present.
        const std::string sld_path = arg_str(arguments, "sld");
        const std::string asm_path = arg_str(arguments, "asm");
        if (!sld_path.empty() && !asm_path.empty()) {
            std::string load_error;
            if (!sources.load_debug_info(sld_path, asm_path, load_error)) {
                return envelope_response(conn, request_seq, command, false,
                                         json{{"message", load_error}});
            }
        }

    } else if (command == "configurationDone") {
        // Nothing to do; acknowledged so the client handshake completes.

    } else if (command == "disconnect" || command == "terminate") {
        // Clicking Stop while a `continue`-triggered run is in flight
        // otherwise does nothing: the run loop only breaks early via
        // `Engine::pause()` (which bypasses the command queue -- a queued
        // pause could never be dequeued while run still owns the actor
        // thread). And since every other queued command waits behind that
        // run, an un-paused run makes the WHOLE session look hung, not just
        // this one request.
        engine.pause();

    } else if (command == "setInstructionBreakpoints") {
        std::set<uint16_t> requested;
        json results = json::array();
        const json& list = arg(arguments, "breakpoints");
        if (list.is_array()) {
            for (const json& bp : list) {
                uint16_t addr = 0;
                if (as_addr(arg(bp, "instructionReference"), arg_int(bp, "offset", 0), addr)) {
                    requested.insert(addr);
                }
            }
        }
        for (uint16_t addr : requested) {
            results.push_back(json{{"verified", true}, {"instructionReference", hex4(addr)}});
        }
        conn.instruction_breakpoints = std::move(requested);
        sync_breakpoints(engine, conn);
        body = json{{"breakpoints", results}};

    } else if (command == "setBreakpoints") {
        // Source-line breakpoints: map each line to an address via the SLD
        // data for whichever source this path names. A clicked line often has
        // no instruction of its own -- a label, a blank, a comment block --
        // so the lookup nudges forward to the next line that does and reports
        // where it landed, which the client moves its marker to. Only when
        // nothing nearby has code is the breakpoint reported unverified, so
        // the client greys it out rather than showing an armed breakpoint
        // that can never fire.
        const json& source = arg(arguments, "source");
        const std::string source_path =
            source.is_object() ? source.value("path", std::string()) : "";
        size_t source_file = 0;
        const RomSourcePtr rom_source = sources.source_for_path(source_path, source_file);

        std::set<uint16_t> addrs;
        json results = json::array();
        // This source's logpoints are replaced with its breakpoints, as DAP
        // says: the list is the whole of what the client wants there now.
        drop_logpoints(engine, conn.source_logpoints[source_path]);
        const json& list = arg(arguments, "breakpoints");
        if (list.is_array()) {
            for (const json& bp : list) {
                const int64_t line = arg_int(bp, "line", -1);
                if (line < 0) {
                    continue;
                }
                if (rom_source == nullptr) {
                    results.push_back(json{{"verified", false},
                                           {"line", line},
                                           {"message", "no debug info loaded for this source"}});
                    continue;
                }
                uint16_t addr = 0;
                uint32_t actual_line = 0;
                if (!rom_source->addr_for_line(source_file, uint32_t(line), addr,
                                               actual_line)) {
                    results.push_back(json{{"verified", false},
                                           {"line", line},
                                           {"message", "no instruction at this line"}});
                    continue;
                }
                // A logpoint reports and lets the run go on, so it is not one
                // of the addresses a run stops at.
                const std::string log_message = arg_str(bp, "logMessage");
                if (!log_message.empty()) {
                    uint32_t id = 0;
                    std::string error;
                    if (!add_logpoint(engine, sources, conn, "", addr, log_message, id, error)) {
                        results.push_back(json{{"verified", false},
                                               {"line", line},
                                               {"message", "logpoint: " + error}});
                        continue;
                    }
                    conn.source_logpoints[source_path].push_back(id);
                    results.push_back(json{{"verified", true},
                                           {"line", actual_line},
                                           {"instructionReference", hex4(addr)}});
                    continue;
                }
                addrs.insert(addr);
                // `line` here is the line the breakpoint ACTUALLY landed on,
                // which may be below the one clicked (see addr_for_line).
                // DAP clients move their marker to it.
                results.push_back(json{{"verified", true},
                                       {"line", actual_line},
                                       {"instructionReference", hex4(addr)}});
            }
        }
        conn.source_breakpoints[source_path] = std::move(addrs);
        sync_breakpoints(engine, conn);
        body = json{{"breakpoints", results}};

    } else if (command == "setLogpoints") {
        // Logpoints for a program rather than a person -- a panel that wants
        // to see something the game does, every time it does it, without the
        // user's breakpoints or the Debug Console being involved. Like
        // setBreakpoints, the list replaces everything this connection set
        // under the same group. Reports come back as `zxLog` events.
        const std::string group = arg_str(arguments, "group");
        if (group.empty()) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", "setLogpoints needs a group"}});
        }
        drop_logpoints(engine, conn.group_logpoints[group]);
        json results = json::array();
        const json& list = arg(arguments, "logpoints");
        if (list.is_array()) {
            for (const json& lp : list) {
                const json& where = arg(lp, "address");
                uint16_t addr = 0;
                std::string error;
                bool placed = false;
                if (where.is_number_integer()) {
                    addr = uint16_t(where.get<int64_t>());
                    placed = true;
                } else if (where.is_string()) {
                    placed = sources.parse_address(where.get<std::string>(), addr, error);
                } else {
                    error = "no address";
                }
                uint32_t id = 0;
                if (placed && add_logpoint(engine, sources, conn, group, addr,
                                           arg_str(lp, "message"), id, error)) {
                    conn.group_logpoints[group].push_back(id);
                    results.push_back(json{{"verified", true}, {"id", id}, {"address", hex4(addr)}});
                } else {
                    results.push_back(json{{"verified", false}, {"message", error}});
                }
            }
        }
        body = json{{"logpoints", results}};

    } else if (command == "source") {
        // Only reached when the client could not open the path itself -- one
        // it cannot resolve, or a client with no access to this machine's
        // disk. Serve the text, but only for a path that names a source we
        // hold debug info for: this port is not a way to read arbitrary
        // files.
        const json& source = arg(arguments, "source");
        const std::string source_path =
            source.is_object() ? source.value("path", std::string()) : "";
        size_t source_file = 0;
        const RomSourcePtr rom_source = sources.source_for_path(source_path, source_file);
        if (rom_source == nullptr) {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", "no debug info loaded for " + source_path}});
        }
        const std::string& file_path = rom_source->files[source_file].path;
        std::vector<uint8_t> bytes;
        if (!read_file(file_path, bytes)) {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", "couldn't read " + file_path}});
        }
        body = json{{"content", std::string(bytes.begin(), bytes.end())},
                    {"mimeType", "text/x-asm"}};

    } else if (command == "continue") {
        // Detached, as a spawned task: a run that
        // never hits a breakpoint must not wedge this connection's request
        // loop, so `pause` can still reach it and the `stopped` event
        // arrives via the Engine handler.
        std::thread([&engine] { engine.run(); }).detach();
        body = json{{"allThreadsContinued", true}};

    } else if (command == "next") {
        // Step over. A plain single step already steps INTO a CALL/RST (it
        // just executes the instruction, which pushes the return address and
        // jumps) -- that is exactly `stepIn`'s semantics. The block-repeat
        // instructions need the same treatment for a different reason: each
        // rewinds PC back to itself after copying one byte, so stepping one
        // instruction only ever completes ONE repeat. For both, run to a
        // temporary breakpoint at the following instruction. HALT needs a
        // third kind of special-casing -- see below.
        const MachineState state = engine.state();
        MemorySnapshot snapshot(engine);
        const ReadFn read = snapshot.reader();
        const Instruction inst = disassemble_one(read, state.pc);

        if (inst.text.rfind("HALT", 0) == 0) {
            // A HALT still waiting for its interrupt looks identical, via a
            // plain single step, to one that has already finished: PC reads
            // as halt_addr+1 either way (see Z80::registers()), and a single
            // step only advances one 4-T re-fetch while still waiting -- so
            // "step over" on a pending HALT looked like it did nothing at
            // all. Stepping over it also means skipping the ISR entirely,
            // landing back at the instruction after HALT. That address is
            // NOT always `state.pc`: pc only already reads as halt_addr+1
            // while `halted` is true; a fresh, not-yet-executed HALT shows
            // its own address like any other instruction, needing pc+length.
            //
            // And getting there is NOT a plain breakpoint+run: a breakpoint
            // only checks the address, and pc reads as that same return
            // address the whole time the CPU sits waiting -- so in a
            // `HALT; ...; JP` loop it would fire the instant the loop came
            // back around to wait for the NEXT interrupt.
            // `step_over_halt` checks `!halted` alongside the address.
            const uint16_t return_addr =
                state.halted ? state.pc : uint16_t(state.pc + inst.length);
            std::thread([&engine, return_addr] { engine.step_over_halt(return_addr); }).detach();
        } else if (is_step_over_as_run(inst.text)) {
            const uint16_t return_addr = uint16_t(state.pc + inst.length);
            // Don't clear a breakpoint the user actually set there.
            const bool already_set = conn.known_breakpoints.count(return_addr) != 0;
            std::thread([&engine, return_addr, already_set] {
                if (!already_set) {
                    engine.set_breakpoint(return_addr);
                }
                engine.run();
                if (!already_set) {
                    engine.clear_breakpoint(return_addr);
                }
            }).detach();
        } else {
            engine.step(1);
        }

    } else if (command == "stepIn" || command == "stepOut") {
        engine.step(1);

    } else if (command == "pause") {
        // Engine::pause fires on_stopped only when it actually interrupts a
        // run. Asking a machine that is ALREADY stopped to pause therefore
        // announces nothing -- and since a DAP client's entire idea of
        // running-or-stopped comes from these events, that silence leaves the
        // UI showing a Pause button that appears to do nothing, for ever.
        //
        // running() is an atomic read rather than a queued state() one, which
        // matters precisely here: state() would queue behind the very run this
        // is trying to interrupt, so the check would hang whenever it mattered.
        const bool was_running = engine.running();
        engine.pause();
        if (!was_running) {
            broadcast_event("stopped", json{{"reason", "pause"},
                                            {"threadId", THREAD_ID},
                                            {"allThreadsStopped", true}});
        }

    } else if (command == "stepBack" || command == "reverseContinue" || command == "stepBackInto"
               || command == "stepBackOut" || command == "runBackToAddress"
               || command == "runBackToWrite" || command == "returnToLive") {
        // stepBack and reverseContinue are standard DAP, sent by VS Code's own
        // toolbar buttons; the rest are this adapter's, from the extension.
#if ZX_REWIND
        if (engine.running()) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", "pause the machine before going back"}});
        }
        RewindOp op = RewindOp::StepBackOver;
        if (command == "reverseContinue") {
            op = RewindOp::ReverseContinue;
        } else if (command == "stepBackInto") {
            op = RewindOp::StepBackInto;
        } else if (command == "stepBackOut") {
            op = RewindOp::StepBackOut;
        } else if (command == "runBackToAddress") {
            op = RewindOp::RunBackToAddress;
        } else if (command == "runBackToWrite") {
            op = RewindOp::RunBackToWrite;
        }
        uint16_t address = 0;
        const json& source = arg(arguments, "source");
        const int64_t line = arg_int(arguments, "line", -1);
        if (op == RewindOp::RunBackToAddress && source.is_object() && line >= 0) {
            // Run Back to Cursor: a source line rather than an address, mapped
            // the way setBreakpoints maps one -- nudged forward to the next
            // line with an instruction.
            size_t source_file = 0;
            const RomSourcePtr rom_source =
                sources.source_for_path(source.value("path", std::string()), source_file);
            uint32_t actual_line = 0;
            if (rom_source == nullptr
                || !rom_source->addr_for_line(source_file, uint32_t(line), address, actual_line)) {
                return envelope_response(
                    conn, request_seq, command, false,
                    json{{"message", rom_source == nullptr
                                         ? "no debug info loaded for this source"
                                         : "no instruction at or after this line"}});
            }
        } else if (op == RewindOp::RunBackToAddress || op == RewindOp::RunBackToWrite) {
            bool present = false;
            std::string addr_error;
            if (!arg_opt_address(arguments, "address", sources, present, address, addr_error)
                || !present) {
                return envelope_response(
                    conn, request_seq, command, false,
                    json{{"message", addr_error.empty() ? "'" + command + "' needs an 'address'"
                                                        : addr_error}});
            }
        }
        // Detached, like continue: a search back through a minute of history
        // takes seconds, and this connection must stay free to send the pause
        // that cancels it. The landing arrives as a `stopped` event.
        const bool to_live = command == "returnToLive";
        std::thread([&engine, op, address, to_live, command] {
            const RewindOutcome o = to_live ? engine.return_to_live() : engine.rewind(op, address);
            report_rewind(command, o);
        }).detach();
#else
        return envelope_response(conn, request_seq, command, false,
                                 json{{"message", "this zx_server was built without rewind "
                                                  "(ZX_REWIND=OFF)"}});
#endif

    } else if (command == "history") {
        // Not standard DAP: how much history there is and where the machine
        // is in it, for the editor's "before live" status. Answers a build
        // without rewind too, so the editor can tell rather than guess.
#if ZX_REWIND
        body = history_body(engine.rewind_status());
#else
        body = json{{"rewind", false}};
#endif

    } else if (command == "dataBreakpointInfo") {
        // Can this be watched, and what do I call it? `name` is an address or
        // a symbol expression when asAddress is set (the memory inspector, and
        // the editor's own Watch Address command); otherwise it names a
        // variable, which here means a register.
        const std::string name = arg_str(arguments, "name");
        const json& as_address = arg(arguments, "asAddress");
        const bool is_address = as_address.is_boolean() && as_address.get<bool>();
        const int64_t reference = arg_int(arguments, "variablesReference", 0);
        if (!is_address && reference != 0) {
            // Registers live in the CPU, not in memory, and nothing on the bus
            // sees them change. Their memoryReference is what to watch instead.
            body = json{{"dataId", nullptr},
                        {"description", name
                                            + " is a register, which the bus never sees written."
                                              " Open it in the memory inspector and watch the"
                                              " address it points at."}};
        } else {
            uint16_t addr = 0;
            std::string addr_error;
            if (!sources.parse_address(name, addr, addr_error)) {
                body = json{{"dataId", nullptr}, {"description", addr_error}};
            } else {
                const int64_t bytes = arg_int(arguments, "bytes", 1);
                const uint16_t length = bytes > 0 ? uint16_t(std::min<int64_t>(bytes, 0x100)) : 1;
                std::string symbol;
                uint16_t offset = 0;
                std::string described = hex4(addr);
                if (sources.resolve_symbol(addr, symbol, offset)) {
                    described = symbol + (offset > 0 ? "+" + std::to_string(offset) : "") + " ("
                                + described + ")";
                }
                if (length > 1) {
                    described += ", " + std::to_string(length) + " bytes";
                }
                body = json{{"dataId", data_id(addr, length)},
                            {"description", described},
                            {"accessTypes", json::array({"read", "write", "readWrite"})},
                            // An address means the same thing next session.
                            {"canPersist", true}};
            }
        }

    } else if (command == "setDataBreakpoints") {
        // Replaces THIS connection's watchpoints, as DAP says -- and only
        // those: see Connection::data_breakpoints.
        std::map<std::string, uint32_t> wanted;
        json results = json::array();
        const json& list = arg(arguments, "breakpoints");
        if (list.is_array()) {
            for (const json& bp : list) {
                const std::string id = arg_str(bp, "dataId");
                Watchpoint w;
                if (!parse_data_id(id, w.addr, w.length)) {
                    results.push_back(json{{"verified", false},
                                           {"message", "unknown dataId '" + id + "'"}});
                    continue;
                }
                const std::string access = arg_str(bp, "accessType");
                w.on_read = access == "read" || access == "readWrite";
                w.on_write = access.empty() || access == "write" || access == "readWrite";
                std::string condition_error;
                if (!parse_watch_condition(arg_str(bp, "condition"), sources, w,
                                           condition_error)) {
                    results.push_back(json{{"verified", false}, {"message", condition_error}});
                    continue;
                }
                // A value test asks about the value written, so it has to see
                // every write, not only the ones that change something.
                w.on_change = w.test == Watchpoint::Test::None;
                const auto existing = conn.data_breakpoints.find(id);
                if (existing != conn.data_breakpoints.end()) {
                    w.id = existing->second; // an edit, not a second watchpoint
                }
                const uint32_t assigned = engine.set_watchpoint(w);
                wanted[id] = assigned;
                json result = json{{"verified", true}, {"instructionReference", hex4(w.addr)}};
                if (!arg_str(bp, "hitCondition").empty()) {
                    result["message"] = "hit counts are not supported; every access stops";
                }
                results.push_back(result);
            }
        }
        for (const auto& entry : conn.data_breakpoints) {
            if (wanted.count(entry.first) == 0) {
                engine.clear_watchpoint(entry.second);
            }
        }
        conn.data_breakpoints = std::move(wanted);
        body = json{{"breakpoints", results}};

    } else if (command == "setWatchpoint") {
        // Not standard DAP: the editor's own Watch Address command, and what
        // its Watchpoints view edits. Unlike setDataBreakpoints this adds one
        // rather than replacing a set, so it can live alongside them.
        uint16_t addr = 0;
        bool present = false;
        std::string addr_error;
        if (!arg_opt_address(arguments, "address", sources, present, addr, addr_error)
            || !present) {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", addr_error.empty() ? "'setWatchpoint' needs an 'address'"
                                                    : addr_error}});
        }
        Watchpoint w;
        w.id = uint32_t(arg_int(arguments, "id", 0));
        w.addr = addr;
        const int64_t length = arg_int(arguments, "length", 1);
        w.length = length > 0 ? uint16_t(std::min<int64_t>(length, 0x100)) : 1;
        const std::string access = arg_str(arguments, "access");
        w.on_read = access == "read" || access == "readWrite";
        w.on_write = access.empty() || access == "write" || access == "readWrite";
        const json& on_change = arg(arguments, "onChange");
        w.on_change = !on_change.is_boolean() || on_change.get<bool>();
        std::string condition_error;
        if (!parse_watch_condition(arg_str(arguments, "condition"), sources, w,
                                   condition_error)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", condition_error}});
        }
        if (w.test != Watchpoint::Test::None) {
            w.on_change = false;
        }
        const json& enabled = arg(arguments, "enabled");
        w.enabled = !enabled.is_boolean() || enabled.get<bool>();
        engine.set_watchpoint(w);
        body = watchpoints_json(engine, sources);

    } else if (command == "clearWatchpoint") {
        // With no id, all of them -- including any a client set through
        // setDataBreakpoints, which is why those ids are forgotten here too.
        const uint32_t id = uint32_t(arg_int(arguments, "id", 0));
        engine.clear_watchpoint(id);
        if (id == 0) {
            conn.data_breakpoints.clear();
        }
        body = watchpoints_json(engine, sources);

    } else if (command == "setAudioVolume") {
        // Not standard DAP: the screen panel's volume slider and mute button,
        // reaching the native sound device, which is where the sound is when
        // the server runs with --audio-device. A percentage, 0 to 100; with
        // none given, just reports. Not logged: a dragged slider sends dozens.
        const json& volume = arg(arguments, "volume");
        if (volume.is_number()) {
            const double v = volume.get<double>();
            engine.set_device_volume(v <= 0 ? 0u : v >= 100 ? 100u : uint32_t(v + 0.5));
        }
        body = json{{"volume", engine.device_volume()}};

    } else if (command == "watchpoints") {
        body = watchpoints_json(engine, sources);

    } else if (command == "threads") {
        body = json{{"threads", json::array({json{{"id", THREAD_ID}, {"name", "Z80"}}})}};

    } else if (command == "stackTrace") {
        // Frame 0 is the current PC; frames 1+ are call_stack's tracked
        // return addresses, innermost first -- call_stack is oldest-first,
        // so it is walked in reverse here.
        const MachineState state = engine.state();
        MemorySnapshot snapshot(engine);
        const ReadFn read = snapshot.reader();

        // stackTrace asks for a WINDOW -- `startFrame` and `levels` -- and
        // VS Code asks for about twenty at a time, paging as you scroll.
        // Building the whole stack regardless is what made clicking Pause
        // take seconds: each frame costs a disassembly, a symbol lookup and a
        // source-line match, and the UI does not redraw until this request
        // comes back. `totalFrames` is what tells the client there is more.
        const size_t total = state.call_stack.size() + 1;
        const int64_t requested_start = arg_int(arguments, "startFrame", 0);
        const int64_t requested_levels = arg_int(arguments, "levels", 0);
        size_t first = requested_start > 0 ? size_t(requested_start) : 0;
        if (first > total) {
            first = total;
        }
        // levels 0 (or absent) means "all of them from startFrame", per spec.
        size_t wanted = requested_levels > 0 ? size_t(requested_levels) : total - first;
        if (first + wanted > total) {
            wanted = total - first;
        }

        json frames = json::array();
        for (size_t i = 0; i < wanted; i++) {
            // Frame 0 is the current PC; 1.. are the tracked return
            // addresses, innermost first -- call_stack is oldest-first, so it
            // is indexed from the end. Ids are absolute positions in the
            // whole stack, not positions within this window, so they stay
            // meaningful across paged requests.
            const size_t index = first + i;
            const uint16_t addr =
                index == 0 ? state.pc : state.call_stack[state.call_stack.size() - index];
            frames.push_back(build_frame(read, sources, int64_t(index), addr));
        }
        body = json{{"stackFrames", frames}, {"totalFrames", total}};

    } else if (command == "scopes") {
        body = json{{"scopes",
                     json::array({
                         json{{"name", "Registers"}, {"variablesReference", 1000}, {"expensive", false}},
                         json{{"name", "Flags"}, {"variablesReference", 1001}, {"expensive", false}},
                         json{{"name", "Debug"}, {"variablesReference", 1002}, {"expensive", false}},
                     })}};

    } else if (command == "variables") {
        const int64_t reference = arg_int(arguments, "variablesReference", 0);
        json variables = json::array();
        if (reference == 1000) {
            variables = register_variables(engine.registers());
        } else if (reference == 1001) {
            variables = flag_variables(engine.registers());
        } else if (reference == 1002) {
            variables = debug_variables(engine.state());
        }
        body = json{{"variables", variables}};

    } else if (command == "setVariable") {
        // Editing a value in the Variables pane. Registers take anything an
        // address does -- "0x8000", "8000", "KEY_INT+9" -- since the pane
        // shows them in hex and that is what a user will type back. Flags,
        // IM and the flip-flops are too narrow for that to make sense and
        // take a plain 0/1 (or true/false) instead.
        const int64_t reference = arg_int(arguments, "variablesReference", 0);
        const std::string name = arg_str(arguments, "name");
        const std::string text = arg_str(arguments, "value");
        Registers r = engine.registers();
        std::string error;
        bool ok = false;
        if (reference == 1000) {
            const int width = register_width(name);
            if (width == 0) {
                error = "\"" + name + "\" is not a register";
            } else if (width <= 2) {
                // IM is 0, 1 or 2; a flip-flop is 0/1 or true/false.
                bool flag = false;
                if (parse_bool_or_bit(text, flag)) {
                    ok = set_register(r, name, flag ? 1 : 0, error);
                } else if (width == 2 && trimmed_copy(text) == "2") {
                    ok = set_register(r, name, 2, error);
                } else {
                    error = "\"" + text + "\" is not a value for " + name;
                }
            } else {
                uint16_t value = 0;
                ok = sources.parse_address(text, value, error) && set_register(r, name, value, error);
            }
        } else if (reference == 1001) {
            bool value = false;
            if (!parse_bool_or_bit(text, value)) {
                error = "a flag is 0 or 1";
            } else {
                ok = set_flag(r, name, value, error);
            }
        } else {
            error = "\"" + name + "\" is read-only";
        }
        if (!ok) {
            return envelope_response(conn, request_seq, command, false, json{{"message", error}});
        }
        const Registers after = engine.set_registers(r);
        // Echo the value as the pane formats it, so the edit shows exactly
        // what the machine now holds -- "0x0038" for a PC typed as KEY_INT.
        std::string shown;
        const json variables = reference == 1000 ? register_variables(after) : flag_variables(after);
        for (const json& v : variables) {
            if (v["name"] == name) {
                shown = v["value"].get<std::string>();
            }
        }
        body = json{{"value", shown}, {"variablesReference", 0}};

    } else if (command == "readMemory") {
        uint16_t addr = 0;
        as_addr(arg(arguments, "memoryReference"), arg_int(arguments, "offset", 0), addr);
        const int64_t count = arg_int(arguments, "count", 0);
        const std::vector<uint8_t> data =
            engine.read_memory(addr, count > 0 ? size_t(count) : 0);
        body = json{{"address", hex4(addr)}, {"data", base64_encode(data)}};

    } else if (command == "writeMemory") {
        uint16_t addr = 0;
        as_addr(arg(arguments, "memoryReference"), arg_int(arguments, "offset", 0), addr);
        std::vector<uint8_t> data = base64_decode(arg_str(arguments, "data"));
        const size_t written = data.size();
        engine.write_memory(addr, std::move(data));
        body = json{{"bytesWritten", written}};

    } else if (command == "disassemble") {
        uint16_t base_addr = 0;
        if (!as_addr(arg(arguments, "memoryReference"), arg_int(arguments, "offset", 0), base_addr)) {
            // VS Code's Disassembly View can internally generate a
            // "disassemblyNotAvailable" placeholder request with an empty
            // memoryReference (e.g. while a scroll event races session
            // setup). A known VS Code bug (microsoft/vscode#270361) means a
            // *failed* response to that specific request can permanently
            // wedge the view's internal loading lock, silently breaking all
            // future auto-scroll-to-PC behaviour for the rest of that
            // view's lifetime. A harmless empty result never triggers it.
            body = json{{"instructions", json::array()}};
        } else {
            body = do_disassemble(engine, sources, arguments, base_addr);
        }

    } else if (command == "keyDown") {
        // Not standard DAP -- sent by the screen-viewer webview's own
        // keydown/keyup handlers so the panel can be played live, not just
        // watched. key_down/key_up bypass the command queue so a keypress
        // takes effect even while a game is running under `continue`.
        const std::string key = arg_str(arguments, "key");
        engine.key_down(key);
        body = json{{"key", key}};

    } else if (command == "keyUp") {
        const std::string key = arg_str(arguments, "key");
        engine.key_up(key);
        body = json{{"key", key}};

    } else if (command == "setWriteOverlay") {
        // Not standard DAP -- the screen panel's own toggle. Dims the frame
        // and shows every bitmap byte written during it at full brightness,
        // which turns "what is this frame drawing" from something you infer
        // off a trace into something you can just look at. `opacityPercent`
        // is how far out of the dim a written byte is lifted (100, the
        // default, is full brightness) and `fadePercent` how much of that a
        // frame boundary takes off (100, the default, leaves only the frame
        // just drawn). Both are left as they were when not given, so the
        // panel's on/off button does not undo a setting made elsewhere.
        const json& enabled = arg(arguments, "enabled");
        const int64_t opacity = arg_int(arguments, "opacityPercent", -1);
        if (opacity >= 0) {
            engine.set_write_overlay_opacity(uint32_t(opacity));
        }
        const int64_t fade = arg_int(arguments, "fadePercent", -1);
        if (fade >= 0) {
            engine.set_write_overlay_fade(uint32_t(fade));
        }
        engine.set_write_overlay(enabled.is_boolean() ? enabled.get<bool>()
                                                      : !engine.write_overlay());
        body = json{{"enabled", engine.write_overlay()},
                    {"opacityPercent", engine.write_overlay_opacity()},
                    {"fadePercent", engine.write_overlay_fade()}};

    } else if (command == "setSpeed") {
        // The speed control in the debug toolbar. Kept as one request taking
        // either form, because "uncapped" and "a multiple of realtime" are the
        // same choice to whoever is picking from the list.
        const json& uncapped = arg(arguments, "uncapped");
        const json& multiplier = arg(arguments, "multiplier");
        if (multiplier.is_number()) {
            engine.set_speed(Speed::Realtime);
            engine.set_speed_multiplier(multiplier.get<double>());
        }
        if (uncapped.is_boolean()) {
            engine.set_speed(uncapped.get<bool>() ? Speed::Uncapped : Speed::Realtime);
        }
        const bool now_uncapped = engine.speed() == Speed::Uncapped;
        // Logged here rather than with the other requests, because what is
        // worth recording is the speed that took effect: the multiplier is
        // clamped, so the number asked for is not always the number running.
        if (now_uncapped) {
            log("DAP  setSpeed uncapped");
        } else {
            log("DAP  setSpeed %.4gx", engine.speed_multiplier());
        }
        body = json{{"uncapped", now_uncapped}, {"multiplier", engine.speed_multiplier()}};

    } else if (command == "setRasterView") {
        // Also not standard DAP. How a STOPPED machine's screen is drawn: the
        // beam's position marked, the picture composed as the beam has
        // actually drawn it, and the writes it has not reached yet picked out
        // of a dimmed screen.
        // Each field is left as it was when not given, so one of them can be
        // changed without knowing the other two.
        RasterView view = engine.raster_view();
        const json& marker = arg(arguments, "marker");
        if (marker.is_boolean()) {
            view.marker = marker.get<bool>();
        }
        const json& in_progress = arg(arguments, "inProgress");
        if (in_progress.is_boolean()) {
            view.in_progress = in_progress.get<bool>();
        }
        const json& pending = arg(arguments, "pending");
        if (pending.is_boolean()) {
            view.pending = pending.get<bool>();
        }
        engine.set_raster_view(view);
        body = json{{"marker", view.marker},
                    {"inProgress", view.in_progress},
                    {"pending", view.pending}};

    } else if (command == "graphicsView") {
        // Not standard DAP. Where the graphics panel is pointed, which an MCP
        // client sets and this hands on -- see GraphicsView in engine.h.
        //
        // Read-only here on purpose. Changes arrive as `zxGraphicsView` events
        // rather than by being asked for, and the panel needs this only when
        // it opens, to catch up on what was asked for before it existed. A
        // version of 0 means nothing ever was, and the panel then keeps its
        // own last state instead of being dragged to the defaults.
        uint64_t version = 0;
        const GraphicsView view = engine.graphics_view(&version);
        body = graphics_view_json(view, version);

    } else if (command == "startTrace") {
        // Not standard DAP either -- the trace viewer's Record button, so a
        // capture can be taken from the panel that displays it rather than
        // only from an MCP client. Trace control bypasses the command queue
        // (see engine.h), so this lands while a game is running, which is the
        // only time a live capture is interesting at all.
        TraceOptions options;
        options.path = arg_str(arguments, "path");
        if (options.path.empty()) {
            options.path = "trace.zxtrace";
        }
        const int64_t limit = arg_int(arguments, "limit", int64_t(TRACE_DEFAULT_LIMIT));
        if (limit < 0) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", "'limit' must not be negative"}});
        }
        options.limit = uint64_t(limit);
        // Both take a symbol expression as readily as a number, so the panel
        // can pass whatever was typed into its own fields straight through.
        uint16_t addr = 0;
        bool present = false;
        std::string addr_error;
        if (!arg_opt_address(arguments, "watch", sources, present, addr, addr_error)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", addr_error}});
        }
        if (present) {
            options.watch = uint32_t(addr);
        }
        // Where to begin: the capture opens now and waits for execution to
        // reach this address. Paired with stopTrace's own `pc`, that is how a
        // window of code is captured rather than a window of time.
        if (!arg_opt_address(arguments, "pc", sources, present, addr, addr_error)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", addr_error}});
        }
        if (present) {
            options.start_pc = uint32_t(addr);
        }
        // The other way to say where a capture begins: a T-state within the
        // frame. A plain number, not an address -- there is nothing for a
        // symbol to name here, and the range is a frame's rather than 64K.
        const json& tstate = arg(arguments, "tstate");
        if (!tstate.is_null()) {
            if (!tstate.is_number_unsigned() || tstate.get<uint64_t>() >= TSTATES_PER_FRAME) {
                return envelope_response(
                    conn, request_seq, command, false,
                    json{{"message", "'tstate' must be a T-state within the frame (0.."
                                         + std::to_string(TSTATES_PER_FRAME - 1) + ")"}});
            }
            options.start_tstate = uint32_t(tstate.get<uint64_t>());
        }
        const json& extra = arg(arguments, "extra");
        options.extra = extra.is_boolean() && extra.get<bool>();
        const json& ula = arg(arguments, "ula");
        options.ula = ula.is_boolean() && ula.get<bool>();
        // On unless asked otherwise, as the MCP tool has it: a capture is far
        // easier to read against names than against bare addresses.
        const json& symbols = arg(arguments, "symbols");
        if (!symbols.is_boolean() || symbols.get<bool>()) {
            options.resolve_symbol = symbol_resolver(sources);
        }

        const std::string error = engine.start_trace(options);
        if (!error.empty()) {
            return envelope_response(conn, request_seq, command, false, json{{"message", error}});
        }
        body = trace_body(engine.trace_status());

    } else if (command == "stopTrace") {
        // With a `pc` the capture is not closed here at all: it is told where
        // to close itself, and keeps recording until execution arrives.
        uint16_t pc = 0;
        bool present = false;
        std::string addr_error;
        if (!arg_opt_address(arguments, "pc", sources, present, pc, addr_error)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", addr_error}});
        }
        body = present ? trace_body(engine.stop_trace(pc)) : trace_body(engine.stop_trace());

    } else if (command == "traceStatus") {
        // Cheap and queue-free by design: the viewer polls this while a
        // capture runs, to show the row count climbing and to notice the
        // moment a capture closes itself at its limit.
        body = trace_body(engine.trace_status());

    } else if (command == "profile") {
        // Not standard DAP: the execution profile behind the editor's heat
        // map. `start` counts from zero, `stop` freezes the counts, and `get`
        // reports them folded into source lines and routines -- every line,
        // since the editor shades each one it has open. All three are queued
        // jobs the run loop services at its yields, so a profile starts and
        // stops on a running game without pausing it.
        //
        // `idle` (routine names) and `period` (a routine, or "frame") may come
        // with any action, and are applied first -- so a start counts against
        // them from its very first instruction.
        const json& idle_arg = arg(arguments, "idle");
        const json& period_arg = arg(arguments, "period");
        if (idle_arg.is_array() || period_arg.is_string()) {
            ProfileSettings settings = current_profile_settings();
            if (idle_arg.is_array()) {
                settings.idle.clear();
                for (const json& name : idle_arg) {
                    if (name.is_string()) {
                        settings.idle.push_back(name.get<std::string>());
                    }
                }
            }
            if (period_arg.is_string()) {
                settings.period = period_arg.get<std::string>();
            }
            apply_profile_settings(engine, sources, settings);
        }
        const std::string action = arg_str(arguments, "action");
        if (action == "start") {
            engine.start_profile();
        } else if (action == "stop") {
            engine.stop_profile();
        } else if (action != "get") {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", "profile action must be start, stop or get, not '" + action + "'"}});
        }
        const int64_t max_routines = arg_int(arguments, "maxRoutines", 100);
        const ProfileReport report = build_profile_report(engine.profile_snapshot(), sources);
        body = profile_report_json(report, 0, max_routines > 0 ? size_t(max_routines) : 0, true);
        // The whole call tree, flat: the profile view groups it by routine
        // itself, in whichever order it is showing.
        body["call_nodes"] = profile_call_nodes_json(report);

    } else if (command == "matchSymbols") {
        // Not standard DAP: what the trace panel's `from`/`to`/`watch` fields
        // offer as you type into them. Every one of those takes a symbol name
        // as readily as a number, and nothing else out here can enumerate the
        // ROM disassembly's 1000-odd labels to know what is on offer.
        //
        // Deliberately not queued and never touching the machine: this is a
        // keystroke-rate request against a parsed file, and must answer while
        // a game runs as readily as while one is stopped.
        const json& limit_arg = arg(arguments, "limit");
        size_t limit = SYMBOL_MATCH_LIMIT;
        if (limit_arg.is_number_unsigned()) {
            limit = std::min(size_t(limit_arg.get<uint64_t>()), SYMBOL_MATCH_LIMIT);
        }
        bool more = false;
        const std::vector<SymbolMatch> matches =
            sources.match_symbols(arg_str(arguments, "prefix"), limit, more);
        json list = json::array();
        for (size_t i = 0; i < matches.size(); i++) {
            list.push_back(json{{"name", matches[i].name}, {"address", matches[i].addr}});
        }
        body = json{{"symbols", list}, {"more", more}};

    } else if (command == "loadTape") {
        // Not standard DAP: the "ZX Spectrum: Load Tape" command, so a tape
        // can be put into a session that is already running rather than only
        // at launch.
        const std::string path = arg_str(arguments, "path");
        std::vector<uint8_t> data;
        if (path.empty() || !read_file(path, data)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", "couldn't read tape " + path}});
        }
        const json& fast = arg(arguments, "fastLoad");
        engine.set_tape_fast_load(!fast.is_boolean() || fast.get<bool>());
        const json& start = arg(arguments, "autoStart");
        // Serviced at the run loop's next yield when a run is in flight, so a
        // tape can be dropped into a running machine and the run carries
        // straight on into loading it -- no stop, no resume.
        const std::string load_error = engine.load_tape(
            std::move(data), path, !start.is_boolean() || start.get<bool>());
        if (!load_error.empty()) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", load_error}});
        }
        body = tape_body(engine.tape_status(), engine.tape_blocks());

    } else if (command == "saveSnapshot") {
        // Not standard DAP: MCP's save_snapshot, for the graphics panel. An
        // export that points into a snapshot instead of carrying a picture
        // saves the machine beside its atlas, so the addresses it names can be
        // read back later. A .sna unless the path ends in .z80.
        const std::string path = arg_str(arguments, "path");
        std::string tail = path.size() >= 4 ? path.substr(path.size() - 4) : std::string();
        for (size_t i = 0; i < tail.size(); i++) {
            tail[i] = char(std::tolower(static_cast<unsigned char>(tail[i])));
        }
        const SnapshotFormat format = tail == ".z80" ? SnapshotFormat::Z80 : SnapshotFormat::Sna;
        std::vector<uint8_t> data;
        const std::string message = path.empty() ? "no path given"
                                                 : engine.save_snapshot(data, format);
        if (!message.empty()) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", message}});
        }
        if (!write_file(path, data)) {
            return envelope_response(conn, request_seq, command, false,
                                     json{{"message", "couldn't write " + path}});
        }
        body = json{{"path", path}, {"bytes", data.size()}};

    } else if (command == "tapeControl") {
        // Queue-free, like the trace requests: Play has to reach a game that
        // is already running and waiting for its next tape part.
        // Applied before the action, so one request can turn fast load off
        // and start the tape -- which is what the pane's toggle does when the
        // tape is already running.
        const json& fast = arg(arguments, "fastLoad");
        if (fast.is_boolean()) {
            engine.set_tape_fast_load(fast.get<bool>());
        }
        const std::string what = arg_str(arguments, "action");
        if (what == "play") {
            engine.tape_play();
        } else if (what == "stop") {
            engine.tape_stop();
        } else if (what == "rewind") {
            engine.tape_rewind();
        } else if (what == "eject") {
            engine.tape_eject();
        } else if (what == "seek") {
            const json& block = arg(arguments, "block");
            if (!block.is_number_unsigned()) {
                return envelope_response(
                    conn, request_seq, command, false,
                    json{{"message", "'seek' needs a 'block' index"}});
            }
            engine.tape_seek(block.get<size_t>());
        } else if (!what.empty() && what != "status") {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message",
                      "'action' must be play, stop, rewind, seek, eject or status"}});
        }
        body = tape_body(engine.tape_status(), engine.tape_blocks());

    } else {
        success = false;
        body = json{{"message", "unsupported request: " + command}};
    }

    return envelope_response(conn, request_seq, command, success, body);
}

void handle_connection(std::shared_ptr<Connection> conn, Engine& engine, Sources& sources) {
    for (;;) {
        json request;
        if (!read_message(*conn, request)) {
            break;
        }
        const std::string command = request.value("command", std::string());
        const json response = handle_request(request, engine, sources, *conn);
        send_message(*conn, response);
        if (command == "initialize" && response.value("success", false)) {
            // Per the DAP spec the adapter sends `initialized` right after
            // its `initialize` response, signalling it is ready for
            // setBreakpoints/setInstructionBreakpoints. Real clients (VS
            // Code included) gate sending those on this event -- without
            // it, breakpoints set in the UI are never transmitted at all,
            // so `continue` runs straight past them.
            send_message(*conn, envelope_event(*conn, "initialized", json::object()));
        }
        if (command == "configurationDone" && response.value("success", false)
            && !engine.running()) {
            // A client that has never heard a `stopped` event assumes the
            // program is running. That assumption is right after a launch
            // that continues, and wrong for every attach to a machine sitting
            // paused -- which is the normal case, since a freshly started
            // server is stopped and so is one left at a breakpoint. The
            // symptom is a session that looks live but is not: a Pause button
            // instead of Continue, no call stack, no registers, and every
            // step control disabled.
            //
            // Nothing in the engine will announce a state it has held since
            // before this client connected, so the handshake ends by saying
            // where the machine actually is. Sent only to the connection that
            // just completed its handshake: other clients already know.
            send_message(*conn, envelope_event(*conn, "stopped",
                                               json{{"reason", "entry"},
                                                    {"threadId", THREAD_ID},
                                                    {"allThreadsStopped", true}}));
        }
    }
    // Leave the machine in a usable state for the next client rather than
    // leaving this connection's breakpoints armed forever.
    for (uint16_t addr : conn->known_breakpoints) {
        engine.clear_breakpoint(addr);
    }
    for (auto& entry : conn->source_logpoints) {
        drop_logpoints(engine, entry.second);
    }
    for (auto& entry : conn->group_logpoints) {
        drop_logpoints(engine, entry.second);
    }
}

} // namespace

void serve_dap(Engine& engine, Sources& sources, const std::string& host, uint16_t port,
               bool exit_on_disconnect) {
    net::Listener listener;
    std::string error;
    if (!listener.listen(host, port, error)) {
        std::fprintf(stderr, "DAP server failed to start: %s\n", error.c_str());
        return;
    }
    std::printf("DAP server listening on %s:%u\n", host.c_str(), unsigned(port));
    std::fflush(stdout);

    engine.on_stopped([&engine, &sources](StopReason reason, uint16_t pc) {
        // A watchpoint stop is the one kind where the address is not the
        // interesting part: what changed, and what changed it, is. Read back
        // from the machine, which has stopped by the time this runs.
        std::string description = hex4(pc);
        if (reason == StopReason::DataBreakpoint) {
            const WatchStop stop = engine.state().watch_stop;
            if (stop.valid) {
                description = describe_watch_stop(stop, sources);
                broadcast_event("output",
                                json{{"category", "console"},
                                     {"output", "Watchpoint: " + description + "\n"}});
            }
        }
        // A stop an MCP client caused -- an agent stepping, running to its own
        // breakpoint, loading a snapshot -- is still shown: the call stack,
        // registers and status all update. What preserveFocusHint stops is
        // VS Code acting on it: revealing the line in an editor (and so
        // switching the tab you were reading), opening the Run and Debug
        // view on a breakpoint, raising the window. Not sent for a stop this
        // window's own user asked for, because the hint also stops VS Code
        // selecting the new top frame -- and then the editor would not follow
        // the program as you stepped it yourself.
        json stopped{{"reason", stop_reason_name(reason)},
                     {"threadId", THREAD_ID},
                     {"allThreadsStopped", true},
                     {"description", description}};
        const bool quietly = engine.driver() == Driver::Mcp;
        if (quietly) {
            stopped["preserveFocusHint"] = true;
        }
        broadcast_event("stopped", stopped);
        if (quietly) {
            // With no frame newly selected, VS Code refreshes the call stack
            // but leaves the Variables pane showing the registers from before
            // the stop. `invalidated` asks for a refresh without selecting
            // anything; the old frame's scopes are fine to re-read, since
            // registers are the machine's, not a frame's.
            broadcast_event("invalidated", json{{"areas", json::array({"variables"})}});
        }
        // Named where possible: "stopped at 0x9607" says far less than
        // "stopped at 0x9607 (WAIT_RASTER+9)" when you are trying to work out
        // what the machine was doing.
        std::string where = hex4(pc); // hex4 already carries the 0x
        std::string name;
        uint16_t offset = 0;
        if (sources.resolve_symbol(pc, name, offset)) {
            where += " (" + name + (offset > 0 ? "+" + std::to_string(offset) : "") + ")";
        }
        log("Stopped: %s at %s", stop_reason_name(reason), where.c_str());
    });
    engine.on_continued([] {
        broadcast_event("continued",
                        json{{"threadId", THREAD_ID}, {"allThreadsContinued", true}});
        log("Running");
    });
    // The one place an MCP client can move something in VS Code. MCP and DAP
    // are separate front-ends onto one Engine with no channel between them, so
    // "point the graphics panel at sprite_017" becomes a set on the Engine
    // here and an unsolicited event out to every open DAP connection, which is
    // the only route from one to the other.
    engine.add_log_handler(deliver_log);
    engine.on_graphics_view([](const GraphicsView& v, uint64_t version) {
        broadcast_event("zxGraphicsView", graphics_view_json(v, version));
        log("Graphics view: %s %s as %s", v.source.c_str(),
            (v.source == "file" ? v.file : v.address).c_str(), v.format.c_str());
    });

    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        auto conn = std::make_shared<Connection>();
        conn->sock = std::move(sock);
        size_t open_now = 0;
        {
            std::lock_guard<std::mutex> lock(g_connections_mutex);
            g_connections.push_back(conn);
            open_now = g_connections.size();
        }
        log("DAP  client connected (%zu open)", open_now);
        std::thread([conn, &engine, &sources, exit_on_disconnect] {
            handle_connection(conn, engine, sources);
            size_t remaining = 0;
            {
                std::lock_guard<std::mutex> lock(g_connections_mutex);
                for (size_t i = 0; i < g_connections.size(); i++) {
                    if (g_connections[i] == conn) {
                        g_connections.erase(g_connections.begin() + long(i));
                        break;
                    }
                }
                remaining = g_connections.size();
            }
            log("DAP  client disconnected (%zu open)", remaining);
            // Counts currently-open connections, not "has anyone ever
            // connected" -- a short-lived diagnostic script can connect and
            // disconnect while VS Code's own session is still open, and that
            // must not kill the server out from under it. Only the
            // transition to zero counts as "debugging stopped".
            if (remaining == 0 && exit_on_disconnect) {
                log("Last DAP connection closed, exiting (--exit-on-disconnect)");
                std::exit(0);
            }
        }).detach();
    }
}

} // namespace zx
