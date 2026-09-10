// The name -> register table shared by the DAP Variables pane and the MCP
// set_registers tool.

#include "register_names.h"
#include "test_main.h"

#include <string>

using namespace zx;

TEST(pairs_halves_and_shadows_are_all_addressable) {
    Registers r;
    std::string error;
    CHECK_EQ(set_register(r, "HL", 0x1234, error), true);
    CHECK_EQ(int(r.h), 0x12);
    CHECK_EQ(int(r.l), 0x34);
    CHECK_EQ(set_register(r, "l", 0x56, error), true);
    CHECK_EQ(int(r.hl()), 0x1256);
    CHECK_EQ(set_register(r, "AF'", 0xABCD, error), true);
    CHECK_EQ(int(r.a_), 0xAB);
    CHECK_EQ(int(r.f_), 0xCD);
    CHECK_EQ(set_register(r, "bc_", 0x9876, error), true); // underscore spelling
    CHECK_EQ(int(r.b_), 0x98);
    CHECK_EQ(int(r.c_), 0x76);
    CHECK_EQ(set_register(r, "IX", 0x1122, error), true);
    CHECK_EQ(set_register(r, "IXL", 0x33, error), true);
    CHECK_EQ(int(r.ix), 0x1133);
    CHECK_EQ(set_register(r, "iyh", 0x44, error), true);
    CHECK_EQ(int(r.iy), 0x4400);
    CHECK_EQ(set_register(r, "PC", 0x0038, error), true);
    CHECK_EQ(int(r.pc), 0x38);
    CHECK_EQ(set_register(r, "I", 0x3F, error), true);
    CHECK_EQ(int(r.i), 0x3F);
    CHECK_EQ(set_register(r, "IM", 2, error), true);
    CHECK_EQ(int(r.im), 2);
    CHECK_EQ(set_register(r, "IFF1", 1, error), true);
    CHECK_EQ(r.iff1, true);
    CHECK_EQ(r.iff2, false);
}

TEST(widths_are_enforced) {
    Registers r;
    std::string error;
    CHECK_EQ(set_register(r, "A", 0x100, error), false);
    CHECK_EQ(set_register(r, "HL", 0x10000, error), false);
    CHECK_EQ(set_register(r, "IM", 3, error), false);
    CHECK_EQ(set_register(r, "IFF2", 2, error), false);
    CHECK_EQ(set_register(r, "XYZ", 0, error), false);
    CHECK_EQ(error.empty(), false);
    CHECK_EQ(register_width("hl"), 16);
    CHECK_EQ(register_width("a'"), 8);
    CHECK_EQ(register_width("iff1"), 1);
    CHECK_EQ(register_width("im"), 2);
    CHECK_EQ(register_width("nope"), 0);
}

TEST(flags_set_one_bit_of_f) {
    Registers r;
    std::string error;
    r.f = 0x00;
    CHECK_EQ(set_flag(r, "Z", true, error), true);
    CHECK_EQ(int(r.f), 0x40);
    CHECK_EQ(set_flag(r, "C", true, error), true);
    CHECK_EQ(int(r.f), 0x41);
    CHECK_EQ(set_flag(r, "P/V", true, error), true);
    CHECK_EQ(int(r.f), 0x45);
    CHECK_EQ(set_flag(r, "Z", false, error), true);
    CHECK_EQ(int(r.f), 0x05);
    CHECK_EQ(set_flag(r, "Q", true, error), false);
}

RUN_TESTS()
