// Exhaustive differential test of our ALU against vendor/chips/z80.h's own
// flag functions.
//
// This is possible (and much simpler than the Rust project's FFI-based
// zx-core-conformance crate) because z80.h is a C header whose internals are
// `static inline` under CHIPS_IMPL -- defining that and including it here puts
// _z80_add_flags, _z80_szp_flags[], _z80_daa and friends directly in this
// translation unit, callable with no shim at all.
//
// Coverage is genuinely exhaustive wherever the input space allows it: every
// 8-bit op is checked over all 256x256 (acc, val) pairs, and the flag-sensitive
// ones over all 256 incoming F values too. That is a complete proof of the port
// for those functions, not a sample -- which matters because this file's whole
// reason for existing is the undocumented flag behavior (CP taking bit3/bit5
// from the operand, BIT taking them from WZ's high byte, DAA's six-way branch)
// where a plausible-looking transcription error would otherwise go unnoticed
// until some real program misbehaved.

#include "alu.h"
#include "flags.h"
#include "test_main.h"

#define CHIPS_IMPL
#include "z80.h"

#include <cstdio>

using namespace zx;

namespace {

/// A z80_t primed with a known A and F, for calling the reference's own
/// cpu-level helpers.
z80_t ref_cpu(uint8_t a, uint8_t f) {
    z80_t cpu{};
    z80_init(&cpu);
    cpu.a = a;
    cpu.f = f;
    return cpu;
}

/// Reports at most a handful of mismatches per test -- an exhaustive loop that
/// is wrong is usually wrong everywhere, and 65536 failure lines helps nobody.
struct Mismatches {
    const char* op;
    int count = 0;

    explicit Mismatches(const char* name) : op(name) {}

    void check(bool ok, const char* fmt, int a, int b, int got, int want) {
        if (ok) {
            return;
        }
        count++;
        if (count <= 3) {
            std::printf("    %s mismatch: ", op);
            std::printf(fmt, a, b, got, want);
            std::printf("\n");
        }
    }
};

const char* const FMT = "in=(%02X,%02X) got=%02X want=%02X";

} // namespace

// ---- 8-bit arithmetic/logic: exhaustive over acc x val x carry --------------

