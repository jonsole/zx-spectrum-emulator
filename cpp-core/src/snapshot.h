#pragma once
// Snapshot loading and saving: .sna (48K and 128K) and .z80 (versions 1 to 3,
// 48K and 128K).
//
// A snapshot names a machine as well as a state. Loading one switches the
// model to what it needs -- a 128K .z80 makes the machine a 128K, a 48K .sna
// makes it a 48K -- which is what every emulator does and what "the machine
// this was taken on" means. The ROM for that model has to have been loaded
// already; the loader has no way to find one.
//
// The 48K .sna's defining quirk: there is no PC field. It represents a
// machine paused as if by a RETN, so PC lives on top of the stack and has to
// be popped (SP += 2) as part of loading. The 128K variant fixes that with a
// trailer holding PC, the paging register and the extra banks.

#include "spectrum.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zx {

constexpr size_t SNA_HEADER_SIZE = 27;
constexpr size_t SNA_48K_SIZE = SNA_HEADER_SIZE + RAM_SIZE; // 49179
/// The 128K variant: the 48K image (banks 5, 2 and whichever is at 0xC000),
/// a 4-byte trailer, then the other five banks -- or six, when the bank at
/// 0xC000 is 5 or 2 and would otherwise be saved twice.
constexpr size_t SNA_128K_TRAILER = 4;
constexpr size_t SNA_128K_SIZE = SNA_48K_SIZE + SNA_128K_TRAILER + 5 * BANK_SIZE; // 131103
constexpr size_t SNA_128K_SIZE_6 = SNA_48K_SIZE + SNA_128K_TRAILER + 6 * BANK_SIZE; // 147487

enum class SnapshotFormat { Sna, Z80 };

/// What a snapshot file says about itself, without loading it.
struct SnapshotInfo {
    SnapshotFormat format = SnapshotFormat::Sna;
    Model model = Model::Spectrum48;
    /// 1, 2 or 3 for a .z80; 0 for a .sna.
    int version = 0;
    uint16_t pc = 0;
};

/// Reads the header of either format. .sna files are fixed-size, so the size
/// alone identifies them; anything else is read as .z80. Returns "" and fills
/// `info`, or why the bytes are neither.
std::string inspect_snapshot(const uint8_t* data, size_t len, SnapshotInfo& info);

/// Loads a snapshot of either format, switching the model to match it.
/// Returns an empty string on success, or the reason it could not be loaded.
std::string load_snapshot(Spectrum& m, const uint8_t* data, size_t len);

/// Loads a 48K or 128K .sna into `m`.
std::string load_sna(Spectrum& m, const uint8_t* data, size_t len);

/// Writes `m` out as a .sna: SNA_48K_SIZE bytes for a 48K, one of the two
/// 128K sizes for a 128K. The machine itself is not touched -- a 48K image
/// pushes PC onto the stack in the SAVED RAM only. Returns an empty string on
/// success, or why the machine cannot be saved (a 48K whose SP points outside
/// RAM, where there is nowhere to push PC).
std::string save_sna(const Spectrum& m, std::vector<uint8_t>& out);

/// Loads a .z80 of version 1, 2 or 3 into `m`. 48K hardware modes make a
/// 48K; everything else -- the 128K, +2, +2A, +3 and Pentagon modes -- is
/// loaded as a 128K, which is right for the first two and the nearest thing
/// to right for the rest.
std::string load_z80(Spectrum& m, const uint8_t* data, size_t len);

/// Writes `m` out as a version 3 .z80 with every page compressed. Never
/// fails: unlike a 48K .sna, the format has a PC field of its own.
void save_z80(const Spectrum& m, std::vector<uint8_t>& out);

} // namespace zx
