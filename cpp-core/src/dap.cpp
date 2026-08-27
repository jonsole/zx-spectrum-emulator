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
// are its tracked return addresses innermost-first), each labeled with the
// disassembled instruction at that address. Source-level debug info (SLD
// symbols, ROM sources) is NOT ported yet, so `setBreakpoints` on a source
// line reports unverified and frames carry no `source`/`line`; instruction
// breakpoints, stepping, registers, memory and disassembly all work.

#include "dap.h"

#include "base64.h"
#include "disassembler.h"
#include "file_io.h"
#include "net.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
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
    const std::string body = message.dump();
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
    return json{{"seq", conn.seq.fetch_add(1)},
                {"type", "response"},
                {"request_seq", request_seq},
                {"success", success},
                {"command", command},
                {"body", body}};
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

json build_frame(const ReadFn& read, int64_t frame_id, uint16_t addr) {
    const Instruction inst = disassemble_one(read, addr);
    return json{{"id", frame_id},
                {"name", hex4(addr) + ": " + inst.text},
                {"instructionPointerReference", hex4(addr)},
                {"line", 0},
                {"column", 0}};
}

json do_disassemble(Engine& engine, const json& arguments, uint16_t base_addr) {
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
        instructions.push_back(json{{"address", hex4(inst.addr)},
                                    {"instructionBytes", bytes},
                                    {"instruction", inst.text}});
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

json handle_request(const json& req, Engine& engine, Connection& conn) {
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
                    {"supportsInstructionBreakpoints", true},
                    {"supportsReadMemoryRequest", true},
                    {"supportsWriteMemoryRequest", true},
                    {"supportsDisassembleRequest", true},
                    {"supportsSteppingGranularity", false}};

    } else if (command == "launch") {
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

    } else if (command == "attach" || command == "configurationDone" ||
               command == "setExceptionBreakpoints") {
        // Nothing to do; acknowledged so the client's handshake completes.
        // VS Code sends setExceptionBreakpoints during setup even though no
        // exception filters are advertised, and a failed response there
        // surfaces as an error popup.

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
        // Source-line breakpoints need SLD debug info to map a line to an
        // address, and that layer isn't ported yet -- report them
        // unverified rather than silently accepting breakpoints that would
        // never fire.
        const json& source = arg(arguments, "source");
        const std::string source_path = source.is_object() ? source.value("path", std::string()) : "";
        json results = json::array();
        const json& list = arg(arguments, "breakpoints");
        if (list.is_array()) {
            for (const json& bp : list) {
                const int64_t line = arg_int(bp, "line", -1);
                if (line < 0) {
                    continue;
                }
                results.push_back(json{{"verified", false},
                                       {"line", line},
                                       {"message", "no debug info loaded for this source"}});
            }
        }
        conn.source_breakpoints[source_path].clear();
        sync_breakpoints(engine, conn);
        body = json{{"breakpoints", results}};

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
        frames.push_back(build_frame(read, 0, state.pc));
        for (size_t i = state.call_stack.size(); i > 0; i--) {
            frames.push_back(build_frame(read, int64_t(frames.size()), state.call_stack[i - 1]));
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
            body = do_disassemble(engine, arguments, base_addr);
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

    } else {
        success = false;
        body = json{{"message", "unsupported request: " + command}};
    }

    return envelope_response(conn, request_seq, command, success, body);
}

void handle_connection(std::shared_ptr<Connection> conn, Engine& engine) {
    for (;;) {
        json request;
        if (!read_message(*conn, request)) {
            break;
        }
        const std::string command = request.value("command", std::string());
        const json response = handle_request(request, engine, *conn);
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

void serve_dap(Engine& engine, const std::string& host, uint16_t port, bool exit_on_disconnect) {
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
        std::thread([conn, &engine, exit_on_disconnect] {
            handle_connection(conn, engine);
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
