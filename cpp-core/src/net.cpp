#include "net.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
constexpr socket_t INVALID = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
constexpr socket_t INVALID = -1;
#define closesocket ::close
#endif

#include <mutex>

namespace zx::net {
namespace {

socket_t as_socket(uintptr_t h) { return socket_t(h); }
uintptr_t as_handle(socket_t s) { return uintptr_t(s); }
constexpr uintptr_t INVALID_HANDLE = ~uintptr_t(0);

} // namespace

bool startup(std::string& error) {
#ifdef _WIN32
    static std::once_flag once;
    static bool ok = false;
    static std::string err;
    std::call_once(once, [] {
        WSADATA data;
        int rc = WSAStartup(MAKEWORD(2, 2), &data);
        ok = rc == 0;
        if (!ok) {
            err = "WSAStartup failed: " + std::to_string(rc);
        }
    });
    if (!ok) {
        error = err;
    }
    return ok;
#else
    (void)error;
    return true;
#endif
}

Socket::~Socket() { close(); }

Socket::Socket(Socket&& other) noexcept : handle_(other.handle_) {
    other.handle_ = INVALID_HANDLE;
}

Socket& Socket::operator=(Socket&& other) noexcept {
    if (this != &other) {
        close();
        handle_ = other.handle_;
        other.handle_ = INVALID_HANDLE;
    }
    return *this;
}

bool Socket::valid() const { return handle_ != INVALID_HANDLE; }

void Socket::close() {
    if (valid()) {
        closesocket(as_socket(handle_));
        handle_ = INVALID_HANDLE;
    }
}

int Socket::recv(char* buf, int len) {
    if (!valid()) {
        return -1;
    }
    return ::recv(as_socket(handle_), buf, len, 0);
}

bool Socket::send_all(const char* data, size_t len) {
    if (!valid()) {
        return false;
    }
    size_t sent = 0;
    while (sent < len) {
        int n = ::send(as_socket(handle_), data + sent, int(len - sent), 0);
        if (n <= 0) {
            return false;
        }
        sent += size_t(n);
    }
    return true;
}

bool Listener::listen(const std::string& host, uint16_t port, std::string& error) {
    if (!startup(error)) {
        return false;
    }
    socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID) {
        error = "socket() failed";
        return false;
    }
    int yes = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof yes);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        error = "bad host address: " + host;
        closesocket(s);
        return false;
    }
    if (::bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
        error = "bind " + host + ":" + std::to_string(port) + " failed (already in use?)";
        closesocket(s);
        return false;
    }
    if (::listen(s, 8) != 0) {
        error = "listen() failed";
        closesocket(s);
        return false;
    }
    handle_ = as_handle(s);
    return true;
}

Socket Listener::accept() {
    if (handle_ == INVALID_HANDLE) {
        return Socket();
    }
    socket_t c = ::accept(as_socket(handle_), nullptr, nullptr);
    if (c == INVALID) {
        return Socket();
    }
    // Debug traffic is many small messages; Nagle would add latency to every
    // single step.
    int yes = 1;
    ::setsockopt(c, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&yes), sizeof yes);
    return Socket(as_handle(c));
}

void Listener::close() {
    if (handle_ != INVALID_HANDLE) {
        closesocket(as_socket(handle_));
        handle_ = INVALID_HANDLE;
    }
}

Listener::~Listener() { close(); }

} // namespace zx::net
