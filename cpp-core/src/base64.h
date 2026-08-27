#pragma once
// Standard base64, as DAP's readMemory/writeMemory use it.

#include <cstdint>
#include <string>
#include <vector>

namespace zx {

std::string base64_encode(const std::vector<uint8_t>& data);
std::vector<uint8_t> base64_decode(const std::string& text);

} // namespace zx
