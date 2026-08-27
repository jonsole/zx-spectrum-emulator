#pragma once
// Minimal blocking TCP listener/socket wrapper.
//
// Thread-per-connection rather than an async runtime: at this scale (a
// debugger, an MCP client and a screen viewer) that is a handful of threads
// spending nearly all their time blocked on a socket, and it keeps the
// protocol code straight-line and readable.

#include <cstdint>
#include <string>

namespace zx::net {

/// Initialises Winsock. Safe to call more than once.
bool startup(std::string& error);

/// A connected socket. Moves, does not copy; closes on destruction.
class Socket {
public:
    Socket() = default;
    explicit Socket(uintptr_t handle) : handle_(handle) {}
    ~Socket();
    Socket(Socket&& other) noexcept;
    Socket& operator=(Socket&& other) noexcept;
    Socket(const Socket&) = delete;
    Socket& operator=(const Socket&) = delete;

    bool valid() const;
    void close();

    /// Reads up to `len` bytes. Returns bytes read, 0 on clean close, <0 on
    /// error.
    int recv(char* buf, int len);
    /// Writes all of `data`. False if the peer went away.
    bool send_all(const char* data, size_t len);
    bool send_all(const std::string& s) { return send_all(s.data(), s.size()); }

private:
    uintptr_t handle_ = ~uintptr_t(0);
};

/// A listening socket.
class Listener {
public:
    /// Binds and listens. Returns false and fills `error` on failure.
    bool listen(const std::string& host, uint16_t port, std::string& error);
    /// Blocks for the next connection. Returns an invalid Socket on failure.
    Socket accept();
    void close();
    ~Listener();

private:
    uintptr_t handle_ = ~uintptr_t(0);
};

} // namespace zx::net