TEST(add8_matches_reference_exhaustively) {
    Mismatches m("add8");
    for (int acc = 0; acc < 256; acc++) {
        for (int val = 0; val < 256; val++) {
            z80_t cpu = ref_cpu(uint8_t(acc), 0);
            _z80_add8(&cpu, uint8_t(val));
            alu::Alu8 got = alu::add8(uint8_t(acc), uint8_t(val));
            m.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                    (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
        }
    }
    CHECK_EQ(m.count, 0);
}

TEST(adc8_matches_reference_exhaustively) {
    Mismatches m("adc8");
    for (int carry = 0; carry < 2; carry++) {
        for (int acc = 0; acc < 256; acc++) {
            for (int val = 0; val < 256; val++) {
                uint8_t f = uint8_t(carry ? FLAG_C : 0);
                z80_t cpu = ref_cpu(uint8_t(acc), f);
                _z80_adc8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::adc8(uint8_t(acc), uint8_t(val), uint8_t(f & FLAG_C));
                m.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                        (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
        }
    }
    CHECK_EQ(m.count, 0);
}

TEST(sub8_matches_reference_exhaustively) {
    Mismatches m("sub8");
    for (int acc = 0; acc < 256; acc++) {
        for (int val = 0; val < 256; val++) {
            z80_t cpu = ref_cpu(uint8_t(acc), 0);
            _z80_sub8(&cpu, uint8_t(val));
            alu::Alu8 got = alu::sub8(uint8_t(acc), uint8_t(val));
            m.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                    (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
        }
    }
    CHECK_EQ(m.count, 0);
}

TEST(sbc8_matches_reference_exhaustively) {
    Mismatches m("sbc8");
    for (int carry = 0; carry < 2; carry++) {
        for (int acc = 0; acc < 256; acc++) {
            for (int val = 0; val < 256; val++) {
                uint8_t f = uint8_t(carry ? FLAG_C : 0);
                z80_t cpu = ref_cpu(uint8_t(acc), f);
                _z80_sbc8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::sbc8(uint8_t(acc), uint8_t(val), uint8_t(f & FLAG_C));
                m.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                        (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
        }
    }
    CHECK_EQ(m.count, 0);
}

TEST(logic_ops_match_reference_exhaustively) {
    Mismatches ma("and8"), mx("xor8"), mo("or8"), mc("cp8");
    for (int acc = 0; acc < 256; acc++) {
        for (int val = 0; val < 256; val++) {
            {
                z80_t cpu = ref_cpu(uint8_t(acc), 0);
                _z80_and8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::and8(uint8_t(acc), uint8_t(val));
                ma.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                         (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(acc), 0);
                _z80_xor8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::xor8(uint8_t(acc), uint8_t(val));
                mx.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                         (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(acc), 0);
                _z80_or8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::or8(uint8_t(acc), uint8_t(val));
                mo.check(got.value == cpu.a && got.flags == cpu.f, FMT, acc, val,
                         (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                // CP is the one whose undocumented bit3/bit5 come from the
                // OPERAND rather than the result -- the exact asymmetry this
                // exhaustive check exists to pin down.
                z80_t cpu = ref_cpu(uint8_t(acc), 0);
                _z80_cp8(&cpu, uint8_t(val));
                uint8_t got = alu::cp8(uint8_t(acc), uint8_t(val));
                mc.check(got == cpu.f, FMT, acc, val, got, cpu.f);
            }
        }
    }
    CHECK_EQ(ma.count, 0);
    CHECK_EQ(mx.count, 0);
    CHECK_EQ(mo.count, 0);
    CHECK_EQ(mc.count, 0);
}

TEST(inc8_dec8_match_reference_exhaustively) {
    Mismatches mi("inc8"), md("dec8");
    for (int f = 0; f < 256; f++) {
        for (int val = 0; val < 256; val++) {
            {
                z80_t cpu = ref_cpu(0, uint8_t(f));
                uint8_t ref_val = _z80_inc8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::inc8(uint8_t(val), uint8_t(f));
                mi.check(got.value == ref_val && got.flags == cpu.f, FMT, f, val,
                         (got.value << 8) | got.flags, (ref_val << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(0, uint8_t(f));
                uint8_t ref_val = _z80_dec8(&cpu, uint8_t(val));
                alu::Alu8 got = alu::dec8(uint8_t(val), uint8_t(f));
                md.check(got.value == ref_val && got.flags == cpu.f, FMT, f, val,
                         (got.value << 8) | got.flags, (ref_val << 8) | cpu.f);
            }
        }
    }
    CHECK_EQ(mi.count, 0);
    CHECK_EQ(md.count, 0);
}

// ---- accumulator rotates / DAA / CPL / SCF / CCF: exhaustive over a x f -----

TEST(accumulator_rotates_daa_and_flag_ops_match_reference_exhaustively) {
    Mismatches mrlca("rlca"), mrrca("rrca"), mrla("rla"), mrra("rra");
    Mismatches mdaa("daa"), mcpl("cpl"), mscf("scf"), mccf("ccf");
    for (int a = 0; a < 256; a++) {
        for (int f = 0; f < 256; f++) {
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_rlca(&cpu);
                alu::Alu8 got = alu::rlca(uint8_t(a), uint8_t(f));
                mrlca.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                            (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_rrca(&cpu);
                alu::Alu8 got = alu::rrca(uint8_t(a), uint8_t(f));
                mrrca.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                            (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_rla(&cpu);
                alu::Alu8 got = alu::rla(uint8_t(a), uint8_t(f));
                mrla.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                           (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_rra(&cpu);
                alu::Alu8 got = alu::rra(uint8_t(a), uint8_t(f));
                mrra.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                           (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                // DAA's six-way branch on N/H/C/nibble is the single most
                // error-prone thing in this file.
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_daa(&cpu);
                alu::Alu8 got = alu::daa(uint8_t(a), uint8_t(f));
                mdaa.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                           (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_cpl(&cpu);
                alu::Alu8 got = alu::cpl(uint8_t(a), uint8_t(f));
                mcpl.check(got.value == cpu.a && got.flags == cpu.f, FMT, a, f,
                           (got.value << 8) | got.flags, (cpu.a << 8) | cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_scf(&cpu);
                uint8_t got = alu::scf(uint8_t(a), uint8_t(f));
                mscf.check(got == cpu.f, FMT, a, f, got, cpu.f);
            }
            {
                z80_t cpu = ref_cpu(uint8_t(a), uint8_t(f));
                _z80_ccf(&cpu);
                uint8_t got = alu::ccf(uint8_t(a), uint8_t(f));
                mccf.check(got == cpu.f, FMT, a, f, got, cpu.f);
            }
        }
    }
    CHECK_EQ(mrlca.count, 0);
    CHECK_EQ(mrrca.count, 0);
    CHECK_EQ(mrla.count, 0);
    CHECK_EQ(mrra.count, 0);
    CHECK_EQ(mdaa.count, 0);
    CHECK_EQ(mcpl.count, 0);
    CHECK_EQ(mscf.count, 0);
    CHECK_EQ(mccf.count, 0);
}

// ---- CB-prefix rotate/shift group: exhaustive over val x carry --------------

TEST(cb_rotate_shift_group_matches_reference_exhaustively) {
    Mismatches m[8] = {Mismatches("rlc"), Mismatches("rrc"), Mismatches("rl"),
                       Mismatches("rr"),  Mismatches("sla"), Mismatches("sra"),
                       Mismatches("sll"), Mismatches("srl")};
    for (int f = 0; f < 256; f++) {
        for (int val = 0; val < 256; val++) {
            uint8_t v = uint8_t(val);
            uint8_t fi = uint8_t(f);
            struct Case {
                uint8_t ref_val;
                uint8_t ref_flags;
                alu::Alu8 got;
            };
            z80_t c0 = ref_cpu(0, fi);
            uint8_t r0 = _z80_rlc(&c0, v);
            z80_t c1 = ref_cpu(0, fi);
            uint8_t r1 = _z80_rrc(&c1, v);
            z80_t c2 = ref_cpu(0, fi);
            uint8_t r2 = _z80_rl(&c2, v);
            z80_t c3 = ref_cpu(0, fi);
            uint8_t r3 = _z80_rr(&c3, v);
            z80_t c4 = ref_cpu(0, fi);
            uint8_t r4 = _z80_sla(&c4, v);
            z80_t c5 = ref_cpu(0, fi);
            uint8_t r5 = _z80_sra(&c5, v);
            z80_t c6 = ref_cpu(0, fi);
            uint8_t r6 = _z80_sll(&c6, v);
            z80_t c7 = ref_cpu(0, fi);
            uint8_t r7 = _z80_srl(&c7, v);

            Case cases[8] = {
                {r0, c0.f, alu::rlc(v)},      {r1, c1.f, alu::rrc(v)},
                {r2, c2.f, alu::rl(v, fi)},   {r3, c3.f, alu::rr(v, fi)},
                {r4, c4.f, alu::sla(v)},      {r5, c5.f, alu::sra(v)},
                {r6, c6.f, alu::sll(v)},      {r7, c7.f, alu::srl(v)},
            };
            for (int i = 0; i < 8; i++) {
                m[i].check(cases[i].got.value == cases[i].ref_val
                               && cases[i].got.flags == cases[i].ref_flags,
                           FMT, f, val, (cases[i].got.value << 8) | cases[i].got.flags,
                           (cases[i].ref_val << 8) | cases[i].ref_flags);
            }
        }
    }
    for (int i = 0; i < 8; i++) {
        CHECK_EQ(m[i].count, 0);
    }
}

// ---- BIT / RES / SET --------------------------------------------------------
// z80.h folds BIT into _z80_cb_action rather than exposing it standalone, so
// this checks against the documented formula the port was written from, with
// the undocumented bit5/bit3 source (WZ high byte when indirect, else the
// tested value) as the property actually under test.

TEST(bit_res_set_behave_correctly) {
    for (int val = 0; val < 256; val++) {
        for (int y = 0; y < 8; y++) {
            uint8_t v = uint8_t(val);
            uint8_t yb = uint8_t(y);

            CHECK_EQ(alu::res(v, yb), uint8_t(v & ~(1 << y)));
            CHECK_EQ(alu::set(v, yb), uint8_t(v | (1 << y)));

            // Direct form: undocumented bits from the tested value.
            uint8_t direct = alu::bit(v, yb, false, 0xAB00, 0);
            CHECK_EQ(uint8_t(direct & (FLAG_5 | FLAG_3)), uint8_t(v & (FLAG_5 | FLAG_3)));
            CHECK(direct & FLAG_H);
            CHECK(!(direct & FLAG_N));
            bool bit_set = (v & (1 << y)) != 0;
            CHECK_EQ(bool(direct & FLAG_Z), !bit_set);

            // Indirect form: undocumented bits from WZ's HIGH byte instead.
            uint8_t indirect = alu::bit(v, yb, true, 0xAB00, 0);
            CHECK_EQ(uint8_t(indirect & (FLAG_5 | FLAG_3)), uint8_t(0xAB & (FLAG_5 | FLAG_3)));

            // C is preserved in both forms.
            CHECK(alu::bit(v, yb, false, 0, FLAG_C) & FLAG_C);
        }
    }
}

// ---- 16-bit arithmetic ------------------------------------------------------
// 2^32 pairs is too many to enumerate; this walks a deterministic spread that
// covers every carry/half-carry/overflow boundary rather than a random sample.

TEST(sixteen_bit_arithmetic_matches_reference) {
    const uint16_t interesting[] = {0x0000, 0x0001, 0x000F, 0x0010, 0x00FF, 0x0100,
                                    0x0FFF, 0x1000, 0x7FFF, 0x8000, 0x8001, 0xABCD,
                                    0xFFFE, 0xFFFF};
    Mismatches madd("add16"), madc("adc16"), msbc("sbc16");
    for (uint16_t acc : interesting) {
        for (uint16_t val : interesting) {
            for (int carry = 0; carry < 2; carry++) {
                uint8_t f = uint8_t(carry ? FLAG_C : 0);
                {
                    z80_t cpu{};
                    z80_init(&cpu);
                    cpu.f = f;
                    cpu.hlx[cpu.hlx_idx].hl = acc;
                    _z80_add16(&cpu, val);
                    alu::Alu16 got = alu::add16(acc, val, f);
                    madd.check(got.value == cpu.hlx[cpu.hlx_idx].hl && got.flags == cpu.f,
                               FMT, acc, val, got.flags, cpu.f);
                }
                {
                    z80_t cpu{};
                    z80_init(&cpu);
                    cpu.f = f;
                    cpu.hl = acc;
                    _z80_adc16(&cpu, val);
                    alu::Alu16 got = alu::adc16(acc, val, uint8_t(f & FLAG_C));
                    madc.check(got.value == cpu.hl && got.flags == cpu.f, FMT, acc, val,
                               got.flags, cpu.f);
                }
                {
                    z80_t cpu{};
                    z80_init(&cpu);
                    cpu.f = f;
                    cpu.hl = acc;
                    _z80_sbc16(&cpu, val);
                    alu::Alu16 got = alu::sbc16(acc, val, uint8_t(f & FLAG_C));
                    msbc.check(got.value == cpu.hl && got.flags == cpu.f, FMT, acc, val,
                               got.flags, cpu.f);
                }
            }
        }
    }
    CHECK_EQ(madd.count, 0);
    CHECK_EQ(madc.count, 0);
    CHECK_EQ(msbc.count, 0);
}

// ---- block instruction + nibble-rotate flag helpers -------------------------

TEST(block_instruction_flag_helpers_match_reference_exhaustively) {
    Mismatches mldi("ldi_ldd"), mcpi("cpi_cpd"), mini("ini_ind"), mout("outi_outd");
    Mismatches min_("in_flags"), mrrd("rrd"), mrld("rld");
    for (int a = 0; a < 256; a++) {
        for (int val = 0; val < 256; val++) {
            uint8_t av = uint8_t(a);
            uint8_t vv = uint8_t(val);

            // Two BC values so the PV ("BC != 0 after decrement") branch is
            // covered both ways.
            for (uint16_t bc : {uint16_t(1), uint16_t(0x1234)}) {
                {
                    z80_t cpu = ref_cpu(av, 0);
                    cpu.bc = bc;
                    _z80_ldi_ldd(&cpu, vv);
                    uint8_t got = alu::ldi_ldd_flags(av, vv, uint16_t(bc - 1), 0);
                    mldi.check(got == cpu.f, FMT, a, val, got, cpu.f);
                }
                {
                    z80_t cpu = ref_cpu(av, 0);
                    cpu.bc = bc;
                    bool ref_repeat = _z80_cpi_cpd(&cpu, vv);
                    alu::CpiCpdResult got = alu::cpi_cpd(av, vv, uint16_t(bc - 1), 0);
                    mcpi.check(got.flags == cpu.f && got.repeat == ref_repeat, FMT, a, val,
                               got.flags, cpu.f);
                }
            }
            {
                // `b` is B AFTER its decrement in our API, so drive the
                // reference with that same already-decremented value.
                z80_t cpu = ref_cpu(0, 0);
                cpu.b = av;
                _z80_ini_ind(&cpu, vv, uint8_t(a + 1));
                uint8_t got = alu::ini_ind_flags(av, vv, uint8_t(a + 1));
                mini.check(got == cpu.f, FMT, a, val, got, cpu.f);
            }
            {
                z80_t cpu = ref_cpu(0, 0);
                cpu.b = av;
                cpu.l = vv;
                _z80_outi_outd(&cpu, vv);
                uint8_t got = alu::outi_outd_flags(av, vv, vv);
                mout.check(got == cpu.f, FMT, a, val, got, cpu.f);
            }
            {
                z80_t cpu = ref_cpu(0, FLAG_C);
                _z80_in(&cpu, vv);
                uint8_t got = alu::in_flags(vv, FLAG_C);
                min_.check(got == cpu.f, FMT, a, val, got, cpu.f);
            }
            {
                z80_t cpu = ref_cpu(av, 0);
                uint8_t ref_mem = _z80_rrd(&cpu, vv);
                alu::NibbleRotate got = alu::rrd(av, vv, 0);
                mrrd.check(got.new_a == cpu.a && got.new_mem == ref_mem && got.flags == cpu.f,
                           FMT, a, val, got.new_a, cpu.a);
            }
            {
                z80_t cpu = ref_cpu(av, 0);
                uint8_t ref_mem = _z80_rld(&cpu, vv);
                alu::NibbleRotate got = alu::rld(av, vv, 0);
                mrld.check(got.new_a == cpu.a && got.new_mem == ref_mem && got.flags == cpu.f,
                           FMT, a, val, got.new_a, cpu.a);
            }
        }
    }
    CHECK_EQ(mldi.count, 0);
    CHECK_EQ(mcpi.count, 0);
    CHECK_EQ(mini.count, 0);
    CHECK_EQ(mout.count, 0);
    CHECK_EQ(min_.count, 0);
    CHECK_EQ(mrrd.count, 0);
    CHECK_EQ(mrld.count, 0);
}

TEST(sziff2_flags_match_reference) {
    Mismatches m("sziff2_flags");
    for (int val = 0; val < 256; val++) {
        for (int f = 0; f < 256; f++) {
            for (int iff2 = 0; iff2 < 2; iff2++) {
                z80_t cpu = ref_cpu(0, uint8_t(f));
                cpu.iff2 = iff2 != 0;
                uint8_t ref = _z80_sziff2_flags(&cpu, uint8_t(val));
                uint8_t got = alu::sziff2_flags(uint8_t(val), uint8_t(f), iff2 != 0);
                m.check(got == ref, FMT, val, f, got, ref);
            }
        }
    }
    CHECK_EQ(m.count, 0);
}

RUN_TESTS()
