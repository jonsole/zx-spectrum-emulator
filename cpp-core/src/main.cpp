// Entrypoint: starts the DAP and screen-stream servers together against one
// shared Engine. (MCP is not wired up yet -- see the TODO below.)

#include "dap.h"
#include "engine.h"
#include "file_io.h"
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
    /// Loaded at startup so the machine is usable the moment a client
    /// connects, rather than only after a `launch` request supplies one.
    std::string rom;
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
        } else if (flag == "--rom") {
            if (!next(args.rom)) return false;
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

    std::thread screen_thread(
        [&] { zx::serve_screen_stream(engine, args.screen_host, args.screen_port); });

    // TODO: MCP server (cpp-mcp, streamable HTTP at /mcp) -- Phase 4's
    // remaining half.

    zx::serve_dap(engine, args.dap_host, args.dap_port, args.exit_on_disconnect);
    screen_thread.join();
    return 0;
}
