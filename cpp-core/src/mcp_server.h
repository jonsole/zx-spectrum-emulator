#pragma once
// MCP server -- the tool surface an agent drives the emulator through.

#include "engine.h"

#include <cstdint>
#include <string>

namespace zx {

/// Serves MCP over Streamable HTTP at `/mcp` until the process ends.
/// Blocking; run on its own thread.
void serve_mcp(Engine& engine, const std::string& host, uint16_t port);

} // namespace zx
