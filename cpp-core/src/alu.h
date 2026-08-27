#pragma once
// Flag-computing ALU helpers, ported from rust-core/zx-core/src/alu.rs --
// which was itself ported directly from vendor/chips/z80.h's _z80_add_flags /
// _z80_sub_flags / _z80_cp_flags / etc, NOT re-derived from the Z80 spec.
// That lineage matters: the undocumented behavior here (e.g. CP's bit3/bit5
// coming from the OPERAND rather than the result, unlike every other function
// in this file) is deliberate, verified bit-for-bit against the reference by
// the differential tests, and must not be "tidied up" into consistency.
//
// Pure computation: nothing here touches memory, pins, or Registers.

#include <cstdint>

namespace zx::alu {

struct Alu8 {
    uint8_t value;
    uint8_t flags;
};

struct Alu16 {
    uint16_t value;
    uint8_t flags;
};

// ---- 8-bit arithmetic/logic -------------------------------------------------
Alu8 add8(uint8_t acc, uint8_t val);
Alu8 adc8(uint8_t acc, uint8_t val, uint8_t carry_in);
Alu8 sub8(uint8_t acc, uint8_t val);
Alu8 sbc8(uint8_t acc, uint8_t val, uint8_t carry_in);
Alu8 and8(uint8_t acc, uint8_t val);
Alu8 xor8(uint8_t acc, uint8_t val);
Alu8 or8(uint8_t acc, uint8_t val);
/// CP never writes back to A, so it yields flags only.
uint8_t cp8(uint8_t acc, uint8_t val);

/// `IN r,(C)` / `IN (C)`: S/Z/5/3/P from the port byte, H=0, N=0, C preserved.
uint8_t in_flags(uint8_t val, uint8_t f);

/// INC/DEC preserve carry, so the caller passes the whole current F in as
/// `carry_in` and only its C bit is kept.
Alu8 inc8(uint8_t val, uint8_t carry_in);
Alu8 dec8(uint8_t val, uint8_t carry_in);

// ---- accumulator rotates ----------------------------------------------------
// S/Z/PV preserved from the incoming F, undocumented bit5/bit3 from the
// RESULT, H/N always cleared, C is the bit rotated out. Flag-wise unrelated
// to the same-named CB-prefix group further down, despite the names.
Alu8 rlca(uint8_t a, uint8_t f);
Alu8 rrca(uint8_t a, uint8_t f);
Alu8 rla(uint8_t a, uint8_t f);
Alu8 rra(uint8_t a, uint8_t f);

Alu8 daa(uint8_t a, uint8_t f);
Alu8 cpl(uint8_t a, uint8_t f);
/// SCF/CCF leave A alone but its bit5/bit3 still feed the undocumented flags.
uint8_t scf(uint8_t a, uint8_t f);
uint8_t ccf(uint8_t a, uint8_t f);

// ---- 16-bit arithmetic ------------------------------------------------------
/// `ADD HL,ss` (and IX/IY): unlike 8-bit ADD, S/Z/PV are UNAFFECTED, and the
/// undocumented bits come from the result's HIGH byte.
Alu16 add16(uint16_t acc, uint16_t val, uint8_t f);
/// `ADC HL,ss` / `SBC HL,ss` -- ED-prefixed only, never rewired to IX/IY.
/// Unlike add16, S/Z/PV ARE affected here.
Alu16 adc16(uint16_t acc, uint16_t val, uint8_t carry_in);
Alu16 sbc16(uint16_t acc, uint16_t val, uint8_t carry_in);

/// `LD A,I` / `LD A,R`: PV comes from IFF2 -- the well-known way to probe
/// interrupt state from software.
uint8_t sziff2_flags(uint8_t val, uint8_t f, bool iff2);

// ---- block instruction flags ------------------------------------------------
/// LDI/LDD/LDIR/LDDR. The Y/X bits use a genuinely odd mapping (bit1->Y,
/// bit3->X of A+transferred) -- as-is from the reference, not a typo.
uint8_t ldi_ldd_flags(uint8_t a, uint8_t transferred, uint16_t bc_after, uint8_t f);
/// CPI/CPD. PV means "BC != 0 after decrementing", not overflow. Returns
/// flags plus the repeat decision CPIR/CPDR use.
struct CpiCpdResult {
    uint8_t flags;
    bool repeat;
};
CpiCpdResult cpi_cpd(uint8_t a, uint8_t val, uint16_t bc_after, uint8_t f);
/// INI/IND/INIR/INDR. `c_for_flags` is C+1 (INI) or C-1 (IND). `b` is B
/// AFTER its decrement.
uint8_t ini_ind_flags(uint8_t b, uint8_t val, uint8_t c_for_flags);
/// OUTI/OUTD/OTIR/OTDR. `l` is L after HL++/HL--. `b` is B after decrement.
uint8_t outi_outd_flags(uint8_t b, uint8_t val, uint8_t l);

// ---- nibble rotates ---------------------------------------------------------
/// RRD/RLD rotate a nibble between A and (HL). The memory write is the
/// caller's job -- this file never touches memory.
struct NibbleRotate {
    uint8_t new_a;
    uint8_t new_mem;
    uint8_t flags;
};
NibbleRotate rrd(uint8_t a, uint8_t mem_val, uint8_t f);
NibbleRotate rld(uint8_t a, uint8_t mem_val, uint8_t f);

// ---- CB-prefix rotate/shift group ------------------------------------------
// These recompute full S/Z/P from the result, where the accumulator forms
// above preserve S/Z/P from the incoming F.
Alu8 rlc(uint8_t val);
Alu8 rrc(uint8_t val);
Alu8 rl(uint8_t val, uint8_t carry_in);
Alu8 rr(uint8_t val, uint8_t carry_in);
Alu8 sla(uint8_t val);
Alu8 sra(uint8_t val);
/// Undocumented ("shift logical left" -- sets bit 0 rather than clearing it)
/// but real silicon behavior; ported as-is rather than omitted.
Alu8 sll(uint8_t val);
Alu8 srl(uint8_t val);

/// BIT y,r / BIT y,(HL) / BIT y,(IX+d) / BIT y,(IY+d). C preserved, H always
/// set, N always clear. The undocumented bit5/bit3 come from WZ's HIGH BYTE
/// for the indirect forms, not from the tested value -- a real quirk.
uint8_t bit(uint8_t val, uint8_t y, bool is_indirect, uint16_t wz, uint8_t carry_in);
/// RES/SET are the only CB-group ops that touch no flags at all.
uint8_t res(uint8_t val, uint8_t y);
uint8_t set(uint8_t val, uint8_t y);

} // namespace zx::alu
