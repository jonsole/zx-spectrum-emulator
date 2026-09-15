// The 128K: paging through port 0x7FFD, the shadow screen, the AY's ports,
// the longer frame, and the snapshot formats that carry all of it.

#include "snapshot.h"
#include "spectrum.h"
#include "test_main.h"

#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// The real 128K ROM pair is copyrighted and gitignored, so tests that need
/// it skip gracefully when it is absent rather than failing.
bool load_rom_128(Spectrum& m) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/128.rom", std::ios::binary);
    if (!f) {
        return false;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    return m.load_rom(rom.data(), rom.size()).empty();
}

/// A fake ROM pair whose two halves are told apart by their fill byte.
void load_fake_rom_128(Spectrum& m, uint8_t rom0, uint8_t rom1) {
    std::vector<uint8_t> rom(ROM_128K_SIZE, rom0);
    for (size_t i = ROM_SIZE; i < ROM_128K_SIZE; i++) {
        rom[i] = rom1;
    }
    CHECK_EQ(m.load_rom(rom.data(), rom.size()), std::string());
}

void poke(Spectrum& m, uint16_t addr, std::initializer_list<uint8_t> bytes) {
    std::vector<uint8_t> v(bytes);
    m.write_memory(addr, v.data(), v.size());
}

void run_at(Spectrum& m, uint16_t pc, int instructions) {
    Registers r = m.registers();
    r.pc = pc;
    r.sp = 0xBFF0;
    m.set_registers(r);
    for (int i = 0; i < instructions; i++) {
        m.step_instruction();
    }
}

/// OUT (C),A to `port` with `value`, through real instructions at 0x8000
/// (bank 2, which is mapped whatever the paging says).
void out_port(Spectrum& m, uint16_t port, uint8_t value) {
    poke(m, 0x8000, {0x01, uint8_t(port), uint8_t(port >> 8), // LD BC,port
                     0x3E, value,                             // LD A,value
                     0xED, 0x79});                            // OUT (C),A
    run_at(m, 0x8000, 3);
}

/// IN A,(C) from `port`, the same way.
uint8_t in_port(Spectrum& m, uint16_t port) {
    poke(m, 0x8000, {0x01, uint8_t(port), uint8_t(port >> 8), // LD BC,port
                     0xED, 0x78});                            // IN A,(C)
    run_at(m, 0x8000, 2);
    return m.registers().a;
}

struct Px {
    uint8_t r, g, b;
    bool operator==(const Px& o) const { return r == o.r && g == o.g && b == o.b; }
};

Px pixel_at(const std::vector<uint8_t>& screen, uint32_t x, uint32_t y) {
    size_t i = (size_t(y) * FULL_WIDTH + x) * 3;
    return Px{screen[i], screen[i + 1], screen[i + 2]};
}

void fill_banks(Spectrum& m) {
    for (uint8_t b = 0; b < RAM_BANKS; b++) {
        for (size_t i = 0; i < BANK_SIZE; i++) {
            m.memory.bank[b][i] = uint8_t(b * 37 + i * 3 + 1);
        }
    }
}

size_t differing_banks(const Spectrum& a, const Spectrum& b) {
    size_t n = 0;
    for (uint8_t bank = 0; bank < RAM_BANKS; bank++) {
        if (a.memory.bank[bank] != b.memory.bank[bank]) {
            n++;
        }
    }
    return n;
}

} // namespace

TEST(a_128k_runs_the_longer_frame_at_the_faster_clock) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    CHECK_EQ(m.ula.timing().tstates_per_frame(), 70908u);
    CHECK_EQ(m.ula.timing().lines_per_frame, 311u);
    CHECK_EQ(m.beeper.clock(), uint64_t(7'093'800));
    // From reset the machine is one priming half-clock into frame 0 (see
    // Spectrum::prime_cpu), so the first frame boundary lands exactly one
    // frame's worth of half-clocks from power-on.
    m.run_frame();
    CHECK_EQ(m.global_hc(), uint64_t(70908 * 2));
    CHECK_EQ(m.ula.frame_count(), uint64_t(1));
    // ...and back to a 48K, which is the default.
    m.set_model(Model::Spectrum48);
    CHECK_EQ(m.ula.timing().tstates_per_frame(), 69888u);
    CHECK_EQ(m.beeper.clock(), uint64_t(7'000'000));
}

