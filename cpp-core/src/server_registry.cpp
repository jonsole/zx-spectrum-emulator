#include "server_registry.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <csignal>
#include <cstdlib>
#include <unistd.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <system_error>
#include <utility>

namespace zx {
namespace {

namespace fs = std::filesystem;

std::mutex g_mutex;
ServerIdentity g_identity;
std::string g_program;
/// The advert's full path once one has been written, empty before and after.
fs::path g_advert;

/// An environment variable as UTF-8, or "" when unset.
std::string env(const char* name) {
#ifdef _WIN32
    // GetEnvironmentVariableW rather than getenv, which MSVC deprecates and
    // this build treats deprecation as an error -- and the wide form, since
    // a profile directory can have any characters in it.
    std::wstring wide(name, name + std::char_traits<char>::length(name));
    const DWORD needed = GetEnvironmentVariableW(wide.c_str(), nullptr, 0);
    if (needed == 0) {
        return "";
    }
    std::wstring value(needed, L'\0');
    const DWORD n = GetEnvironmentVariableW(wide.c_str(), value.data(), needed);
    value.resize(n);
    return fs::path(value).u8string();
#else
    const char* value = std::getenv(name);
    return value ? value : "";
#endif
}

uint32_t current_pid() {
#ifdef _WIN32
    return uint32_t(GetCurrentProcessId());
#else
    return uint32_t(getpid());
#endif
}

std::string utc_now() {
    const std::time_t now = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &now);
#else
    gmtime_r(&now, &tm);
#endif
    char text[32];
    std::strftime(text, sizeof text, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return text;
}

nlohmann::json info_locked() {
    const ServerPorts& p = g_identity.ports;
    nlohmann::json ports = {{"dap", p.dap}, {"mcp", p.mcp}, {"screen", p.screen}};
    // null rather than 0: there is no audio port to connect to, and a reader
    // treating 0 as a port would try.
    ports["audio"] = p.audio != 0 ? nlohmann::json(p.audio) : nlohmann::json(nullptr);
    return nlohmann::json{
        {"version", SERVER_ADVERT_VERSION},
        {"pid", g_identity.pid},
        {"serverVersion", g_identity.version},
        {"host", g_identity.host},
        {"ports", ports},
        {"started", g_identity.started},
        {"exe", g_identity.exe},
        {"cwd", g_identity.cwd},
        {"roms", g_identity.roms},
        {"audioDevice", g_identity.audio_device},
        {"program", g_program.empty() ? nlohmann::json(nullptr) : nlohmann::json(g_program)},
    };
}

/// Writes the advert beside itself and renames it into place, so a reader
/// listing the directory at the wrong moment never sees half a file.
bool write_locked(std::string& error) {
    if (g_advert.empty()) {
        return true;
    }
    fs::path temp = g_advert;
    temp += ".tmp";
    {
        std::ofstream file(temp, std::ios::binary | std::ios::trunc);
        if (!file) {
            error = "couldn't write " + temp.u8string();
            return false;
        }
        file << info_locked().dump(2) << "\n";
        if (!file) {
            error = "couldn't write " + temp.u8string();
            return false;
        }
    }
    std::error_code ec;
    fs::rename(temp, g_advert, ec);
    if (ec) {
        fs::remove(temp, ec);
        error = "couldn't write " + g_advert.u8string();
        return false;
    }
    return true;
}

#ifdef _WIN32
/// Runs on a thread of its own when the console is closed or Ctrl+C'd.
/// Returning FALSE hands the event on to the default handler, which ends the
/// process as it would have anyway -- this only tidies up first.
BOOL WINAPI on_console_event(DWORD) {
    withdraw();
    return FALSE;
}
#else
void on_signal(int sig) {
    // try_lock, since the signal may have landed on a thread holding the
    // lock: a stale advert is a reader's problem to tidy, a deadlock is not.
    if (g_mutex.try_lock()) {
        std::error_code ec;
        if (!g_advert.empty()) {
            fs::remove(g_advert, ec);
            g_advert.clear();
        }
        g_mutex.unlock();
    }
    std::signal(sig, SIG_DFL);
    std::raise(sig);
}
#endif

} // namespace

std::string advert_directory() {
    const std::string overridden = env("ZX_SERVER_ADVERT_DIR");
    if (!overridden.empty()) {
        return overridden;
    }
#ifdef _WIN32
    std::string base = env("LOCALAPPDATA");
#else
    std::string base = env("XDG_RUNTIME_DIR");
    if (base.empty() && !env("HOME").empty()) {
        base = (fs::u8path(env("HOME")) / ".cache").u8string();
    }
#endif
    if (base.empty()) {
        std::error_code ec;
        base = fs::temp_directory_path(ec).u8string();
    }
    return (fs::u8path(base) / "zx-spectrum" / "servers").u8string();
}

void set_server_identity(ServerIdentity identity) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_identity = std::move(identity);
    g_identity.pid = current_pid();
    g_identity.started = utc_now();
    std::error_code ec;
    g_identity.cwd = fs::current_path(ec).u8string();
}

bool advertise(const std::string& dir, std::string& error) {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::error_code ec;
    fs::create_directories(fs::u8path(dir), ec);
    if (ec) {
        error = "couldn't create " + dir + ": " + ec.message();
        return false;
    }
    g_advert = fs::u8path(dir) / (std::to_string(g_identity.pid) + ".json");
    if (!write_locked(error)) {
        g_advert.clear();
        return false;
    }
    return true;
}

void withdraw() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_advert.empty()) {
        return;
    }
    std::error_code ec;
    fs::remove(g_advert, ec);
    g_advert.clear();
}

void withdraw_on_exit() {
    std::atexit([] { withdraw(); });
#ifdef _WIN32
    SetConsoleCtrlHandler(on_console_event, TRUE);
#else
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
#endif
}

void note_program(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_program = path;
    // A failure here is not worth reporting: the advert still names the
    // server and its ports, which is what it is for, and whoever loaded the
    // program has their answer already.
    std::string error;
    write_locked(error);
}

nlohmann::json server_info() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return info_locked();
}

} // namespace zx
