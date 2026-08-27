//! Flag-computing ALU helpers, ported directly from `vendor/chips/z80.h`'s
//! `_z80_add_flags`/`_z80_sub_flags`/`_z80_cp_flags`/etc (not re-derived
//! from the Z80 spec independently) so undocumented behavior -- e.g. that
//! `CP`'s undocumented bit3/bit5 flags come from the OPERAND, not the
//! subtraction result, unlike every other flag in this file -- matches the
//! proven reference exactly. Verified bit-for-bit against that same
//! reference by `zx-core-conformance`'s differential tests.

use crate::flags::*;

fn sz_flags(val: u8) -> u8 {
    if val != 0 {
        val & FLAG_S
    } else {
        FLAG_Z
    }
}

/// Sign+zero+bit5+bit3+carry+halfcarry, shared by ADD/ADC/SUB/SBC. `res`
/// must carry a possible bit-8 carry/borrow (hence `u16`, not `u8`).
fn szyxch_flags(acc: u8, val: u8, res: u16) -> u8 {
    let res8 = res as u8;
    sz_flags(res8) | (res8 & (FLAG_5 | FLAG_3)) | (((res >> 8) as u8) & FLAG_C) | ((acc ^ val ^ res8) & FLAG_H)
}

fn add_overflow(acc: u8, val: u8, res8: u8) -> u8 {
    (((val ^ acc ^ 0x80) & (val ^ res8)) >> 5) & FLAG_PV
}

fn sub_overflow(acc: u8, val: u8, res8: u8) -> u8 {
    (((val ^ acc) & (res8 ^ acc)) >> 5) & FLAG_PV
}

fn add_flags(acc: u8, val: u8, res: u16) -> u8 {
    szyxch_flags(acc, val, res) | add_overflow(acc, val, res as u8)
}

fn sub_flags(acc: u8, val: u8, res: u16) -> u8 {
    FLAG_N | szyxch_flags(acc, val, res) | sub_overflow(acc, val, res as u8)
}

/// CP's bit3/bit5 come from `val` (the operand), not the result -- a real,
/// well-known Z80 undocumented-flags quirk, not a typo.
fn cp_flags(acc: u8, val: u8, res: u16) -> u8 {
    let res8 = res as u8;
    FLAG_N
        | sz_flags(res8)
        | (val & (FLAG_5 | FLAG_3))
        | (((res >> 8) as u8) & FLAG_C)
        | ((acc ^ val ^ res8) & FLAG_H)
        | sub_overflow(acc, val, res8)
}

fn szp_flags(val: u8) -> u8 {
    sz_flags(val) | (val & (FLAG_5 | FLAG_3)) | if val.count_ones() % 2 == 0 { FLAG_PV } else { 0 }
}

pub struct Alu8 {
    pub value: u8,
    pub flags: u8,
}

pub fn add8(acc: u8, val: u8) -> Alu8 {
    let res = acc as u16 + val as u16;
    Alu8 { value: res as u8, flags: add_flags(acc, val, res) }
}

pub fn adc8(acc: u8, val: u8, carry_in: u8) -> Alu8 {
    let res = acc as u16 + val as u16 + carry_in as u16;
    Alu8 { value: res as u8, flags: add_flags(acc, val, res) }
}

pub fn sub8(acc: u8, val: u8) -> Alu8 {
    let res = (acc as u16).wrapping_sub(val as u16);
    Alu8 { value: res as u8, flags: sub_flags(acc, val, res) }
}

pub fn sbc8(acc: u8, val: u8, carry_in: u8) -> Alu8 {
    let res = (acc as u16).wrapping_sub(val as u16).wrapping_sub(carry_in as u16);
    Alu8 { value: res as u8, flags: sub_flags(acc, val, res) }
}

pub fn and8(acc: u8, val: u8) -> Alu8 {
    let value = acc & val;
    Alu8 { value, flags: szp_flags(value) | FLAG_H }
}

pub fn xor8(acc: u8, val: u8) -> Alu8 {
    let value = acc ^ val;
    Alu8 { value, flags: szp_flags(value) }
}

pub fn or8(acc: u8, val: u8) -> Alu8 {
    let value = acc | val;
    Alu8 { value, flags: szp_flags(value) }
}

