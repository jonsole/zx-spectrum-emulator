// Machine-level tests: CPU + ULA + memory + keyboard on one bus.
//
// The headline test here boots the real 48K ROM. That is a far stronger
// end-to-end signal than any unit test: the ROM exercises the CPU, the
// interrupt, the memory map and the screen layout simultaneously, and it only
// produces the familiar copyright screen if all of them are right together.

#include "snapshot.h"
#include "spectrum.h"
#include "test_main.h"

#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// The real ROM is copyrighted and gitignored, so tests that need it skip
/// gracefully when it is absent rather than failing.
bool load_rom(Spectrum48K& m) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
    if (!f) {
        return false;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    return m.load_rom(rom.data(), rom.size()).empty();
}

/// Colour of one pixel of the full canvas (border included).
struct Px {
    uint8_t r, g, b;
    bool operator==(const Px& o) const { return r == o.r && g == o.g && b == o.b; }
};

Px pixel_at(const std::vector<uint8_t>& screen, uint32_t x, uint32_t y) {
    size_t i = (size_t(y) * FULL_WIDTH + x) * 3;
    return Px{screen[i], screen[i + 1], screen[i + 2]};
}

void poke(Spectrum48K& m, uint16_t addr, std::initializer_list<uint8_t> bytes) {
    std::vector<uint8_t> v(bytes);
    m.write_memory(addr, v.data(), v.size());
}

void run_at(Spectrum48K& m, uint16_t pc, int instructions) {
    Registers r = m.registers();
    r.pc = pc;
    m.set_registers(r);
    for (int i = 0; i < instructions; i++) {
        m.step_instruction();
    }
}

} // namespace

TEST(frame_timing_matches_the_spectrum) {
    // 312 lines x 224 T-states = 69888 T-states per frame, at 2 half-clocks
    // each. Getting this wrong would put every timing-sensitive effect out.
    CHECK_EQ(HC_PER_FRAME, 69888u * 2);
    CHECK_EQ(FULL_WIDTH, 352u);
    CHECK_EQ(FULL_HEIGHT, 312u);

    Spectrum48K m;
    uint64_t before = m.ula.frame_count();
    m.run_frame();
    CHECK_EQ(m.ula.frame_count(), before + 1);
}

TEST(interrupt_fires_once_per_frame_and_is_not_queued) {
    Spectrum48K m;
    poke(m, 0x8000, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}); // NOP sled
    Registers r;
    r.pc = 0x8000;
    r.sp = 0xFF00;
    r.iff1 = true;
    r.iff2 = true;
    r.im = 1;
    m.set_registers(r);

    // The INT window is open at the very start of a frame -- including a
    // freshly constructed machine's. Real hardware grants no grace period
    // after reset either, which is exactly why the 48K ROM's first
    // instruction is DI.
    bool reached_isr = false;
    for (int i = 0; i < 200 && !reached_isr; i++) {
        m.step_instruction();
        if (m.registers().pc == 0x0038) {
            reached_isr = true;
        }
    }
    CHECK(reached_isr);
    CHECK(!m.registers().iff1); // interrupts disabled on entry
    CHECK_EQ(m.registers().sp, uint16_t(0xFEFE)); // return address pushed
}

TEST(border_writes_show_up_in_the_rendered_border) {
    Spectrum48K m;
    // LD A,2 (red) ; OUT (0xFE),A ; then spin.
    poke(m, 0x8000, {0x3E, 0x02, 0xD3, 0xFE, 0x18, 0xFE}); // ...; JR -2
    run_at(m, 0x8000, 2);
    CHECK_EQ(m.ula.border, uint8_t(2));

    m.run_frame();
    m.run_frame(); // one full frame drawn entirely with the new border

    // Top-left corner is border by definition.
    Px p = pixel_at(m.screen(), 4, 4);
    CHECK_EQ(p.r, uint8_t(0xCD)); // red, non-bright
    CHECK_EQ(p.g, uint8_t(0x00));
    CHECK_EQ(p.b, uint8_t(0x00));
}