TEST(port_7ffd_pages_a_bank_in_at_c000) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    poke(m, 0xC000, {0xAA}); // bank 0, the power-on bank
    out_port(m, 0x7FFD, 0x01);
    CHECK_EQ(int(m.memory.bank_at_c000()), 1);
    CHECK_EQ(int(m.memory.read(0xC000)), 0); // bank 1 is untouched
    poke(m, 0xC000, {0x55});
    CHECK_EQ(int(m.memory.bank[1][0]), 0x55);
    out_port(m, 0x7FFD, 0x00);
    CHECK_EQ(int(m.memory.read(0xC000)), 0xAA);
    // 0x4000 and 0x8000 never move: banks 5 and 2 whatever is written.
    poke(m, 0x4000, {0x11});
    poke(m, 0x8100, {0x22});
    out_port(m, 0x7FFD, 0x07);
    CHECK_EQ(int(m.memory.read(0x4000)), 0x11);
    CHECK_EQ(int(m.memory.read(0x8100)), 0x22);
    CHECK_EQ(int(m.memory.bank[5][0]), 0x11);
    CHECK_EQ(int(m.memory.bank[2][0x100]), 0x22);
}

TEST(paging_is_decoded_on_a15_and_a1_only) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    // Any port with A15 and A1 low reaches the latch: 0x3FFD does, 0x7FFF
    // (A1 high) does not, and neither does 0xFFFD (A15 high).
    out_port(m, 0x3FFD, 0x03);
    CHECK_EQ(int(m.memory.bank_at_c000()), 3);
    out_port(m, 0x7FFF, 0x05);
    CHECK_EQ(int(m.memory.bank_at_c000()), 3);
    out_port(m, 0xFFFD, 0x06);
    CHECK_EQ(int(m.memory.bank_at_c000()), 3);
}

TEST(rom_select_bit_swaps_the_two_roms) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    load_fake_rom_128(m, 0x11, 0x22);
    CHECK_EQ(int(m.memory.read(0x0000)), 0x11);
    CHECK_EQ(int(m.memory.read(0x3FFF)), 0x11);
    out_port(m, 0x7FFD, PAGING_ROM1);
    CHECK_EQ(int(m.memory.read(0x0000)), 0x22);
    CHECK_EQ(int(m.memory.rom_selected()), 1);
    // Still write-protected, whichever is in.
    poke(m, 0x0000, {0x99});
    CHECK_EQ(int(m.memory.read(0x0000)), 0x22);
}

TEST(paging_lock_holds_until_reset) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    out_port(m, 0x7FFD, uint8_t(PAGING_LOCK | 0x03));
    CHECK_EQ(int(m.memory.bank_at_c000()), 3);
    CHECK(m.memory.paging_locked());
    out_port(m, 0x7FFD, 0x04);
    CHECK_EQ(int(m.memory.bank_at_c000()), 3);
    out_port(m, 0x7FFD, 0x00); // not even an attempt to unlock works
    CHECK(m.memory.paging_locked());
    m.reset();
    CHECK(!m.memory.paging_locked());
    CHECK_EQ(int(m.memory.bank_at_c000()), 0);
    CHECK_EQ(int(m.memory.paging()), 0);
}

TEST(paging_port_does_nothing_on_a_48k) {
    Spectrum m;
    load_fake_rom_128(m, 0x11, 0x22);
    std::vector<uint8_t> rom48(ROM_SIZE, 0x33);
    CHECK_EQ(m.load_rom(rom48.data(), rom48.size()), std::string());
    poke(m, 0xC000, {0xAA});
    out_port(m, 0x7FFD, 0x11);
    CHECK_EQ(int(m.memory.paging()), 0);
    CHECK_EQ(int(m.memory.read(0xC000)), 0xAA);
    CHECK_EQ(int(m.memory.read(0x0000)), 0x33);
}

TEST(a_48k_with_only_the_128k_rom_pair_boots_rom_1) {
    Spectrum m;
    load_fake_rom_128(m, 0x11, 0x22);
    CHECK(m.memory.has_rom(Model::Spectrum48));
    CHECK_EQ(int(m.memory.read(0x0000)), 0x22);
}

