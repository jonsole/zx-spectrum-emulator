// MCP server, ported from rust-core/zx-server/src/mcp.rs.
//
// Speaks the Streamable HTTP transport directly rather than pulling in an MCP
// library: the protocol here is JSON-RPC 2.0 over an HTTP POST, and with the
// socket and JSON layers already in place that is a few hundred lines we
// control, against several thousand vendored ones we would not.
//
// Responses are plain `application/json`. The spec also allows answering a
// POST with an SSE stream, and offers a GET for server-initiated messages;
// neither is needed since every tool here is request/response, so GET is
// refused with 405 (which the spec explicitly allows).
//
// The tool surface matches the Rust server's, plus set_speed for the
// emulator's realtime pacing.

#include "mcp_server.h"

#include "base64.h"
#include "file_io.h"
#include "beeper.h"
#include "http.h"
#include "net.h"
#include "screen_stream.h"
#include "snapshot.h"

#include <nlohmann/json.hpp>

#include <cstdio>
#include <functional>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;

namespace zx {
namespace {

constexpr const char* SERVER_NAME = "zx-spectrum";
constexpr const char* SERVER_VERSION = "0.1.0";
/// Protocol revision we implement. A client asking for a different one is
/// answered with this, per spec -- it then decides whether it can proceed.
constexpr const char* PROTOCOL_VERSION = "2025-06-18";

// ---- JSON-RPC error codes --------------------------------------------------
constexpr int PARSE_ERROR = -32700;
constexpr int INVALID_REQUEST = -32600;
constexpr int METHOD_NOT_FOUND = -32601;
constexpr int INVALID_PARAMS = -32602;

// ---- small helpers ---------------------------------------------------------

std::string hex_encode(const std::vector<uint8_t>& data) {
    std::string out;
    out.reserve(data.size() * 2);
    for (uint8_t b : data) {
        char buf[4];
        std::snprintf(buf, sizeof buf, "%02x", b);
        out += buf;
    }
    return out;
}

/// Decodes hex, tolerating whitespace. False on an odd digit count or any
/// non-hex character -- a silent partial write would be far worse than an
/// error message.
bool hex_decode(const std::string& text, std::vector<uint8_t>& out) {
    int nibble = 0;
    uint8_t value = 0;
    for (char c : text) {
        if (std::isspace(static_cast<unsigned char>(c))) {
            continue;
        }
        uint8_t digit;
        if (c >= '0' && c <= '9') {
            digit = uint8_t(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            digit = uint8_t(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            digit = uint8_t(c - 'A' + 10);
        } else {
            return false;
        }
        value = uint8_t((value << 4) | digit);
        if (++nibble == 2) {
            out.push_back(value);
            nibble = 0;
            value = 0;
        }
    }
    return nibble == 0;
}

std::string hex4(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "0x%04X", v);
    return buf;
}

json registers_json(const Registers& r) {
    return json{{"a", r.a},   {"f", r.f},     {"b", r.b},       {"c", r.c},
                {"d", r.d},   {"e", r.e},     {"h", r.h},       {"l", r.l},
                {"af", r.af()}, {"bc", r.bc()}, {"de", r.de()}, {"hl", r.hl()},
                {"a_", r.a_}, {"f_", r.f_},   {"b_", r.b_},     {"c_", r.c_},
                {"d_", r.d_}, {"e_", r.e_},   {"h_", r.h_},     {"l_", r.l_},
                {"ix", r.ix}, {"iy", r.iy},   {"sp", r.sp},     {"pc", r.pc},
                {"i", r.i},   {"r", r.r},     {"iff1", r.iff1}, {"iff2", r.iff2},
                {"im", r.im}, {"wz", r.wz}};
}

json state_json(const MachineState& s) {
    return json{{"pc", s.pc},
                {"registers", registers_json(s.registers)},
                {"halted", s.halted},
                {"running", s.running},
                {"border", s.border},
                {"tstate", s.tstate},
                {"frame_count", s.frame_count},
                {"interrupt_count", s.interrupt_count},
                {"breakpoints", s.breakpoints},
                {"call_stack", s.call_stack}};
}

// ---- tool results ----------------------------------------------------------

json text_result(const std::string& message) {
    return json{{"content", json::array({json{{"type", "text"}, {"text", message}}})}};
}

json json_result(const json& value) {
    return text_result(value.dump());
}

json image_result(const std::vector<uint8_t>& png) {
    return json{{"content", json::array({json{{"type", "image"},
                                              {"data", base64_encode(png)},
                                              {"mimeType", "image/png"}}})}};
}

/// A tool failure. Per the MCP spec this is a SUCCESSFUL JSON-RPC response
/// carrying isError, not a protocol-level error: the model is meant to see
/// the message and adapt, which a transport error would deny it.
json error_result(const std::string& message) {
    json result = text_result(message);
    result["isError"] = true;
    return result;
}

// ---- argument access -------------------------------------------------------

const json& arg(const json& args, const char* name) {
    static const json null_value;
    auto it = args.find(name);
    return it == args.end() ? null_value : *it;
}

bool arg_u16(const json& args, const char* name, uint16_t& out, std::string& error) {
    const json& v = arg(args, name);
    if (!v.is_number_integer()) {
        error = std::string("'") + name + "' is required and must be an integer";
        return false;
    }
    const int64_t n = v.get<int64_t>();
    if (n < 0 || n > 0xFFFF) {
        error = std::string("'") + name + "' must be a 16-bit address (0..65535)";
        return false;
    }
    out = uint16_t(n);
    return true;
}

bool arg_string(const json& args, const char* name, std::string& out, std::string& error) {
    const json& v = arg(args, name);
    if (!v.is_string()) {
        error = std::string("'") + name + "' is required and must be a string";
        return false;
    }
    out = v.get<std::string>();
    return true;
}

/// How much recent audio get_audio can look back over.
constexpr size_t MCP_CAPTURE_SAMPLES = size_t(AUDIO_SAMPLE_RATE) * 4;

/// The capture window get_audio reads from.
///
/// A function-local static because the tool surface is free functions with
/// nowhere to hang per-server state, and there is exactly one Engine in a
/// process. serve_mcp touches it at startup rather than leaving it to the
/// first get_audio call: registering a sink is what switches the beeper on, so
/// a lazily-created ring would make the first call after a run come back empty
/// -- the one call most likely to be asking "did that make a sound?".
AudioRing& capture_ring(Engine& engine) {
    static std::shared_ptr<AudioRing> ring = engine.add_audio_sink(MCP_CAPTURE_SAMPLES);
    return *ring;
}

/// Trace state, reported identically by start_trace, stop_trace and
/// trace_status so a caller only has to learn one shape.
json trace_status_json(const TraceStatus& status) {
    json out{{"active", status.active},
             {"path", status.path},
             {"rows", status.rows},
             {"limit", status.limit},
             {"extra", status.extra}};
    if (status.watching) {
        out["watch"] = status.watch;
    }
    return out;
}

/// What is on the tape, block by block -- the answer to "what does this image
/// contain", which otherwise means reading the file by hand. Sent with every
/// tape reply, so `tape_control {}` on its own is a full contents listing.
json tape_blocks_json(const std::vector<TapeBlockInfo>& blocks) {
    json out = json::array();
    for (size_t i = 0; i < blocks.size(); i++) {
        const TapeBlockInfo& b = blocks[i];
        json entry{{"index", i},
                   {"kind", b.kind},
                   {"data_bytes", b.data_bytes},
                   {"duration_ms", b.duration_ms}};
        if (!b.name.empty()) {
            entry["name"] = b.name;
        }
        // Only when they are not the ordinary case, so a plain .tap listing
        // stays readable instead of repeating "standard_speed: true" per row.
        if (!b.standard_speed) {
            entry["standard_speed"] = false;
            entry["tzx_block"] = b.id;
        }
        if (b.stop_tape) {
            entry["stop_tape"] = true;
        }
        if (b.pause_ms != 0) {
            entry["pause_ms"] = b.pause_ms;
        }
        out.push_back(std::move(entry));
    }
    return out;
}

/// Tape state, reported identically by load_tape and tape_control so a caller
/// only has to learn one shape.
json tape_status_json(const TapeStatus& status, const std::vector<TapeBlockInfo>& blocks) {
    json out{{"inserted", status.inserted},
             {"playing", status.playing},
             {"at_end", status.at_end},
             {"fast_load", status.fast_load},
             {"name", status.name},
             {"block", status.block},
             {"blocks", status.blocks},
             {"position_ms", status.position_ms},
             {"total_ms", status.total_ms}};
    if (!status.description.empty()) {
        out["description"] = status.description;
    }
    if (!status.warnings.empty()) {
        out["warnings"] = status.warnings;
    }
    if (!blocks.empty()) {
        out["block_list"] = tape_blocks_json(blocks);
    }
    return out;
}

// ---- the tool surface ------------------------------------------------------

/// A JSON Schema object for a tool with no parameters.
json no_params() {
    return json{{"type", "object"}, {"properties", json::object()}};
}

json schema(const json& properties, const std::vector<std::string>& required) {
    json s{{"type", "object"}, {"properties", properties}};
    if (!required.empty()) {
        s["required"] = required;
    }
    return s;
}

json integer_prop(const char* description) {
    return json{{"type", "integer"}, {"description", description}};
}

json string_prop(const char* description) {
    return json{{"type", "string"}, {"description", description}};
}

json bool_prop(const char* description) {
    return json{{"type", "boolean"}, {"description", description}};
}

json tools_list() {
    json tools = json::array();
    auto add = [&tools](const char* name, const char* description, const json& input_schema) {
        tools.push_back(
            json{{"name", name}, {"description", description}, {"inputSchema", input_schema}});
    };

    add("load_rom", "Load a 48K ROM image (base64-encoded, exactly 16384 bytes)",
        schema(json{{"rom_base64", string_prop("Base64-encoded 16384-byte 48K ROM image.")}},
               {"rom_base64"}));
    add("load_snapshot",
        "Load a .sna snapshot (base64-encoded) -- restores RAM, registers, and border",
        schema(json{{"sna_base64", string_prop("Base64-encoded 49179-byte .sna snapshot.")}},
               {"sna_base64"}));
    add("reset", "Reset the machine (registers only -- RAM/ROM contents are unaffected)",
        no_params());
    add("step", "Step one or more whole instructions, or a given number of T-states",
        schema(json{{"instructions", integer_prop("Whole instructions to step (default 1).")},
                    {"ticks", integer_prop("If set, step this many T-states instead of whole "
                                           "instructions.")}},
               {}));
    add("run", "Run until a breakpoint is hit or pause is called", no_params());
    add("pause", "Pause an in-flight run", no_params());
    add("set_breakpoint", "Set a breakpoint at an address",
        schema(json{{"addr", integer_prop("16-bit address.")}}, {"addr"}));
    add("clear_breakpoint", "Clear a breakpoint at an address",
        schema(json{{"addr", integer_prop("16-bit address.")}}, {"addr"}));
    add("read_memory", "Read memory starting at an address",
        schema(json{{"addr", integer_prop("16-bit address.")},
                    {"length", integer_prop("Bytes to read (default 1).")}},
               {"addr"}));
    add("write_memory", "Write hex-encoded bytes to memory starting at an address",
        schema(json{{"addr", integer_prop("16-bit address.")},
                    {"data_hex", string_prop("Hex-encoded bytes to write.")}},
               {"addr", "data_hex"}));
    add("get_registers", "Get the full Z80 register set", no_params());
    add("set_registers",
        "Set individual Z80 registers (fetch-modify-writeback -- omit fields to leave them "
        "unchanged)",
        schema(json{{"pc", integer_prop("Program counter.")},
                    {"sp", integer_prop("Stack pointer.")},
                    {"af", integer_prop("AF register pair.")},
                    {"bc", integer_prop("BC register pair.")},
                    {"de", integer_prop("DE register pair.")},
                    {"hl", integer_prop("HL register pair.")},
                    {"ix", integer_prop("IX index register.")},
                    {"iy", integer_prop("IY index register.")},
                    {"im", integer_prop("Interrupt mode (0, 1 or 2).")},
                    {"iff1", json{{"type", "boolean"}, {"description", "Interrupt flip-flop 1."}}},
                    {"iff2", json{{"type", "boolean"}, {"description", "Interrupt flip-flop 2."}}}},
               {}));
    add("key_down", "Press a key",
        schema(json{{"key", string_prop("Key name, e.g. \"A\", \"ENTER\", \"CAPS SHIFT\", "
                                        "\"SYM SHIFT\", \"SPACE\".")}},
               {"key"}));
    add("key_up", "Release a key",
        schema(json{{"key", string_prop("Key name, e.g. \"A\", \"ENTER\", \"CAPS SHIFT\", "
                                        "\"SYM SHIFT\", \"SPACE\".")}},
               {"key"}));
    add("get_screen", "Get the current screen as a PNG image", no_params());
    add("get_audio",
        "Measure what the beeper has been playing: sample count, RMS and peak level, and the "
        "pitch in Hz estimated from zero crossings. For checking that a BEEP, a sound effect or "
        "a tape tone actually came out, and at what frequency, without a human listening. Reads "
        "a rolling window of the most recent audio and does NOT consume it, so it can be called "
        "repeatedly and alongside live playback.",
        schema(json{{"duration_ms",
                     integer_prop("How far back to look, in milliseconds (default 1000, "
                                  "maximum 4000).")},
                    {"include_wav",
                     json{{"type", "boolean"},
                          {"description", "Also return the window as a base64 16-bit mono WAV. "
                                          "Off by default -- a second of audio is 44100 numbers, "
                                          "and the summary is usually the answer."}}}},
               {}));
    add("get_state",
        "Get a full state snapshot: pc, registers, breakpoints, running, border, call stack",
        no_params());
    add("load_debug_info",
        "Attach source-level debug info (a sjasmplus SLD file + its matching .asm) for the "
        "currently-loaded program -- enables resolve_symbol/resolve_address and DAP source-level "
        "debugging for this program's addresses, alongside the ROM's own (always available "
        "separately, so calls into the ROM still resolve)",
        schema(json{{"sld_path", string_prop("Path to the program's sjasmplus SLD file.")},
                    {"asm_path", string_prop("Path to the matching .asm source.")}},
               {"sld_path", "asm_path"}));
    add("resolve_symbol",
        "Look up a routine/label's address by name, checking the currently-loaded program's debug "
        "info first, then the ROM's own",
        schema(json{{"name", string_prop("Routine/label name, e.g. \"KEY_INT\".")}}, {"name"}));
    add("resolve_address",
        "Find the nearest named routine at or before a 16-bit address, with its offset (e.g. "
        "0x0005 -> {symbol: START, offset: 5}) -- same sources as resolve_symbol",
        schema(json{{"addr", integer_prop("16-bit address.")}}, {"addr"}));
    add("set_break_on_interrupt",
        "Stop a run at the first instruction of the interrupt handler each time the CPU "
        "accepts an interrupt -- for seeing what a handler does, or what state it was "
        "entered from",
        schema(json{{"enabled",
                     json{{"type", "boolean"},
                          {"description", "True to break on each accepted interrupt."}}}},
               {"enabled"}));
    add("start_trace",
        "Start a cycle-by-cycle bus trace: one row per half-T-state, written as the box-drawn "
        "table visualz80remix's Trace Log panel produces (M1/MREQ/IORQ/RFSH/RD/WR, address bus, "
        "data bus, PC and the instruction in flight). For questions about WHEN within an "
        "instruction something reaches the bus -- contention, interrupt timing, the exact "
        "T-state a write lands on. Start it, then run or step, then stop_trace -- both take "
        "effect immediately, so a capture can be opened and closed around part of a run rather "
        "than only around the whole of one. It also stops "
        "itself at `limit` rows, so a forgotten capture cannot fill the disk. View the result "
        "with tools/trace_viewer.html, or the \"ZX Spectrum: Show Trace\" command in VS Code.",
        schema(json{{"path", string_prop("File to write. Relative paths resolve against the "
                                         "server's working directory (the workspace folder). "
                                         "Default \"trace.zxtrace\".")},
                    {"limit", integer_prop("Half-T-states to record before the capture closes "
                                           "itself. 139,776 is one frame and 7,000,000 one "
                                           "emulated second; default 25000, and 0 means "
                                           "unlimited.")},
                    {"watch", integer_prop("16-bit address to sample into the Watch column on "
                                           "every half-clock. Omit for none.")},
                    {"symbols", json{{"type", "boolean"},
                                     {"description", "Resolve addresses against the loaded SLD "
                                                     "debug info: adds a Symbol column naming "
                                                     "where each instruction lives, and annotates "
                                                     "the Asm column's operands. On by default "
                                                     "when debug info is loaded; set false to keep "
                                                     "the layout identical to visualz80remix's."}}},
                    {"extra", json{{"type", "boolean"},
                                   {"description", "Add the 48K-specific columns (HALT, WAIT, "
                                                   "INT, NMI, frame, T-state). Off by default, "
                                                   "which keeps the layout identical to "
                                                   "visualz80remix's for side-by-side "
                                                   "comparison."}}}},
               {}));
    add("stop_trace",
        "Stop the running trace and report where it was written and how many half-T-states it "
        "captured. Takes effect immediately, mid-run included -- no need to pause first",
        no_params());
    add("trace_status",
        "Report whether a trace is running, its file, and its row count. Safe to poll during a "
        "run, so it can be watched filling up",
        no_params());
    add("set_speed",
        "Set emulation speed: \"realtime\" paces to a real 48K's 50Hz, \"uncapped\" runs as fast "
        "as the host allows (what the ZEXALL-style exercisers want)",
        schema(json{{"speed", string_prop("\"realtime\" or \"uncapped\".")}}, {"speed"}));
    add("load_tape",
        "Insert a .tap or .tzx tape image and, by default, start loading it: resets the machine, "
        "types LOAD \"\" for you, and starts the tape, so all that is left is to `run`. "
        "Standard-speed blocks are satisfied instantly by trapping the ROM's LD-BYTES routine; "
        "anything non-standard (turbo loaders, custom .tzx blocks) automatically falls back to "
        "real pulse-level playback through the EAR line, so every loader works -- just at tape "
        "speed, which for a whole game is minutes. Use set_speed uncapped to hurry that along",
        schema(json{{"path", string_prop("Path to the .tap or .tzx, resolved against the "
                                         "server's working directory. The format is detected "
                                         "from the file's contents, not its extension.")},
                    {"auto_start", bool_prop("Reset, type LOAD \"\" and start the tape. "
                                             "True by default. False leaves the tape inserted "
                                             "and stopped, for a program that loads its own "
                                             "next part.")},
                    {"fast_load", bool_prop("Trap the ROM loader and satisfy standard-speed "
                                            "blocks instantly. True by default; false to watch "
                                            "(and hear) the real pulse-level load.")}},
               {"path"}));
    add("tape_control",
        "Play, stop, rewind, seek or eject the inserted tape, or report what is on it and where "
        "it has got to -- every reply lists the blocks, so calling this with no arguments is how "
        "to find out what an image contains. Takes effect immediately, mid-run included -- which "
        "is the only time Play is any use, since a program waiting for the next part of a tape "
        "is by definition already running",
        schema(json{{"action", string_prop("\"play\", \"stop\", \"rewind\", \"seek\", "
                                           "\"eject\" or \"status\" (the default).")},
                    {"block", integer_prop("Which block to seek to, counting from 0, as "
                                           "listed in block_list. Only for \"seek\", which "
                                           "leaves the motor stopped -- follow it with "
                                           "\"play\" to load from there, which is how to "
                                           "replay one part of a multi-load tape.")},
                    {"fast_load", bool_prop("Also turn fast load on or off.")}},
               {}));
    return tools;
}

json call_tool(Engine& engine, Sources& sources, const std::string& name,
               const json& args) {
    std::string error;

    if (name == "load_rom") {
        std::string b64;
        if (!arg_string(args, "rom_base64", b64, error)) {
            return error_result(error);
        }
        const std::string message = engine.load_rom(base64_decode(b64));
        return message.empty() ? text_result("ROM loaded") : error_result(message);
    }

    if (name == "load_snapshot") {
        std::string b64;
        if (!arg_string(args, "sna_base64", b64, error)) {
            return error_result(error);
        }
        const std::string message = engine.load_snapshot(base64_decode(b64));
        return message.empty() ? text_result("snapshot loaded") : error_result(message);
    }

    if (name == "reset") {
        const Registers r = engine.reset();
        return json_result(json{{"pc", r.pc}});
    }

    if (name == "step") {
        const json& ticks = arg(args, "ticks");
        if (ticks.is_number_integer()) {
            const Registers r = engine.step_tstates(uint32_t(ticks.get<int64_t>()));
            return json_result(json{{"pc", r.pc}, {"registers", registers_json(r)}});
        }
        const json& count = arg(args, "instructions");
        const uint32_t instructions =
            count.is_number_integer() ? uint32_t(count.get<int64_t>()) : 1;
        const Registers r = engine.step(instructions);
        return json_result(json{{"pc", r.pc}, {"registers", registers_json(r)}});
    }

    if (name == "run") {
        // Blocks until a breakpoint or a pause, exactly as the Rust server
        // did. `pause` bypasses the command queue, so it can still reach this.
        const MachineState s = engine.run();
        return json_result(json{{"pc", s.pc}, {"running", s.running}});
    }

    if (name == "pause") {
        engine.pause();
        return text_result("paused");
    }

    if (name == "set_breakpoint" || name == "clear_breakpoint") {
        uint16_t addr = 0;
        if (!arg_u16(args, "addr", addr, error)) {
            return error_result(error);
        }
        if (name == "set_breakpoint") {
            engine.set_breakpoint(addr);
            return text_result("breakpoint set at " + hex4(addr));
        }
        engine.clear_breakpoint(addr);
        return text_result("breakpoint cleared at " + hex4(addr));
    }

    if (name == "read_memory") {
        uint16_t addr = 0;
        if (!arg_u16(args, "addr", addr, error)) {
            return error_result(error);
        }
        const json& len = arg(args, "length");
        const int64_t length = len.is_number_integer() ? len.get<int64_t>() : 1;
        if (length < 0 || length > 0x10000) {
            return error_result("'length' must be between 0 and 65536");
        }
        const std::vector<uint8_t> data = engine.read_memory(addr, size_t(length));
        return json_result(json{{"addr", addr}, {"hex", hex_encode(data)}});
    }

    if (name == "write_memory") {
        uint16_t addr = 0;
        std::string data_hex;
        if (!arg_u16(args, "addr", addr, error) || !arg_string(args, "data_hex", data_hex, error)) {
            return error_result(error);
        }
        std::vector<uint8_t> data;
        if (!hex_decode(data_hex, data)) {
            return error_result("'data_hex' must be an even number of hex digits");
        }
        engine.write_memory(addr, std::move(data));
        return text_result("memory written");
    }

    if (name == "get_registers") {
        return json_result(registers_json(engine.registers()));
    }

    if (name == "set_registers") {
        // Fetch-modify-writeback: anything not named keeps its current value.
        Registers r = engine.registers();
        auto apply16 = [&args](const char* key, uint16_t& field) {
            const json& v = arg(args, key);
            if (v.is_number_integer()) {
                field = uint16_t(v.get<int64_t>());
            }
        };
        auto apply_pair = [&args, &r](const char* key, void (Registers::*setter)(uint16_t)) {
            const json& v = arg(args, key);
            if (v.is_number_integer()) {
                (r.*setter)(uint16_t(v.get<int64_t>()));
            }
        };
        apply16("pc", r.pc);
        apply16("sp", r.sp);
        apply16("ix", r.ix);
        apply16("iy", r.iy);
        apply_pair("af", &Registers::set_af);
        apply_pair("bc", &Registers::set_bc);
        apply_pair("de", &Registers::set_de);
        apply_pair("hl", &Registers::set_hl);
        if (arg(args, "im").is_number_integer()) {
            r.im = uint8_t(arg(args, "im").get<int64_t>());
        }
        if (arg(args, "iff1").is_boolean()) {
            r.iff1 = arg(args, "iff1").get<bool>();
        }
        if (arg(args, "iff2").is_boolean()) {
            r.iff2 = arg(args, "iff2").get<bool>();
        }
        return json_result(registers_json(engine.set_registers(r)));
    }

    if (name == "key_down" || name == "key_up") {
        std::string key;
        if (!arg_string(args, "key", key, error)) {
            return error_result(error);
        }
        if (name == "key_down") {
            engine.key_down(key);
            return text_result("key down");
        }
        engine.key_up(key);
        return text_result("key up");
    }

    if (name == "get_screen") {
        return image_result(encode_png(engine.screen()));
    }

    if (name == "get_audio") {
        const json& window = arg(args, "duration_ms");
        int64_t duration_ms = window.is_number_integer() ? window.get<int64_t>() : 1000;
        if (duration_ms < 1) {
            duration_ms = 1;
        }
        const int64_t max_ms =
            int64_t(MCP_CAPTURE_SAMPLES) * 1000 / int64_t(engine.audio_sample_rate());
        if (duration_ms > max_ms) {
            duration_ms = max_ms;
        }
        const uint32_t rate = engine.audio_sample_rate();
        const size_t wanted = size_t(duration_ms * int64_t(rate) / 1000);

        std::vector<int16_t> samples;
        capture_ring(engine).peek_latest(samples, wanted);

        float rms = 0.0f;
        float peak = 0.0f;
        measure_level(samples, rms, peak);
        json out{{"sample_rate", rate},
                 {"samples", samples.size()},
                 {"duration_ms", samples.size() * 1000 / size_t(rate)},
                 {"rms", rms},
                 {"peak", peak},
                 {"silent", peak < 0.001f},
                 {"frequency_hz", estimate_frequency_hz(samples)}};
        if (arg(args, "include_wav").is_boolean() && arg(args, "include_wav").get<bool>()) {
            out["wav_base64"] = base64_encode(encode_wav(samples, rate));
        }
        return json_result(out);
    }

    if (name == "get_state") {
        return json_result(state_json(engine.state()));
    }

    if (name == "set_break_on_interrupt") {
        const json& enabled = arg(args, "enabled");
        if (!enabled.is_boolean()) {
            return error_result("'enabled' is required and must be a boolean");
        }
        engine.set_break_on_interrupt(enabled.get<bool>());
        return text_result(enabled.get<bool>()
                               ? "will break on each accepted interrupt"
                               : "no longer breaking on interrupts");
    }

    if (name == "start_trace") {
        TraceOptions options;
        const json& path = arg(args, "path");
        options.path = path.is_string() ? path.get<std::string>() : std::string("trace.zxtrace");
        const json& limit = arg(args, "limit");
        if (limit.is_number_integer()) {
            const int64_t n = limit.get<int64_t>();
            if (n < 0) {
                return error_result("'limit' must not be negative");
            }
            options.limit = uint64_t(n);
        }
        const json& watch = arg(args, "watch");
        if (watch.is_number_integer()) {
            const int64_t n = watch.get<int64_t>();
            if (n < 0 || n > 0xFFFF) {
                return error_result("'watch' must be a 16-bit address (0..65535)");
            }
            options.watch = uint32_t(n);
        }
        const json& extra = arg(args, "extra");
        options.extra = extra.is_boolean() && extra.get<bool>();
        const json& symbols = arg(args, "symbols");
        if (!symbols.is_boolean() || symbols.get<bool>()) {
            options.resolve_symbol = symbol_resolver(sources);
        }

        const std::string message = engine.start_trace(options);
        if (!message.empty()) {
            return error_result(message);
        }
        return json_result(trace_status_json(engine.trace_status()));
    }

    if (name == "stop_trace") {
        return json_result(trace_status_json(engine.stop_trace()));
    }

    if (name == "trace_status") {
        return json_result(trace_status_json(engine.trace_status()));
    }

    if (name == "set_speed") {
        std::string speed;
        if (!arg_string(args, "speed", speed, error)) {
            return error_result(error);
        }
        if (speed == "realtime") {
            engine.set_speed(Speed::Realtime);
            return text_result("speed: realtime (paced to 50Hz)");
        }
        if (speed == "uncapped") {
            engine.set_speed(Speed::Uncapped);
            return text_result("speed: uncapped");
        }
        return error_result("'speed' must be \"realtime\" or \"uncapped\"");
    }

    if (name == "load_debug_info") {
        std::string sld_path;
        std::string asm_path;
        if (!arg_string(args, "sld_path", sld_path, error)
            || !arg_string(args, "asm_path", asm_path, error)) {
            return error_result(error);
        }
        std::string load_error;
        if (!sources.load_debug_info(sld_path, asm_path, load_error)) {
            return error_result(load_error);
        }
        const RomSourcePtr loaded = sources.debug_info();
        return json_result(json{{"symbols", loaded->symbols.size()},
                                {"instructions", loaded->line_to_addr.size()}});
    }

    if (name == "resolve_symbol") {
        std::string symbol;
        if (!arg_string(args, "name", symbol, error)) {
            return error_result(error);
        }
        const std::vector<RomSourcePtr> active = sources.active();
        for (const RomSourcePtr& source : active) {
            auto it = source->symbols.find(symbol);
            if (it != source->symbols.end()) {
                return json_result(json{{"found", true}, {"address", it->second}});
            }
        }
        const std::string reason =
            active.empty()
                ? "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py"
                : "no symbol named \"" + symbol + "\"";
        return json_result(json{{"found", false}, {"reason", reason}});
    }

    if (name == "resolve_address") {
        uint16_t addr = 0;
        if (!arg_u16(args, "addr", addr, error)) {
            return error_result(error);
        }
        const std::vector<RomSourcePtr> active = sources.active();
        std::string symbol;
        uint16_t offset = 0;
        for (const RomSourcePtr& source : active) {
            if (source->symbol_at(addr, RomSource::NO_MAX, symbol, offset)) {
                return json_result(
                    json{{"found", true}, {"symbol", symbol}, {"offset", offset}});
            }
        }
        const std::string reason =
            active.empty()
                ? "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py"
                : "address precedes every known symbol";
        return json_result(json{{"found", false}, {"reason", reason}});
    }

    if (name == "load_tape") {
        std::string path;
        if (!arg_string(args, "path", path, error)) {
            return error_result(error);
        }
        std::vector<uint8_t> data;
        if (!read_file(path, data)) {
            return error_result("couldn't read tape " + path);
        }
        // Both flags default ON, so the bare call does the obvious thing.
        const json& fast = arg(args, "fast_load");
        engine.set_tape_fast_load(!fast.is_boolean() || fast.get<bool>());
        const json& start = arg(args, "auto_start");
        const std::string message =
            engine.load_tape(std::move(data), path, !start.is_boolean() || start.get<bool>());
        if (!message.empty()) {
            return error_result(message);
        }
        return json_result(tape_status_json(engine.tape_status(), engine.tape_blocks()));
    }

    if (name == "tape_control") {
        const json& fast = arg(args, "fast_load");
        if (fast.is_boolean()) {
            engine.set_tape_fast_load(fast.get<bool>());
        }
        const json& action = arg(args, "action");
        const std::string what = action.is_string() ? action.get<std::string>() : "status";
        if (what == "play") {
            engine.tape_play();
        } else if (what == "stop") {
            engine.tape_stop();
        } else if (what == "rewind") {
            engine.tape_rewind();
        } else if (what == "eject") {
            engine.tape_eject();
        } else if (what == "seek") {
            const json& block = arg(args, "block");
            if (!block.is_number_unsigned()) {
                return error_result("\"seek\" needs a \"block\" index");
            }
            engine.tape_seek(block.get<size_t>());
        } else if (what != "status") {
            return error_result("'action' must be \"play\", \"stop\", \"rewind\", "
                                "\"seek\", \"eject\" or \"status\"");
        }
        return json_result(tape_status_json(engine.tape_status(), engine.tape_blocks()));
    }

    return error_result("unknown tool: " + name);
}

// ---- JSON-RPC --------------------------------------------------------------

json rpc_error(const json& id, int code, const std::string& message) {
    return json{{"jsonrpc", "2.0"},
                {"id", id},
                {"error", json{{"code", code}, {"message", message}}}};
}

json rpc_result(const json& id, const json& result) {
    return json{{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
}

/// Handles one JSON-RPC message. `handled` comes back false for a
/// notification, which by definition gets no reply.
json handle_rpc(Engine& engine, Sources& sources, const json& message, bool& handled) {
    handled = true;
    const json id = message.contains("id") ? message["id"] : json();
    const std::string method = message.value("method", std::string());

    if (method.empty()) {
        return rpc_error(id, INVALID_REQUEST, "missing 'method'");
    }
    // Notifications carry no id and must not be answered.
    if (!message.contains("id")) {
        handled = false;
        return json();
    }

    static const json empty = json::object();
    const json& params =
        message.contains("params") && message["params"].is_object() ? message["params"] : empty;

    if (method == "initialize") {
        return rpc_result(
            id, json{{"protocolVersion", PROTOCOL_VERSION},
                     {"capabilities", json{{"tools", json{{"listChanged", false}}}}},
                     {"serverInfo", json{{"name", SERVER_NAME}, {"version", SERVER_VERSION}}}});
    }
    if (method == "ping") {
        return rpc_result(id, json::object());
    }
    if (method == "tools/list") {
        return rpc_result(id, json{{"tools", tools_list()}});
    }
    if (method == "tools/call") {
        const json& name = arg(params, "name");
        if (!name.is_string()) {
            return rpc_error(id, INVALID_PARAMS, "missing tool 'name'");
        }
        const json& arguments =
            params.contains("arguments") && params["arguments"].is_object() ? params["arguments"]
                                                                            : empty;
        return rpc_result(id, call_tool(engine, sources, name.get<std::string>(), arguments));
    }
    // resources/* and prompts/* are deliberately unimplemented: this server
    // exposes tools only, and says so in its initialize capabilities.
    return rpc_error(id, METHOD_NOT_FOUND, "unknown method: " + method);
}

// ---- HTTP plumbing ---------------------------------------------------------

void handle_post(Engine& engine, Sources& sources, const http::Request& request,
                 http::Response& response) {
    const json message = json::parse(request.body, nullptr, /*allow_exceptions=*/false);
    if (message.is_discarded()) {
        response.status = 400;
        response.body = rpc_error(json(), PARSE_ERROR, "invalid JSON").dump();
        return;
    }

    // A client may batch several messages into one array.
    if (message.is_array()) {
        json replies = json::array();
        for (const json& one : message) {
            bool handled = false;
            const json reply = handle_rpc(engine, sources, one, handled);
            if (handled) {
                replies.push_back(reply);
            }
        }
        if (replies.empty()) {
            response.status = 202; // nothing but notifications
            return;
        }
        response.body = replies.dump();
        return;
    }

    bool handled = false;
    const json reply = handle_rpc(engine, sources, message, handled);
    if (!handled) {
        response.status = 202; // a notification: accepted, nothing to say back
        return;
    }
    response.body = reply.dump();
}

void handle_connection(net::Socket sock, Engine& engine, Sources& sources) {
    std::string buffer;
    for (;;) {
        http::Request request;
        if (!http::read_request(sock, buffer, request)) {
            return; // EOF or a request we cannot parse
        }

        http::Response response;
        if (request.target != "/mcp") {
            response.status = 404;
            response.body = R"({"error":"not found; MCP is served at /mcp"})";
        } else if (request.method == "POST") {
            handle_post(engine, sources, request, response);
        } else if (request.method == "DELETE") {
            // Session teardown. Nothing is kept per-session (there is one
            // machine, shared), so this is just an acknowledgement.
            response.status = 202;
        } else {
            // Including GET: this server never initiates messages, so it has
            // no SSE stream to offer. The spec allows refusing it outright.
            response.status = 405;
            response.body = R"({"error":"method not allowed"})";
        }

        if (!http::write_response(sock, response)) {
            return;
        }
    }
}

} // namespace

void serve_mcp(Engine& engine, Sources& sources, const std::string& host, uint16_t port) {
    // Up front, so audio is already accumulating whenever get_audio is first
    // asked -- see capture_ring().
    capture_ring(engine);
    net::Listener listener;
    std::string error;
    if (!listener.listen(host, port, error)) {
        std::fprintf(stderr, "MCP server failed to start: %s\n", error.c_str());
        return;
    }
    std::printf("MCP server listening on %s:%u (streamable-HTTP, /mcp)\n", host.c_str(),
                unsigned(port));
    std::fflush(stdout);

    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        std::thread([s = std::move(sock), &engine, &sources]() mutable {
            handle_connection(std::move(s), engine, sources);
        }).detach();
    }
}

} // namespace zx
