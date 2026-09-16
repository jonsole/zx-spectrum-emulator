#pragma once
// The bus the CPU reads/writes through. Ported from
// rust-core/zx-core/src/memory.rs, and since grown the 128K's paging.

#include <array>
#include <vector>
#include <cstddef>
#include <cstdint>
#include <string>

namespace zx {

/// Abstract bus. `read` is non-const because a real (contended or
/// side-effecting) bus may change state on access.
class Memory {
public:
    virtual ~Memory() = default;
    virtual uint8_t read(uint16_t addr) = 0;
    virtual void write(uint16_t addr, uint8_t value) = 0;
};

/// Unguarded flat 64K -- just enough to exercise the CPU in isolation
/// (differential/pin-level tests, the ZEXALL harness). No write protection.
class FlatMemory : public Memory {
public:
    std::array<uint8_t, 0x10000> bytes{};

    uint8_t read(uint16_t addr) override { return bytes[addr]; }
    void write(uint16_t addr, uint8_t value) override { bytes[addr] = value; }
};

/// Which Spectrum the machine is being. The two differ in memory (a 48K has
/// one ROM and no paging; a 128K has two ROMs, eight 16K RAM banks and port
/// 0x7FFD to page them), in video timing (see UlaTiming), and in the 128K
/// having an AY-3-8912 sound chip on ports 0xFFFD/0xBFFD.
enum class Model { Spectrum48, Spectrum128 };

const char* model_name(Model m);

/// Port 0x7FFD's value in words: "ROM 1, bank 7, screen 7, locked".
std::string describe_paging(uint8_t paging);

constexpr size_t ROM_SIZE = 0x4000;
/// The 48K's RAM, and the part of a 128K's that a 48K program can see.
constexpr size_t RAM_SIZE = 0xC000;
/// The unit paging works in: every ROM and every RAM bank is 16K.
constexpr size_t BANK_SIZE = 0x4000;
constexpr size_t RAM_BANKS = 8;
/// A 128K ROM image as the emulator takes it: ROM 0 (the 128K editor and
/// menu) followed by ROM 1 (48K BASIC), the layout of the usual `128.rom`.
constexpr size_t ROM_128K_SIZE = 2 * ROM_SIZE;

/// Port 0x7FFD's fields, as the 128K's paging register holds them.
constexpr uint8_t PAGING_BANK_MASK = 0x07;  // RAM bank at 0xC000
constexpr uint8_t PAGING_SHADOW_SCREEN = 0x08; // display bank 7 instead of 5
constexpr uint8_t PAGING_ROM1 = 0x10;         // ROM 1 (48K BASIC) instead of ROM 0
constexpr uint8_t PAGING_LOCK = 0x20;         // ignore every later write

/// The RAM banks a 48K program's three 16K pages live in -- also the 128K's
/// power-on map, so a 48K snapshot lands on a 128K exactly where the 128K
/// itself would have put it. Bank 5 holds the (normal) screen.
constexpr uint8_t BANK_AT_4000 = 5;
constexpr uint8_t BANK_AT_8000 = 2;
constexpr uint8_t DEFAULT_BANK_AT_C000 = 0;
constexpr uint8_t SCREEN_BANK = 5;
constexpr uint8_t SHADOW_SCREEN_BANK = 7;

/// Marks "this address is ROM" where a RAM bank number is expected.
constexpr uint8_t NO_BANK = 0xFF;

/// The Spectrum's memory: 16K of ROM at the bottom and RAM above it, with the
/// 128K's paging layered on.
///
/// The address space is four 16K slots. Slot 0 is always ROM: the 48K's one
/// ROM, or whichever of the 128K's two the paging register selects. Slot 1
/// is always bank 5 and slot 2 always bank 2, on both models. Slot 3 is bank
/// 0 on a 48K -- which gives it the 48K's flat 48K of RAM in banks 5, 2 and
/// 0 -- and on a 128K whichever bank port 0x7FFD names.
///
/// All eight banks and all three ROMs are held whatever the model, so a
/// 128K snapshot or a 48K one can be loaded into either machine and the
/// model switched to match; only what is PAGED changes with the model.
class SpectrumMemory : public Memory {
public:
    /// The 48K machine's ROM.
    std::array<uint8_t, ROM_SIZE> rom48{};
    /// The 128K's two: [0] is the editor/menu ROM, [1] is 48K BASIC.
    std::array<std::array<uint8_t, ROM_SIZE>, 2> rom128{};
    std::array<std::array<uint8_t, BANK_SIZE>, RAM_BANKS> bank{};

