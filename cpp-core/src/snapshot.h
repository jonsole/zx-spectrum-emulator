#pragma once
// .sna snapshot loading (48K, the fixed 49179-byte layout).
//
// The format's defining quirk: there is no PC field. A .sna represents a
// machine paused as if by a RETN, so PC lives on top of the stack and has to
// be popped (SP += 2) as part of loading.

#include "spectrum.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zx {

constexpr size_t SNA_HEADER_SIZE = 27;
constexpr size_t SNA_48K_SIZE = SNA_HEADER_SIZE + RAM_SIZE; // 49179

/// Loads a 48K .sna into `m`. Returns an empty string on success, or the
/// reason it could not be loaded.
std::string load_sna(Spectrum48K& m, const uint8_t* data, size_t len);

/// Writes `m` out as a 48K .sna, exactly SNA_48K_SIZE bytes. The inverse of
/// load_sna: PC is pushed onto the stack in the saved RAM image (SP -= 2),
/// which is the format's convention -- the machine itself is not touched.
/// Returns an empty string on success, or why the machine cannot be saved
/// (SP pointing outside RAM, where there is nowhere to push PC).
std::string save_sna(const Spectrum48K& m, std::vector<uint8_t>& out);

} // namespace zx
