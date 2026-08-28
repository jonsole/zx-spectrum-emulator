// Entrypoint: starts the DAP, MCP and screen-stream servers together against
// one shared Engine and one shared set of debug sources.

#include "dap.h"
#include "engine.h"
#include "file_io.h"
#include "mcp_server.h"
#include "rom_source.h"
#include "audio_device.h"
#include "audio_stream.h"
#include "screen_stream.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

namespace {

struct Args {
    std::string dap_host = "127.0.0.1";
    uint16_t dap_port = 4711;
    std::string screen_host = "127.0.0.1";
    std::string audio_host = "127.0.0.1";
    uint16_t audio_port = 8501;
    /// Plays the beeper out of this process, as well as streaming it. Off by
    /// default: a debug server that grabs the sound card the moment it starts
    /// is a nuisance, and the VS Code panel is the usual way to listen.
    bool audio_device = false;
    /// Stops the audio stream server binding at all.
    bool no_audio = false;
    /// How much audio to keep buffered ahead of the speaker, in
    /// milliseconds. Lower feels more immediate; too low and the sound card
    /// runs dry between the emulator's pacing sleeps and gaps. Sets both the
    /// native device's queue and, via the stream preamble, the VS Code
    /// panel's own jitter buffer.
    uint32_t audio_latency_ms = zx::DEFAULT_AUDIO_LATENCY_MS;
    uint16_t screen_port = 8500;
    std::string mcp_host = "127.0.0.1";
    uint16_t mcp_port = 8000;
    /// Directory holding the built ROM disassembly (rom.asm/rom.sld). Default
    /// is relative to the project root, matching the "run from the workspace
    /// folder" convention the VS Code task uses. A missing directory is fine:
    /// symbol lookups simply find nothing.
    std::string rom_disassembly_dir = "rom_disassembly";
    /// Loaded at startup so the machine is usable the moment a client
    /// connects, rather than only after a `launch` request supplies one.
    std::string rom;
    /// A .tap or .tzx to insert at startup. Loaded after the ROM, since
    /// auto-start needs a ROM to type LOAD "" into.
    std::string tape;
    bool tape_autostart = true;
    bool tape_fast_load = true;
    /// Type LOAD "" at startup even with no tape, so the machine sits in
    /// the ROM loader ready for one to be inserted later.
    bool wait_for_tape = false;
    /// Runs as fast as the host allows instead of pacing to a real 48K's
    /// 50Hz. What the exercisers (ZEXALL/ZEXDOC/z80full) want -- they have no
    /// visual output to get wrong and wall-clock speed is the whole point.
    bool uncapped = false;
    /// Starts a cycle-by-cycle bus trace at boot, written here. Empty means no
    /// trace; the MCP start_trace/stop_trace tools can begin one later either
    /// way. This flag exists for the one window those cannot reach -- the
    /// machine's first few thousand half-clocks, which are over long before a
    /// client has finished connecting.
    std::string trace_log;
    uint64_t trace_limit = zx::TRACE_DEFAULT_LIMIT;
    /// Memory address sampled into the trace's Watch column, if any.
    uint32_t trace_watch = zx::TRACE_NO_WATCH;
    /// Adds the 48K-specific trace columns (HALT/WAIT/INT/NMI, frame, T-state)
    /// at the cost of the byte-for-byte match with visualz80remix's layout.
    bool trace_extra = false;
    /// Exits the whole process once the last open DAP connection closes
    /// (e.g. VS Code's Stop action), so a preLaunchTask can rebind the same
    /// port next launch instead of colliding with a stale server. Off by
    /// default: a short-lived diagnostic script connecting alongside a
    /// long-running server shouldn't take the whole thing down.
    bool exit_on_disconnect = false;
};

bool parse_args(int argc, char** argv, Args& args) {
    for (int i = 1; i < argc; i++) {
        const std::string flag = argv[i];
        auto next = [&](std::string& out) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s needs a value\n", flag.c_str());
                return false;
            }
            out = argv[++i];
            return true;
        };
        std::string value;
        if (flag == "--dap-host") {
            if (!next(args.dap_host)) return false;
        } else if (flag == "--dap-port") {
            if (!next(value)) return false;
            args.dap_port = uint16_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--screen-host") {
            if (!next(args.screen_host)) return false;
        } else if (flag == "--screen-port") {
            if (!next(value)) return false;
            args.screen_port = uint16_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--audio-host") {
            if (!next(args.audio_host)) return false;
        } else if (flag == "--audio-port") {
            if (!next(value)) return false;
            args.audio_port = uint16_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--audio-device") {
            args.audio_device = true;
        } else if (flag == "--no-audio") {
            args.no_audio = true;
        } else if (flag == "--audio-latency-ms") {
            if (!next(value)) return false;
            args.audio_latency_ms = uint32_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--mcp-host") {
            if (!next(args.mcp_host)) return false;
        } else if (flag == "--mcp-port") {
            if (!next(value)) return false;
            args.mcp_port = uint16_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--rom-disassembly-dir") {
            if (!next(args.rom_disassembly_dir)) return false;
        } else if (flag == "--rom") {
            if (!next(args.rom)) return false;
        } else if (flag == "--tape") {
            if (!next(args.tape)) return false;
        } else if (flag == "--no-tape-autostart") {
            args.tape_autostart = false;
        } else if (flag == "--no-tape-fast-load") {
            args.tape_fast_load = false;
        } else if (flag == "--wait-for-tape") {
            args.wait_for_tape = true;
        } else if (flag == "--trace-log") {
            if (!next(args.trace_log)) return false;
        } else if (flag == "--trace-limit") {
            if (!next(value)) return false;
            args.trace_limit = std::strtoull(value.c_str(), nullptr, 10);
        } else if (flag == "--trace-watch") {
            if (!next(value)) return false;
            args.trace_watch = uint32_t(std::strtoul(value.c_str(), nullptr, 16)) & 0xFFFF;
        } else if (flag == "--trace-extra") {
            args.trace_extra = true;
        } else if (flag == "--uncapped") {
            args.uncapped = true;
        } else if (flag == "--exit-on-disconnect") {
            args.exit_on_disconnect = true;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", flag.c_str());
            return false;
        }
    }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    // Deterministic marker for VS Code's background-task problem matcher
    // (.vscode/tasks.json's beginsPattern) -- printed unconditionally,
    // before any other work, so it fires whether or not the build step
    // needed to rebuild anything first.
    std::printf("Starting ZX Spectrum server...\n");
    std::fflush(stdout);

    Args args;
    if (!parse_args(argc, argv, args)) {
        return 2;
    }

    zx::Engine engine;
    if (args.uncapped) {
        engine.set_speed(zx::Speed::Uncapped);
        std::printf("Speed: uncapped (--uncapped)\n");
    }

    if (!args.rom.empty()) {
        std::vector<uint8_t> data;
        if (!zx::read_file(args.rom, data)) {
            std::fprintf(stderr, "couldn't read ROM %s\n", args.rom.c_str());
            return 1;
        }
        const std::string error = engine.load_rom(std::move(data));
        if (!error.empty()) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        std::printf("Loaded ROM %s\n", args.rom.c_str());
    }

    // After the ROM on purpose: auto-start types LOAD "" through the ROM's own
    // keyboard scan, so there has to be a ROM there to type into.
    if (!args.tape.empty()) {
        std::vector<uint8_t> data;
        if (!zx::read_file(args.tape, data)) {
            std::fprintf(stderr, "couldn't read tape %s\n", args.tape.c_str());
            return 1;
        }
        engine.set_tape_fast_load(args.tape_fast_load);
        const std::string error =
            engine.load_tape(std::move(data), args.tape, args.tape_autostart);
        if (!error.empty()) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        const zx::TapeStatus tape = engine.tape_status();
        std::printf("Inserted tape %s (%zu blocks, fast load %s%s)\n", args.tape.c_str(),
                    tape.blocks, args.tape_fast_load ? "on" : "off",
                    args.tape_autostart ? ", loading" : "");
        for (const std::string& warning : tape.warnings) {
            std::printf("  tape: %s\n", warning.c_str());
        }
    }

    // Skipped when a tape was inserted AND auto-started, since that already
    // typed the command -- doing it twice would reset the machine out from
    // under a tape that had started loading.
    if (args.wait_for_tape && !(!args.tape.empty() && args.tape_autostart)) {
        const std::string error = engine.wait_for_tape();
        if (!error.empty()) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        std::printf("Typed LOAD \"\" -- waiting for a tape\n");
    }

    zx::Sources sources(args.rom_disassembly_dir);
    if (zx::RomSourcePtr rom = zx::get_rom_source(args.rom_disassembly_dir)) {
        std::printf("ROM disassembly: %zu symbols, %zu mapped instructions\n",
                    rom->symbols.size(), rom->line_to_addr.size());
    } else {
        std::printf("No ROM disassembly in %s -- symbols unavailable "
                    "(build it with scripts/build_rom_source.py)\n",
                    args.rom_disassembly_dir.c_str());
    }

    // After the ROM, so the capture opens on a machine that has one -- the Asm
    // column would otherwise disassemble 16K of zeroes as NOPs -- and after
    // `sources`, so the Symbol column can name ROM routines from the very
    // first row rather than only once something attaches debug info later.
    if (!args.trace_log.empty()) {
        zx::TraceOptions trace;
        trace.path = args.trace_log;
        trace.limit = args.trace_limit;
        trace.watch = args.trace_watch;
        trace.extra = args.trace_extra;
        trace.resolve_symbol = zx::symbol_resolver(sources);
        const std::string error = engine.start_trace(trace);
        if (!error.empty()) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        std::printf("Tracing to %s (limit %llu half-clocks)\n", args.trace_log.c_str(),
                    (unsigned long long)args.trace_limit);
    }

    if (args.audio_device) {
        std::string audio_error;
        uint32_t actual_ms = args.audio_latency_ms;
        if (start_audio_device(engine, args.audio_latency_ms, actual_ms, audio_error)) {
            std::printf("Native audio playback on the default device "
                        "(%u Hz, %ums buffer)\n",
                        unsigned(engine.audio_sample_rate()), unsigned(actual_ms));
        } else {
            // Not fatal: a headless box or a busy device is an ordinary
            // situation for a debug server, and the stream is still there.
            std::fprintf(stderr, "Native audio unavailable: %s\n", audio_error.c_str());
        }
    }

    std::thread audio_thread;
    if (!args.no_audio) {
        audio_thread = std::thread(
            [&] {
                zx::serve_audio_stream(engine, args.audio_host, args.audio_port,
                                       args.audio_latency_ms);
            });
    }

    std::thread screen_thread(
        [&] { zx::serve_screen_stream(engine, args.screen_host, args.screen_port); });
    std::thread mcp_thread(
        [&] { zx::serve_mcp(engine, sources, args.mcp_host, args.mcp_port); });

    // DAP last and on this thread: it is the one that can end the process
    // (--exit-on-disconnect), and it is what the launch is waiting on.
    zx::serve_dap(engine, sources, args.dap_host, args.dap_port, args.exit_on_disconnect);
    mcp_thread.join();
    screen_thread.join();
    if (audio_thread.joinable()) {
        audio_thread.join();
    }
    return 0;
}
