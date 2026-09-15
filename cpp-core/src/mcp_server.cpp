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
#include "log.h"
#include "beeper.h"
#include "http.h"
#include "net.h"
#include "profile_report.h"
#include "register_names.h"
#include "screen_stream.h"
#include "snapshot.h"

#include <nlohmann/json.hpp>

#include <cctype>
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

/// "1x", "0.5x", "10x" -- trailing zeros trimmed, because a speed picker
/// showing "0.50x" reads like a precision that is not there.
std::string describe_multiplier(double multiplier) {
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%.4g", multiplier);
    return std::string(buffer) + "x realtime";
}

/// The current speed, as both protocols report it.
json speed_json(const Engine& engine) {
    const bool uncapped = engine.speed() == Speed::Uncapped;
    return json{{"uncapped", uncapped},
                {"multiplier", engine.speed_multiplier()},
                {"description", uncapped
                                    ? std::string("uncapped -- as fast as the host manages")
                                    : describe_multiplier(engine.speed_multiplier())}};
}

json state_json(const MachineState& s) {
    json paging = json{{"port_7ffd", s.paging},
                       {"rom", (s.paging & PAGING_ROM1) != 0 ? 1 : 0},
                       {"bank_at_c000", s.paging & PAGING_BANK_MASK},
                       {"screen_bank", (s.paging & PAGING_SHADOW_SCREEN) != 0 ? 7 : 5},
                       {"locked", (s.paging & PAGING_LOCK) != 0}};
    return json{{"pc", s.pc},
                {"registers", registers_json(s.registers)},
                {"halted", s.halted},
                {"running", s.running},
                {"model", model_name(s.model)},
                {"paging", s.model == Model::Spectrum128 ? paging : json(nullptr)},
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

/// An OPTIONAL address argument in either shape a caller may write it: a JSON
/// integer (decimal, as JSON numbers are), or a string holding a symbol
/// expression -- "KEY_INT+9", "0x0038", "0038". `present` tells an omitted
/// argument from a real 0, which matters when 0x0000 is a legitimate address.
bool arg_opt_address(const json& args, const char* name, const Sources& sources, bool& present,
                     uint16_t& out, std::string& error) {
    const json& v = arg(args, name);
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
             {"waiting", status.waiting},
             {"path", status.path},
             {"rows", status.rows},
             {"limit", status.limit},
             {"extra", status.extra},
             {"ula", status.ula}};
    if (status.watching) {
        out["watch"] = status.watch;
    }
    // Only when gated, so a plain capture reports the shape it always has.
    if (status.has_start_pc) {
        out["start_pc"] = status.start_pc;
    }
    if (status.has_start_tstate) {
        out["start_tstate"] = status.start_tstate;
    }
    if (status.has_stop_pc) {
        out["stop_pc"] = status.stop_pc;
    }
    return out;
}

/// Recording state, reported identically by start_video, stop_video and
/// video_status so a caller only has to learn one shape.
json video_status_json(const VideoStatus& status) {
    json out{{"active", status.active},
             {"path", status.path},
             {"frames", status.frames},
             {"duration_ms", status.frames * 20},
             {"dropped", status.dropped}};
    if (status.limit != 0) {
        out["limit"] = status.limit;
    }
    // Only once there is one: a recording still going has not exited.
    if (!status.active) {
        out["exit_code"] = status.exit_code;
    }
    if (!status.error.empty()) {
        out["error"] = status.error;
    }
    return out;
}

/// The most frames one get_screen_sequence may return. Each is a separate
/// image for the model to look at, and sixteen 352x312 pictures is already
/// a lot of looking; a longer span is better taken as fewer frames further
/// apart, or as a video.
constexpr int64_t MAX_SEQUENCE_FRAMES = 16;
/// ...and the furthest apart they may be: 250 frames is five seconds.
constexpr int64_t MAX_SEQUENCE_EVERY = 250;
/// The longest a recording may be asked to stop itself at, in seconds.
constexpr double MAX_VIDEO_SECONDS = 600.0;

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

/// A parameter taking either a number or a symbol expression. Declared as
/// both types rather than as a string, so a caller with an address already in
/// hand does not have to format it first.
json address_prop(const char* description) {
    return json{{"type", json::array({"integer", "string"})}, {"description", description}};
}

json string_prop(const char* description) {
    return json{{"type", "string"}, {"description", description}};
}

json bool_prop(const char* description) {
    return json{{"type", "boolean"}, {"description", description}};
}

json number_prop(const char* description) {
    return json{{"type", "number"}, {"description", description}};
}

json tools_list() {
    json tools = json::array();
    auto add = [&tools](const char* name, const char* description, const json& input_schema) {
        tools.push_back(
            json{{"name", name}, {"description", description}, {"inputSchema", input_schema}});
    };

    add("load_rom",
        "Load a ROM image (base64-encoded): exactly 16384 bytes for the 48K ROM, or 32768 for "
        "the 128K pair (ROM 0, the editor/menu, then ROM 1, 48K BASIC). Either can be loaded "
        "whatever model the machine currently is, ready for a switch to the other.",
        schema(json{{"rom_base64", string_prop("Base64-encoded 16K (48K) or 32K (128K) ROM image.")}},
               {"rom_base64"}));
    add("load_snapshot",
        "Load a .sna or .z80 snapshot (base64-encoded) -- restores RAM, registers, border and, "
        "for a 128K snapshot, paging and the AY registers. The machine becomes whichever model "
        "the snapshot was taken on (48K or 128K), so the matching ROM must already be loaded.",
        schema(json{{"sna_base64", string_prop("Base64-encoded snapshot: a .sna (49179 bytes "
                                               "for 48K, 131103 or 147487 for 128K) or a .z80 "
                                               "of version 1, 2 or 3.")}},
               {"sna_base64"}));
    add("save_snapshot",
        "Save the machine as a .sna or .z80 file (by the path's extension; .sna unless it ends "
        "in .z80) -- RAM, registers, border and on a 128K the paging and AY state, taken "
        "between two instructions so it is consistent even mid-run. Reload it later with "
        "load_snapshot to return to exactly this point: past a long tape load, at the start of "
        "a level, or just before the thing being debugged goes wrong.",
        schema(json{{"path", string_prop("File to write, .sna or .z80 extension included. Relative "
                                         "paths resolve against the server's working directory "
                                         "(the workspace folder). Overwrites an existing file.")}},
               {"path"}));
    add("reset",
        "Reset the machine (registers and paging only -- RAM/ROM contents are unaffected). "
        "Optionally switch it to the other model first: a 128K boots to the 128 menu, a 48K to "
        "48K BASIC.",
        schema(json{{"machine", string_prop("\"48\" or \"128\": make the machine this model "
                                            "before resetting. Omit to keep the current one. "
                                            "The model's ROM must already be loaded.")}},
               {}));
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
    add("read_memory",
        "Read memory starting at an address, as the CPU sees it -- or, with bank, straight out "
        "of one of a 128K's eight 16K RAM banks whether or not it is paged in",
        schema(json{{"addr", integer_prop("16-bit address; with bank, an offset 0..16383 "
                                          "within that bank.")},
                    {"length", integer_prop("Bytes to read (default 1).")},
                    {"bank", integer_prop("RAM bank 0-7 to read directly, ignoring paging. "
                                          "Bank 5 is the screen (0x4000 on both models), 2 "
                                          "is 0x8000, 7 the 128K's shadow screen.")}},
               {"addr"}));
    add("write_memory", "Write hex-encoded bytes to memory starting at an address",
        schema(json{{"addr", integer_prop("16-bit address.")},
                    {"data_hex", string_prop("Hex-encoded bytes to write.")}},
               {"addr", "data_hex"}));
    add("get_registers", "Get the full Z80 register set", no_params());
    add("set_registers",
        "Set any Z80 registers (fetch-modify-writeback -- omit fields to leave them unchanged). "
        "Every register is addressable: the pairs, their 8-bit halves, the shadow set (af_, "
        "bc_, de_, hl_ and a_ ... l_), the index registers and their halves, I, R, IM and the "
        "flip-flops. A 16-bit value may be a symbol expression -- \"KEY_INT+9\", \"0x8000\", "
        "\"8000\" (bare is hex) -- so pc: \"MAIN_LOOP\" jumps straight there. Pairs are "
        "applied before halves, so {hl: 0x1234, l: 0} ends with HL=0x1200. Replies with the "
        "full register set afterwards",
        schema(json{{"pc", address_prop("Program counter.")},
                    {"sp", address_prop("Stack pointer.")},
                    {"af", address_prop("AF register pair.")},
                    {"bc", address_prop("BC register pair.")},
                    {"de", address_prop("DE register pair.")},
                    {"hl", address_prop("HL register pair.")},
                    {"ix", address_prop("IX index register.")},
                    {"iy", address_prop("IY index register.")},
                    {"af_", address_prop("AF' shadow pair.")},
                    {"bc_", address_prop("BC' shadow pair.")},
                    {"de_", address_prop("DE' shadow pair.")},
                    {"hl_", address_prop("HL' shadow pair.")},
                    {"a", integer_prop("Accumulator.")},
                    {"f", integer_prop("Flags byte (S Z 5 H 3 P/V N C, bit 7 down to 0).")},
                    {"b", integer_prop("B.")},
                    {"c", integer_prop("C.")},
                    {"d", integer_prop("D.")},
                    {"e", integer_prop("E.")},
                    {"h", integer_prop("H.")},
                    {"l", integer_prop("L.")},
                    {"a_", integer_prop("A'.")},
                    {"f_", integer_prop("F'.")},
                    {"b_", integer_prop("B'.")},
                    {"c_", integer_prop("C'.")},
                    {"d_", integer_prop("D'.")},
                    {"e_", integer_prop("E'.")},
                    {"h_", integer_prop("H'.")},
                    {"l_", integer_prop("L'.")},
                    {"ixh", integer_prop("High byte of IX.")},
                    {"ixl", integer_prop("Low byte of IX.")},
                    {"iyh", integer_prop("High byte of IY.")},
                    {"iyl", integer_prop("Low byte of IY.")},
                    {"i", integer_prop("Interrupt vector register.")},
                    {"r", integer_prop("Memory refresh register.")},
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
    add("get_screen_sequence",
        "Get a SEQUENCE of screens: several consecutive frames, one image each, in the order "
        "the machine drew them -- as close to watching the display as still pictures get. For "
        "anything that only shows up as change over time: whether a sprite moves and which "
        "way, whether something flickers, what a loading screen or an animation does frame by "
        "frame. Each frame is exactly as the ULA completed it, tagged with its frame number "
        "and its offset in emulated milliseconds from the first. On a running machine the "
        "frames are picked out of the run without disturbing it; on a stopped one the machine "
        "is stepped forward the needed number of frames and left stopped there. For a longer "
        "or smoother record use start_video instead.",
        schema(json{{"frames", integer_prop("How many frames to return, 1-16. Default 8.")},
                    {"every", integer_prop("Take one frame in this many, 1-250. 1 (the "
                                           "default) is consecutive frames, 20ms apart; 5 is a "
                                           "frame every 100ms; 50 is one a second.")}},
               {}));
    add("start_video",
        "Start recording the display to a video file: every completed frame, at the "
        "Spectrum's own 50 frames a second, encoded by ffmpeg into whatever the extension "
        "asks for (.mp4 plays everywhere; .webm and .gif also work). Records a RUNNING machine "
        "as it runs and a stepped one step by step, mid-run included, and keeps going until "
        "stop_video or its own `seconds`/`frames` limit -- so the shape is start, drive the "
        "machine (run, keys, steps), stop. The file is for a person to watch: to see what it "
        "recorded yourself, use get_screen_sequence. Needs ffmpeg on PATH, or zx_server "
        "started with --ffmpeg <path>.",
        schema(json{{"path", string_prop("File to write, its extension choosing the format. "
                                         "Relative paths resolve against the server's working "
                                         "directory (the workspace folder). Default "
                                         "\"screen.mp4\".")},
                    {"seconds", number_prop("Stop by itself after this much emulated time, "
                                            "up to 600. Omit to record until stop_video.")},
                    {"frames", integer_prop("Stop by itself after this many frames -- the "
                                            "same limit as `seconds`, in frames (50 a "
                                            "second). Omit to record until stop_video.")},
                    {"scale", integer_prop("Integer pixel scaling, 1-4. Default 2, which "
                                           "makes the 352x312 canvas a 704x624 video that "
                                           "plays crisply.")}},
               {}));
    add("stop_video",
        "Stop the recording and finalise the file, reporting its path and how many frames it "
        "holds. Takes effect immediately, mid-run included -- no need to pause first",
        no_params());
    add("video_status",
        "Report whether a recording is in progress, its file, and its frame count so far. "
        "Safe to poll during a run. A recording that reached its own limit is finalised "
        "here if stop_video has not been called",
        no_params());
    add("set_write_overlay",
        "Turn the display-write overlay on or off. With it on, the picture is dimmed to half "
        "brightness and every BYTE the program writes to the screen bitmap -- all eight of its "
        "pixels, in their own colours -- is shown at full brightness on the frame it was "
        "written, so a get_screen shows WHAT THE PROGRAM IS ACTUALLY DRAWING: which sprites "
        "move, how much of the screen a redraw touches, which parts are static. Every write "
        "counts, erases and rewrites of the same value included; attributes are not tracked "
        "at all. It dims the picture while it is on, so turn it off to read the screen "
        "normally again",
        schema(json{{"enabled", bool_prop("True to show the overlay, false to hide it. "
                                          "Toggles when omitted.")},
                    {"opacity_percent",
                     integer_prop("How far a freshly written byte is lifted out of the dimmed "
                                  "picture, 0-100. 100 (the default) is full brightness; 50 "
                                  "stops half-way, so a write stands out less. Left as it was "
                                  "when omitted.")},
                    {"fade_percent",
                     integer_prop("How much of the overlay each frame boundary removes, 0-100. "
                                  "100 (the default) clears it completely, so each frame shows "
                                  "only its own drawing. Lower values leave a fading trail "
                                  "across the frames that follow -- 10 fades over about a "
                                  "second -- and 0 never fades, accumulating everything the "
                                  "program has drawn since. Note it only bites where drawing "
                                  "STOPS: a game repainting its playfield every frame refreshes "
                                  "those bytes to full brightness before any fade can dim them. "
                                  "Left as it was when omitted.")}},
               {}));
    add("set_raster_view",
        "Control how the screen is drawn while the machine is STOPPED -- stepping, or sitting "
        "on a breakpoint -- or running in SLOW MOTION (a set_speed multiplier below 1). At full "
        "speed none of it applies, and one whole completed frame is shown instead: the beam "
        "crosses the screen in 20ms there, far faster than frames are published, so a marker "
        "would be a smear. Slowed down it sweeps visibly instead, which is the point. Between "
        "them these answer where the beam is and what it has left to do, which "
        "is what any frame-synchronised effect -- border stripes, a mid-screen colour change, a "
        "sprite racing the raster -- has to be reasoned about and is otherwise invisible in a "
        "picture of the last completed frame. Every field is left as it was when omitted",
        schema(json{{"marker",
                     bool_prop("Mark the beam: a dashed line across the raster line it is on "
                               "and a solid tick at the exact dot. On by default.")},
                    {"in_progress",
                     bool_prop("Compose the picture the way a CRT has it at this instant -- "
                               "this frame's drawing down to the beam, the previous frame "
                               "beyond it -- instead of the last completed frame. On by "
                               "default. This is what makes a raster effect visible while "
                               "stepping: a border stripe appears at the line the OUT happened "
                               "on rather than only in the next completed frame.")},
                    {"pending",
                     bool_prop("Pick out every display byte -- bitmap or attribute -- written "
                               "since the beam last passed it: the changes that are in memory "
                               "but NOT YET ON THE PICTURE, because the beam has not reached "
                               "them. Those bytes keep their own colours and the rest of the "
                               "screen is dimmed to half brightness around them -- and the dim "
                               "goes on whether or not anything turns out to be pending, so a "
                               "screen with nothing at full brightness means the beam has "
                               "displayed everything written so far. Off by default")}},
               {}));
    add("set_graphics_view",
        "Point VS Code's ZX Spectrum Graphics panel at some bytes and say how to draw them: a "
        "sprite sheet, a character set, or a screen dump. This is the one tool that moves "
        "something in the editor rather than in the machine -- it changes NOTHING the emulator "
        "does, and returns no picture. Use it to put a sprite in front of the person you are "
        "working with (\"here is what is actually at sprite_017\"), not to look at one yourself. "
        "It needs an open VS Code debug session to reach; with none, the view is remembered and "
        "the panel picks it up when one starts. The panel opens itself if it is closed. Every "
        "field is left as it was when omitted, so a width can be corrected without restating the "
        "address. Traffic is one-way: what the person then does with the panel's own controls is "
        "not reported back here",
        schema(json{{"source",
                     string_prop("Where the bytes come from: \"memory\" (the default) reads the "
                                 "running machine, \"file\" reads `file`, \"selection\" uses "
                                 "whatever is selected in their editor.")},
                    {"address",
                     string_prop("For source=memory. A number in any usual form or a SYMBOL "
                                 "NAME, optionally displaced: \"16384\", \"$4000\", \"0x4000\", "
                                 "\"4000h\", \"sprite_000\", \"sprite_000+4\". Resolved in the "
                                 "editor against the same symbol table resolve_symbol uses, so "
                                 "a name is usually the clearer thing to send.")},
                    {"file", string_prop("For source=file. Path to a .scr or a raw binary.")},
                    {"offset",
                     integer_prop("For source=file or source=selection: bytes to skip at the "
                                  "start. How a byte range inside a bigger file is addressed, "
                                  "since only source=memory has an `address` -- a sprite at "
                                  "$8B0A in a .sna is offset 27 + $8B0A - $4000, the 27 being "
                                  "the snapshot header.")},
                    {"format",
                     string_prop("\"sprite\" for a grid of items laid out by the width/height/"
                                 "count fields; \"font\" for the same with a character set's "
                                 "shape (1 byte wide, 8 rows, 96 items) filled in and each glyph "
                                 "labelled with its code; \"screen\" for the display file's "
                                 "scrambled layout, coloured from the attributes when 6912 bytes "
                                 "are available rather than 6144.")},
                    {"width", integer_prop("Bytes across per item, BEFORE any mask interleaving "
                                           "-- so 3 means 24 pixels wide however `interleave` is "
                                           "set. Ignored by format=screen.")},
                    {"height", integer_prop("Pixel rows per item.")},
                    {"count", integer_prop("How many items to draw. Items past the end of the "
                                           "data are reported rather than drawn as rubbish, so "
                                           "guessing high is a way to find out how many there "
                                           "are.")},
                    {"columns", integer_prop("Items per row of the sheet.")},
                    {"header",
                     integer_prop("Bytes to skip before EACH item, for data that carries a "
                                  "per-sprite width/height pair ahead of its bitmap.")},
                    {"first",
                     integer_prop("The character code of the first item, in format=font "
                                  "(default 32, which is where the ROM's set at $3D00 starts).")},
                    {"interleave",
                     string_prop("How a mask is stored alongside the bitmap, interleaved PER "
                                 "BYTE across a row: \"none\" (default), \"md\" for mask then "
                                 "data, \"dm\" for data then mask. Masked pixels are drawn "
                                 "transparent over a checkerboard, so the wrong choice here is "
                                 "obvious rather than merely wrong-looking.")},
                    {"invert_mask",
                     bool_prop("Read a CLEAR mask bit as transparent rather than a set one.")},
                    {"flip",
                     bool_prop("Row 0 of the data is the BOTTOM row of the picture -- how "
                               "Ultimate stored theirs, and so how anything descended from that "
                               "code stores them.")},
                    {"ink", integer_prop("0-15, the ULA's palette with bright as the top bit "
                                         "(so 15 is bright white). What a set bit is drawn as. "
                                         "Ignored by format=screen when the data carries its "
                                         "own attributes.")},
                    {"paper", integer_prop("0-15, as `ink`. What a clear bit is drawn as.")},
                    {"zoom", integer_prop("1-16 (default 3).")},
                    {"grid", bool_prop("Draw byte-column and 8-row boundaries over each item. "
                                       "On by default; suppressed below 3x zoom, where the "
                                       "lines would be most of the picture.")},
                    {"labels", bool_prop("Caption each item with its index, or in format=font "
                                         "its character code and character. On by default.")},
                    {"pin",
                     bool_prop("ADD this sprite to the panel's sheet instead of replacing the "
                               "one being dialled in. How you show several sprites of DIFFERENT "
                               "sizes at once: one call each, every one with pin=true, and each "
                               "keeps its own width, height, format and mask arrangement. Every "
                               "other field merges over the previous call, so a run of sprites "
                               "in the same format only has to restate what actually differs. "
                               "Unlike every other field this one does not persist -- it is off "
                               "again on the next call.")}},
               {}));
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
        "Get a full state snapshot: pc, registers, breakpoints, running, border, call stack, "
        "which model the machine is (48K or 128K) and, on a 128K, the paging register",
        no_params());
    add("load_debug_info",
        "Attach source-level debug info (a sjasmplus SLD file + its matching .asm) for the "
        "currently-loaded program -- enables resolve_symbol/resolve_address and DAP source-level "
        "debugging for this program's addresses, alongside the ROM's own (always available "
        "separately, so calls into the ROM still resolve)",
        schema(json{{"sld_path", string_prop("Path to the program's sjasmplus SLD file.")},
                    {"asm_path", string_prop("Path to the matching .asm source. The ENTRY source only -- any files it INCLUDEs are named by the SLD and resolved beside it.")}},
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
        "than only around the whole of one. Give both a `pc` to capture a code window instead: "
        "start_trace {pc: A} records nothing until execution reaches A, and stop_trace {pc: B} "
        "closes the capture when it reaches B -- so the file holds exactly the path from A to B, "
        "however many frames of running it took to get there. `pc` and `watch` take a symbol "
        "expression as well as a number -- \"KEY_INT\", \"KEY_INT+9\", \"0x0038\" or \"0038\" -- so a "
        "row of a trace can be pasted straight back in (an offset after a symbol is decimal, a "
        "bare number is hex, exactly as each is printed). It also stops "
        "itself at `limit` rows, so a forgotten capture cannot fill the disk. View the result "
        "with tools/trace_viewer.html, or the \"ZX Spectrum: Show Trace\" command in VS Code.",
        schema(json{{"path", string_prop("File to write. Relative paths resolve against the "
                                         "server's working directory (the workspace folder). "
                                         "Default \"trace.zxtrace\".")},
                    {"limit", integer_prop("Half-T-states to record before the capture closes "
                                           "itself. 139,776 is one frame and 7,000,000 one "
                                           "emulated second; default 25000, and 0 means "
                                           "unlimited.")},
                    {"watch", address_prop("Address to sample into the Watch column on every "
                                           "half-clock. Omit for none.")},
                    {"pc", address_prop("Address to start recording at: the capture opens its "
                                        "file now but writes nothing until the CPU fetches the "
                                        "instruction here, and the first row is that fetch. Omit "
                                        "to record from the very next half-clock.")},
                    {"tstate", integer_prop("T-state within the video frame to start recording "
                                            "at, counted from the interrupt (0..69887) exactly "
                                            "as the `extra` T-state column prints it. For "
                                            "questions about raster position -- what the bus is "
                                            "doing when the beam reaches a given line -- where "
                                            "the wanted half-clock is usually mid-instruction "
                                            "and so has no fetch for `pc` to match. Waits for "
                                            "the next frame if the machine is already past it. "
                                            "Mutually exclusive with `pc`.")},
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
                                                   "comparison."}}},
                    {"ula", json{{"type", "boolean"},
                                 {"description", "Add the ULA's own bus columns (ULA-AB, ULA-DB "
                                                 "and a byte count): what the display fetch read "
                                                 "from memory each half-clock. The ULA is the "
                                                 "machine's other bus master, and this is the "
                                                 "traffic memory contention and the snow artifact "
                                                 "are about. Blank on half-clocks where it read "
                                                 "nothing."}}}},
               {}));
    add("stop_trace",
        "Stop the running trace and report where it was written and how many half-T-states it "
        "captured. Takes effect immediately, mid-run included -- no need to pause first. With a "
        "`pc` it stops LATER instead: the capture keeps recording and closes itself when "
        "execution reaches that address, which is how to capture up to a point without having to "
        "watch for it",
        schema(json{{"pc", address_prop("Address to stop at: the capture closes on arriving "
                                       "there, before the instruction is fetched, so it ends "
                                       "exactly where a breakpoint would. Omit to stop now.")}},
               {}));
    add("trace_status",
        "Report whether a trace is running, its file, and its row count. Safe to poll during a "
        "run, so it can be watched filling up",
        no_params());
    add("profile",
        "Measure where execution time goes. `start` counts from zero -- every instruction's "
        "address, how often it ran, and the T-states it really took (ULA contention included) "
        "-- `stop` freezes the counts, and `get` reports them. Works on a running machine "
        "without pausing it: get the game to the part worth measuring, start, let it run, "
        "then get. The report folds addresses into source lines and routines through the "
        "loaded SLD debug info (the program's, then the ROM's), most expensive first, with "
        "T-states per frame -- what decides whether a game holds its frame rate. Interrupt "
        "acknowledges are counted separately rather than charged to whichever line they "
        "interrupted; a HALT's waiting shows on the HALT. Code with no source is grouped by "
        "256-byte page. `periods` has every frame's (or turn's) busy time as a strip, and the "
        "busiest ones with their own lines and routines -- where averages hide a spike. "
        "`call_tree` nests the calls by path, so a routine's children say what "
        "calling them cost it rather than what they cost the whole program. Use it before and after an optimisation to measure the change "
        "instead of estimating it.",
        schema(json{{"action", json{{"type", "string"},
                                    {"enum", json::array({"start", "stop", "get"})},
                                    {"description", "start, stop or get."}}},
                    {"lines", integer_prop("How many of the most expensive source lines to "
                                           "report. Default 20; 0 for all.")},
                    {"routines", integer_prop("How many of the most expensive routines to "
                                              "report. Default 20; 0 for all.")},
                    {"tree_min_percent",
                     json{{"type", "number"},
                          {"description", "The call tree -- what each routine's calls cost it, "
                                          "by call path -- is cut to the calls holding at least "
                                          "this percentage of all profiled time. Default 2; "
                                          "time in the calls cut is reported per node as "
                                          "other_calls_tstates."}}},
                    {"idle", json{{"type", "array"},
                                  {"items", json{{"type", "string"}}},
                                  {"description", "Routines whose time is waiting, not work -- a "
                                                  "busy-wait that paces the game, say. Their time "
                                                  "is reported as idle_tstates and left out of "
                                                  "busy time, and a period's busy time is what "
                                                  "ranks it among the worst. A HALT waiting is "
                                                  "always idle. Replaces the list; kept across "
                                                  "calls and starts. Applies from now on."}}},
                    {"period", string_prop("What the program's work repeats in: \"frame\" (the "
                                           "default) or a routine name whose arrival starts "
                                           "each period -- a game loop that takes more than a "
                                           "frame a turn. Changing it restarts the periods.")}},
               {"action"}));
    add("set_speed",
        "Set emulation speed. \"realtime\" paces to a real 48K's 50Hz, \"uncapped\" runs as fast "
        "as the host allows (what the ZEXALL-style exercisers want), and a `multiplier` scales "
        "realtime -- 0.1 for a tenth speed, 2 for double. Slow speeds are how you watch a raster "
        "effect happen; note that anything other than 1x is silent, since samples produced at the "
        "wrong rate are noise rather than slower music.",
        schema(json{{"speed", string_prop("\"realtime\" or \"uncapped\". Optional when a "
                                          "multiplier is given, which implies realtime.")},
                    {"multiplier", number_prop("Realtime multiplier, 0.001 to 20. 1 is a real "
                                               "48K; 0.001 (1/1000) creeps slowly enough to "
                                               "watch a single write land ahead of the "
                                               "beam.")}},
               {}));
    add("load_tape",
        "Insert a .tap, .tzx, .wav or .csw tape image and, by default, start loading it: resets "
        "the machine, types LOAD \"\" for you, and starts the tape, so all that is left is to "
        "`run`. Standard-speed blocks are satisfied instantly by trapping the ROM's LD-BYTES "
        "routine; anything non-standard (turbo loaders, custom .tzx blocks, and every audio "
        "recording) automatically falls back to real pulse-level playback through the EAR line, "
        "so every loader works -- just at tape speed, which for a whole game is minutes. Use "
        "set_speed uncapped to hurry that along",
        schema(json{{"path", string_prop("Path to the .tap, .tzx, .wav or .csw, resolved "
                                         "against the server's working directory. The format is "
                                         "detected from the file's contents, not its extension. "
                                         "A .wav is a recording of a real cassette and is "
                                         "decoded back into pulses, so it always loads at tape "
                                         "speed.")},
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
        const std::vector<uint8_t> data = base64_decode(b64);
        SnapshotInfo info;
        const std::string what = inspect_snapshot(data.data(), data.size(), info);
        if (!what.empty()) {
            return error_result(what);
        }
        const std::string message = engine.load_snapshot(data);
        if (!message.empty()) {
            return error_result(message);
        }
        return json_result(json{{"loaded", info.format == SnapshotFormat::Z80 ? "z80" : "sna"},
                                {"model", model_name(info.model)},
                                {"pc", info.pc}});
    }

    if (name == "save_snapshot") {
        std::string path;
        if (!arg_string(args, "path", path, error)) {
            return error_result(error);
        }
        // The extension picks the format; anything but .z80 is a .sna.
        std::string tail = path.size() >= 4 ? path.substr(path.size() - 4) : std::string();
        for (size_t i = 0; i < tail.size(); i++) {
            tail[i] = char(std::tolower(static_cast<unsigned char>(tail[i])));
        }
        const SnapshotFormat format = tail == ".z80" ? SnapshotFormat::Z80 : SnapshotFormat::Sna;
        std::vector<uint8_t> data;
        const std::string message = engine.save_snapshot(data, format);
        if (!message.empty()) {
            return error_result(message);
        }
        if (!write_file(path, data)) {
            return error_result("couldn't write " + path);
        }
        // PC as the file holds it rather than a fresh registers() read, which
        // mid-run is already somewhere else.
        SnapshotInfo info;
        inspect_snapshot(data.data(), data.size(), info);
        return json_result(json{{"path", path},
                                {"bytes", data.size()},
                                {"format", format == SnapshotFormat::Z80 ? "z80" : "sna"},
                                {"model", model_name(info.model)},
                                {"pc", info.pc}});
    }

    if (name == "reset") {
        const json& machine = arg(args, "machine");
        if (!machine.is_null()) {
            const std::string wanted = machine.is_number_integer()
                                           ? std::to_string(machine.get<int64_t>())
                                           : (machine.is_string() ? machine.get<std::string>()
                                                                  : std::string());
            Model model = Model::Spectrum48;
            if (wanted == "128" || wanted == "128k" || wanted == "128K") {
                model = Model::Spectrum128;
            } else if (wanted != "48" && wanted != "48k" && wanted != "48K") {
                return error_result("'machine' must be \"48\" or \"128\"");
            }
            if (!engine.has_rom(model)) {
                return error_result(std::string("no ") + model_name(model)
                                    + " ROM is loaded -- load_rom a "
                                    + (model == Model::Spectrum128 ? "32K" : "16K")
                                    + " image first, or start the server with --rom");
            }
            // set_model resets itself; the plain reset below would be a second.
            engine.set_model(model);
            return json_result(json{{"pc", engine.registers().pc}, {"model", model_name(model)}});
        }
        const Registers r = engine.reset();
        return json_result(json{{"pc", r.pc}, {"model", model_name(engine.model())}});
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
        const json& bank = arg(args, "bank");
        if (!bank.is_null()) {
            if (!bank.is_number_integer() || bank.get<int64_t>() < 0
                || bank.get<int64_t>() >= int64_t(RAM_BANKS)) {
                return error_result("'bank' must be a RAM bank number 0..7");
            }
            if (addr >= BANK_SIZE) {
                return error_result("with 'bank', 'addr' is an offset within the 16K bank (0..16383)");
            }
            const std::vector<uint8_t> data =
                engine.read_bank(uint8_t(bank.get<int64_t>()), addr, size_t(length));
            return json_result(json{{"bank", bank.get<int64_t>()}, {"addr", addr},
                                    {"hex", hex_encode(data)}});
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
        // 16-bit registers first, so a pair and one of its halves in the same
        // call compose the way the description promises.
        static const char* const ORDER[] = {
            "pc", "sp", "af", "bc", "de", "hl", "ix", "iy", "af_", "bc_", "de_", "hl_",
            "a", "f", "b", "c", "d", "e", "h", "l", "a_", "f_", "b_", "c_", "d_", "e_", "h_", "l_",
            "ixh", "ixl", "iyh", "iyl", "i", "r", "im", "iff1", "iff2",
        };
        Registers r = engine.registers();
        for (const char* key : ORDER) {
            const json& v = arg(args, key);
            if (v.is_null()) {
                continue;
            }
            uint32_t value = 0;
            if (v.is_boolean()) {
                if (register_width(key) != 1) {
                    return error_result(std::string("'") + key + "' takes a number, not a boolean");
                }
                value = v.get<bool>() ? 1 : 0;
            } else if (v.is_number_integer()) {
                const int64_t n = v.get<int64_t>();
                if (n < 0 || n > 0xFFFF) {
                    return error_result(std::string("'") + key + "' is out of range");
                }
                value = uint32_t(n);
            } else if (v.is_string() && register_width(key) == 16) {
                uint16_t addr = 0;
                if (!sources.parse_address(v.get<std::string>(), addr, error)) {
                    return error_result(std::string("'") + key + "': " + error);
                }
                value = addr;
            } else {
                return error_result(std::string("'") + key + "' must be a number"
                                    + (register_width(key) == 16 ? " or a symbol expression" : ""));
            }
            if (!set_register(r, key, value, error)) {
                return error_result(error);
            }
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

    if (name == "get_screen_sequence") {
        int64_t frames = 8;
        int64_t every = 1;
        const json& frames_arg = arg(args, "frames");
        if (frames_arg.is_number_integer()) {
            frames = frames_arg.get<int64_t>();
        }
        const json& every_arg = arg(args, "every");
        if (every_arg.is_number_integer()) {
            every = every_arg.get<int64_t>();
        }
        if (frames < 1 || frames > MAX_SEQUENCE_FRAMES) {
            return error_result("'frames' must be between 1 and "
                                + std::to_string(MAX_SEQUENCE_FRAMES));
        }
        if (every < 1 || every > MAX_SEQUENCE_EVERY) {
            return error_result("'every' must be between 1 and "
                                + std::to_string(MAX_SEQUENCE_EVERY));
        }
        // How long the span takes to happen: 20ms a frame at real speed,
        // longer in slow motion, and however long the host takes uncapped
        // (less, in practice). Plus a margin for the first boundary to come
        // round and for a run yielding late.
        double span_ms = double(frames * every) * 20.0;
        if (engine.speed() == Speed::Realtime) {
            span_ms /= engine.speed_multiplier();
        }
        int64_t timeout_ms = int64_t(span_ms) + 2000;
        if (timeout_ms > 60000) {
            timeout_ms = 60000;
        }
        const bool was_running = engine.running();
        const std::vector<CapturedFrame> captured = engine.capture_frames(
            uint32_t(frames), uint32_t(every), std::chrono::milliseconds(timeout_ms));
        if (captured.empty()) {
            return error_result(was_running ? "no frame completed within " + std::to_string(timeout_ms)
                                                  + "ms -- is the run stuck, or the machine very slow?"
                                            : "no frame was completed");
        }
        std::string summary = std::to_string(captured.size()) + " frame"
                              + (captured.size() == 1 ? "" : "s") + ", "
                              + std::to_string(every * 20) + "ms of emulated time apart";
        if (int64_t(captured.size()) < frames) {
            summary += " -- fewer than asked for: the run stopped, or the time ran out";
        }
        json content = json::array();
        content.push_back(json{{"type", "text"}, {"text", summary}});
        const uint64_t first = captured[0].frame_number;
        for (size_t i = 0; i < captured.size(); i++) {
            const CapturedFrame& f = captured[i];
            content.push_back(json{{"type", "text"},
                                   {"text", "frame " + std::to_string(i + 1) + "/"
                                                + std::to_string(captured.size()) + ": emulated frame #"
                                                + std::to_string(f.frame_number) + ", +"
                                                + std::to_string((f.frame_number - first) * 20)
                                                + "ms"}});
            content.push_back(json{{"type", "image"},
                                   {"data", base64_encode(encode_png(f.rgb))},
                                   {"mimeType", "image/png"}});
        }
        return json{{"content", content}};
    }

    if (name == "start_video") {
        VideoOptions options;
        const json& path = arg(args, "path");
        if (path.is_string()) {
            options.path = path.get<std::string>();
        }
        const json& seconds = arg(args, "seconds");
        if (seconds.is_number()) {
            const double s = seconds.get<double>();
            if (s <= 0.0 || s > MAX_VIDEO_SECONDS) {
                return error_result("'seconds' must be between 0 and 600");
            }
            options.frames = uint64_t(s * 50.0 + 0.5);
        }
        const json& frames = arg(args, "frames");
        if (frames.is_number_integer()) {
            const int64_t n = frames.get<int64_t>();
            if (n <= 0 || double(n) > MAX_VIDEO_SECONDS * 50.0) {
                return error_result("'frames' must be between 1 and 30000");
            }
            options.frames = uint64_t(n);
        }
        const json& scale = arg(args, "scale");
        if (scale.is_number_integer()) {
            const int64_t n = scale.get<int64_t>();
            if (n < 1 || n > 4) {
                return error_result("'scale' must be between 1 and 4");
            }
            options.scale = uint32_t(n);
        }
        const std::string message = engine.start_video(options);
        if (!message.empty()) {
            return error_result(message);
        }
        return json_result(video_status_json(engine.video_status()));
    }

    if (name == "stop_video") {
        return json_result(video_status_json(engine.stop_video()));
    }

    if (name == "video_status") {
        return json_result(video_status_json(engine.video_status()));
    }

    if (name == "set_write_overlay") {
        const json& opacity = arg(args, "opacity_percent");
        if (opacity.is_number_integer()) {
            const int64_t percent = opacity.get<int64_t>();
            if (percent < 0 || percent > int64_t(PERCENT_MAX)) {
                return error_result("'opacity_percent' must be between 0 and 100");
            }
            engine.set_write_overlay_opacity(uint32_t(percent));
        }
        const json& fade = arg(args, "fade_percent");
        if (fade.is_number_integer()) {
            const int64_t percent = fade.get<int64_t>();
            if (percent < 0 || percent > int64_t(PERCENT_MAX)) {
                return error_result("'fade_percent' must be between 0 and 100");
            }
            engine.set_write_overlay_fade(uint32_t(percent));
        }
        const json& enabled = arg(args, "enabled");
        engine.set_write_overlay(enabled.is_boolean() ? enabled.get<bool>()
                                                      : !engine.write_overlay());
        if (!engine.write_overlay()) {
            return text_result("write overlay: off");
        }
        std::string message = "write overlay: on (picture dimmed, bytes written lifted "
                              + std::to_string(engine.write_overlay_opacity())
                              + "% of the way to full brightness, ";
        const uint32_t fade_percent = engine.write_overlay_fade();
        if (fade_percent >= PERCENT_MAX) {
            message += "cleared every frame)";
        } else if (fade_percent == 0) {
            message += "never faded)";
        } else {
            message += "fading " + std::to_string(fade_percent) + "% a frame)";
        }
        return text_result(message);
    }

    if (name == "set_raster_view") {
        RasterView view = engine.raster_view();
        const json& marker = arg(args, "marker");
        if (marker.is_boolean()) {
            view.marker = marker.get<bool>();
        }
        const json& in_progress = arg(args, "in_progress");
        if (in_progress.is_boolean()) {
            view.in_progress = in_progress.get<bool>();
        }
        const json& pending = arg(args, "pending");
        if (pending.is_boolean()) {
            view.pending = pending.get<bool>();
        }
        engine.set_raster_view(view);
        std::string message = "raster view (while stopped): beam marker ";
        message += view.marker ? "on" : "off";
        message += ", in-progress frame ";
        message += view.in_progress ? "on" : "off";
        message += ", pending writes ";
        message += view.pending ? "on" : "off";
        return text_result(message);
    }

    if (name == "set_graphics_view") {
        GraphicsView view = engine.graphics_view();
        // The one field that does not merge. It says "do this", not "be this",
        // and a pin left set would turn the next correction into a new tile.
        view.pin = false;
        // Every field optional and merged over what is already there, exactly
        // as set_raster_view does: a client correcting one guess should not
        // have to restate the fifteen it got right.
        const auto take_string = [&args](const char* key, std::string& out) {
            const json& v = arg(args, key);
            if (v.is_string()) {
                out = v.get<std::string>();
            }
        };
        const auto take_uint = [&args](const char* key, uint32_t& out, uint32_t low,
                                       uint32_t high) {
            const json& v = arg(args, key);
            if (v.is_number_integer()) {
                // Clamped rather than rejected, like the speed multiplier: these
                // land in a UI, and the nearest sensible value beats an error.
                const int64_t raw = v.get<int64_t>();
                out = uint32_t(raw < int64_t(low) ? low : raw > int64_t(high) ? high : raw);
            }
        };
        const auto take_bool = [&args](const char* key, bool& out) {
            const json& v = arg(args, key);
            if (v.is_boolean()) {
                out = v.get<bool>();
            }
        };

        take_string("source", view.source);
        take_string("address", view.address);
        take_string("file", view.file);
        take_string("format", view.format);
        take_string("interleave", view.interleave);
        take_uint("width", view.width, 1, 64);
        take_uint("height", view.height, 1, 256);
        take_uint("count", view.count, 1, 1024);
        take_uint("columns", view.columns, 1, 64);
        take_uint("header", view.header, 0, 64);
        take_uint("offset", view.offset, 0, 0xFFFFFFFFu);
        take_uint("first", view.first, 0, 255);
        take_uint("ink", view.ink, 0, 15);
        take_uint("paper", view.paper, 0, 15);
        take_uint("zoom", view.zoom, 1, 16);
        take_bool("invert_mask", view.invert_mask);
        take_bool("flip", view.flip);
        take_bool("grid", view.grid);
        take_bool("labels", view.labels);
        take_bool("pin", view.pin);

        // Named sets only. A typo here would otherwise reach the panel and
        // leave it drawing nothing, with the mistake three processes away from
        // whoever has to find it.
        if (view.source != "memory" && view.source != "file" && view.source != "selection") {
            return error_result("source must be \"memory\", \"file\" or \"selection\", not \""
                                + view.source + "\"");
        }
        if (view.format != "sprite" && view.format != "font" && view.format != "screen") {
            return error_result("format must be \"sprite\", \"font\" or \"screen\", not \""
                                + view.format + "\"");
        }
        if (view.interleave != "none" && view.interleave != "md" && view.interleave != "dm") {
            return error_result("interleave must be \"none\", \"md\" or \"dm\", not \""
                                + view.interleave + "\"");
        }

        engine.set_graphics_view(view);

        std::string message = "graphics panel: " + view.format + " from ";
        if (view.source == "memory") {
            message += "memory at " + view.address;
        } else if (view.source == "file") {
            message += view.file.empty() ? "a file (none given)" : view.file;
            message += " at +" + std::to_string(view.offset);
        } else {
            message += "the editor selection";
        }
        if (view.format != "screen") {
            message += ", " + std::to_string(view.width) + " bytes x "
                       + std::to_string(view.height) + " rows, " + std::to_string(view.count)
                       + " of them";
            if (view.interleave != "none") {
                message += ", mask interleaved (" + view.interleave + ")";
            }
            if (view.flip) {
                message += ", bottom-up";
            }
        }
        message += view.pin ? ". Added to the sheet." : ".";
        message += " This changes nothing in the machine -- it moves a panel in VS Code, and "
                   "only reaches one that is open in a debug session.";
        return text_result(message);
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
        uint16_t addr = 0;
        bool present = false;
        if (!arg_opt_address(args, "watch", sources, present, addr, error)) {
            return error_result(error);
        }
        if (present) {
            options.watch = uint32_t(addr);
        }
        if (!arg_opt_address(args, "pc", sources, present, addr, error)) {
            return error_result(error);
        }
        if (present) {
            options.start_pc = uint32_t(addr);
        }
        const json& tstate = arg(args, "tstate");
        if (!tstate.is_null()) {
            if (!tstate.is_number_unsigned() || tstate.get<uint64_t>() >= TSTATES_PER_FRAME) {
                return error_result("'tstate' must be a T-state within the frame (0.."
                                    + std::to_string(TSTATES_PER_FRAME - 1) + ")");
            }
            options.start_tstate = uint32_t(tstate.get<uint64_t>());
        }
        const json& extra = arg(args, "extra");
        options.extra = extra.is_boolean() && extra.get<bool>();
        const json& ula = arg(args, "ula");
        options.ula = ula.is_boolean() && ula.get<bool>();
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
        uint16_t pc = 0;
        bool present = false;
        if (!arg_opt_address(args, "pc", sources, present, pc, error)) {
            return error_result(error);
        }
        return json_result(trace_status_json(present ? engine.stop_trace(pc)
                                                     : engine.stop_trace()));
    }

    if (name == "trace_status") {
        return json_result(trace_status_json(engine.trace_status()));
    }

    if (name == "profile") {
        const json& idle_arg = arg(args, "idle");
        const json& period_arg = arg(args, "period");
        if (idle_arg.is_array() || period_arg.is_string()) {
            ProfileSettings settings = current_profile_settings();
            if (idle_arg.is_array()) {
                settings.idle.clear();
                for (const json& idle_name : idle_arg) {
                    if (idle_name.is_string()) {
                        settings.idle.push_back(idle_name.get<std::string>());
                    }
                }
            }
            if (period_arg.is_string()) {
                settings.period = period_arg.get<std::string>();
            }
            apply_profile_settings(engine, sources, settings);
        }
        const json& action_arg = arg(args, "action");
        const std::string action = action_arg.is_string() ? action_arg.get<std::string>() : "";
        if (action == "start") {
            engine.start_profile();
        } else if (action == "stop") {
            engine.stop_profile();
        } else if (action != "get") {
            return error_result("'action' must be start, stop or get");
        }
        size_t lines = 20;
        size_t routines = 20;
        const json& lines_arg = arg(args, "lines");
        if (lines_arg.is_number_unsigned()) {
            lines = size_t(lines_arg.get<uint64_t>());
        }
        const json& routines_arg = arg(args, "routines");
        if (routines_arg.is_number_unsigned()) {
            routines = size_t(routines_arg.get<uint64_t>());
        }
        double min_percent = 2.0;
        const json& min_arg = arg(args, "tree_min_percent");
        if (min_arg.is_number()) {
            min_percent = min_arg.get<double>();
        }
        const ProfileReport report = build_profile_report(engine.profile_snapshot(), sources);
        json out = profile_report_json(report, lines, routines, false);
        out["call_tree"] = profile_call_tree_json(report, min_percent / 100.0, 12);
        return json_result(out);
    }

    if (name == "set_speed") {
        const json& multiplier = arg(args, "multiplier");
        const json& speed_arg = arg(args, "speed");
        if (!multiplier.is_number() && !speed_arg.is_string()) {
            return error_result("give 'speed' (\"realtime\" or \"uncapped\") or a 'multiplier'");
        }
        if (multiplier.is_number()) {
            // A multiplier is meaningless without a rate to scale, so it
            // implies realtime rather than erroring when both are given.
            engine.set_speed(Speed::Realtime);
            engine.set_speed_multiplier(multiplier.get<double>());
        }
        if (speed_arg.is_string()) {
            const std::string speed = speed_arg.get<std::string>();
            if (speed == "realtime") {
                engine.set_speed(Speed::Realtime);
            } else if (speed == "uncapped") {
                engine.set_speed(Speed::Uncapped);
            } else {
                return error_result("'speed' must be \"realtime\" or \"uncapped\"");
            }
        }
        return json_result(speed_json(engine));
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
                                {"instructions", loaded->instruction_count()}});
    }

    if (name == "resolve_symbol") {
        std::string symbol;
        if (!arg_string(args, "name", symbol, error)) {
            return error_result(error);
        }
        uint16_t address = 0;
        if (sources.symbol_value(symbol, address)) {
            return json_result(json{{"found", true}, {"address", address}});
        }
        const std::vector<RomSourcePtr> active = sources.active();
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
        log("MCP  client connected");
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
        // Every tool call, with the argument that identifies it. This is
        // the only record of what an agent did to the machine -- unlike a
        // person driving VS Code, nobody watched it happen.
        const std::string tool = name.get<std::string>();
        std::string detail;
        for (const char* key : {"path", "addr", "speed", "action", "key", "symbol"}) {
            const json& value = arg(arguments, key);
            if (value.is_string()) {
                detail = " " + value.get<std::string>();
                break;
            }
            if (value.is_number_unsigned()) {
                detail = " " + hex4(uint16_t(value.get<uint32_t>()));
                break;
            }
        }
        log("MCP  %s%s", tool.c_str(), detail.c_str());
        return rpc_result(id, call_tool(engine, sources, tool, arguments));
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
            log("MCP  client disconnected");
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
