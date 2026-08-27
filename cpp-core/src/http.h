#pragma once
// Just enough HTTP/1.1 to carry MCP's Streamable HTTP transport: parse a
// request with a Content-Length body, write a response, keep the connection
// alive for the next one.
//
// Not a general-purpose server. It handles exactly what an MCP client sends --
// no chunked request bodies, no compression, no ranges. A request it cannot
// parse is answered with an error rather than guessed at.

#include "net.h"

#include <map>
#include <string>

namespace zx::http {

struct Request {
    std::string method;
    std::string target; ///< path only; any query string is stripped
    /// Header names are lowercased, so lookups don't have to guess at case.
    std::map<std::string, std::string> headers;
    std::string body;

    /// Header value, or "" if absent. `name` must be lowercase.
    std::string header(const std::string& name) const;
};

struct Response {
    int status = 200;
    std::string content_type = "application/json";
    std::string body;
    /// Extra headers, sent verbatim. Used for Mcp-Session-Id.
    std::map<std::string, std::string> headers;
};

/// Reads one request. False at EOF, on a malformed request, or if the peer
/// went away mid-body.
bool read_request(net::Socket& sock, std::string& buffer, Request& out);

/// Writes a response with the correct framing. False if the peer went away.
bool write_response(net::Socket& sock, const Response& response);

} // namespace zx::http