    SpectrumMemory();

#if ZX_REWIND
    /// The RAM and the paging, for rewind's checkpoints. Only the banks the
    /// model can reach: 5, 2 and 0 on a 48K, all eight on a 128K. The ROMs are
    /// not kept -- loading one ends the history.
    struct State {
        Model model = Model::Spectrum48;
        uint8_t paging = 0;
        std::vector<uint8_t> ram;
    };
    void save_state(State& s) const;
    void restore_state(const State& s);
#endif

    /// Loads a 16K image as the 48K ROM or a 32K one as the 128K pair (ROM 0
    /// then ROM 1). Returns an empty string on success, or the error message.
    /// Which model is selected does not change: a 48K machine can hold the
    /// 128K's ROMs ready for a snapshot that needs them, and vice versa.
    std::string load_rom(const uint8_t* data, size_t len);

    /// Whether a ROM for `m` has been loaded. What a caller checks before
    /// switching to a model whose ROM would otherwise boot into NOPs. A 48K
    /// counts as having one when only the 128K pair is loaded: ROM 1 of the
    /// pair is the 48K ROM (with a handful of bytes changed), and a machine
    /// given roms/128.rom alone should still boot 48K BASIC when switched.
    bool has_rom(Model m) const;

    Model model() const { return model_; }
    /// Switches model and returns paging to its power-on state, which is the
    /// only paging state a 48K has. RAM and ROM contents are untouched.
    void set_model(Model m);

    /// The last value written to port 0x7FFD. Always 0 on a 48K.
    uint8_t paging() const { return paging_; }
    /// A write to port 0x7FFD. Ignored on a 48K, and once PAGING_LOCK has
    /// been set -- which only a reset clears, as on the hardware.
    void write_paging(uint8_t value);
    /// Puts paging back to its power-on state: ROM 0, bank 0, screen 5,
    /// unlocked. What a reset does; on a 48K it is a no-op.
    void reset_paging();
    /// The ROM in slot 0 -- 0 or 1 on a 128K, always 0 on a 48K (meaning its
    /// one ROM).
    uint8_t rom_selected() const { return rom_selected_; }
    /// The bank at 0xC000.
    uint8_t bank_at_c000() const { return bank_c000_; }
    bool paging_locked() const { return (paging_ & PAGING_LOCK) != 0; }

    /// The bank the ULA is displaying: 5, or 7 when the 128K's shadow screen
    /// is selected.
    uint8_t screen_bank() const { return screen_bank_; }
    /// That bank's bytes, for the ULA to fetch from directly. Through the CPU
    /// map would be wrong: the shadow screen is displayed whether or not bank
    /// 7 is paged anywhere the CPU can see it.
    const uint8_t* screen_bytes() const { return bank[screen_bank_].data(); }

    /// Which RAM bank a CPU address currently reaches, or NO_BANK for ROM.
    uint8_t bank_of(uint16_t addr) const { return slot_bank_[addr >> 14]; }

    /// A byte of the 48K's flat RAM, by offset from 0x4000 -- banks 5, 2 and
    /// 0 in that order, regardless of what is paged. How a 48K snapshot and
    /// the 48K tests address RAM.
    uint8_t& ram48(size_t offset) {
        return bank[RAM48_BANKS[offset / BANK_SIZE]][offset % BANK_SIZE];
    }
    uint8_t ram48(size_t offset) const {
        return bank[RAM48_BANKS[offset / BANK_SIZE]][offset % BANK_SIZE];
    }

    uint8_t read(uint16_t addr) override { return slot_[addr >> 14][addr & (BANK_SIZE - 1)]; }

    /// Writes below ROM_SIZE are silently discarded -- that IS the hardware
    /// behavior (there's nothing to write to), not an error worth reporting.
    void write(uint16_t addr, uint8_t value) override {
        if (addr >= ROM_SIZE) {
            slot_[addr >> 14][addr & (BANK_SIZE - 1)] = value;
        }
    }

private:
    static constexpr uint8_t RAM48_BANKS[3] = {BANK_AT_4000, BANK_AT_8000, DEFAULT_BANK_AT_C000};

    Model model_ = Model::Spectrum48;
    bool rom48_loaded_ = false;
    bool rom128_loaded_ = false;
    uint8_t paging_ = 0;
    uint8_t rom_selected_ = 0;
    uint8_t bank_c000_ = DEFAULT_BANK_AT_C000;
    uint8_t screen_bank_ = SCREEN_BANK;
    /// What each 16K slot reads from. Rebuilt by remap() whenever the model
    /// or the paging register changes, so read() is one index and a load.
    uint8_t* slot_[4] = {nullptr, nullptr, nullptr, nullptr};
    uint8_t slot_bank_[4] = {NO_BANK, BANK_AT_4000, BANK_AT_8000, DEFAULT_BANK_AT_C000};

    void remap();
};

} // namespace zx
