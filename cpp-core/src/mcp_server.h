#pragma once
// MCP server -- the tool surface an agent drives the emulator through.

#include "engine.h"
#include "net.h"
#include "rom_source.h"

namespace zx {

/// Serves MCP over Streamable HTTP at `/mcp` on an already-bound listener,
/// until the process ends. Blocking; run on its own thread.
void serve_mcp(Engine& engine, Sources& sources, net::Listener listener);

} // namespace zx