TEST(shadow_screen_is_displayed_from_bank_7) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    const uint32_t paper_top = m.ula.timing().paper_line_begin;
    CHECK_EQ(paper_top, 63u);
    // Bank 5's screen is black on black; bank 7's first cell has white
    // paper.
    m.memory.bank[7][0x1800] = 0x38;
    m.run_frame();
    m.run_frame();
    CHECK(pixel_at(m.screen(), BORDER_LEFT_PX, paper_top) == (Px{0, 0, 0}));
    out_port(m, 0x7FFD, PAGING_SHADOW_SCREEN);
    CHECK_EQ(int(m.memory.screen_bank()), 7);
    CHECK_EQ(int(m.ula.screen_bank()), 7);
    m.run_frame();
    m.run_frame();
    CHECK(pixel_at(m.screen(), BORDER_LEFT_PX, paper_top) == (Px{0xCD, 0xCD, 0xCD}));
    // The bank is displayed whether or not it is paged in anywhere.
    CHECK_EQ(int(m.memory.bank_at_c000()), 0);
    out_port(m, 0x7FFD, 0x00);
    m.run_frame();
    m.run_frame();
    CHECK(pixel_at(m.screen(), BORDER_LEFT_PX, paper_top) == (Px{0, 0, 0}));
}

TEST(canvas_bottom_line_repeats_the_frames_last_line) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    m.ula.border = 2; // red
    m.run_frame();
    m.run_frame();
    CHECK(pixel_at(m.screen(), 10, 310) == (Px{0xCD, 0, 0}));
    CHECK(pixel_at(m.screen(), 10, 311) == (Px{0xCD, 0, 0}));
}

TEST(ay_registers_are_reached_through_ports_fffd_and_bffd) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    out_port(m, 0xFFFD, 7);
    out_port(m, 0xBFFD, 0x3E);
    CHECK_EQ(int(m.ay.reg(7)), 0x3E);
    CHECK_EQ(int(in_port(m, 0xFFFD)), 0x3E);
    out_port(m, 0xFFFD, 1);
    out_port(m, 0xBFFD, 0xFF);
    CHECK_EQ(int(in_port(m, 0xFFFD)), 0x0F);
    // Loosely decoded, like everything else: A15, A14 and A1 are all that
    // is looked at.
    out_port(m, 0xC001, 8); // A0 high does not matter... but A1 low is required
    CHECK_EQ(int(m.ay.selected()), 8);
    out_port(m, 0xFFFF, 9); // A1 high: nothing
    CHECK_EQ(int(m.ay.selected()), 8);
}

TEST(ay_ports_do_nothing_on_a_48k) {
    Spectrum m;
    out_port(m, 0xFFFD, 7);
    out_port(m, 0xBFFD, 0x3E);
    CHECK_EQ(int(m.ay.reg(7)), 0);
    CHECK_EQ(int(m.ay.selected()), 0);
    // In the border nothing drives the bus, so an odd port reads 0xFF.
    CHECK_EQ(int(in_port(m, 0xFFFD)), 0xFF);
}

TEST(sna_128k_round_trip_restores_every_bank_and_the_paging) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    fill_banks(m);
    out_port(m, 0x7FFD, uint8_t(PAGING_ROM1 | 0x03));
    Registers r = m.registers();
    r.pc = 0xC123;
    r.sp = 0xBFF0;
    r.set_hl(0x1234);
    r.im = 1;
    r.iff1 = r.iff2 = true;
    m.set_registers(r);
    m.ula.border = 6;

    std::vector<uint8_t> sna;
    CHECK_EQ(save_sna(m, sna), std::string());
    CHECK_EQ(sna.size(), SNA_128K_SIZE);

    Spectrum back; // a 48K until the snapshot says otherwise
    CHECK_EQ(load_snapshot(back, sna.data(), sna.size()), std::string());
    CHECK(back.model() == Model::Spectrum128);
    CHECK_EQ(int(back.memory.paging()), int(PAGING_ROM1 | 0x03));
    CHECK_EQ(int(back.memory.bank_at_c000()), 3);
    CHECK_EQ(int(back.memory.rom_selected()), 1);
    CHECK_EQ(differing_banks(m, back), size_t(0));
    CHECK_EQ(int(back.registers().pc), 0xC123);
    CHECK_EQ(int(back.registers().sp), 0xBFF0);
    CHECK_EQ(int(back.registers().hl()), 0x1234);
    CHECK_EQ(int(back.ula.border), 6);
}

