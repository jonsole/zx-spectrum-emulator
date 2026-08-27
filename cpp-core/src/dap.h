#pragma once
// Debug Adapter Protocol server -- what VS Code connects to.

#include "engine.h"
#include "rom_source.h"

#include <cstdint>
#include <string>

namespace zx {

/// Serves DAP on host:port until the process ends. Blocking; run on its own
/// thread. If `exit_on_disconnect`, the process exits when the last DAP
/// connection closes -- which lets a VS Code preLaunchTask rebind the port on
/// the next launch instead of colliding with a server left over from the
/// previous session.
void serve_dap(Engine& engine, Sources& sources, const std::string& host, uint16_t port,
               bool exit_on_disconnect);

} // namespace zx
