"""Generates rust-core/zx-core/src/generated/dispatch.rs from
vendor/chips/z80_desc.yml, porting codegen/z80_gen.py's own algorithm
(the script that generates the real z80.h from that same YAML -- fetched
for reference to .chips-codegen-src/z80_gen.py, not vendored/committed)
to target Rust instead of C.

Scope: unprefixed (0x00-0xFF) and ED-prefixed opcodes only. CB/DD/FD
prefixes, interrupt acknowledge sequences, and I/O (any mcycle of type
ioread/iowrite) are all deliberately skipped -- see the rust-core plan
(project memory) for the reasoning.

Mechanical parts (opcode enumeration via the YAML's `cond` bitfield
expressions, T-state/step bookkeeping per mcycle type) are fully
data-driven, porting z80_gen.py's own algorithm directly. The free-form
`action`/`post_action` C snippets are NOT auto-transpiled -- they're
translated via a hand-verified per-instruction-name lookup below (built by
reading every entry in z80_desc.yml directly), since the set of distinct
patterns is small and enumerable, and hand-translating with a human
understanding of Z80 semantics is far more reliable than a fragile general
C-expression parser would be for this one-time job.

Usage:
    python scripts/generate_z80_dispatch.py
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DESC_PATH = PROJECT_ROOT / "vendor" / "chips" / "z80_desc.yml"
OUT_PATH = PROJECT_ROOT / "rust-core" / "zx-core" / "src" / "generated" / "dispatch.rs"

ED_STEP_BASE = 256
EXTRA_STEP_BASE = 512

MEM_TCYCLES = 3

# Names of YAML entries this generator does not attempt: HALT is
# hand-written in cpu.rs (its PC-rewind trick doesn't fit the generic
# pattern), everything else here uses ioread/iowrite (deferred -- no I/O
# device model yet) or is a `special` payload (CB/DD/FD/interrupt
# handling, out of scope for this pass).
SKIP_NAMES = {
    "HALT",
    "OUT (n),A", "IN A,(n)", "IN $RY,(C)", "IN (C)", "OUT (C),$RY", "OUT (C),0",
    "INI", "IND", "INIR", "INDR", "OUTI", "OUTD", "OTIR", "OTDR",
    "ddfdcb", "int_im0", "int_im1", "int_im2", "nmi",
    # The BYTE-DISPATCH entries for the CB/DD/FD prefixes themselves (not
    # to be confused with the lowercase 'cb'/'ddfdcb' *payload* entries
    # above, which are separately marked `special` and already excluded
    # that way). These MUST be skipped explicitly: `emit_overlapped()`
    # only special-cases `prefix: ed`, so leaving these in silently
    # treated 0xCB/0xDD/0xFD as a bare no-op-then-refetch instead of
    # properly failing -- found via a real, nasty bug this caused (see
    # rust-core plan): ZEXALL's own shared per-iteration test harness does
    # `POP IY; POP IX` on every single iteration of every single test
    # group, so `POP IX` (0xDD 0xE1) silently became "NOP; POP HL",
    # corrupting HL every iteration without ever panicking -- no crash to
    # notice, just wrong results forever. Skipping these here instead
    # makes hitting 0xCB/0xDD/0xFD panic loudly (the stated design
    # principle for anything genuinely unimplemented), which is what
    # should have happened from the start.
    "CB prefix", "DD prefix", "FD prefix",
}

# ---- register field tables, indexed by the y/z/p 3-bit (or 2-bit) field ----
# B C D E H L (HL) A -- index 6 ((HL)) is never used by any op this
# generator handles (those go through $DLATCH/$ADDR instead), so it's
# left as None and will loudly KeyError/TypeError if something tries.
R = ["self.regs.b", "self.regs.c", "self.regs.d", "self.regs.e",
     "self.regs.h", "self.regs.l", None, "self.regs.a"]

# 16-bit pair reads. dd-style (index 3 = SP) and qq/rp2-style (index 3 = AF)
# differ only at index 3.
RP_DD_READ = ["self.regs.bc()", "self.regs.de()", "self.regs.hl()", "self.regs.sp"]
RP_QQ_READ = ["self.regs.bc()", "self.regs.de()", "self.regs.hl()", "self.regs.af()"]
RP_DD_SET = ["set_bc", "set_de", "set_hl", None]  # SP has no setter, direct field
RP_QQ_SET = ["set_bc", "set_de", "set_hl", "set_af"]

# High/low BYTE of a pair -- for BC/DE/HL these are just the existing
# individual register fields (same insight z80_gen.py's own rpl_map/rph_map
# tables encode); only SP/AF need something else, and AF's halves are just
# A and F, also plain fields.
RP_LOW = ["self.regs.c", "self.regs.e", "self.regs.l", "self.regs.spl()"]
RP_HIGH = ["self.regs.b", "self.regs.d", "self.regs.h", "self.regs.sph()"]
RP2_LOW = ["self.regs.c", "self.regs.e", "self.regs.l", "self.regs.f"]
RP2_HIGH = ["self.regs.b", "self.regs.d", "self.regs.h", "self.regs.a"]
RP_LOW_SET = ["self.regs.c", "self.regs.e", "self.regs.l", None]  # SP low set via set_spl()
RP_HIGH_SET = ["self.regs.b", "self.regs.d", "self.regs.h", None]

CC_EXPR = [
    "self.regs.f & FLAG_Z == 0", "self.regs.f & FLAG_Z != 0",
    "self.regs.f & FLAG_C == 0", "self.regs.f & FLAG_C != 0",
    "self.regs.f & FLAG_PV == 0", "self.regs.f & FLAG_PV != 0",
    "self.regs.f & FLAG_S == 0", "self.regs.f & FLAG_S != 0",
]
CC_NAME = ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"]

IM_TABLE = [0, 0, 1, 2, 0, 0, 1, 2]


def r_read(idx: int) -> str:
    return R[idx]


def r_read_expr(idx: int) -> str:
    """$RY/$RZ-style SUBSTITUTABLE 8-bit register read: index 4/5 (H/L)
    route through hlx_h()/hlx_l() (become IXH/IXL/IYH/IYL under a DD/FD
    prefix); everything else is a plain field, unaffected by any prefix."""
    if idx == 4:
        return "self.hlx_h()"
    if idx == 5:
        return "self.hlx_l()"
    return R[idx]


def r_write_stmt(idx: int, value_expr: str) -> str:
    """Same substitution as `r_read_expr`, but as a full assignment
    statement (H/L need a setter *call*, not an lvalue, since hlx routing
    is a runtime choice of field)."""
    if idx == 4:
        return f"self.set_hlx_h({value_expr});"
    if idx == 5:
        return f"self.set_hlx_l({value_expr});"
    return f"{R[idx]} = {value_expr};"


def rp_read(p: int, dd: bool) -> str:
    return (RP_DD_READ if dd else RP_QQ_READ)[p]


def rp_read_expr(p: int, dd: bool) -> str:
    """$RP/$RP2-style SUBSTITUTABLE 16-bit pair read: p==2 (HL slot) routes
    through hlx() (becomes IX/IY under a DD/FD prefix); BC/DE/SP/AF are
    never shadowed, so they stay literal."""
    if p == 2:
        return "self.hlx()"
    return (RP_DD_READ if dd else RP_QQ_READ)[p]


def rp_set_stmt_hlx(p: int, dd: bool, value_expr: str) -> str:
    if p == 2:
        return f"self.set_hlx({value_expr});"
    return rp_set_stmt(p, dd, value_expr)


def rp_set_stmt(p: int, dd: bool, value_expr: str) -> str:
    setter = (RP_DD_SET if dd else RP_QQ_SET)[p]
    if setter is None:
        return f"self.regs.sp = {value_expr};"
    return f"self.regs.{setter}({value_expr});"


class Op:
    def __init__(self, name: str, cond: str, prefix: str, flags: dict, mcycles: list):
        self.name = name
        self.cond = cond
        self.cond_compiled = compile(cond, "<string>", "eval")
        self.prefix = prefix
        self.flags = flags
        self.mcycles = mcycles


# These two ARE handled this pass, despite being `flags: {special: true}`
# in the YAML (meaning "not enumerated via cond/x/y/z/p/q the normal
# way") -- they're the CB-prefix payload steps (register-direct and
# "(HL)" forms), generated at fixed extra-step numbers below and
# dispatched into by the hand-written CB fetch machine cycle in cpu.rs.
# `ddfdcb` (the DD+CB/FD+CB double-prefix payload) stays skipped -- it
# needs IX/IY substitution machinery that doesn't exist yet.
SPECIAL_BUT_HANDLED = {"cb", "cbhl"}


def parse_opdescs() -> list[Op]:
    with open(DESC_PATH, "r") as fp:
        desc = yaml.safe_load(fp)
    ops = []
    for name, d in desc.items():
        if name in SKIP_NAMES:
            continue
        if d.get("flags", {}).get("special") and name not in SPECIAL_BUT_HANDLED:
            continue
        mcycles = d.get("mcycles")
        if mcycles is None:
            raise ValueError(f"op '{name}' has no mcycles")
        if any(mc["type"] in ("ioread", "iowrite") for mc in mcycles):
            continue  # deferred, see SKIP_NAMES doc comment
        ops.append(Op(name, d.get("cond", "True"), d.get("prefix", ""), d.get("flags", {}), mcycles))
    return ops


def find_op(ops: list[Op], name: str) -> Op:
    for op in ops:
        if op.name == name:
            return op
    raise ValueError(f"op '{name}' not found (check SPECIAL_BUT_HANDLED/SKIP_NAMES)")


def enumerate_opcodes(ops: list[Op]) -> dict[int, tuple[Op, int, int, int, int]]:
    """Returns {opcode_index: (op, y, z, p, q)}, opcode_index in 0..256 for
    unprefixed, ED_STEP_BASE..ED_STEP_BASE+256 for ED-prefixed. Mirrors
    z80_gen.py's expand_optable(): eval `cond` against every opcode byte,
    asserting no two descriptors ever claim the same byte.
    """
    table: dict[int, tuple[Op, int, int, int, int]] = {}
    for prefix_offset, prefix in ((0, ""), (ED_STEP_BASE, "ed")):
        for opcode in range(256):
            x = opcode >> 6
            y = (opcode >> 3) & 7
            z = opcode & 7
            p = y >> 1
            q = y & 1
            for op in ops:
                if op.prefix != prefix or op.flags.get("special"):
                    # `special` ops (currently: cb/cbhl, let through by
                    # parse_opdescs() specifically so find_op() can locate
                    # them) aren't enumerated via cond/x/y/z/p/q -- they're
                    # dispatched into a different way, see generate()'s own
                    # explicit gen_op() calls for them.
                    continue
                if eval(op.cond_compiled, {}, {"x": x, "y": y, "z": z, "p": p, "q": q}):
                    idx = prefix_offset + opcode
                    if idx in table:
                        raise ValueError(
                            f"condition collision at opcode {opcode:#04x} prefix={prefix!r}: "
                            f"'{table[idx][0].name}' and '{op.name}'"
                        )
                    table[idx] = (op, y, z, p, q)
    return table


# ============================================================================
# Per-instruction-name action translation. Each entry is a function
# (y, z, p, q, mcycle_index) -> Rust statement(s) (a string, possibly
# multiple `;`-separated statements, NO trailing self.step assignment --
# that's added generically). `mcycle_index` is which of the op's mcycles
# this action belongs to (0-based), since a few instructions have actions
# on more than one mcycle.
# ============================================================================

def alu_call(op_index_expr: str, val_expr: str) -> str:
    return f"self.alu_op({op_index_expr}, {val_expr});"


ACTIONS: dict[str, "callable"] = {
    "LD $RY,$RZ": lambda y, z, p, q, i: r_write_stmt(y, r_read_expr(z)),
    "$ALU (HL)": lambda y, z, p, q, i: alu_call(str(y), "self.dlatch"),
    "$ALU $RZ": lambda y, z, p, q, i: alu_call(str(y), r_read_expr(z)),
    "$ALU n": lambda y, z, p, q, i: alu_call(str(y), "self.dlatch"),
    "EX AF,AF'": lambda y, z, p, q, i: (
        "let af = self.regs.af(); "
        "let af2 = ((self.regs.a_ as u16) << 8) | self.regs.f_ as u16; "
        "self.regs.set_af(af2); self.regs.a_ = (af >> 8) as u8; self.regs.f_ = af as u8;"
    ),
    "DJNZ d": {
        1: lambda y, z, p, q, i, nextstep: (
            f"self.regs.b = self.regs.b.wrapping_sub(1); "
            f"if self.regs.b == 0 {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        2: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); "
            "self.regs.wz = self.regs.pc;"
        ),
    },
    "JR d": {
        1: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); "
            "self.regs.wz = self.regs.pc;"
        ),
    },
    "JR $CC-4,d": {
        0: lambda y, z, p, q, i, nextstep: (
            f"if !({CC_EXPR[y - 4]}) {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        1: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); "
            "self.regs.wz = self.regs.pc;"
        ),
    },
    # z80.h's _z80_add16/_z80_adc16/_z80_sbc16 all set cpu->wz = (old) HL+1
    # as a side effect (ported here explicitly since alu::add16/adc16/sbc16
    # only compute the arithmetic result+flags, not this register side
    # effect -- found missing via a real differential-test failure, not
    # anticipated in advance).
    "ADD HL,$RP": lambda y, z, p, q, i: (
        f"self.regs.wz = self.hlx().wrapping_add(1); "
        f"let r = alu::add16(self.hlx(), {rp_read_expr(p, True)}, self.regs.f); "
        f"self.set_hlx(r.value); self.regs.f = r.flags;"
    ),
    "LD (BC),A": lambda y, z, p, q, i: (
        "self.regs.set_wzl(self.regs.c.wrapping_add(1)); self.regs.set_wzh(self.regs.a);"
    ),
    "LD (DE),A": lambda y, z, p, q, i: (
        "self.regs.set_wzl(self.regs.e.wrapping_add(1)); self.regs.set_wzh(self.regs.a);"
    ),
    "LD (nn),A": {2: lambda y, z, p, q, i: "self.regs.set_wzh(self.regs.a);"},
    "LD A,(BC)": lambda y, z, p, q, i: "self.regs.wz = self.regs.bc().wrapping_add(1);",
    "LD A,(DE)": lambda y, z, p, q, i: "self.regs.wz = self.regs.de().wrapping_add(1);",
    "INC (HL)": lambda y, z, p, q, i: (
        "let r = alu::inc8(self.dlatch, self.regs.f); self.dlatch = r.value; self.regs.f = r.flags;"
    ),
    "DEC (HL)": lambda y, z, p, q, i: (
        "let r = alu::dec8(self.dlatch, self.regs.f); self.dlatch = r.value; self.regs.f = r.flags;"
    ),
    "INC $RY": lambda y, z, p, q, i: (
        f"let r = alu::inc8({r_read_expr(y)}, self.regs.f); {r_write_stmt(y, 'r.value')} self.regs.f = r.flags;"
    ),
    "DEC $RY": lambda y, z, p, q, i: (
        f"let r = alu::dec8({r_read_expr(y)}, self.regs.f); {r_write_stmt(y, 'r.value')} self.regs.f = r.flags;"
    ),
    "RLCA": lambda y, z, p, q, i: "let r = alu::rlca(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "RRCA": lambda y, z, p, q, i: "let r = alu::rrca(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "RLA": lambda y, z, p, q, i: "let r = alu::rla(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "RRA": lambda y, z, p, q, i: "let r = alu::rra(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "DAA": lambda y, z, p, q, i: "let r = alu::daa(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "CPL": lambda y, z, p, q, i: "let r = alu::cpl(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;",
    "SCF": lambda y, z, p, q, i: "self.regs.f = alu::scf(self.regs.a, self.regs.f);",
    "CCF": lambda y, z, p, q, i: "self.regs.f = alu::ccf(self.regs.a, self.regs.f);",
    "RET $CC": {
        0: lambda y, z, p, q, i, nextstep: f"if !({CC_EXPR[y]}) {{ self.step = {nextstep + 6}; return Some(pins); }}",
        2: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;",
    },
    "RET": {1: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;"},
    "EXX": lambda y, z, p, q, i: (
        "std::mem::swap(&mut self.regs.b, &mut self.regs.b_); "
        "std::mem::swap(&mut self.regs.c, &mut self.regs.c_); "
        "std::mem::swap(&mut self.regs.d, &mut self.regs.d_); "
        "std::mem::swap(&mut self.regs.e, &mut self.regs.e_); "
        "std::mem::swap(&mut self.regs.h, &mut self.regs.h_); "
        "std::mem::swap(&mut self.regs.l, &mut self.regs.l_);"
    ),
    "JP HL": lambda y, z, p, q, i: "self.regs.pc = self.hlx();",
    "LD SP,HL": lambda y, z, p, q, i: "self.regs.sp = self.hlx();",
    "JP $CC,nn": {1: lambda y, z, p, q, i: f"if {CC_EXPR[y]} {{ self.regs.pc = self.regs.wz; }}"},
    "JP nn": {1: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;"},
    "EX (SP),HL": {3: lambda y, z, p, q, i: "self.set_hlx(self.regs.wz);"},
    "EX DE,HL": lambda y, z, p, q, i: (
        "let de = self.regs.de(); self.regs.set_de(self.regs.hl()); self.regs.set_hl(de);"
    ),
    "DI": lambda y, z, p, q, i: "self.regs.iff1 = false; self.regs.iff2 = false;",
    "EI": {
        0: lambda y, z, p, q, i: "self.regs.iff1 = false; self.regs.iff2 = false;",
        "post": lambda y, z, p, q, i: "self.regs.iff1 = true; self.regs.iff2 = true;",
    },
    "CALL $CC,nn": {1: lambda y, z, p, q, i, nextstep: f"if !({CC_EXPR[y]}) {{ self.step = {nextstep + 7}; return Some(pins); }}",
                    4: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;"},
    "CALL nn": {3: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;"},
    "RST $Y*8": {2: lambda y, z, p, q, i: f"self.regs.wz = {y * 8}; self.regs.pc = self.regs.wz;"},
    # ED prefix block
    "SBC HL,$RP": lambda y, z, p, q, i: (
        f"self.regs.wz = self.regs.hl().wrapping_add(1); "
        f"let r = alu::sbc16(self.regs.hl(), {rp_read(p, True)}, self.regs.f & FLAG_C); "
        f"self.regs.set_hl(r.value); self.regs.f = r.flags;"
    ),
    "ADC HL,$RP": lambda y, z, p, q, i: (
        f"self.regs.wz = self.regs.hl().wrapping_add(1); "
        f"let r = alu::adc16(self.regs.hl(), {rp_read(p, True)}, self.regs.f & FLAG_C); "
        f"self.regs.set_hl(r.value); self.regs.f = r.flags;"
    ),
    "NEG": lambda y, z, p, q, i: "let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;",
    "RETI": {1: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;",
              "post": lambda y, z, p, q, i: "self.regs.iff1 = self.regs.iff2;"},
    "RETN": {1: lambda y, z, p, q, i: "self.regs.pc = self.regs.wz;",
             "post": lambda y, z, p, q, i: "self.regs.iff1 = self.regs.iff2;"},
    "IM $IMY": lambda y, z, p, q, i: f"self.regs.im = {IM_TABLE[y]};",
    "LD I,A": lambda y, z, p, q, i: "self.regs.i = self.regs.a;",
    "LD R,A": lambda y, z, p, q, i: "self.regs.r = self.regs.a;",
    "LD A,I": lambda y, z, p, q, i: (
        "self.regs.a = self.regs.i; self.regs.f = alu::sziff2_flags(self.regs.i, self.regs.f, self.regs.iff2);"
    ),
    "LD A,R": lambda y, z, p, q, i: (
        "self.regs.a = self.regs.r; self.regs.f = alu::sziff2_flags(self.regs.r, self.regs.f, self.regs.iff2);"
    ),
    "RRD": {1: lambda y, z, p, q, i: (
        "let (new_a, new_mem, flags) = alu::rrd(self.regs.a, self.dlatch, self.regs.f); "
        "self.regs.a = new_a; self.dlatch = new_mem; self.regs.f = flags;"
    ), 2: lambda y, z, p, q, i: "self.regs.wz = self.regs.hl().wrapping_add(1);"},
    "RLD": {1: lambda y, z, p, q, i: (
        "let (new_a, new_mem, flags) = alu::rld(self.regs.a, self.dlatch, self.regs.f); "
        "self.regs.a = new_a; self.dlatch = new_mem; self.regs.f = flags;"
    ), 2: lambda y, z, p, q, i: "self.regs.wz = self.regs.hl().wrapping_add(1);"},
    "LDI": {2: lambda y, z, p, q, i: (
        "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
        "self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f);"
    )},
    "LDD": {2: lambda y, z, p, q, i: (
        "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
        "self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f);"
    )},
    "LDIR": {
        2: lambda y, z, p, q, i, nextstep: (
            "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
            "self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f); "
            f"if bc_after == 0 {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        3: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; "
            "self.regs.pc = self.regs.pc.wrapping_sub(1);"
        ),
    },
    "LDDR": {
        2: lambda y, z, p, q, i, nextstep: (
            "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
            "self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f); "
            f"if bc_after == 0 {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        3: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; "
            "self.regs.pc = self.regs.pc.wrapping_sub(1);"
        ),
    },
    "CPI": {1: lambda y, z, p, q, i: (
        "self.regs.wz = self.regs.wz.wrapping_add(1); "
        "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
        "let (flags, _repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags;"
    )},
    "CPD": {1: lambda y, z, p, q, i: (
        "self.regs.wz = self.regs.wz.wrapping_sub(1); "
        "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
        "let (flags, _repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags;"
    )},
    "CPIR": {
        1: lambda y, z, p, q, i, nextstep: (
            "self.regs.wz = self.regs.wz.wrapping_add(1); "
            "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
            "let (flags, repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags; "
            f"if !repeat {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        2: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; "
            "self.regs.pc = self.regs.pc.wrapping_sub(1);"
        ),
    },
    "CPDR": {
        1: lambda y, z, p, q, i, nextstep: (
            "self.regs.wz = self.regs.wz.wrapping_sub(1); "
            "let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); "
            "let (flags, repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags; "
            f"if !repeat {{ self.step = {nextstep + 5}; return Some(pins); }}"
        ),
        2: lambda y, z, p, q, i: (
            "self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; "
            "self.regs.pc = self.regs.pc.wrapping_sub(1);"
        ),
    },
    # LD r,n / LD (HL),n / LD $RP,nn / LD (nn),HL / LD HL,(nn) / LD (nn),$RP /
    # LD $RP,(nn) / PUSH / POP -- no `action` text at all, pure data
    # movement fully handled by the generic dst/ab/db substitution below.
    "LD $RY,n": None,
    "LD (HL),n": None,
    "LD $RP,nn": None,
    "LD (nn),HL": None,
    "LD HL,(nn)": None,
    "LD (nn),$RP": None,
    "LD $RP,(nn)": None,
    "POP $RP2": None,
    "PUSH $RP2": None,
    "INC $RP": lambda y, z, p, q, i: rp_set_stmt_hlx(p, True, rp_read_expr(p, True) + ".wrapping_add(1)"),
    "DEC $RP": lambda y, z, p, q, i: rp_set_stmt_hlx(p, True, rp_read_expr(p, True) + ".wrapping_sub(1)"),
    "JP nn (target)": None,  # placeholder, unused (JP nn handled above)
    # CB-prefix payload steps (see SPECIAL_BUT_HANDLED) -- `z`/`x`/`y` here
    # come from the CB-suffix opcode itself (`self.opcode`, latched by the
    # hand-written CB fetch machine cycle in cpu.rs), NOT from this op's
    # own generation-time y/z/p/q (which are meaningless here, these two
    # entries aren't enumerated per-opcode the normal way).
    "cb": lambda y, z, p, q, i: (
        "let z = self.opcode & 7; "
        "let val = self.get_reg8_plain(z); "
        "if let Some(new_val) = self.cb_action(val, false) { self.set_reg8_plain(z, new_val); }"
    ),
    "cbhl": {
        0: lambda y, z, p, q, i, nextstep: (
            "if let Some(v) = self.cb_action(self.dlatch, true) { self.dlatch = v; } "
            f"else {{ self.step = {nextstep + 3}; return Some(pins); }}"
        ),
    },
}


def get_action(name: str, mcycle_index: int, y: int, z: int, p: int, q: int,
                nextstep: int | None, is_post: bool = False) -> str | None:
    entry = ACTIONS.get(name)
    if entry is None:
        return None
    if callable(entry):
        # A plain-callable ACTIONS entry means "the action for this op's
        # one real (non-auto-appended-overlapped) mcycle" -- mci 0.
        # Anything else (the auto-appended trailing overlapped, or a
        # `post_action` query) genuinely has no action here.
        if mcycle_index != 0 or is_post:
            return None
        return entry(y, z, p, q, mcycle_index)
    key = "post" if is_post else mcycle_index
    fn = entry.get(key)
    if fn is None:
        return None
    try:
        return fn(y, z, p, q, mcycle_index, nextstep)
    except TypeError:
        return fn(y, z, p, q, mcycle_index)


# ============================================================================
# ab / db / dst simple-token substitution (mirrors z80_gen.py's map_cpu, but
# only the small set of tokens actually used unprefixed/ED in this file --
# and unlike map_cpu, increment/decrement forms need dedicated Cpu helper
# methods since Rust has no lvalue-expression `x++`).
# ============================================================================

def addr_expr(tok: str, y: int, z: int, p: int, q: int) -> str:
    table = {
        "$ADDR": "self.addr",
        "$PC++": "self.pc_post_inc()",
        "$BC": "self.regs.bc()",
        "$DE": "self.regs.de()",
        "$SP": "self.regs.sp",
        "$SP++": "self.sp_post_inc()",
        "$SP+1": "self.regs.sp.wrapping_add(1)",
        "--$SP": "self.sp_pre_dec()",
        "$WZ": "self.regs.wz",
        "$WZ++": "self.wz_post_inc()",
        "cpu->hl": "self.regs.hl()",
        "cpu->hl++": "self.hl_post_inc()",
        "cpu->hl--": "self.hl_post_dec()",
        "cpu->de++": "self.de_post_inc()",
        "cpu->de--": "self.de_post_dec()",
    }
    if tok in table:
        return table[tok]
    raise ValueError(f"unhandled address expression: {tok!r}")


def data_read_expr(tok: str, y: int, z: int, p: int, q: int) -> str:
    if tok == "$DLATCH":
        return "self.dlatch"
    # $H/$L (bare, unlike $RRY/$RRZ) ARE substitutable in the YAML -- used
    # only by "LD (nn),HL"/"LD HL,(nn)"/"EX (SP),HL" (all p==2-fixed,
    # unprefixed), and real DD/FD-prefixed forms of those (LD (nn),IX,
    # EX (SP),IX, ...) really do read/write IXH/IXL. Verified directly
    # against z80.h (case 607/610 use cpu->hlx[cpu->hlx_idx].l/.h).
    if tok == "$H":
        return "self.hlx_h()"
    if tok == "$L":
        return "self.hlx_l()"
    plain_regs = {"$A": "a", "$B": "b", "$C": "c", "$D": "d", "$E": "e"}
    if tok in plain_regs:
        return f"self.regs.{plain_regs[tok]}"
    if tok == "$RRZ":
        return R[z]
    if tok == "$RRY":
        return R[y]
    if tok == "$PCH":
        return "(self.regs.pc >> 8) as u8"
    if tok == "$PCL":
        return "self.regs.pc as u8"
    if tok == "$RP2H":
        return "self.hlx_h()" if p == 2 else RP2_HIGH[p]
    if tok == "$RP2L":
        return "self.hlx_l()" if p == 2 else RP2_LOW[p]
    if tok == "$RRPH":
        return RP_HIGH[p]
    if tok == "$RRPL":
        return RP_LOW[p]
    if tok == '"0"' or tok == 0:
        return "0"
    raise ValueError(f"unhandled data-read expression: {tok!r}")


def dest_write_expr(tok: str, y: int, z: int, p: int, q: int) -> str:
    """Returns either a Rust lvalue expression (assignable with `= value;`)
    or one of the `__XXX__` sentinels `emit_dest_assign` special-cases (for
    targets that need a setter *call*, not a plain field), for an `mread`'s
    `dst` field. `$RY == 6` ((HL)) never occurs among the ops this
    generator handles (they route through $DLATCH instead)."""
    if tok == "$DLATCH":
        return "self.dlatch"
    if tok == "$RY":
        # Substitutable (LD $RY,n, e.g. -- DD-prefixed LD H,n really means
        # LD IXH,n).
        if y == 4:
            return "__HLXH__"
        if y == 5:
            return "__HLXL__"
        return R[y]
    if tok == "$RRY":
        return R[y]  # never substituted -- see z80_desc.yml's own note
    if tok == "$H":
        return "__HLXH__"
    if tok == "$L":
        return "__HLXL__"
    plain_regs = {"$A": "a", "$B": "b", "$C": "c", "$D": "d", "$E": "e"}
    if tok in plain_regs:
        return f"self.regs.{plain_regs[tok]}"
    if tok == "$WZL":
        return "__WZL__"  # handled specially, see emit_mread
    if tok == "$WZH":
        return "__WZH__"
    if tok == "$RPL":
        # Substitutable (LD $RP,nn -- DD-prefixed LD HL,nn really means
        # LD IX,nn).
        if p == 2:
            return "__HLXL__"
        return RP_LOW[p] if p != 3 else "__SPL__"
    if tok == "$RPH":
        if p == 2:
            return "__HLXH__"
        return RP_HIGH[p] if p != 3 else "__SPH__"
    if tok == "$RP2L":
        # Substitutable (POP $RP2 -- DD-prefixed POP HL really means POP IX).
        if p == 2:
            return "__HLXL__"
        return RP2_LOW[p]
    if tok == "$RP2H":
        if p == 2:
            return "__HLXH__"
        return RP2_HIGH[p]
    if tok == "$RRPL":
        return RP_LOW[p] if p != 3 else "__SPL__"
    if tok == "$RRPH":
        return RP_HIGH[p] if p != 3 else "__SPH__"
    raise ValueError(f"unhandled dest-write token: {tok!r}")


def emit_dest_assign(tok: str, y: int, z: int, p: int, q: int) -> str:
    target = dest_write_expr(tok, y, z, p, q)
    if target == "__WZL__":
        return "self.regs.set_wzl(get_data(pins));"
    if target == "__WZH__":
        return "self.regs.set_wzh(get_data(pins));"
    if target == "__SPL__":
        return "self.regs.set_spl(get_data(pins));"
    if target == "__SPH__":
        return "self.regs.set_sph(get_data(pins));"
    if target == "__HLXH__":
        return "self.set_hlx_h(get_data(pins));"
    if target == "__HLXL__":
        return "self.set_hlx_l(get_data(pins));"
    return f"{target} = get_data(pins);"


# ============================================================================
# Step/code generation, mirroring z80_gen.py's gen_decoder(): each mcycle
# type expands into a fixed sequence of T-states. Unlike the first draft of
# this generator, step NUMBERS for an entire op are assigned in one flat
# pass over every T-state up front (dispatch_index for the first, then
# Generator.alloc() for every other one, including the trailing
# `overlapped` T-state) -- this is the fix for a real bug caught before
# ever running it: allocating the "next step after this mcycle" lazily,
# without reserving it via alloc(), let a later op's alloc() call hand out
# the SAME number again, silently colliding two different opcodes' code
# onto one match arm.
# ============================================================================

class TState:
    """One T-state (one generated match arm) within a single instruction.
    `kind` selects which template `render()` uses; `number` is assigned by
    Generator.assign_numbers(), not at construction time."""

    def __init__(self, kind: str, **kw):
        self.kind = kind
        self.kw = kw
        self.number: int | None = None


def build_tstates(op: Op) -> list[TState]:
    """Flattens one op's `mcycles` into the exact per-T-state sequence
    z80_gen.py's own add()/add_fetch() calls would produce -- an
    `overlapped` mcycle is auto-appended if the op doesn't already end
    with one, mirroring parse_opdescs()'s own `num_overlapped == 0` check."""
    mcycles = list(op.mcycles)
    if not any(mc["type"] == "overlapped" for mc in mcycles):
        mcycles = mcycles + [{"type": "overlapped"}]

    tstates: list[TState] = []
    for mci, mc in enumerate(mcycles):
        t = mc["type"]
        if t == "mread":
            tcycles = mc.get("tcycles", MEM_TCYCLES)
            tstates.append(TState("plain"))
            tstates.append(TState("mread_wait", ab=mc["ab"]))
            tstates.append(TState("mread_latch", dst=mc["dst"], mci=mci))
            tstates += [TState("plain") for _ in range(3, tcycles)]
        elif t == "mwrite":
            tcycles = mc.get("tcycles", MEM_TCYCLES)
            tstates.append(TState("plain"))
            tstates.append(TState("mwrite_go", ab=mc["ab"], db=mc["db"], mci=mci))
            tstates.append(TState("plain"))
            tstates += [TState("plain") for _ in range(3, tcycles)]
        elif t == "generic":
            tstates.append(TState("generic", mci=mci))
            tstates += [TState("plain") for _ in range(1, mc["tcycles"])]
        elif t == "overlapped":
            tstates.append(TState("overlapped", mci=mci, prefix=mc.get("prefix")))
        else:
            raise ValueError(f"{op.name}: unhandled mcycle type {t!r}")
    if tstates[-1].kind != "overlapped":
        raise ValueError(f"{op.name}: internal error, didn't end on 'overlapped'")
    return tstates


