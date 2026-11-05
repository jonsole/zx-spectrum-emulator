// The joysticks (docs/joystick.md), read through real IN instructions: a
// Kempston on its port with A5 low, Interface II and the cursor keys on the
// keyboard rows, and what a port both the ULA and the Kempston answer gives.
//
// The expected bytes are worked out from the interfaces' documentation, not
// from the code: the Kempston's 000FUDLR with bits 7-5 zero, and for the
// keyed modes the key the issue's table names, read as the keyboard reads
// that key.

#include "spectrum.h"
#include "test_main.h"

#include <initializer_list>
#include <memory>
#include <string>
#include <vector>

using namespace zx;

namespace {

void poke(Spectrum& m, uint16_t addr, std::initializer_list<uint8_t> bytes) {
    std::vector<uint8_t> v(bytes);
    m.write_memory(addr, v.data(), v.size());
}

void run_at(Spectrum& m, uint16_t pc, int instructions) {
    Registers r = m.registers();
    r.pc = pc;
    m.set_registers(r);
    for (int i = 0; i < instructions; i++) {
        m.step_instruction();
    }
}

/// IN A,(port) with A = high first, so the port is high:port. Run at the top
/// of a fresh frame, in the border, where the floating bus reads 0xFF.
uint8_t in_port(Spectrum& m, uint8_t high, uint8_t port) {
    poke(m, 0x8000, {0x3E, high, 0xDB, port});
    run_at(m, 0x8000, 2);
    return m.registers().a;
}

/// A fresh machine with nothing plugged in anywhere.
void unplug(Spectrum& m) {
    m.joystick.mode[JOY_LEFT_PORT] = JoystickMode::None;
    m.joystick.mode[JOY_RIGHT_PORT] = JoystickMode::None;
}

/// An even port with no key held and the speaker bit clear: bits 0-4 and 5
/// and 7 high, bit 6 (EAR, no tape) low. See spectrum_tests'
/// ear_reads_the_last_outs_speaker_bit_with_no_tape.
constexpr uint8_t IDLE_ULA = 0xBF;

} // namespace

TEST(power_on_is_kempston_left_and_sinclair1_right) {
    Spectrum m;
    CHECK(m.joystick.mode[JOY_LEFT_PORT] == JoystickMode::Kempston);
    CHECK(m.joystick.mode[JOY_RIGHT_PORT] == JoystickMode::Sinclair1);
    // The board's JOY byte for the same: 0x11.
    CHECK_EQ(m.joystick.modes_byte(), uint8_t(0x11));
}

TEST(kempston_reads_000fudlr_on_any_port_with_a5_low) {
    Spectrum m;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0x00)); // centred, fire up
    m.joystick.stick[JOY_LEFT_PORT] = JOY_UP | JOY_FIRE;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0x18));
    m.joystick.stick[JOY_LEFT_PORT] = JOY_RIGHT;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0x01));
    m.joystick.stick[JOY_LEFT_PORT] = JOY_LEFT | JOY_DOWN;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0x06));
    // 0xDF has A5 low too, and the high byte is not decoded.
    CHECK_EQ(in_port(m, 0x7F, 0xDF), uint8_t(0x06));
    // 0x3F has A5 high: not the Kempston's, and odd, so nothing's -- the
    // floating bus, 0xFF in the border.
    CHECK_EQ(in_port(m, 0x00, 0x3F), uint8_t(0xFF));
}

TEST(both_ports_in_kempston_mode_are_ored) {
    Spectrum m;
    m.joystick.mode[JOY_RIGHT_PORT] = JoystickMode::Kempston;
    m.joystick.stick[JOY_LEFT_PORT] = JOY_RIGHT;
    m.joystick.stick[JOY_RIGHT_PORT] = JOY_FIRE;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0x11));
}

TEST(with_no_kempston_its_port_is_the_floating_bus) {
    Spectrum m;
    m.joystick.mode[JOY_LEFT_PORT] = JoystickMode::Cursor;
    m.joystick.stick[JOY_LEFT_PORT] = JOY_FIRE;
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0xFF));
}

