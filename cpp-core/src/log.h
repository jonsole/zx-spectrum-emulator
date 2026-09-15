#pragma once
// One-line, timestamped server log.
//
// Everything the servers report goes through here so that a session's story
// reads in order on one stream: who connected, what they asked for, and where
// the machine stopped. Four threads can be writing at once -- DAP, MCP, the
// screen viewer, the audio stream -- so each line is formatted first and
// written under a lock, rather than printf'd in pieces that interleave.
//
// stdout, not stderr: this is a narrative of what the server is doing, not a
// stream of failures, and VS Code shows the task's stdout in the terminal
// panel where it is meant to be read. Errors that stop the server keep going
// to stderr.

#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <mutex>
#include <string>

namespace zx {

inline std::mutex& log_mutex() {
    static std::mutex m;
    return m;
}

/// Wall-clock time as HH:MM:SS.mmm.
///
/// Wall clock rather than time-since-start because the point of these lines
/// is to line up with something else -- a click in VS Code, a message in an
/// MCP client, a note in a bug report.
inline std::string log_timestamp() {
    using clock = std::chrono::system_clock;
    const auto now = clock::now();
    const std::time_t seconds = clock::to_time_t(now);
    const auto millis =
        std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
    std::tm parts{};
#ifdef _WIN32
    localtime_s(&parts, &seconds);
#else
    localtime_r(&seconds, &parts);
#endif
    char buffer[16];
    std::snprintf(buffer, sizeof buffer, "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min,
                  parts.tm_sec, int(millis));
    return buffer;
}

/// Writes one timestamped line. Format string, as printf.
inline void log(const char* format, ...) {
    char message[512];
    va_list args;
    va_start(args, format);
    std::vsnprintf(message, sizeof message, format, args);
    va_end(args);

    const std::string stamped = "[" + log_timestamp() + "] " + message + "\n";
    std::lock_guard<std::mutex> lock(log_mutex());
    // fwrite of the whole line, then flush: the server's output is usually
    // being watched live (a VS Code terminal, or the launcher's log file),
    // and a line that appears only when a buffer happens to fill is worse
    // than useless for following what just happened.
    std::fwrite(stamped.data(), 1, stamped.size(), stdout);
    std::fflush(stdout);
}

} // namespace zx
