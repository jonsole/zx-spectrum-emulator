#include "alu.h"

#include "flags.h"

namespace zx::alu {
namespace {

/// Truncating cast, spelled out once so the intent is obvious at every call
/// site. Rust's u8 arithmetic wraps natively; C++ promotes to int first, so
/// every expression that should stay 8-bit needs this on the way out.
constexpr uint8_t u8(int v) { return static_cast<uint8_t>(v); }
constexpr uint8_t u8(uint32_t v) { return static_cast<uint8_t>(v); }

constexpr uint8_t sz_flags(uint8_t val) {
    return val != 0 ? u8(val & FLAG_S) : FLAG_Z;
}

/// Sign+zero+bit5+bit3+carry+halfcarry, shared by ADD/ADC/SUB/SBC. `res`
/// carries a possible bit-8 carry/borrow, hence uint16_t.
constexpr uint8_t szyxch_flags(uint8_t acc, uint8_t val, uint16_t res) {
    uint8_t res8 = u8(res);
    return u8(sz_flags(res8) | (res8 & (FLAG_5 | FLAG_3)) | (u8(res >> 8) & FLAG_C)
              | ((acc ^ val ^ res8) & FLAG_H));
}

constexpr uint8_t add_overflow(uint8_t acc, uint8_t val, uint8_t res8) {
    return u8((((val ^ acc ^ 0x80) & (val ^ res8)) >> 5) & FLAG_PV);
}

constexpr uint8_t sub_overflow(uint8_t acc, uint8_t val, uint8_t res8) {
    return u8((((val ^ acc) & (res8 ^ acc)) >> 5) & FLAG_PV);
}

constexpr uint8_t add_flags(uint8_t acc, uint8_t val, uint16_t res) {
    return u8(szyxch_flags(acc, val, res) | add_overflow(acc, val, u8(res)));
}

constexpr uint8_t sub_flags(uint8_t acc, uint8_t val, uint16_t res) {
    return u8(FLAG_N | szyxch_flags(acc, val, res) | sub_overflow(acc, val, u8(res)));
}

/// CP's bit3/bit5 come from `val` (the operand), not the result -- a real,
/// well-known undocumented-flags quirk, not a typo.
constexpr uint8_t cp_flags(uint8_t acc, uint8_t val, uint16_t res) {
    uint8_t res8 = u8(res);
    return u8(FLAG_N | sz_flags(res8) | (val & (FLAG_5 | FLAG_3)) | (u8(res >> 8) & FLAG_C)
              | ((acc ^ val ^ res8) & FLAG_H) | sub_overflow(acc, val, res8));
}

/// Even parity -> PV set. (std::popcount is C++20; this project is C++17.)
constexpr bool even_parity(uint8_t val) {
    uint8_t v = val;
    v ^= u8(v >> 4);
    v ^= u8(v >> 2);
    v ^= u8(v >> 1);
    return (v & 1) == 0;
}

constexpr uint8_t szp_flags(uint8_t val) {
    return u8(sz_flags(val) | (val & (FLAG_5 | FLAG_3)) | (even_parity(val) ? FLAG_PV : 0));
}

/// Shared formula for INI/IND/OUTI/OUTD -- _z80_ini_ind and _z80_outi_outd
/// are identical but for which value feeds `t`. `b` is B after its decrement.
constexpr uint8_t block_io_flags(uint8_t b, uint8_t val, uint8_t t_operand) {
    uint8_t f = u8(sz_flags(b) | (b & (FLAG_5 | FLAG_3)));
    if (val & FLAG_S) {
        f |= FLAG_N;
    }
    uint32_t t = static_cast<uint32_t>(t_operand) + val;
    if (t & 0x100) {
        f |= FLAG_H | FLAG_C;
    }
    f |= szp_flags(u8((u8(t) & 7) ^ b)) & FLAG_PV;
    return f;
}

} // namespace

// ---- 8-bit arithmetic/logic -------------------------------------------------

Alu8 add8(uint8_t acc, uint8_t val) {
    uint16_t res = static_cast<uint16_t>(acc + val);
    return {u8(res), add_flags(acc, val, res)};
}

Alu8 adc8(uint8_t acc, uint8_t val, uint8_t carry_in) {
    uint16_t res = static_cast<uint16_t>(acc + val + carry_in);
    return {u8(res), add_flags(acc, val, res)};
}

Alu8 sub8(uint8_t acc, uint8_t val) {
    uint16_t res = static_cast<uint16_t>(acc - val);
    return {u8(res), sub_flags(acc, val, res)};
}

Alu8 sbc8(uint8_t acc, uint8_t val, uint8_t carry_in) {
    uint16_t res = static_cast<uint16_t>(acc - val - carry_in);
    return {u8(res), sub_flags(acc, val, res)};
}

Alu8 and8(uint8_t acc, uint8_t val) {
    uint8_t value = u8(acc & val);
    return {value, u8(szp_flags(value) | FLAG_H)};
}

Alu8 xor8(uint8_t acc, uint8_t val) {
    uint8_t value = u8(acc ^ val);
    return {value, szp_flags(value)};
}

Alu8 or8(uint8_t acc, uint8_t val) {
    uint8_t value = u8(acc | val);
    return {value, szp_flags(value)};
}

uint8_t cp8(uint8_t acc, uint8_t val) {
    uint16_t res = static_cast<uint16_t>(acc - val);
    return cp_flags(acc, val, res);
}

uint8_t in_flags(uint8_t val, uint8_t f) {
    return u8(szp_flags(val) | (f & FLAG_C));
}

Alu8 inc8(uint8_t val, uint8_t carry_in) {
    uint8_t res = u8(val + 1);
    uint8_t f = u8(sz_flags(res) | (res & (FLAG_5 | FLAG_3)) | ((res ^ val) & FLAG_H));
    if (res == 0x80) {
        f |= FLAG_PV;
    }
    return {res, u8(f | (carry_in & FLAG_C))};
}

Alu8 dec8(uint8_t val, uint8_t carry_in) {
    uint8_t res = u8(val - 1);
    uint8_t f = u8(FLAG_N | sz_flags(res) | (res & (FLAG_5 | FLAG_3)) | ((res ^ val) & FLAG_H));
    if (res == 0x7F) {
        f |= FLAG_PV;
    }
    return {res, u8(f | (carry_in & FLAG_C))};
}

// ---- accumulator rotates ----------------------------------------------------

Alu8 rlca(uint8_t a, uint8_t f) {
    uint8_t res = u8((a << 1) | (a >> 7));
    uint8_t flags = u8(((a >> 7) & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV))
                       | (res & (FLAG_5 | FLAG_3)));
    return {res, flags};
}