TEST(sna_128k_saves_six_banks_when_bank_5_or_2_is_paged) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    fill_banks(m);
    out_port(m, 0x7FFD, 0x05);
    Registers r = m.registers();
    r.pc = 0x8000;
    r.sp = 0xBFF0;
    m.set_registers(r);
    std::vector<uint8_t> sna;
    CHECK_EQ(save_sna(m, sna), std::string());
    CHECK_EQ(sna.size(), SNA_128K_SIZE_6);
    Spectrum back;
    CHECK_EQ(load_sna(back, sna.data(), sna.size()), std::string());
    CHECK_EQ(differing_banks(m, back), size_t(0));
    CHECK_EQ(int(back.memory.bank_at_c000()), 5);
}

TEST(z80_round_trip_128k_keeps_banks_paging_and_the_ay) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    fill_banks(m);
    // A stretch of the sort the compressor codes: a long run, and runs of
    // the ED byte that mark its escapes.
    for (size_t i = 0x100; i < 0x400; i++) {
        m.memory.bank[4][i] = 0;
    }
    for (size_t i = 0x400; i < 0x410; i++) {
        m.memory.bank[4][i] = 0xED;
    }
    m.memory.bank[4][0x410] = 0xED;
    m.memory.bank[4][0x411] = 0x01;
    m.memory.bank[4][0x412] = 0xED;
    out_port(m, 0x7FFD, 0x16);
    out_port(m, 0xFFFD, 8);
    out_port(m, 0xBFFD, 0x0C);
    out_port(m, 0xFFFD, 0);
    out_port(m, 0xBFFD, 0x7B);
    out_port(m, 0xFFFD, 13);
    out_port(m, 0xBFFD, 0x0E);
    Registers r = m.registers();
    r.pc = 0x8765;
    r.sp = 0xBFF0;
    r.r = 0x93; // bit 7 set: stored apart from the other seven
    r.set_af(0x1234);
    r.a_ = 0x55;
    r.iff1 = true;
    r.iff2 = false;
    r.im = 2;
    m.set_registers(r);
    m.ula.border = 3;

    std::vector<uint8_t> z80;
    save_z80(m, z80);
    CHECK(z80.size() < 8 * BANK_SIZE); // the fill compresses at least a little

    SnapshotInfo info;
    CHECK_EQ(inspect_snapshot(z80.data(), z80.size(), info), std::string());
    CHECK(info.format == SnapshotFormat::Z80);
    CHECK(info.model == Model::Spectrum128);
    CHECK_EQ(info.version, 3);
    CHECK_EQ(int(info.pc), 0x8765);

    Spectrum back;
    CHECK_EQ(load_snapshot(back, z80.data(), z80.size()), std::string());
    CHECK(back.model() == Model::Spectrum128);
    CHECK_EQ(differing_banks(m, back), size_t(0));
    CHECK_EQ(int(back.memory.paging()), 0x16);
    CHECK_EQ(int(back.ay.reg(8)), 0x0C);
    CHECK_EQ(int(back.ay.reg(0)), 0x7B);
    CHECK_EQ(int(back.ay.reg(13)), 0x0E);
    CHECK_EQ(int(back.ay.selected()), 13);
    const Registers b = back.registers();
    CHECK_EQ(int(b.pc), 0x8765);
    CHECK_EQ(int(b.r), 0x93);
    CHECK_EQ(int(b.af()), 0x1234);
    CHECK_EQ(int(b.a_), 0x55);
    CHECK_EQ(b.iff1, true);
    CHECK_EQ(b.iff2, false);
    CHECK_EQ(int(b.im), 2);
    CHECK_EQ(int(back.ula.border), 3);
}

TEST(z80_round_trip_48k_makes_a_48k) {
    Spectrum m;
    for (size_t i = 0; i < RAM_SIZE; i++) {
        m.memory.ram48(i) = uint8_t(i * 7 + 3);
    }
    Registers r = m.registers();
    r.pc = 0x6000;
    r.sp = 0xFF00;
    m.set_registers(r);
    std::vector<uint8_t> z80;
    save_z80(m, z80);

    Spectrum back;
    back.set_model(Model::Spectrum128);
    CHECK_EQ(load_snapshot(back, z80.data(), z80.size()), std::string());
    CHECK(back.model() == Model::Spectrum48);
    size_t differing = 0;
    for (size_t i = 0; i < RAM_SIZE; i++) {
        if (back.memory.ram48(i) != m.memory.ram48(i)) {
            differing++;
        }
    }
    CHECK_EQ(differing, size_t(0));
    CHECK_EQ(int(back.registers().pc), 0x6000);
}

