#pragma once
// Screen-frame streaming TCP server -- what the VS Code screen-viewer panel
// connects to.

#include "engine.h"
#include "net.h"

#include <cstdint>
#include <string>
#include <vector>

namespace zx {

/// The picture's size from its byte count: the plain FULL_WIDTH x
/// FULL_HEIGHT, or the RF look's RF_WIDTH x RF_HEIGHT. False for anything
/// else (a screen not primed yet). Either pointer may be null.
bool screen_size(size_t bytes, uint32_t* width, uint32_t* height);

/// Encodes an RGB picture of either size as PNG; empty for any other size.
std::vector<uint8_t> encode_png(const std::vector<uint8_t>& rgb);

/// The same picture as a PNG whose data is stored, not compressed: a few
/// milliseconds where encode_png takes a hundred on the RF look's noisy
/// 704x624, which hardly compresses anyway. For the stream, where time
/// matters more than size; empty for a size screen_size does not know.
std::vector<uint8_t> encode_png_stored(const std::vector<uint8_t>& rgb);

/// Pushes the live display to every connected client as
/// `[big-endian u32 length][PNG bytes]`, forever. Blocking; run on its own
/// thread.
void serve_screen_stream(Engine& engine, const std::string& host, uint16_t port);
/// The same, on a listener already bound -- how zx_server does it, so that a
/// port in use stops it at startup and a port of 0 can be reported.
void serve_screen_stream(Engine& engine, net::Listener listener);

} // namespace zx