TEST(a_port_both_answer_reads_the_kempston) {
    // 0x1E: A0 low for the ULA, A5 low for the Kempston. High byte 0xEF
    // selects the row holding 0 9 8 7 6.
    Spectrum m;
    unplug(m);
    m.keyboard.key_down("0"); // bit 0 of that row
    CHECK_EQ(in_port(m, 0xEF, 0x1E), uint8_t(IDLE_ULA & ~0x01));

    // With a Kempston the interface's byte is all the CPU sees -- the key's
    // low on bit 0 included, against the stick's high there.
    m.joystick.mode[JOY_LEFT_PORT] = JoystickMode::Kempston;
    m.joystick.stick[JOY_LEFT_PORT] = JOY_RIGHT;
    CHECK_EQ(in_port(m, 0xEF, 0x1E), uint8_t(0x01));
    m.joystick.stick[JOY_LEFT_PORT] = 0;
    CHECK_EQ(in_port(m, 0xEF, 0x1E), uint8_t(0x00));
    // 0xFE has A5 high: the ULA's alone, Kempston or not.
    CHECK_EQ(in_port(m, 0xEF, 0xFE), uint8_t(IDLE_ULA & ~0x01));
}

TEST(the_keyed_modes_hold_the_keys_their_tables_name) {
    // From the issue's table: right, left, down, up, fire.
    struct Mode {
        JoystickMode mode;
        const char* keys[5];
    };
    const Mode modes[] = {
        {JoystickMode::Sinclair1, {"7", "6", "8", "9", "0"}},
        {JoystickMode::Sinclair2, {"2", "1", "3", "4", "5"}},
        {JoystickMode::Cursor, {"8", "5", "6", "7", "0"}},
    };
    const uint8_t directions[5] = {JOY_RIGHT, JOY_LEFT, JOY_DOWN, JOY_UP, JOY_FIRE};
    // The two half-rows the digits are on: 1-5 and 0-6.
    const uint8_t rows[2] = {0xF7, 0xEF};
    for (const Mode& md : modes) {
        for (int port = 0; port < JOY_PORTS; port++) {
            for (int d = 0; d < 5; d++) {
                // Through pointers: two machines are a lot of stack.
                auto with_stick = std::make_unique<Spectrum>();
                unplug(*with_stick);
                with_stick->joystick.mode[port] = md.mode;
                with_stick->joystick.stick[port] = directions[d];
                auto with_key = std::make_unique<Spectrum>();
                unplug(*with_key);
                with_key->keyboard.key_down(md.keys[d]);
                for (uint8_t row : rows) {
                    const uint8_t want = in_port(*with_key, row, 0xFE);
                    CHECK_EQ(in_port(*with_stick, row, 0xFE), want);
                }
                // And it is a key: some row shows it pressed.
                CHECK((in_port(*with_stick, 0x00, 0xFE) & 0x1F) != 0x1F);
            }
        }
    }
}

TEST(joystick_keys_are_ored_with_the_keyboard) {
    Spectrum m;
    unplug(m);
    m.joystick.mode[JOY_RIGHT_PORT] = JoystickMode::Sinclair1;
    m.joystick.stick[JOY_RIGHT_PORT] = JOY_LEFT; // 6, bit 4
    m.keyboard.key_down("9");                    // bit 1
    CHECK_EQ(in_port(m, 0xEF, 0xFE), uint8_t(IDLE_ULA & ~0x12));
    // A row the stick's keys are not on is untouched.
    CHECK_EQ(in_port(m, 0xF7, 0xFE), IDLE_ULA);
}

TEST(a_port_plugged_into_nothing_does_nothing) {
    Spectrum m;
    unplug(m);
    m.joystick.stick[JOY_LEFT_PORT] = JOY_ALL;
    m.joystick.stick[JOY_RIGHT_PORT] = JOY_ALL;
    CHECK_EQ(in_port(m, 0x00, 0xFE), IDLE_ULA);
    CHECK_EQ(in_port(m, 0x00, 0x1F), uint8_t(0xFF));
}