Alu8 rrca(uint8_t a, uint8_t f) {
    uint8_t res = u8((a >> 1) | (a << 7));
    uint8_t flags = u8((a & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV))
                       | (res & (FLAG_5 | FLAG_3)));
    return {res, flags};
}

Alu8 rla(uint8_t a, uint8_t f) {
    uint8_t res = u8((a << 1) | (f & FLAG_C));
    uint8_t flags = u8(((a >> 7) & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV))
                       | (res & (FLAG_5 | FLAG_3)));
    return {res, flags};
}

Alu8 rra(uint8_t a, uint8_t f) {
    uint8_t res = u8((a >> 1) | ((f & FLAG_C) << 7));
    uint8_t flags = u8((a & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV))
                       | (res & (FLAG_5 | FLAG_3)));
    return {res, flags};
}

Alu8 daa(uint8_t a, uint8_t f) {
    uint8_t res = a;
    if (f & FLAG_N) {
        if ((a & 0xF) > 0x9 || (f & FLAG_H)) {
            res = u8(res - 0x06);
        }
        if (a > 0x99 || (f & FLAG_C)) {
            res = u8(res - 0x60);
        }
    } else {
        if ((a & 0xF) > 0x9 || (f & FLAG_H)) {
            res = u8(res + 0x06);
        }
        if (a > 0x99 || (f & FLAG_C)) {
            res = u8(res + 0x60);
        }
    }
    uint8_t flags = u8(f & (FLAG_C | FLAG_N));
    if (a > 0x99) {
        flags |= FLAG_C;
    }
    flags |= (a ^ res) & FLAG_H;
    flags |= szp_flags(res);
    return {res, flags};
}

