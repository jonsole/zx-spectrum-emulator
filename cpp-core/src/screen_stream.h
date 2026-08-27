#pragma once
// Screen-frame streaming TCP server -- what the VS Code screen-viewer panel
// connects to.

#include "engine.h"

#include <cstdint>
#include <string>
#include <vector>

namespace zx {

/// Encodes a FULL_WIDTH x FULL_HEIGHT RGB buffer as PNG.
std::vector<uint8_t> encode_png(const std::vector<uint8_t>& rgb);

/// Pushes the live display to every connected client as
/// `[big-endian u32 length][PNG bytes]`, forever. Blocking; run on its own
/// thread.
void serve_screen_stream(Engine& engine, const std::string& host, uint16_t port);

} // namespace zx
