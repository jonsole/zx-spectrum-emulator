#pragma once
// Reading and writing a whole binary file. std::ifstream rather than fopen: MSVC
// deprecates fopen and this build treats warnings as errors.

#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace zx {

inline bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    return true;
}

inline bool write_file(const std::string& path, const std::vector<uint8_t>& data) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
        return false;
    }
    file.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
    return bool(file);
}

} // namespace zx
