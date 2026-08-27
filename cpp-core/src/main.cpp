// Entrypoint: starts the DAP, MCP and screen-stream servers together against
// one shared Engine and one shared set of debug sources.

#include "dap.h"
#include "engine.h"
#include "file_io.h"
#include "mcp_server.h"
#include "rom_source.h"
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
    /// Runs as fast as the host allows instead of pacing to a real 48K's
    /// 50Hz. What the exercisers (ZEXALL/ZEXDOC/z80full) want -- they have no
    /// visual output to get wrong and wall-clock speed is the whole point.
    bool uncapped = false;
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
        } else if (flag == "--mcp-host") {
            if (!next(args.mcp_host)) return false;
        } else if (flag == "--mcp-port") {
            if (!next(value)) return false;
            args.mcp_port = uint16_t(std::strtoul(value.c_str(), nullptr, 10));
        } else if (flag == "--rom-disassembly-dir") {
            if (!next(args.rom_disassembly_dir)) return false;
        } else if (flag == "--rom") {
            if (!next(args.rom)) return false;
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

    zx::Sources sources(args.rom_disassembly_dir);
    if (zx::RomSourcePtr rom = zx::get_rom_source(args.rom_disassembly_dir)) {
        std::printf("ROM disassembly: %zu symbols, %zu mapped instructions\n",
                    rom->symbols.size(), rom->line_to_addr.size());
    } else {
        std::printf("No ROM disassembly in %s -- symbols unavailable "
                    "(build it with scripts/build_rom_source.py)\n",
                    args.rom_disassembly_dir.c_str());
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
    return 0;
}