TEST(screen_memory_is_rendered_with_the_right_layout) {
    Spectrum48K m;
    // Fill the bitmap with all-ink and set every attribute to bright white
    // ink on black paper, then check a paper pixel really is white.
    for (uint16_t y = 0; y < 192; y++) {
        for (uint16_t x = 0; x < 256; x += 8) {
            uint8_t v = 0xFF;
            m.write_memory(pixel_addr(x, y), &v, 1);
        }
    }
    for (uint16_t y = 0; y < 192; y += 8) {
        for (uint16_t x = 0; x < 256; x += 8) {
            uint8_t attr = 0x47; // bright, white ink, black paper
            m.write_memory(attr_addr(x, y), &attr, 1);
        }
    }
    // HALT so the CPU cannot wander into screen memory while it is drawn.
    poke(m, 0x0000, {0x76});
    run_at(m, 0x0000, 1);

    m.run_frame();
    m.run_frame();

    // Middle of the paper area.
    Px p = pixel_at(m.screen(), BORDER_LEFT_PX + 128, PAPER_LINE_BEGIN + 96);
    CHECK_EQ(p.r, uint8_t(0xFF));
    CHECK_EQ(p.g, uint8_t(0xFF));
    CHECK_EQ(p.b, uint8_t(0xFF));

    // Just outside the paper rectangle must still be border (black here).
    Px border = pixel_at(m.screen(), BORDER_LEFT_PX - 4, PAPER_LINE_BEGIN + 96);
    CHECK_EQ(border.r, uint8_t(0));
    CHECK_EQ(border.g, uint8_t(0));
    CHECK_EQ(border.b, uint8_t(0));
}

TEST(keyboard_reads_combine_selected_half_rows) {
    Spectrum48K m;
    m.keyboard.key_down("Z"); // row 0 (addr bit 0), bit 1
    m.keyboard.key_down("A"); // row 1 (addr bit 1), bit 0

    // High byte 0xFC has address bits 0 and 1 both LOW -> both rows selected
    // and combined.
    uint8_t bits = m.keyboard.read_port(0xFC);
    CHECK_EQ(uint8_t(bits & 0x1F), uint8_t(0x1F & ~0x03));

    // Selecting only row 0 must not show row 1's key.
    uint8_t row0 = m.keyboard.read_port(0xFE);
    CHECK_EQ(uint8_t(row0 & 0x1F), uint8_t(0x1F & ~0x02));
}

TEST(keyboard_is_readable_through_a_real_in_instruction) {
    Spectrum48K m;
    m.keyboard.key_down("SPACE"); // row 7 (addr bit 7), bit 0
    // LD A,0x7F ; IN A,(0xFE) ; HALT  -- 0x7F selects row 7 only.
    poke(m, 0x8000, {0x3E, 0x7F, 0xDB, 0xFE, 0x76});
    run_at(m, 0x8000, 2);
    CHECK_EQ(uint8_t(m.registers().a & 0x01), uint8_t(0)); // pressed == 0
}

TEST(rom_is_write_protected_on_the_real_bus) {
    Spectrum48K m;
    std::vector<uint8_t> rom(ROM_SIZE, 0xAA);
    CHECK_EQ(m.load_rom(rom.data(), rom.size()), std::string());
    // LD A,0xFF ; LD (0x1234),A ; HALT -- a real store through the bus.
    poke(m, 0x8000, {0x3E, 0xFF, 0x32, 0x34, 0x12, 0x76});
    run_at(m, 0x8000, 2);
    CHECK_EQ(m.read_memory(0x1234, 1)[0], uint8_t(0xAA));
}

// ---- the real thing --------------------------------------------------------

TEST(real_rom_boots_to_the_copyright_screen) {
    Spectrum48K m;
    if (!load_rom(m)) {
        std::printf("    (skipped: roms/48.rom not present)\n");
        return;
    }
    Registers r;
    m.set_registers(r); // PC = 0, as on power-up

    // 100 frames, not a handful: the ROM's first act is a RAM-check that
    // walks all 48K before it ever clears the screen. At ~12 frames the
    // picture is still entirely black and this test passed for completely
    // the wrong reason -- "every paper pixel differs from white" is true of a
    // black screen too. Hence the two-sided assertion below.
    for (int i = 0; i < 100; i++) {
        m.run_frame();
    }

    const std::vector<uint8_t>& screen = m.screen();
    const Px WHITE{0xCD, 0xCD, 0xCD};

    // Border is white.
    CHECK(pixel_at(screen, 4, 4) == WHITE);

    // The booted screen is white paper with the copyright line in black near
    // the bottom. So it must be MOSTLY white...
    int white = 0;
    int ink = 0;
    for (uint32_t y = PAPER_LINE_BEGIN; y < PAPER_LINE_END; y++) {
        for (uint32_t x = PAPER_DOT_BEGIN; x < PAPER_DOT_END; x++) {
            if (pixel_at(screen, x, y) == WHITE) {
                white++;
            } else {
                ink++;
            }
        }
    }
    const int paper_pixels = int(SCREEN_WIDTH * SCREEN_HEIGHT);
    std::printf("    (%d white, %d ink of %d paper pixels)\n", white, ink, paper_pixels);

    // ...which rules out the all-black screen an unfinished boot gives...
    CHECK(white > paper_pixels * 9 / 10);
    // ...and it must contain real text, which rules out a blank screen.
    CHECK(ink > 200);
    // The copyright line sits in the bottom third; nothing should be drawn
    // in the top third at this point.
    int ink_top = 0;
    for (uint32_t y = PAPER_LINE_BEGIN; y < PAPER_LINE_BEGIN + 64; y++) {
        for (uint32_t x = PAPER_DOT_BEGIN; x < PAPER_DOT_END; x++) {
            if (!(pixel_at(screen, x, y) == WHITE)) {
                ink_top++;
            }
        }
    }
    CHECK_EQ(ink_top, 0);
}

