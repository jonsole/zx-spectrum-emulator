// Memory map tests -- ports the equivalent cases from
// rust-core/zx-core/tests/spectrum.rs (rom_is_write_protected, ram_is_writable)
// plus load_rom's size validation.

#include "memory.h"
#include "pins.h"
#include "registers.h"
#include "test_main.h"

#include <vector>

using namespace zx;

TEST(rom_is_write_protected) {
    Spectrum48KMemory mem;
    std::vector<uint8_t> rom(ROM_SIZE, 0xAA);
    CHECK_EQ(mem.load_rom(rom.data(), rom.size()), std::string());

    mem.write(0x1234, 0xFF);
    CHECK_EQ(mem.read(0x1234), uint8_t(0xAA));
}

TEST(ram_is_writable) {
    Spectrum48KMemory mem;
    mem.write(0x8000, 0x42);
    CHECK_EQ(mem.read(0x8000), uint8_t(0x42));
}

TEST(load_rom_rejects_a_wrong_sized_image) {
    Spectrum48KMemory mem;
    std::vector<uint8_t> too_short(100, 0);
    CHECK(mem.load_rom(too_short.data(), too_short.size()) != std::string());
}

TEST(flat_memory_is_unguarded_across_the_whole_64k) {
    FlatMemory mem;
    mem.write(0x0000, 0x11); // would be ROM on a real machine
    mem.write(0xFFFF, 0x22);
    CHECK_EQ(mem.read(0x0000), uint8_t(0x11));
    CHECK_EQ(mem.read(0xFFFF), uint8_t(0x22));
}

// The pin layout is load-bearing: vendor/chips/z80.h's shim uses these exact
// bit positions, so the differential tests depend on them matching.
TEST(pin_helpers_round_trip_address_and_data) {
    uint64_t pins = 0;
    pins = set_addr_data_ctrl(pins, 0x4000, 0x42, MREQ | RD);
    CHECK_EQ(get_addr(pins), uint16_t(0x4000));
    CHECK_EQ(get_data(pins), uint8_t(0x42));
    CHECK(pins & MREQ);
    CHECK(pins & RD);

    // Control lines persist until explicitly released -- the core convention
    // change that makes half-T-state timing expressible.
    pins = set_addr(pins, 0x8000);
    CHECK(pins & MREQ);
    pins = release_ctrl(pins, MREQ | RD);
    CHECK(!(pins & MREQ));
    CHECK(!(pins & RD));
    CHECK_EQ(get_data(pins), uint8_t(0x42)); // data bus untouched by a ctrl release
}

TEST(register_pair_accessors_split_high_and_low_correctly) {
    Registers regs;
    regs.set_bc(0x1234);
    CHECK_EQ(regs.b, uint8_t(0x12));
    CHECK_EQ(regs.c, uint8_t(0x34));
    CHECK_EQ(regs.bc(), uint16_t(0x1234));

    regs.ix = 0xABCD;
    CHECK_EQ(regs.ixh(), uint8_t(0xAB));
    CHECK_EQ(regs.ixl(), uint8_t(0xCD));
    regs.set_ixh(0x11);
    CHECK_EQ(regs.ix, uint16_t(0x11CD));
}

RUN_TESTS()
