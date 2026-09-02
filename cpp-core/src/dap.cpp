// DAP (Debug Adapter Protocol) TCP server. Ported from
// rust-core/zx-server/src/dap.rs.
//
// Real base-protocol framing (`Content-Length: N\r\n\r\n{json}`), a
// per-connection request loop, and `Engine` events forwarded to every open
// connection as unsolicited `stopped`/`continued` events. Responses and
// events share one write mutex per connection, so they are each written
// whole, but the two can legitimately interleave -- a client must tolerate
// that.
//
// Stack traces come from `Spectrum48K::call_stack` (frame 0 is PC, frames 1+
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
#include "net.h"
#include "rom_source.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <cctype>
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
        std::snprintf(buf, sizeof buf, e.value > 0xFF ? "0x%04X" : "0x%02X", e.value);
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
    return json::array({json{{"name", "T-states"},
                             {"value", std::to_string(state.tstate)},
                             {"variablesReference", 0}},
                        json{{"name", "Frame"},
                             {"value", std::to_string(state.frame_count)},
                             {"variablesReference", 0}},
                        json{{"name", "Interrupts"},
                             {"value", std::to_string(state.interrupt_count)},
                             {"variablesReference", 0}}});
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
        auto it = source->addr_to_line.find(addr);
        if (it == source->addr_to_line.end()) {
            continue;
        }
        std::string label;
        uint16_t offset = 0;
        if (source->symbol_at(addr, SYMBOL_MAX_OFFSET, label, offset)) {
            if (offset != 0) {
                label += "+" + std::to_string(offset);
            }
            frame["name"] = label + "  " + name;
        }
        frame["source"] = json{{"name", file_name_of(source->asm_path)},
                               {"path", absolute_source_path(source->asm_path)}};
        frame["line"] = it->second;
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

// ---- request dispatch ------------------------------------------------------

json handle_request(const json& req, Engine& engine, Sources& sources, Connection& conn) {
    const std::string command = req.value("command", std::string());
    const int64_t request_seq = req.value("seq", int64_t(0));
    static const json empty_args = json::object();
    const json& arguments = req.contains("arguments") && req["arguments"].is_object()
                                ? req["arguments"]
                                : empty_args;

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
                    {"supportsSteppingGranularity", false}};

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

    } else if (command == "attach" || command == "configurationDone") {
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
        const RomSourcePtr rom_source = sources.source_for_path(source_path);

        std::set<uint16_t> addrs;
        json results = json::array();
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
                if (!rom_source->addr_for_line(uint32_t(line), addr, actual_line)) {
                    results.push_back(json{{"verified", false},
                                           {"line", line},
                                           {"message", "no instruction at this line"}});
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

    } else if (command == "source") {
        // Only reached when the client could not open the path itself -- one
        // it cannot resolve, or a client with no access to this machine's
        // disk. Serve the text, but only for a path that names a source we
        // hold debug info for: this port is not a way to read arbitrary
        // files.
        const json& source = arg(arguments, "source");
        const std::string source_path =
            source.is_object() ? source.value("path", std::string()) : "";
        const RomSourcePtr rom_source = sources.source_for_path(source_path);
        if (rom_source == nullptr) {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", "no debug info loaded for " + source_path}});
        }
        std::vector<uint8_t> bytes;
        if (!read_file(rom_source->asm_path, bytes)) {
            return envelope_response(
                conn, request_seq, command, false,
                json{{"message", "couldn't read " + rom_source->asm_path}});
        }
        body = json{{"content", std::string(bytes.begin(), bytes.end())},
                    {"mimeType", "text/x-asm"}};

    } else if (command == "continue") {
        // Detached, mirroring the Rust server's spawned task: a run that
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
        engine.pause();

    } else if (command == "threads") {
        body = json{{"threads", json::array({json{{"id", THREAD_ID}, {"name", "Z80"}}})}};

    } else if (command == "stackTrace") {
        // Frame 0 is the current PC; frames 1+ are call_stack's tracked
        // return addresses, innermost first -- call_stack is oldest-first,
        // so it is walked in reverse here.
        const MachineState state = engine.state();
        MemorySnapshot snapshot(engine);
        const ReadFn read = snapshot.reader();
        json frames = json::array();
        frames.push_back(build_frame(read, sources, 0, state.pc));
        for (size_t i = state.call_stack.size(); i > 0; i--) {
            frames.push_back(
                build_frame(read, sources, int64_t(frames.size()), state.call_stack[i - 1]));
        }
        body = json{{"stackFrames", frames}, {"totalFrames", frames.size()}};

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
    }
    // Leave the machine in a usable state for the next client rather than
    // leaving this connection's breakpoints armed forever.
    for (uint16_t addr : conn->known_breakpoints) {
        engine.clear_breakpoint(addr);
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

    engine.on_stopped([](StopReason reason, uint16_t pc) {
        broadcast_event("stopped", json{{"reason", stop_reason_name(reason)},
                                        {"threadId", THREAD_ID},
                                        {"allThreadsStopped", true},
                                        {"description", hex4(pc)}});
    });
    engine.on_continued([] {
        broadcast_event("continued",
                        json{{"threadId", THREAD_ID}, {"allThreadsContinued", true}});
    });

    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        auto conn = std::make_shared<Connection>();
        conn->sock = std::move(sock);
        {
            std::lock_guard<std::mutex> lock(g_connections_mutex);
            g_connections.push_back(conn);
        }
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
            // Counts currently-open connections, not "has anyone ever
            // connected" -- a short-lived diagnostic script can connect and
            // disconnect while VS Code's own session is still open, and that
            // must not kill the server out from under it. Only the
            // transition to zero counts as "debugging stopped".
            if (remaining == 0 && exit_on_disconnect) {
                std::printf("Last DAP connection closed, exiting (--exit-on-disconnect)\n");
                std::fflush(stdout);
                std::exit(0);
            }
        }).detach();
    }
}

} // namespace zx