// ---- snapshots -------------------------------------------------------------

TEST(sna_round_trip_restores_registers_ram_and_border) {
    Spectrum48K m;
    Registers r;
    r.set_af(0x1234);  r.set_bc(0x5678);  r.set_de(0x9ABC);  r.set_hl(0xDEF0);
    r.a_ = 0x11;  r.f_ = 0x22;  r.b_ = 0x33;  r.c_ = 0x44;
    r.d_ = 0x55;  r.e_ = 0x66;  r.h_ = 0x77;  r.l_ = 0x88;
    r.ix = 0xABCD;  r.iy = 0x4321;  r.sp = 0xFF00;  r.pc = 0x8123;
    r.i = 0x3F;  r.r = 0x5A;  r.iff1 = r.iff2 = true;  r.im = 2;
    m.set_registers(r);
    m.ula.border = 5;
    for (size_t i = 0; i < RAM_SIZE; i++) {
        m.memory.ram[i] = uint8_t(i * 7 + 3);
    }

    std::vector<uint8_t> sna;
    CHECK_EQ(save_sna(m, sna), std::string());
    CHECK_EQ(sna.size(), SNA_48K_SIZE);
    // The file's SP is two below the machine's, with PC pushed there.
    CHECK_EQ(int(sna[23] | (sna[24] << 8)), 0xFEFE);
    CHECK_EQ(int(sna[SNA_HEADER_SIZE + 0xFEFE - ROM_SIZE]), 0x23);
    CHECK_EQ(int(sna[SNA_HEADER_SIZE + 0xFEFF - ROM_SIZE]), 0x81);
    // ...and the machine itself was not touched by that push.
    CHECK_EQ(int(m.memory.ram[0xFEFE - ROM_SIZE]), int(((0xFEFE - ROM_SIZE) * 7 + 3) & 0xFF));
    CHECK_EQ(int(m.registers().sp), 0xFF00);

    Spectrum48K back;
    CHECK_EQ(load_sna(back, sna.data(), sna.size()), std::string());
    const Registers b = back.registers();
    CHECK_EQ(int(b.af()), 0x1234);
    CHECK_EQ(int(b.bc()), 0x5678);
    CHECK_EQ(int(b.de()), 0x9ABC);
    CHECK_EQ(int(b.hl()), 0xDEF0);
    CHECK_EQ(int(b.a_), 0x11);  CHECK_EQ(int(b.f_), 0x22);
    CHECK_EQ(int(b.b_), 0x33);  CHECK_EQ(int(b.c_), 0x44);
    CHECK_EQ(int(b.d_), 0x55);  CHECK_EQ(int(b.e_), 0x66);
    CHECK_EQ(int(b.h_), 0x77);  CHECK_EQ(int(b.l_), 0x88);
    CHECK_EQ(int(b.ix), 0xABCD);
    CHECK_EQ(int(b.iy), 0x4321);
    CHECK_EQ(int(b.sp), 0xFF00);
    CHECK_EQ(int(b.pc), 0x8123);
    CHECK_EQ(int(b.i), 0x3F);
    CHECK_EQ(int(b.r), 0x5A);
    CHECK_EQ(b.iff1, true);
    CHECK_EQ(b.iff2, true);
    CHECK_EQ(int(b.im), 2);
    CHECK_EQ(int(back.ula.border), 5);
    size_t differing = 0;
    for (size_t i = 0; i < RAM_SIZE; i++) {
        if (back.memory.ram[i] != m.memory.ram[i]) {
            differing++;
        }
    }
    // Only the two bytes PC was pushed over may differ.
    CHECK_EQ(differing, size_t(2));
}

TEST(sna_cannot_be_saved_with_sp_in_rom) {
    Spectrum48K m;
    Registers r;
    r.sp = 0x4001; // one byte of RAM below SP: not enough for PC
    m.set_registers(r);
    std::vector<uint8_t> sna;
    CHECK_EQ(save_sna(m, sna).empty(), false);
}

RUN_TESTS()