/// CP only sets flags -- it never writes back to A, so there's no `value`.
pub fn cp8(acc: u8, val: u8) -> u8 {
    let res = (acc as u16).wrapping_sub(val as u16);
    cp_flags(acc, val, res)
}

/// `IN r,(C)`/`IN (C)`: S/Z/5/3/P from the byte read off the port, H=0,
/// N=0, C preserved (mirrors `_z80_in()` in `z80.h`).
pub fn in_flags(val: u8, f: u8) -> u8 {
    szp_flags(val) | (f & FLAG_C)
}

/// INC/DEC preserve the carry flag (it's not one of the flags they touch),
/// so the caller passes the current `F` register in as `carry_in` and only
/// its C bit is kept.
pub fn inc8(val: u8, carry_in: u8) -> Alu8 {
    let res = val.wrapping_add(1);
    let mut f = sz_flags(res) | (res & (FLAG_5 | FLAG_3)) | ((res ^ val) & FLAG_H);
    if res == 0x80 {
        f |= FLAG_PV;
    }
    Alu8 { value: res, flags: f | (carry_in & FLAG_C) }
}

pub fn dec8(val: u8, carry_in: u8) -> Alu8 {
    let res = val.wrapping_sub(1);
    let mut f = FLAG_N | sz_flags(res) | (res & (FLAG_5 | FLAG_3)) | ((res ^ val) & FLAG_H);
    if res == 0x7F {
        f |= FLAG_PV;
    }
    Alu8 { value: res, flags: f | (carry_in & FLAG_C) }
}

// The accumulator-rotate group (RLCA/RRCA/RLA/RRA) all share the same
// flag shape: S/Z/PV preserved from the incoming F (untouched by these),
// undocumented bit5/bit3 taken from the RESULT, H/N always cleared
// (simply absent from every OR term below), C is the bit that rotated out.
pub fn rlca(a: u8, f: u8) -> Alu8 {
    let res = (a << 1) | (a >> 7);
    let flags = ((a >> 7) & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV)) | (res & (FLAG_5 | FLAG_3));
    Alu8 { value: res, flags }
}

pub fn rrca(a: u8, f: u8) -> Alu8 {
    let res = (a >> 1) | (a << 7);
    let flags = (a & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV)) | (res & (FLAG_5 | FLAG_3));
    Alu8 { value: res, flags }
}

pub fn rla(a: u8, f: u8) -> Alu8 {
    let res = (a << 1) | (f & FLAG_C);
    let flags = ((a >> 7) & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV)) | (res & (FLAG_5 | FLAG_3));
    Alu8 { value: res, flags }
}

pub fn rra(a: u8, f: u8) -> Alu8 {
    let res = (a >> 1) | ((f & FLAG_C) << 7);
    let flags = (a & FLAG_C) | (f & (FLAG_S | FLAG_Z | FLAG_PV)) | (res & (FLAG_5 | FLAG_3));
    Alu8 { value: res, flags }
}

/// BCD-adjusts A after an 8-bit add/subtract, ported verbatim from
/// z80.h's `_z80_daa` (not re-derived -- DAA's six-way branch on
/// N/H/C/nibble is exactly the kind of thing worth getting from the
/// proven reference rather than reconstructing from the informal "add 6
/// if..." rule of thumb).
pub fn daa(a: u8, f: u8) -> Alu8 {
    let mut res = a;
    if f & FLAG_N != 0 {
        if (a & 0xF) > 0x9 || f & FLAG_H != 0 {
            res = res.wrapping_sub(0x06);
        }
        if a > 0x99 || f & FLAG_C != 0 {
            res = res.wrapping_sub(0x60);
        }
    } else {
        if (a & 0xF) > 0x9 || f & FLAG_H != 0 {
            res = res.wrapping_add(0x06);
        }
        if a > 0x99 || f & FLAG_C != 0 {
            res = res.wrapping_add(0x60);
        }
    }
    let mut flags = f & (FLAG_C | FLAG_N);
    flags |= if a > 0x99 { FLAG_C } else { 0 };
    flags |= (a ^ res) & FLAG_H;
    flags |= szp_flags(res);
    Alu8 { value: res, flags }
}

