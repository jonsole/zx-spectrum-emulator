#pragma once
// Debug Adapter Protocol server -- what VS Code connects to.

#include "engine.h"
#include "net.h"
#include "rom_source.h"

namespace zx {

/// Serves DAP on an already-bound listener until the process ends. Blocking;
/// run on its own thread. If `exit_on_disconnect`, the process exits when the
/// last DAP connection closes -- which lets a VS Code preLaunchTask rebind
/// the port on the next launch instead of colliding with a server left over
/// from the previous session.
void serve_dap(Engine& engine, Sources& sources, net::Listener listener,
               bool exit_on_disconnect);

} // namespace zx