TEST(z80_version_1_compressed_image_loads) {
    // A hand-built version 1 file: PC non-zero in the header marks it, bit 5
    // of byte 12 says the 48K image is compressed, and the image is 48K of
    // 0x42 as runs of 255 plus one of 192, then the end marker.
    std::vector<uint8_t> z80(30, 0);
    z80[6] = 0x00;
    z80[7] = 0x80; // PC = 0x8000
    z80[8] = 0x00;
    z80[9] = 0xFF; // SP = 0xFF00
    z80[12] = uint8_t(0x20 | (5 << 1)); // compressed, border 5
    for (int i = 0; i < 192; i++) {
        z80.push_back(0xED); z80.push_back(0xED); z80.push_back(255); z80.push_back(0x42);
    }
    z80.push_back(0xED); z80.push_back(0xED); z80.push_back(192); z80.push_back(0x42);
    z80.push_back(0x00); z80.push_back(0xED); z80.push_back(0xED); z80.push_back(0x00);

    Spectrum m;
    CHECK_EQ(load_snapshot(m, z80.data(), z80.size()), std::string());
    CHECK(m.model() == Model::Spectrum48);
    CHECK_EQ(int(m.memory.read(0x4000)), 0x42);
    CHECK_EQ(int(m.memory.read(0xFFFF)), 0x42);
    CHECK_EQ(int(m.registers().pc), 0x8000);
    CHECK_EQ(int(m.ula.border), 5);
}

TEST(a_48k_sna_turns_a_128k_back_into_a_48k) {
    Spectrum m;
    Registers r = m.registers();
    r.sp = 0xFF00;
    r.pc = 0x5000;
    m.set_registers(r);
    std::vector<uint8_t> sna;
    CHECK_EQ(save_sna(m, sna), std::string());

    Spectrum back;
    back.set_model(Model::Spectrum128);
    CHECK_EQ(load_snapshot(back, sna.data(), sna.size()), std::string());
    CHECK(back.model() == Model::Spectrum48);
    CHECK_EQ(int(back.registers().pc), 0x5000);
}

TEST(malformed_z80_leaves_the_machine_alone) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    fill_banks(m);
    std::vector<uint8_t> junk(40, 0);
    junk[30] = 23; // version 2, but with no pages and a truncated header
    CHECK(!load_snapshot(m, junk.data(), 10).empty());
    CHECK(m.model() == Model::Spectrum128);
    CHECK_EQ(int(m.memory.bank[3][0]), int(uint8_t(3 * 37 + 1)));
}

TEST(real_128k_rom_boots_to_the_menu) {
    Spectrum m;
    m.set_model(Model::Spectrum128);
    if (!load_rom_128(m)) {
        std::printf("    (skipped: roms/128.rom not present)\n");
        return;
    }
    m.set_model(Model::Spectrum128);
    // The 128K ROM tests all of RAM before drawing its menu, which takes a
    // little longer than the 48K's boot.
    for (int i = 0; i < 200; i++) {
        m.run_frame();
    }
    // The menu is drawn on white paper with a coloured band; enough of the
    // paper area is white to tell it from a blank or black screen.
    size_t white = 0;
    const uint32_t top = m.ula.timing().paper_line_begin;
    for (uint32_t y = top; y < top + SCREEN_HEIGHT; y++) {
        for (uint32_t x = BORDER_LEFT_PX; x < BORDER_LEFT_PX + SCREEN_WIDTH; x++) {
            if (pixel_at(m.screen(), x, y) == (Px{0xCD, 0xCD, 0xCD})) {
                white++;
            }
        }
    }
    CHECK(white > 10000);
    // The menu ROM is ROM 0, and it is what is still paged in while the
    // menu is showing.
    CHECK_EQ(int(m.memory.rom_selected()), 0);
}

RUN_TESTS()