TEST(a_reset_keeps_what_is_plugged_in_and_held) {
    Spectrum m;
    m.joystick.mode[JOY_LEFT_PORT] = JoystickMode::Cursor;
    m.joystick.mode[JOY_RIGHT_PORT] = JoystickMode::Kempston;
    m.joystick.stick[JOY_RIGHT_PORT] = JOY_UP;
    m.reset();
    CHECK(m.joystick.mode[JOY_LEFT_PORT] == JoystickMode::Cursor);
    CHECK(m.joystick.mode[JOY_RIGHT_PORT] == JoystickMode::Kempston);
    CHECK_EQ(m.joystick.stick[JOY_RIGHT_PORT], JOY_UP);
}

TEST(the_modes_byte_is_the_boards_joy_setting) {
    Joystick j;
    j.set_modes_byte(0x1C); // left 4 cursor, right 3 sinclair2
    CHECK(j.mode[JOY_LEFT_PORT] == JoystickMode::Cursor);
    CHECK(j.mode[JOY_RIGHT_PORT] == JoystickMode::Sinclair2);
    CHECK_EQ(j.modes_byte(), uint8_t(0x1C));
    // 5-7 mean none, as on the board.
    j.set_modes_byte(0x3F);
    CHECK(j.mode[JOY_LEFT_PORT] == JoystickMode::None);
    CHECK(j.mode[JOY_RIGHT_PORT] == JoystickMode::None);

    Joystick k;
    k.mode[JOY_LEFT_PORT] = JoystickMode::Sinclair2;
    k.stick[JOY_LEFT_PORT] = JOY_FIRE;
    k.stick[JOY_RIGHT_PORT] = JOY_UP | JOY_LEFT;
    Joystick back;
    back.set_packed(k.packed());
    CHECK_EQ(back.packed(), k.packed());
    CHECK_EQ(back.stick[JOY_RIGHT_PORT], uint8_t(JOY_UP | JOY_LEFT));
}

TEST(names_and_letters_parse_both_ways) {
    JoystickMode mode = JoystickMode::None;
    CHECK(Joystick::parse_mode("sinclair2", mode));
    CHECK(mode == JoystickMode::Sinclair2);
    CHECK(Joystick::parse_mode("Kempston", mode));
    CHECK(mode == JoystickMode::Kempston);
    CHECK(!Joystick::parse_mode("interface2", mode));
    CHECK_EQ(std::string(Joystick::mode_name(JoystickMode::Cursor)), std::string("cursor"));

    uint8_t stick = 0xFF;
    CHECK(Joystick::parse_directions("fu", stick));
    CHECK_EQ(stick, uint8_t(JOY_UP | JOY_FIRE));
    CHECK(Joystick::parse_directions("", stick));
    CHECK_EQ(stick, uint8_t(0));
    CHECK(!Joystick::parse_directions("UX", stick));
    CHECK_EQ(Joystick::directions_text(JOY_ALL), std::string("UDLRF"));

    int port = -1;
    CHECK(Joystick::parse_port("right", port));
    CHECK_EQ(port, JOY_RIGHT_PORT);
    CHECK(!Joystick::parse_port("2", port));
}

#if ZX_REWIND
TEST(the_joysticks_are_part_of_the_rewind_state) {
    auto m = std::make_unique<Spectrum>();
    auto before = std::make_unique<Spectrum::State>();
    m->save_state(*before);
    m->joystick.mode[JOY_LEFT_PORT] = JoystickMode::Sinclair2;
    m->joystick.stick[JOY_RIGHT_PORT] = JOY_FIRE;
    auto after = std::make_unique<Spectrum::State>();
    m->save_state(*after);
    CHECK(Spectrum::state_hash(*before) != Spectrum::state_hash(*after));
    m->restore_state(*before);
    CHECK(m->joystick.mode[JOY_LEFT_PORT] == JoystickMode::Kempston);
    CHECK_EQ(m->joystick.stick[JOY_RIGHT_PORT], uint8_t(0));
}
#endif

RUN_TESTS()