Alu8 cpl(uint8_t a, uint8_t f) {
    uint8_t value = u8(a ^ 0xFF);
    uint8_t flags = u8((f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | FLAG_H | FLAG_N
                       | (value & (FLAG_5 | FLAG_3)));
    return {value, flags};
}

uint8_t scf(uint8_t a, uint8_t f) {
    return u8((f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | FLAG_C | (a & (FLAG_5 | FLAG_3)));
}

uint8_t ccf(uint8_t a, uint8_t f) {
    return u8(((f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | ((f & FLAG_C) << 4)
               | (a & (FLAG_5 | FLAG_3)))
              ^ FLAG_C);
}

// ---- 16-bit arithmetic ------------------------------------------------------

Alu16 add16(uint16_t acc, uint16_t val, uint8_t f) {
    uint32_t acc32 = acc;
    uint32_t val32 = val;
    uint32_t res32 = acc32 + val32;
    uint8_t flags = u8((f & (FLAG_S | FLAG_Z | FLAG_PV))
                       | (u8((acc32 ^ res32 ^ val32) >> 8) & FLAG_H)
                       | (u8(res32 >> 16) & FLAG_C)
                       | (u8(res32 >> 8) & (FLAG_5 | FLAG_3)));
    return {static_cast<uint16_t>(res32), flags};
}

Alu16 adc16(uint16_t acc, uint16_t val, uint8_t carry_in) {
    uint32_t acc32 = acc;
    uint32_t val32 = val;
    uint32_t res32 = acc32 + val32 + carry_in;
    uint8_t flags = u8((u8(((val32 ^ acc32 ^ 0x8000) & (val32 ^ res32) & 0x8000) >> 13))
                       | (u8((acc32 ^ res32 ^ val32) >> 8) & FLAG_H)
                       | (u8(res32 >> 16) & FLAG_C)
                       | (u8(res32 >> 8) & (FLAG_S | FLAG_5 | FLAG_3))
                       | ((res32 & 0xFFFF) == 0 ? FLAG_Z : 0));
    return {static_cast<uint16_t>(res32), flags};
}

Alu16 sbc16(uint16_t acc, uint16_t val, uint8_t carry_in) {
    uint32_t acc32 = acc;
    uint32_t val32 = val;
    uint32_t res32 = acc32 - val32 - carry_in;
    uint8_t flags = u8(FLAG_N
                       | (u8(((val32 ^ acc32) & (acc32 ^ res32) & 0x8000) >> 13))
                       | (u8((acc32 ^ res32 ^ val32) >> 8) & FLAG_H)
                       | (u8(res32 >> 16) & FLAG_C)
                       | (u8(res32 >> 8) & (FLAG_S | FLAG_5 | FLAG_3))
                       | ((res32 & 0xFFFF) == 0 ? FLAG_Z : 0));
    return {static_cast<uint16_t>(res32), flags};
}

uint8_t sziff2_flags(uint8_t val, uint8_t f, bool iff2) {
    return u8((f & FLAG_C) | sz_flags(val) | (val & (FLAG_5 | FLAG_3)) | (iff2 ? FLAG_PV : 0));
}

// ---- block instruction flags ------------------------------------------------

uint8_t ldi_ldd_flags(uint8_t a, uint8_t transferred, uint16_t bc_after, uint8_t f) {
    uint8_t res = u8(a + transferred);
    return u8((f & (FLAG_S | FLAG_Z | FLAG_C))
              | ((res & 2) ? FLAG_5 : 0)
              | ((res & 8) ? FLAG_3 : 0)
              | (bc_after != 0 ? FLAG_PV : 0));
}

CpiCpdResult cpi_cpd(uint8_t a, uint8_t val, uint16_t bc_after, uint8_t f) {
    uint8_t res = u8(a - val);
    uint8_t flags = u8((f & FLAG_C) | FLAG_N | sz_flags(res));
    if ((res & 0xF) > (a & 0xF)) {
        flags |= FLAG_H;
        res = u8(res - 1);
    }
    if (res & 2) {
        flags |= FLAG_5;
    }
    if (res & 8) {
        flags |= FLAG_3;
    }
    if (bc_after != 0) {
        flags |= FLAG_PV;
    }
    bool repeat = bc_after != 0 && (flags & FLAG_Z) == 0;
    return {flags, repeat};
}

uint8_t ini_ind_flags(uint8_t b, uint8_t val, uint8_t c_for_flags) {
    return block_io_flags(b, val, c_for_flags);
}

uint8_t outi_outd_flags(uint8_t b, uint8_t val, uint8_t l) {
    return block_io_flags(b, val, l);
}

// ---- nibble rotates ---------------------------------------------------------

NibbleRotate rrd(uint8_t a, uint8_t mem_val, uint8_t f) {
    uint8_t low_a = u8(a & 0x0F);
    uint8_t new_a = u8((a & 0xF0) | (mem_val & 0x0F));
    uint8_t new_mem = u8((mem_val >> 4) | (low_a << 4));
    return {new_a, new_mem, u8((f & FLAG_C) | szp_flags(new_a))};
}

NibbleRotate rld(uint8_t a, uint8_t mem_val, uint8_t f) {
    uint8_t low_a = u8(a & 0x0F);
    uint8_t new_a = u8((a & 0xF0) | (mem_val >> 4));
    uint8_t new_mem = u8((mem_val << 4) | low_a);
    return {new_a, new_mem, u8((f & FLAG_C) | szp_flags(new_a))};
}

// ---- CB-prefix rotate/shift group ------------------------------------------

Alu8 rlc(uint8_t val) {
    uint8_t res = u8((val << 1) | (val >> 7));
    return {res, u8(szp_flags(res) | ((val >> 7) & FLAG_C))};
}

Alu8 rrc(uint8_t val) {
    uint8_t res = u8((val >> 1) | (val << 7));
    return {res, u8(szp_flags(res) | (val & FLAG_C))};
}

Alu8 rl(uint8_t val, uint8_t carry_in) {
    uint8_t res = u8((val << 1) | (carry_in & FLAG_C));
    return {res, u8(szp_flags(res) | ((val >> 7) & FLAG_C))};
}

Alu8 rr(uint8_t val, uint8_t carry_in) {
    uint8_t res = u8((val >> 1) | ((carry_in & FLAG_C) << 7));
    return {res, u8(szp_flags(res) | (val & FLAG_C))};
}

Alu8 sla(uint8_t val) {
    uint8_t res = u8(val << 1);
    return {res, u8(szp_flags(res) | ((val >> 7) & FLAG_C))};
}

Alu8 sra(uint8_t val) {
    uint8_t res = u8((val >> 1) | (val & 0x80));
    return {res, u8(szp_flags(res) | (val & FLAG_C))};
}

Alu8 sll(uint8_t val) {
    uint8_t res = u8((val << 1) | 1);
    return {res, u8(szp_flags(res) | ((val >> 7) & FLAG_C))};
}

Alu8 srl(uint8_t val) {
    uint8_t res = u8(val >> 1);
    return {res, u8(szp_flags(res) | (val & FLAG_C))};
}

uint8_t bit(uint8_t val, uint8_t y, bool is_indirect, uint16_t wz, uint8_t carry_in) {
    uint8_t res = u8(val & (1 << y));
    uint8_t flags = u8((carry_in & FLAG_C) | FLAG_H
                       | (res != 0 ? (res & FLAG_S) : (FLAG_Z | FLAG_PV)));
    uint8_t undoc_source = is_indirect ? u8(wz >> 8) : val;
    flags |= undoc_source & (FLAG_5 | FLAG_3);
    return flags;
}

uint8_t res(uint8_t val, uint8_t y) {
    return u8(val & ~(1 << y));
}

uint8_t set(uint8_t val, uint8_t y) {
    return u8(val | (1 << y));
}

} // namespace zx::alu