class Generator:
    def __init__(self):
        self.cur_extra_step = EXTRA_STEP_BASE
        self.arms: list[str] = []

    def alloc(self) -> int:
        s = self.cur_extra_step
        self.cur_extra_step += 1
        return s

    def gen_op(self, dispatch_index: int | None, op: Op, y: int, z: int, p: int, q: int) -> int:
        """Returns the step number assigned to this op's first T-state --
        `dispatch_index` when given explicitly (the main 0..512 opcode
        table), otherwise a freshly `alloc()`'d one (used for standalone
        entries like `cb`/`cbhl` that aren't part of that table but still
        need a real, collision-free step number for hand-written code
        elsewhere to jump to)."""
        tstates = build_tstates(op)
        tstates[0].number = dispatch_index if dispatch_index is not None else self.alloc()
        for ts in tstates[1:]:
            ts.number = self.alloc()

        for i, ts in enumerate(tstates):
            # $NEXTSTEP == this T-state's own natural successor (its
            # `_goto()` target if nothing branches early) -- well-defined
            # for every kind except the last (always 'overlapped', which
            # dispatches via begin_fetch()/begin_fetch_ed() instead of a
            # plain `self.step = next`).
            nxt = tstates[i + 1].number if i + 1 < len(tstates) else None
            self.arms.append(f"            {ts.number} => {{\n{self.render(ts, nxt, op, y, z, p, q)}\n            }}")

        return tstates[0].number

    def render(self, ts: TState, nxt: int | None, op: Op, y: int, z: int, p: int, q: int) -> str:
        if ts.kind == "plain":
            return f"                self.step = {nxt};\n                pins"
        if ts.kind == "mread_wait":
            addr = addr_expr(ts.kw["ab"], y, z, p, q)
            return (
                "                if pins & WAIT != 0 { return Some(pins); }\n"
                f"                let pins = set_addr_ctrl(pins, {addr}, MREQ | RD);\n"
                f"                self.step = {nxt};\n"
                "                pins"
            )
        if ts.kind == "mread_latch":
            dest_stmt = emit_dest_assign(ts.kw["dst"], y, z, p, q)
            action = get_action(op.name, ts.kw["mci"], y, z, p, q, nxt)
            body = f"                {dest_stmt}\n"
            if action:
                body += f"                {action}\n"
            body += f"                self.step = {nxt};\n                pins"
            return body
        if ts.kind == "mwrite_go":
            addr = addr_expr(ts.kw["ab"], y, z, p, q)
            db_tok = ts.kw["db"]
            data = "0" if db_tok in ("0", 0) else data_read_expr(db_tok, y, z, p, q)
            action = get_action(op.name, ts.kw["mci"], y, z, p, q, nxt)
            body = (
                "                if pins & WAIT != 0 { return Some(pins); }\n"
                f"                let pins = set_addr_data_ctrl(pins, {addr}, {data}, MREQ | WR);\n"
            )
            if action:
                body += f"                {action}\n"
            body += f"                self.step = {nxt};\n                pins"
            return body
        if ts.kind == "generic":
            action = get_action(op.name, ts.kw["mci"], y, z, p, q, nxt)
            body = ""
            if action:
                body += f"                {action}\n"
            body += f"                self.step = {nxt};\n                pins"
            return body
        if ts.kind == "overlapped":
            mci = ts.kw["mci"]
            action = get_action(op.name, mci, y, z, p, q, None)
            post_action = get_action(op.name, mci, y, z, p, q, None, is_post=True)
            body = f"                {action}\n" if action else ""
            prefix = ts.kw.get("prefix")
            if prefix == "ed":
                body += "                self.begin_fetch_ed(pins)"
            elif prefix is not None:
                # Any other prefix value (cb/dd/fd) means this op should
                # have been excluded via SKIP_NAMES instead -- silently
                # falling through to a plain begin_fetch() here previously
                # caused a real bug (see SKIP_NAMES's own comment): the
                # prefix byte got treated as a harmless no-op instead of
                # properly failing loud.
                raise ValueError(
                    f"{op.name}: unhandled prefix {prefix!r} -- add it to SKIP_NAMES "
                    f"until real dispatch for it exists, don't let it fall through silently"
                )
            elif post_action:
                body += "                let pins = self.begin_fetch(pins);\n"
                body += f"                {post_action}\n"
                body += "                pins"
            else:
                body += "                self.begin_fetch(pins)"
            return body
        raise ValueError(f"unhandled T-state kind {ts.kind!r}")


