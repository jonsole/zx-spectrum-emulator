#include "http.h"

#include <cctype>
#include <cstdlib>

namespace zx::http {
namespace {

/// Fills `buffer` until it holds at least `wanted` bytes. False at EOF.
bool fill(net::Socket& sock, std::string& buffer, size_t wanted) {
    char chunk[8192];
    while (buffer.size() < wanted) {
        int n = sock.recv(chunk, int(sizeof chunk));
        if (n <= 0) {
            return false;
        }
        buffer.append(chunk, size_t(n));
    }
    return true;
}

/// Reads one CRLF-terminated line, without its terminator. False at EOF.
bool read_line(net::Socket& sock, std::string& buffer, std::string& out) {
    size_t pos;
    while ((pos = buffer.find('\n')) == std::string::npos) {
        if (!fill(sock, buffer, buffer.size() + 1)) {
            return false;
        }
    }
    out = buffer.substr(0, pos);
    buffer.erase(0, pos + 1);
    if (!out.empty() && out.back() == '\r') {
        out.pop_back();
    }
    return true;
}

std::string lowercase(std::string s) {
    for (char& c : s) {
        c = char(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

std::string trim(const std::string& s) {
    size_t begin = 0;
    size_t end = s.size();
    while (begin < end && std::isspace(static_cast<unsigned char>(s[begin]))) {
        begin++;
    }
    while (end > begin && std::isspace(static_cast<unsigned char>(s[end - 1]))) {
        end--;
    }
    return s.substr(begin, end - begin);
}

const char* status_text(int status) {
    switch (status) {
        case 200: return "OK";
        case 202: return "Accepted";
        case 400: return "Bad Request";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 406: return "Not Acceptable";
        case 411: return "Length Required";
        case 500: return "Internal Server Error";
        default: return "Unknown";
    }
}

} // namespace

std::string Request::header(const std::string& name) const {
    auto it = headers.find(name);
    return it == headers.end() ? std::string() : it->second;
}

bool read_request(net::Socket& sock, std::string& buffer, Request& out) {
    out = Request();

    std::string line;
    if (!read_line(sock, buffer, line)) {
        return false;
    }
    // "METHOD target HTTP/1.1"
    const size_t first_space = line.find(' ');
    if (first_space == std::string::npos) {
        return false;
    }
    const size_t second_space = line.find(' ', first_space + 1);
    if (second_space == std::string::npos) {
        return false;
    }
    out.method = line.substr(0, first_space);
    out.target = line.substr(first_space + 1, second_space - first_space - 1);
    const size_t query = out.target.find('?');
    if (query != std::string::npos) {
        out.target.erase(query);
    }

    for (;;) {
        if (!read_line(sock, buffer, line)) {
            return false;
        }
        if (line.empty()) {
            break;
        }
        const size_t colon = line.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        out.headers[lowercase(trim(line.substr(0, colon)))] = trim(line.substr(colon + 1));
    }

    // Chunked bodies are not supported; say so rather than silently reading a
    // body that is actually chunk framing.
    if (!out.header("transfer-encoding").empty()) {
        return false;
    }

    const std::string length = out.header("content-length");
    if (!length.empty()) {
        const size_t n = size_t(std::strtoul(length.c_str(), nullptr, 10));
        if (!fill(sock, buffer, n)) {
            return false;
        }
        out.body = buffer.substr(0, n);
        buffer.erase(0, n);
    }
    return true;
}

bool write_response(net::Socket& sock, const Response& response) {
    std::string out = "HTTP/1.1 " + std::to_string(response.status) + " "
                      + status_text(response.status) + "\r\n";
    out += "Content-Type: " + response.content_type + "\r\n";
    out += "Content-Length: " + std::to_string(response.body.size()) + "\r\n";
    for (const auto& header : response.headers) {
        out += header.first + ": " + header.second + "\r\n";
    }
    out += "Connection: keep-alive\r\n\r\n";
    out += response.body;
    return sock.send_all(out);
}

} // namespace zx::http