pub fn cpl(a: u8, f: u8) -> Alu8 {
    let value = a ^ 0xFF;
    let flags =
        (f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | FLAG_H | FLAG_N | (value & (FLAG_5 | FLAG_3));
    Alu8 { value, flags }
}

/// SCF/CCF only set flags -- A is untouched, but its bit5/bit3 still feed
/// the undocumented flag bits (from A itself here, unlike everything else
/// in this file which takes them from a result byte).
pub fn scf(a: u8, f: u8) -> u8 {
    (f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | FLAG_C | (a & (FLAG_5 | FLAG_3))
}

pub fn ccf(a: u8, f: u8) -> u8 {
    ((f & (FLAG_S | FLAG_Z | FLAG_PV | FLAG_C)) | ((f & FLAG_C) << 4) | (a & (FLAG_5 | FLAG_3))) ^ FLAG_C
}

pub struct Alu16 {
    pub value: u16,
    pub flags: u8,
}

/// `ADD HL,ss` (also IX/IY once those exist): unlike 8-bit ADD, S/Z/PV are
/// UNAFFECTED (preserved from the incoming F); undocumented bit5/bit3 come
/// from the high byte of the 16-bit result, not the low byte. `u32` is used
/// (matching z80.h's own `uint32_t res`) purely to give the bit-16 carry
/// somewhere to live -- this one wasn't re-proven to fit in `u16` the way
/// the 8-bit ALU ops were, so it keeps the reference's own width.
pub fn add16(acc: u16, val: u16, f: u8) -> Alu16 {
    let acc32 = acc as u32;
    let val32 = val as u32;
    let res32 = acc32 + val32;
    let flags = (f & (FLAG_S | FLAG_Z | FLAG_PV))
        | (((acc32 ^ res32 ^ val32) >> 8) as u8 & FLAG_H)
        | ((res32 >> 16) as u8 & FLAG_C)
        | ((res32 >> 8) as u8 & (FLAG_5 | FLAG_3));
    Alu16 { value: res32 as u16, flags }
}

/// `ADC HL,ss`/`SBC HL,ss` (ED-prefixed only -- never rewired to IX/IY,
/// per z80.h's own comment on `_z80_adc16`). Unlike `ADD HL,ss`, S/Z/PV
/// ARE affected here (computed from the full result), matching z80.h's
/// `_z80_adc16`/`_z80_sbc16` exactly.
pub fn adc16(acc: u16, val: u16, carry_in: u8) -> Alu16 {
    let acc32 = acc as u32;
    let val32 = val as u32;
    let res32 = acc32 + val32 + carry_in as u32;
    let flags = (((val32 ^ acc32 ^ 0x8000) & (val32 ^ res32) & 0x8000) >> 13) as u8
        | (((acc32 ^ res32 ^ val32) >> 8) as u8 & FLAG_H)
        | ((res32 >> 16) as u8 & FLAG_C)
        | ((res32 >> 8) as u8 & (FLAG_S | FLAG_5 | FLAG_3))
        | if res32 & 0xFFFF == 0 { FLAG_Z } else { 0 };
    Alu16 { value: res32 as u16, flags }
}

pub fn sbc16(acc: u16, val: u16, carry_in: u8) -> Alu16 {
    let acc32 = acc as u32;
    let val32 = val as u32;
    let res32 = acc32.wrapping_sub(val32).wrapping_sub(carry_in as u32);
    let flags = FLAG_N
        | (((val32 ^ acc32) & (acc32 ^ res32) & 0x8000) >> 13) as u8
        | (((acc32 ^ res32 ^ val32) >> 8) as u8 & FLAG_H)
        | ((res32 >> 16) as u8 & FLAG_C)
        | ((res32 >> 8) as u8 & (FLAG_S | FLAG_5 | FLAG_3))
        | if res32 & 0xFFFF == 0 { FLAG_Z } else { 0 };
    Alu16 { value: res32 as u16, flags }
}

/// `LD A,I` / `LD A,R`: S/Z/bit5/bit3 from the value, C preserved, PV set
/// from IFF2 (a real, well-known way to probe interrupt state from
/// software, not a bug) -- ported from z80.h's `_z80_sziff2_flags`.
pub fn sziff2_flags(val: u8, f: u8, iff2: bool) -> u8 {
    (f & FLAG_C) | sz_flags(val) | (val & (FLAG_5 | FLAG_3)) | if iff2 { FLAG_PV } else { 0 }
}

/// Shared flag logic for LDI/LDD (the transfer direction/HL,DE step is a
/// cpu.rs concern; this only computes flags from the already-updated BC
/// and the transferred byte). The Y/X bits come from `A + transferred`
/// but via a genuinely odd bit mapping (bit1->Y, bit3->X, not the usual
/// "copy bits 5/3 of some byte") -- ported as-is from `_z80_ldi_ldd`
/// rather than "corrected" to look like every other flag function here.
pub fn ldi_ldd_flags(a: u8, transferred: u8, bc_after: u16, f: u8) -> u8 {
    let res = a.wrapping_add(transferred);
    (f & (FLAG_S | FLAG_Z | FLAG_C))
        | if res & 2 != 0 { FLAG_5 } else { 0 }
        | if res & 8 != 0 { FLAG_3 } else { 0 }
        | if bc_after != 0 { FLAG_PV } else { 0 }
}

/// CPI/CPD: like `cp8`, but PV means "BC != 0 after decrementing" (not
/// overflow) and H can further adjust the byte used for the Y/X bits.
/// Returns `(flags, should_repeat)` -- `should_repeat` is what CPIR/CPDR
/// use to decide whether to loop. Ported from `_z80_cpi_cpd`.
pub fn cpi_cpd(a: u8, val: u8, bc_after: u16, f: u8) -> (u8, bool) {
    let mut res = a.wrapping_sub(val);
    let mut flags = (f & FLAG_C) | FLAG_N | sz_flags(res);
    if (res & 0xF) > (a & 0xF) {
        flags |= FLAG_H;
        res = res.wrapping_sub(1);
    }
    if res & 2 != 0 {
        flags |= FLAG_5;
    }
    if res & 8 != 0 {
        flags |= FLAG_3;
    }
    if bc_after != 0 {
        flags |= FLAG_PV;
    }
    let repeat = bc_after != 0 && flags & FLAG_Z == 0;
    (flags, repeat)
}

/// Shared flag formula for INI/IND/OUTI/OUTD (and their repeating forms)
/// -- ported from `_z80_ini_ind`/`_z80_outi_outd`, which are identical
/// but for which value feeds `t`. `b` is B AFTER the port-read/write
/// step's own decrement has already applied (not before); `val` is the
/// byte just transferred; `t_operand` is C+1/C-1 for INI/IND or the
/// (already-adjusted) L register for OUTI/OUTD -- not a real register
/// change, just an input this undocumented-flag formula happens to use.
fn block_io_flags(b: u8, val: u8, t_operand: u8) -> u8 {
    let mut f = sz_flags(b) | (b & (FLAG_5 | FLAG_3));
    if val & FLAG_S != 0 {
        f |= FLAG_N;
    }
    let t = t_operand as u32 + val as u32;
    if t & 0x100 != 0 {
        f |= FLAG_H | FLAG_C;
    }
    f |= szp_flags((t as u8 & 7) ^ b) & FLAG_PV;
    f
}

/// INI/IND: `c_for_flags` is C+1 (INI) or C-1 (IND). Ported from
/// `_z80_ini_ind`; `b != 0` (computed by the caller, which already has
/// the post-decrement B) is INIR/INDR's own repeat condition.
pub fn ini_ind_flags(b: u8, val: u8, c_for_flags: u8) -> u8 {
    block_io_flags(b, val, c_for_flags)
}

/// OUTI/OUTD: `l` is the L register after HL++/HL-- has already applied.
/// Ported from `_z80_outi_outd`; `b != 0` (computed by the caller, which
/// already has the post-decrement B) is OTIR/OTDR's own repeat condition.
pub fn outi_outd_flags(b: u8, val: u8, l: u8) -> u8 {
    block_io_flags(b, val, l)
}

/// RRD/RLD rotate a nibble between A and `(HL)`. Returns
/// `(new_a, new_mem_value, flags)` -- the memory write itself is a
/// cpu.rs concern (it needs the `Memory` trait, which this file doesn't
/// touch, matching alu.rs's role as pure flag/value computation only).
pub fn rrd(a: u8, mem_val: u8, f: u8) -> (u8, u8, u8) {
    let low_a = a & 0x0F;
    let new_a = (a & 0xF0) | (mem_val & 0x0F);
    let new_mem = (mem_val >> 4) | (low_a << 4);
    (new_a, new_mem, (f & FLAG_C) | szp_flags(new_a))
}

pub fn rld(a: u8, mem_val: u8, f: u8) -> (u8, u8, u8) {
    let low_a = a & 0x0F;
    let new_a = (a & 0xF0) | (mem_val >> 4);
    let new_mem = (mem_val << 4) | low_a;
    (new_a, new_mem, (f & FLAG_C) | szp_flags(new_a))
}

// The CB-prefix rotate/shift group (RLC/RRC/RL/RR/SLA/SRA/SLL/SRL on any
// register or (HL)/(IX+d)/(IY+d)) is flag-wise UNRELATED to the
// accumulator-only RLCA/RLA/etc above, despite the similar names: these
// recompute full S/Z/P from the result (via `szp_flags`), where the
// accumulator forms preserve S/Z/P from the incoming F and only touch C
// plus the undocumented bits. Ported from z80.h's `_z80_rlc`/etc.
pub fn rlc(val: u8) -> Alu8 {
    let res = (val << 1) | (val >> 7);
    Alu8 { value: res, flags: szp_flags(res) | ((val >> 7) & FLAG_C) }
}

pub fn rrc(val: u8) -> Alu8 {
    let res = (val >> 1) | (val << 7);
    Alu8 { value: res, flags: szp_flags(res) | (val & FLAG_C) }
}

pub fn rl(val: u8, carry_in: u8) -> Alu8 {
    let res = (val << 1) | (carry_in & FLAG_C);
    Alu8 { value: res, flags: szp_flags(res) | ((val >> 7) & FLAG_C) }
}

pub fn rr(val: u8, carry_in: u8) -> Alu8 {
    let res = (val >> 1) | ((carry_in & FLAG_C) << 7);
    Alu8 { value: res, flags: szp_flags(res) | (val & FLAG_C) }
}

pub fn sla(val: u8) -> Alu8 {
    let res = val << 1;
    Alu8 { value: res, flags: szp_flags(res) | ((val >> 7) & FLAG_C) }
}

pub fn sra(val: u8) -> Alu8 {
    let res = (val >> 1) | (val & 0x80);
    Alu8 { value: res, flags: szp_flags(res) | (val & FLAG_C) }
}

/// Undocumented ("shift logical left", sets bit 0 rather than clearing
/// it) but real, tested silicon behavior -- ported as-is, not omitted.
pub fn sll(val: u8) -> Alu8 {
    let res = (val << 1) | 1;
    Alu8 { value: res, flags: szp_flags(res) | ((val >> 7) & FLAG_C) }
}

pub fn srl(val: u8) -> Alu8 {
    let res = val >> 1;
    Alu8 { value: res, flags: szp_flags(res) | (val & FLAG_C) }
}

/// `BIT y,r` / `BIT y,(HL)` / `BIT y,(IX+d)` / `BIT y,(IY+d)`. C is
/// preserved, H is always set, N always clear (simply absent from the OR
/// terms). The undocumented bit5/bit3 flags are a real, well-known
/// quirk: for the `(HL)`/`(IX+d)`/`(IY+d)` forms they come from the HIGH
/// BYTE OF WZ/MEMPTR (`is_indirect`), not from the tested value itself
/// (which every OTHER form uses) -- ported from z80.h's `_z80_cb_action`
/// exactly, not simplified to "always from val" as might seem natural.
pub fn bit(val: u8, y: u8, is_indirect: bool, wz: u16, carry_in: u8) -> u8 {
    let res = val & (1 << y);
    let mut flags = (carry_in & FLAG_C) | FLAG_H | if res != 0 { res & FLAG_S } else { FLAG_Z | FLAG_PV };
    let undoc_source = if is_indirect { (wz >> 8) as u8 } else { val };
    flags |= undoc_source & (FLAG_5 | FLAG_3);
    flags
}

/// `RES`/`SET` never touch any flag -- these two are the only CB-group
/// operations with no `cpu->f = ...` at all in the reference.
pub fn res(val: u8, y: u8) -> u8 {
    val & !(1 << y)
}

pub fn set(val: u8, y: u8) -> u8 {
    val | (1 << y)
}