def generate() -> str:
    ops = parse_opdescs()
    table = enumerate_opcodes(ops)

    gen = Generator()
    for idx in sorted(table):
        op, y, z, p, q = table[idx]
        gen.gen_op(idx, op, y, z, p, q)

    # CB-prefix payload steps: not part of the 0..512 opcode table (they're
    # dispatched into by cpu.rs's hand-written CB fetch machine cycle,
    # which decides between them based on the CB-suffix opcode's own z
    # field), so they get fresh alloc()'d step numbers instead of a fixed
    # dispatch_index -- exported below as named constants so that
    # hand-written code can reference them without hardcoding magic
    # numbers.
    cb_step = gen.gen_op(None, find_op(ops, "cb"), 0, 0, 0, 0)
    cbhl_step = gen.gen_op(None, find_op(ops, "cbhl"), 0, 0, 0, 0)

    header = f"""\
// GENERATED FILE -- do not edit by hand.
// Produced by scripts/generate_z80_dispatch.py from vendor/chips/z80_desc.yml.
// Regenerate with: python scripts/generate_z80_dispatch.py
//
// A separate module (not spliced into cpu.rs -- `include!()` inside an
// `impl` block turned out not to be accepted by Rust's parser in item
// position), so the handful of Cpu fields/methods this needs
// (step/opcode/dlatch/addr/regs, begin_fetch/begin_fetch_ed/alu_op/the
// post-inc-dec helpers) are `pub(crate)` rather than exposed publicly.

use crate::alu;
use crate::flags::*;
use crate::pins::*;

/// Step number for the CB-prefix register-direct payload ("cb" in
/// z80_desc.yml) -- cpu.rs's hand-written CB fetch machine cycle jumps
/// here directly, not through the 0..512 table.
pub(crate) const CB_STEP: u16 = {cb_step};
/// Same, for the "(HL)" form ("cbhl" in z80_desc.yml).
pub(crate) const CBHL_STEP: u16 = {cbhl_step};

impl crate::cpu::Cpu {{
    pub(crate) fn dispatch_generated(&mut self, pins: u64) -> Option<u64> {{
        Some(match self.step {{
{chr(10).join(gen.arms)}
            _ => return None,
        }})
    }}
}}
"""
    return header


def main():
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(generate())
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
