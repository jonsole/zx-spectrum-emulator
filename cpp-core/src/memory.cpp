#include "memory.h"

namespace zx {

const char* model_name(Model m) {
    return m == Model::Spectrum128 ? "128K" : "48K";
}

std::string describe_paging(uint8_t paging) {
    std::string out = "ROM ";
    out += (paging & PAGING_ROM1) != 0 ? "1" : "0";
    out += ", bank " + std::to_string(paging & PAGING_BANK_MASK);
    out += ", screen ";
    out += (paging & PAGING_SHADOW_SCREEN) != 0 ? "7" : "5";
    if ((paging & PAGING_LOCK) != 0) {
        out += ", locked";
    }
    return out;
}

SpectrumMemory::SpectrumMemory() {
    remap();
}

std::string SpectrumMemory::load_rom(const uint8_t* data, size_t len) {
    if (len == ROM_SIZE) {
        for (size_t i = 0; i < ROM_SIZE; i++) {
            rom48[i] = data[i];
        }
        rom48_loaded_ = true;
        remap();
        return {};
    }
    if (len == ROM_128K_SIZE) {
        for (size_t i = 0; i < ROM_SIZE; i++) {
            rom128[0][i] = data[i];
            rom128[1][i] = data[ROM_SIZE + i];
        }
        rom128_loaded_ = true;
        remap();
        return {};
    }
    return "ROM must be exactly " + std::to_string(ROM_SIZE) + " bytes (48K) or "
           + std::to_string(ROM_128K_SIZE) + " bytes (128K: ROM 0 then ROM 1), got "
           + std::to_string(len);
}

bool SpectrumMemory::has_rom(Model m) const {
    if (m == Model::Spectrum128) {
        return rom128_loaded_;
    }
    return rom48_loaded_ || rom128_loaded_;
}

void SpectrumMemory::set_model(Model m) {
    model_ = m;
    reset_paging();
}

void SpectrumMemory::write_paging(uint8_t value) {
    if (model_ != Model::Spectrum128 || paging_locked()) {
        return;
    }
    paging_ = value;
    remap();
}

void SpectrumMemory::reset_paging() {
    paging_ = 0;
    remap();
}

void SpectrumMemory::remap() {
    if (model_ == Model::Spectrum128) {
        rom_selected_ = (paging_ & PAGING_ROM1) != 0 ? 1 : 0;
        bank_c000_ = uint8_t(paging_ & PAGING_BANK_MASK);
        screen_bank_ = (paging_ & PAGING_SHADOW_SCREEN) != 0 ? SHADOW_SCREEN_BANK : SCREEN_BANK;
        slot_[0] = rom128[rom_selected_].data();
    } else {
        rom_selected_ = 0;
        bank_c000_ = DEFAULT_BANK_AT_C000;
        screen_bank_ = SCREEN_BANK;
        // The 128K's ROM 1 stands in for a 48K ROM that was never loaded --
        // see has_rom.
        slot_[0] = rom48_loaded_ || !rom128_loaded_ ? rom48.data() : rom128[1].data();
    }
    slot_[1] = bank[BANK_AT_4000].data();
    slot_[2] = bank[BANK_AT_8000].data();
    slot_[3] = bank[bank_c000_].data();
    slot_bank_[0] = NO_BANK;
    slot_bank_[1] = BANK_AT_4000;
    slot_bank_[2] = BANK_AT_8000;
    slot_bank_[3] = bank_c000_;
}

#if ZX_REWIND
void SpectrumMemory::save_state(State& s) const {
    s.model = model_;
    s.paging = paging_;
    if (model_ == Model::Spectrum128) {
        s.ram.resize(size_t(RAM_BANKS) * BANK_SIZE);
        for (size_t b = 0; b < RAM_BANKS; b++) {
            std::copy(bank[b].begin(), bank[b].end(), s.ram.begin() + b * BANK_SIZE);
        }
    } else {
        s.ram.resize(sizeof RAM48_BANKS * BANK_SIZE);
        for (size_t i = 0; i < sizeof RAM48_BANKS; i++) {
            const auto& from = bank[RAM48_BANKS[i]];
            std::copy(from.begin(), from.end(), s.ram.begin() + i * BANK_SIZE);
        }
    }
}

void SpectrumMemory::restore_state(const State& s) {
    model_ = s.model;
    paging_ = s.paging;
    if (model_ == Model::Spectrum128) {
        for (size_t b = 0; b < RAM_BANKS && (b + 1) * BANK_SIZE <= s.ram.size(); b++) {
            std::copy(s.ram.begin() + b * BANK_SIZE, s.ram.begin() + (b + 1) * BANK_SIZE,
                      bank[b].begin());
        }
    } else {
        for (size_t i = 0; i < sizeof RAM48_BANKS && (i + 1) * BANK_SIZE <= s.ram.size(); i++) {
            std::copy(s.ram.begin() + i * BANK_SIZE, s.ram.begin() + (i + 1) * BANK_SIZE,
                      bank[RAM48_BANKS[i]].begin());
        }
    }
    // The slot pointers point into this object's own arrays, so they are
    // derived from the paging, never copied.
    remap();
}
#endif

} // namespace zx
