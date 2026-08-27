#include "memory.h"

#include <algorithm>

namespace zx {

std::string Spectrum48KMemory::load_rom(const uint8_t* data, size_t len) {
    if (len != ROM_SIZE) {
        return "ROM must be exactly " + std::to_string(ROM_SIZE) + " bytes, got "
             + std::to_string(len);
    }
    std::copy(data, data + len, rom.begin());
    return {};
}

} // namespace zx
