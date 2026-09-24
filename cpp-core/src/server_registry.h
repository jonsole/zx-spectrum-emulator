#pragma once
// What a running zx_server is, and where it says so.
//
// Two ways to ask. A client already connected sends the DAP `serverInfo`
// request (or MCP's `server_info` tool) and gets it back directly. A client
// that has not found the server yet -- the VS Code screen panel looking for
// every emulator on the machine, or a launch that asked for free ports and
// needs to know which it got -- reads the advert: one small JSON file per
// server, `<pid>.json` in advert_directory(), written once every port is
// bound and removed again on the way out.
//
// Removal cannot be guaranteed: a server killed outright (taskkill /F, VS
// Code's own stop) runs no code at all on the way out. So a reader takes an
// advert as a claim to check rather than a fact -- the PID has to be alive
// and the ports have to answer -- and deletes the ones that fail.

#include <nlohmann/json.hpp>

#include <cstdint>
#include <string>
#include <vector>

namespace zx {

/// The advert's layout version, bumped when a reader would misread it.
constexpr int SERVER_ADVERT_VERSION = 1;

/// The ports one server is on, as bound -- never the 0 a command line may
/// have asked for. `audio` is 0 when the audio stream is off (--no-audio).
struct ServerPorts {
    uint16_t dap = 0;
    uint16_t mcp = 0;
    uint16_t screen = 0;
    uint16_t audio = 0;
};

/// Everything that tells one server apart from another, fixed at startup.
struct ServerIdentity {
    uint32_t pid = 0;
    std::string host;
    ServerPorts ports;
    /// When it started, ISO 8601 UTC, so a list of servers can say which is
    /// newest.
    std::string started;
    std::string exe;
    std::string cwd;
    std::vector<std::string> roms;
    /// Whether it plays sound out of the host's own sound card.
    bool audio_device = false;
};

/// Where adverts go: $ZX_SERVER_ADVERT_DIR when set, else
/// %LOCALAPPDATA%\zx-spectrum\servers on Windows and
/// $XDG_RUNTIME_DIR (or ~/.cache)/zx-spectrum/servers elsewhere.
std::string advert_directory();

/// The identity to report from now on, with the fields only this process can
/// know (pid, started, cwd) filled in. Called once, from main.
void set_server_identity(ServerIdentity identity);

/// Writes this process's advert into `dir`, creating it if need be, and
/// keeps it up to date from then on (see note_program). False, with
/// `error`, if it could not be written -- which is worth a warning but not
/// worth refusing to serve over.
bool advertise(const std::string& dir, std::string& error);

/// Removes this process's advert. Safe to call more than once and from an
/// exit handler.
void withdraw();

/// Removes the advert when the process exits normally or its console is
/// closed or interrupted (Ctrl+C), which covers everything but a kill.
void withdraw_on_exit();

/// Records the program most recently loaded, by path, and rewrites the
/// advert so that a list of servers can say what each one is running.
void note_program(const std::string& path);

/// The identity plus the current program: the body of `serverInfo` and the
/// content of the advert.
nlohmann::json server_info();

} // namespace zx
