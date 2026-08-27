//! Differential tests: every instruction the hand-written `zx_core::Cpu`
//! implements gets run, in lockstep, against the real `chips/z80.h` core
//! (via `ReferenceCpu`) starting from identical random register/memory
//! state, asserting the full register file matches after every single
//! step. This is the actual "100% the same as the C implementation" check
//! -- not a hope, a per-instruction diff against the proven reference.

use zx_core::{Cpu, FlatMemory, Memory, Registers};
use zx_core_conformance::ReferenceCpu;

/// Tiny deterministic PRNG (SplitMix64) so a failing seed is reproducible
/// without pulling in the `rand` crate for a handful of call sites.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn next_u8(&mut self) -> u8 {
        self.next_u64() as u8
    }

    fn next_u16(&mut self) -> u16 {
        self.next_u64() as u16
    }

    fn choice(&mut self, options: &[u8]) -> u8 {
        options[(self.next_u64() as usize) % options.len()]
    }
}

fn random_registers(rng: &mut Rng, hl_scratch: u16, ix_scratch: u16, iy_scratch: u16) -> Registers {
    let mut regs = Registers {
        a: rng.next_u8(),
        f: rng.next_u8(),
        b: rng.next_u8(),
        c: rng.next_u8(),
        d: rng.next_u8(),
        e: rng.next_u8(),
        h: 0,
        l: 0,
        a_: rng.next_u8(),
        f_: rng.next_u8(),
        b_: rng.next_u8(),
        c_: rng.next_u8(),
        d_: rng.next_u8(),
        e_: rng.next_u8(),
        h_: rng.next_u8(),
        l_: rng.next_u8(),
        ix: ix_scratch,
        iy: iy_scratch,
        sp: rng.next_u16(),
        pc: 0,
        i: rng.next_u8(),
        r: rng.next_u8() & 0x7F,
        iff1: false,
        iff2: false,
        im: 0,
        wz: 0,
    };
    regs.set_hl(hl_scratch);
    regs
}

// Destination registers are restricted to B,C,D,E,(HL),A -- H(4)/L(5) are
// excluded so HL never drifts mid-stream, which keeps every (HL) form
// pointed at the fixed scratch cell instead of back into the instruction
// stream it's currently executing.
const DST_REGS: [u8; 6] = [0, 1, 2, 3, 6, 7];
const SRC_REGS: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
// 16-bit "dd"/"ss" register field: BC, DE, SP -- HL(2) excluded for the
// same reason as above (LD HL,nn / INC HL / DEC HL would let HL drift).
const DD_REGS: [u8; 3] = [0, 1, 3];
// 8-bit register field with (HL)/(IX+d)/(IY+d) (index 6) excluded -- used
// by the DD/FD fuzz branch below, where index 6 isn't a valid register
// selector at all (it's the byte 0x76/HALT when combined with itself, and
// every other (IX+d)-touching form already has its own dedicated opcode
// pattern with an explicit displacement byte, not this field).
const REGS_NO_HL: [u8; 7] = [0, 1, 2, 3, 4, 5, 7];

/// Builds a random stream of `count` instructions starting at address 0,
/// restricted to opcodes with no control flow (so PC only ever advances
/// sequentially and nothing needs stack space) -- everything implemented
/// so far except HALT/JP/JR/DJNZ/CALL/RET/PUSH/POP, which get their own
/// small hand-written differential tests below instead, since fuzzing
/// jumps risks landing on an unimplemented opcode or corrupting the
/// in-flight instruction stream.
// Single-byte, accumulator/flags-only opcodes: safe to fuzz freely since
// they touch neither PC/HL nor memory.
const ACCUMULATOR_SINGLES: [u8; 9] = [0x07, 0x0F, 0x17, 0x1F, 0x27, 0x2F, 0x37, 0x3F, 0x08];

fn random_program(rng: &mut Rng, count: usize) -> Vec<u8> {
    let mut bytes = Vec::new();
    for _ in 0..count {
        match rng.next_u64() % 9 {
            0 => bytes.push(0x00), // NOP
            1 => {
                let dst = rng.choice(&DST_REGS);
                bytes.push(0x06 | (dst << 3));
                bytes.push(rng.next_u8()); // n
            }
            2 => {
                let dst = rng.choice(&DST_REGS);
                let src = if dst == 6 {
                    // avoid LD (HL),(HL) == 0x76 == HALT
                    *SRC_REGS.iter().filter(|&&s| s != 6).nth(
                        (rng.next_u64() as usize) % (SRC_REGS.len() - 1),
                    ).unwrap()
                } else {
                    rng.choice(&SRC_REGS)
                };
                bytes.push(0x40 | (dst << 3) | src);
            }
            3 => {
                // ALU op A,r or ALU op A,n
                let op = (rng.next_u64() % 8) as u8;
                if rng.next_u64() % 2 == 0 {
                    let src = rng.choice(&SRC_REGS);
                    bytes.push(0x80 | (op << 3) | src);
                } else {
                    bytes.push(0xC6 | (op << 3));
                    bytes.push(rng.next_u8());
                }
            }
            4 => {
                // INC r / DEC r
                let r = rng.choice(&DST_REGS);
                let base = if rng.next_u64() % 2 == 0 { 0x04 } else { 0x05 };
                bytes.push(base | (r << 3));
            }
            5 => bytes.push(rng.choice(&ACCUMULATOR_SINGLES)),
            6 => {
                // CB-prefixed: rotate/shift/BIT/RES/SET, register or (HL)
                // (HL) is safe to include -- HL stays pinned to the fixed
                // scratch address either way, same as every other (HL)
                // form already in this generator.
                let x = (rng.next_u64() % 4) as u8;
                let y = (rng.next_u64() % 8) as u8;
                let z = rng.choice(&DST_REGS);
                bytes.push(0xCB);
                bytes.push((x << 6) | (y << 3) | z);
            }
            7 => {
                // DD/FD-prefixed: IX/IY register substitution (8-bit and
                // 16-bit, including the undocumented IXH/IXL/IYH/IYL forms)
                // plus the (IX+d)/(IY+d) indirect forms. IX/IY are pinned to
                // their own fixed scratch addresses (see IX_SCRATCH/
                // IY_SCRATCH in the caller) so indirect writes can't corrupt
                // the in-flight instruction stream, same reasoning as HL's.
                let prefix = if rng.next_u64() % 2 == 0 { 0xDD } else { 0xFD };
                bytes.push(prefix);
                match rng.next_u64() % 8 {
                    0 => {
                        bytes.push(0x21); // LD IX,nn
                        bytes.push(rng.next_u8());
                        bytes.push(rng.next_u8());
                    }
                    1 => {
                        let p = rng.choice(&[0u8, 1, 2, 3]); // BC, DE, IX, SP
                        bytes.push(0x09 | (p << 4)); // ADD IX,rp
                    }
                    2 => {
                        // INC/DEC IX, or INC/DEC IXH/IXL (undocumented)
                        let r = rng.choice(&[2u8, 4, 5]); // 2 = whole IX (0x23/0x2B), 4/5 = IXH/IXL
                        if r == 2 {
                            bytes.push(if rng.next_u64() % 2 == 0 { 0x23 } else { 0x2B });
                        } else {
                            let base = if rng.next_u64() % 2 == 0 { 0x04 } else { 0x05 };
                            bytes.push(base | (r << 3));
                        }
                    }
                    3 => {
                        // LD IXH/IXL,n
                        let r = rng.choice(&[4u8, 5]);
                        bytes.push(0x06 | (r << 3));
                        bytes.push(rng.next_u8());
                    }
                    4 => {
                        // LD dst,src where dst/src range over the plain
                        // registers and IXH/IXL (undocumented register-to-
                        // register substitution) -- (IX+d) has its own
                        // dedicated arm below since it needs a displacement
                        // byte, not this field.
                        let dst = rng.choice(&REGS_NO_HL);
                        let src = rng.choice(&REGS_NO_HL);
                        bytes.push(0x40 | (dst << 3) | src);
                    }
                    5 => {
                        // ALU A,IXH/IXL
                        let op = (rng.next_u64() % 8) as u8;
                        let src = rng.choice(&[4u8, 5]);
                        bytes.push(0x80 | (op << 3) | src);
                    }
                    6 => {
                        // (IX+d) indirect: LD (IX+d),r / LD r,(IX+d) /
                        // LD (IX+d),n / INC (IX+d) / DEC (IX+d) / ALU A,(IX+d)
                        let d = rng.next_u8();
                        match rng.next_u64() % 5 {
                            0 => {
                                let src = rng.choice(&REGS_NO_HL);
                                bytes.push(0x70 | src); // LD (IX+d),r
                                bytes.push(d);
                            }
                            1 => {
                                let dst = rng.choice(&REGS_NO_HL);
                                bytes.push(0x46 | (dst << 3)); // LD r,(IX+d)
                                bytes.push(d);
                            }
                            2 => {
                                bytes.push(0x36); // LD (IX+d),n
                                bytes.push(d);
                                bytes.push(rng.next_u8());
                            }
                            3 => {
                                bytes.push(if rng.next_u64() % 2 == 0 { 0x34 } else { 0x35 }); // INC/DEC (IX+d)
                                bytes.push(d);
                            }
                            _ => {
                                let op = (rng.next_u64() % 8) as u8;
                                bytes.push(0x86 | (op << 3)); // ALU A,(IX+d)
                                bytes.push(d);
                            }
                        }
                    }
                    _ => {
                        // DD+CB/FD+CB ("DDCB"): rotate/shift/BIT/RES/SET on
                        // (IX+d), including the undocumented "also store to
                        // register" form (z != 6) that isn't exercised any
                        // other way.
                        let d = rng.next_u8();
                        let x = (rng.next_u64() % 4) as u8;
                        let y = (rng.next_u64() % 8) as u8;
                        let z = rng.choice(&DST_REGS); // 6 = "no extra register", same encoding as plain CB
                        bytes.push(0xCB);
                        bytes.push(d);
                        bytes.push((x << 6) | (y << 3) | z);
                    }
                }
            }
            _ => {
                // LD dd,nn / INC ss / DEC ss
                let dd = rng.choice(&DD_REGS);
                match rng.next_u64() % 3 {
                    0 => {
                        bytes.push(0x01 | (dd << 4));
                        bytes.push(rng.next_u8());
                        bytes.push(rng.next_u8());
                    }
                    1 => bytes.push(0x03 | (dd << 4)),
                    _ => bytes.push(0x0B | (dd << 4)),
                }
            }
        }
    }
    bytes
}

fn diff(new: &Registers, reference: &Registers) -> Option<String> {
    if new == reference {
        return None;
    }
    Some(format!("zx_core = {new:?}\nreference = {reference:?}"))
}

#[test]
fn ld_and_nop_opcodes_match_the_real_z80h_core_step_by_step() {
    const SEEDS: usize = 200;
    const INSTRUCTIONS_PER_RUN: usize = 300;
    const HL_SCRATCH: u16 = 0xC000;
    // IX/IY get their own scratch cells, far enough apart (and from
    // HL_SCRATCH) that even the widest (IX+d)/(IY+d) displacement
    // (d in -128..127) can never reach another scratch region or the
    // in-flight instruction stream at the bottom of memory.
    const IX_SCRATCH: u16 = 0xC400;
    const IY_SCRATCH: u16 = 0xC800;

    for seed in 0..SEEDS as u64 {
        let mut rng = Rng::new(0xC0FFEE ^ seed);

        let mut mem_bytes = [0u8; 0x10000];
        for b in mem_bytes.iter_mut() {
            *b = rng.next_u8();
        }
        let program = random_program(&mut rng, INSTRUCTIONS_PER_RUN);
        mem_bytes[0..program.len()].copy_from_slice(&program);

        let initial_regs = random_registers(&mut rng, HL_SCRATCH, IX_SCRATCH, IY_SCRATCH);

        let mut new_cpu = Cpu::new();
        let mut new_mem = FlatMemory(mem_bytes);
        new_cpu.set_registers(initial_regs, &mut new_mem);

        let mut reference = ReferenceCpu::new();
        let mut reference_mem = FlatMemory(mem_bytes);
        reference.set_registers(&initial_regs, &mut reference_mem);

        for step in 0..INSTRUCTIONS_PER_RUN {
            new_cpu.step(&mut new_mem);
            reference.step(&mut reference_mem);

            if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
                panic!(
                    "seed {seed} step {step}: registers diverged from the real z80.h core\n{detail}"
                );
            }
        }
    }
}

#[test]
fn halt_behaves_identically_to_the_real_z80h_core() {
    // LD A,0x42 ; LD B,A ; HALT -- same program as the step-1 smoke test,
    // run long enough (well past the HALT) to confirm both cores freeze
    // PC identically rather than only checking the first few steps.
    let mut mem_bytes = [0u8; 0x10000];
    mem_bytes[0..4].copy_from_slice(&[0x3E, 0x42, 0x47, 0x76]);

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    // Rust's Cpu::new() is a plain zeroed Default; z80.h's zx_init() leaves
    // registers in its own (non-zero) init pattern instead, so align both
    // cores to the same explicit starting state before comparing.
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..10 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted);
}

#[test]
fn control_flow_matches_the_real_z80h_core() {
    // A single hand-written program touching every control-flow opcode
    // implemented so far: LD SP,nn / LD BC,nn / PUSH / POP / LD B,n /
    // DJNZ (looped 3x: 2 taken, 1 fallthrough) / JP nn / CALL nn / RET /
    // INC r / HALT. Hand-written rather than fuzzed: a random JP/CALL
    // target risks landing on an address with an unimplemented opcode, or
    // (via PUSH/CALL) overwriting the in-flight instruction stream on the
    // stack -- exactly the self-corruption problem `random_program()`'s
    // doc comment already avoids for the same reason.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x31, 0xFE, 0xFF]), // LD SP,0xFFFE
        (0x0003, &[0x01, 0x03, 0x02]), // LD BC,0x0203
        (0x0006, &[0xC5]),             // PUSH BC
        (0x0007, &[0xD1]),             // POP DE
        (0x0008, &[0x06, 0x03]),       // LD B,3
        (0x000A, &[0x10, 0xFE]),       // DJNZ -2 (loops back to itself)
        (0x000C, &[0xC3, 0x20, 0x00]), // JP 0x0020
        (0x0020, &[0xCD, 0x30, 0x00]), // CALL 0x0030
        (0x0023, &[0x76]),             // HALT
        (0x0030, &[0x3C]),             // INC A
        (0x0031, &[0xC9]),             // RET
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    // LD SP,nn / LD BC,nn / PUSH / POP / LD B,n / DJNZ x3 / JP / CALL /
    // INC A / RET / HALT / one extra halted-idle step = 15.
    for step in 0..15 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0023");
    assert_eq!(new_cpu.registers().a, 1, "INC A inside the CALLed subroutine should have run");
    assert_eq!(new_cpu.registers().de(), 0x0203, "POP DE should have recovered the PUSHed BC");
}

#[test]
fn jr_matches_the_real_z80h_core() {
    // JR e (unconditional) then XOR A (sets Z) then JR Z,e (taken) then
    // JR NZ,e (not taken, since Z is still set) then HALT. Covers both the
    // plain and conditional JR opcodes, and both branches of the
    // conditional form -- the DJNZ-based control-flow test above doesn't
    // exercise these since DJNZ is a distinct opcode.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x18, 0x02]), // JR +2 -> 0x0004
        (0x0004, &[0xAF]),       // XOR A (sets Z)
        (0x0005, &[0x28, 0x02]), // JR Z,+2 -> 0x0009 (taken)
        (0x0009, &[0x20, 0x02]), // JR NZ,+2 (not taken, Z still set)
        (0x000B, &[0x76]),       // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..6 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x000B");
    assert_eq!(new_cpu.registers().pc, 0x0C);
}

#[test]
fn sixteen_bit_and_exchange_ops_match_the_real_z80h_core() {
    // ADD HL,ss / EX DE,HL / EXX / LD (nn),HL / LD HL,(nn) / LD SP,HL --
    // all deliberately excluded from the random fuzzer because they
    // mutate HL directly (ADD HL,ss always writes back to HL regardless
    // of which ss was added; EX DE,HL/EXX would swap it away entirely),
    // which would break the fuzzer's "HL stays pinned to a safe scratch
    // address" invariant. Hand-written instead, same rigor, deterministic.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x21, 0xFF, 0x00]), // LD HL,0x00FF
        (0x0003, &[0x01, 0x01, 0x00]), // LD BC,0x0001
        (0x0006, &[0x09]),             // ADD HL,BC -> 0x0100 (half-carry)
        (0x0007, &[0xEB]),             // EX DE,HL -> DE=0x0100
        (0x0008, &[0x21, 0xFF, 0xFF]), // LD HL,0xFFFF
        (0x000B, &[0x29]),             // ADD HL,HL -> 0xFFFE, carry set
        (0x000C, &[0xD9]),             // EXX -> swaps BC/DE/HL with shadows
        (0x000D, &[0x22, 0x00, 0x80]), // LD (0x8000),HL
        (0x0010, &[0x2A, 0x00, 0x80]), // LD HL,(0x8000) -- round-trips
        (0x0013, &[0xF9]),             // LD SP,HL
        (0x0014, &[0x76]),             // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    // Give the shadow registers known, distinct values so EXX's swap is
    // actually observable rather than swapping zero into zero.
    let mut initial = Registers::default();
    initial.b_ = 0xAA;
    initial.c_ = 0xBB;
    initial.d_ = 0xCC;
    initial.e_ = 0xDD;
    initial.h_ = 0xEE;
    initial.l_ = 0x11;

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(initial, &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&initial, &mut reference_mem);

    for step in 0..12 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0014");
    // EXX (step 6) swaps HL with the shadow pair (h_=0xEE, l_=0x11) before
    // the LD(nn),HL/LD HL,(nn) round-trip and final LD SP,HL, so the
    // expected value here is the shadow HL, not the 0xFFFE computed
    // earlier -- confirmed via the step-by-step diff above, not asserted
    // blind.
    assert_eq!(new_cpu.registers().sp, 0xEE11, "LD SP,HL should have copied the final HL");
}

#[test]
fn ix_iy_control_flow_and_stack_ops_match_the_real_z80h_core() {
    // The DD/FD forms the random fuzzer's own DD/FD branch can't safely
    // cover: PUSH/POP (mutate SP), LD SP,IX (mutates SP), EX (SP),IX
    // (reads/writes the live stack), and JP (IY) (control flow) -- same
    // reasoning `sixteen_bit_and_exchange_ops_match_the_real_z80h_core`
    // already documents for the unprefixed equivalents of these ops.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x31, 0xFE, 0xFF]),       // LD SP,0xFFFE
        (0x0003, &[0xDD, 0x21, 0x00, 0x80]), // LD IX,0x8000
        (0x0007, &[0xDD, 0xE5]),             // PUSH IX -> SP=0xFFFC
        (0x0009, &[0xFD, 0xE1]),             // POP IY -> IY=0x8000, SP=0xFFFE
        (0x000B, &[0xDD, 0xF9]),             // LD SP,IX -> SP=0x8000
        (0x000D, &[0x31, 0xFE, 0xFF]),       // LD SP,0xFFFE (restore)
        (0x0010, &[0x21, 0x78, 0x56]),       // LD HL,0x5678
        (0x0013, &[0xE5]),                   // PUSH HL -> SP=0xFFFC, mem[FFFC..FFFE)=0x5678
        (0x0014, &[0xDD, 0x21, 0x34, 0x12]), // LD IX,0x1234
        (0x0018, &[0xDD, 0xE3]),             // EX (SP),IX -> IX=0x5678, stack now holds 0x1234
        (0x001A, &[0xFD, 0xE9]),             // JP (IY) -> jumps to 0x8000
        (0x8000, &[0x76]),                   // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..12 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x8000");
    assert_eq!(new_cpu.registers().ix, 0x5678, "EX (SP),IX should have swapped in the pushed HL value");
    assert_eq!(new_cpu.registers().iy, 0x8000, "POP IY should have recovered the pushed IX value");
    assert_eq!(new_cpu.registers().pc, 0x8001, "JP (IY) should have landed on the HALT at 0x8000");
}

#[test]
fn memory_indirect_loads_and_misc_singles_match_the_real_z80h_core() {
    // LD (BC),A / LD A,(BC) / LD (DE),A / LD A,(DE) / LD (nn),A / LD A,(nn)
    // -- excluded from the fuzzer because a random address operand could
    // write into the in-flight instruction stream, the same
    // self-corruption risk the fuzzer already avoids for HL. Also covers
    // JP (HL), RST, and DI/EI, none of which fit the straight-line-only
    // fuzzer either.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x01, 0x00, 0x90]), // LD BC,0x9000
        (0x0003, &[0x3E, 0x55]),       // LD A,0x55
        (0x0005, &[0x02]),             // LD (BC),A
        (0x0006, &[0x3E, 0x00]),       // LD A,0
        (0x0008, &[0x0A]),             // LD A,(BC) -> 0x55
        (0x0009, &[0x11, 0x01, 0x90]), // LD DE,0x9001
        (0x000C, &[0x12]),             // LD (DE),A
        (0x000D, &[0xAF]),             // XOR A
        (0x000E, &[0x1A]),             // LD A,(DE) -> 0x55
        (0x000F, &[0x32, 0x02, 0x90]), // LD (0x9002),A
        (0x0012, &[0xAF]),             // XOR A
        (0x0013, &[0x3A, 0x02, 0x90]), // LD A,(0x9002) -> 0x55
        (0x0016, &[0xF3]),             // DI
        (0x0017, &[0xFB]),             // EI
        (0x0018, &[0x21, 0x30, 0x00]), // LD HL,0x0030
        (0x001B, &[0xE9]),             // JP (HL) -> 0x0030
        (0x0030, &[0xFF]),             // RST 38h -> 0x0038
        (0x0038, &[0x76]),             // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..18 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0038 via RST 38h");
    assert_eq!(new_cpu.registers().a, 0x55);
    assert!(new_cpu.regs.iff1 && new_cpu.regs.iff2, "EI after DI should leave interrupts on");
}

#[test]
fn ed_accumulator_and_control_ops_match_the_real_z80h_core() {
    // LD I,A / LD A,I / LD R,A / LD A,R / NEG / IM 1 / CALL / RETN, with
    // IFF1 != IFF2 going in so RETN's "IFF1 = IFF2" copy is actually
    // observable rather than a no-op.
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x3E, 0x9F]),       // LD A,0x9F
        (0x0002, &[0xED, 0x47]),       // LD I,A
        (0x0004, &[0x3E, 0x00]),       // LD A,0
        (0x0006, &[0xED, 0x57]),       // LD A,I
        (0x0008, &[0x3E, 0x37]),       // LD A,0x37
        (0x000A, &[0xED, 0x4F]),       // LD R,A
        (0x000C, &[0x3E, 0x00]),       // LD A,0
        (0x000E, &[0xED, 0x5F]),       // LD A,R
        (0x0010, &[0xED, 0x44]),       // NEG
        (0x0012, &[0xED, 0x56]),       // IM 1
        (0x0014, &[0xCD, 0x30, 0x00]), // CALL 0x0030
        (0x0017, &[0x76]),             // HALT
        (0x0030, &[0xED, 0x45]),       // RETN
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut initial = Registers::default();
    initial.iff1 = false;
    initial.iff2 = true;

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(initial, &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&initial, &mut reference_mem);

    for step in 0..14 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0017 via RETN");
    assert_eq!(new_cpu.registers().im, 1);
    assert!(new_cpu.regs.iff1, "RETN should have copied IFF2 (true) into IFF1");
}

#[test]
fn ed_sixteen_bit_and_nibble_ops_match_the_real_z80h_core() {
    // ADC HL,ss / SBC HL,ss / RRD / RLD / LD (nn),dd / LD dd,(nn) -- the
    // ED-prefixed 16-bit forms, plus the BCD nibble-rotate pair.
    let mut mem_bytes = [0u8; 0x10000];
    mem_bytes[0x9000] = 0x34; // RRD/RLD operate on this byte
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x21, 0xFF, 0xFF]),       // LD HL,0xFFFF
        (0x0003, &[0x11, 0x01, 0x00]),       // LD DE,0x0001
        (0x0006, &[0x37]),                   // SCF
        (0x0007, &[0xED, 0x5A]),             // ADC HL,DE
        (0x0009, &[0x11, 0x00, 0x80]),       // LD DE,0x8000
        (0x000C, &[0xED, 0x52]),             // SBC HL,DE
        (0x000E, &[0x3E, 0x12]),             // LD A,0x12
        (0x0010, &[0x21, 0x00, 0x90]),       // LD HL,0x9000
        (0x0013, &[0xED, 0x67]),             // RRD
        (0x0015, &[0xED, 0x6F]),             // RLD
        (0x0017, &[0x01, 0xCD, 0xAB]),       // LD BC,0xABCD
        (0x001A, &[0xED, 0x43, 0x10, 0x90]), // LD (0x9010),BC
        (0x001E, &[0x11, 0x00, 0x00]),       // LD DE,0
        (0x0021, &[0xED, 0x5B, 0x10, 0x90]), // LD DE,(0x9010)
        (0x0025, &[0x76]),                   // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..16 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0025");
    assert_eq!(new_cpu.registers().de(), 0xABCD, "LD dd,(nn) should round-trip LD (nn),dd");
}

#[test]
fn ed_block_transfer_and_search_ops_match_the_real_z80h_core() {
    // LDIR (copies a 3-byte buffer) then CPIR (searches a 3-byte buffer
    // for a byte in the middle) -- both repeating forms, so this exercises
    // the "repeat vs fall through" PC-rewind logic, not just one iteration.
    let mut mem_bytes = [0u8; 0x10000];
    mem_bytes[0x9000..0x9003].copy_from_slice(&[0x11, 0x22, 0x33]);
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x21, 0x00, 0x90]), // LD HL,0x9000
        (0x0003, &[0x11, 0x00, 0x91]), // LD DE,0x9100
        (0x0006, &[0x01, 0x03, 0x00]), // LD BC,0x0003
        (0x0009, &[0xED, 0xB0]),       // LDIR
        (0x000B, &[0x21, 0x00, 0x90]), // LD HL,0x9000
        (0x000E, &[0x01, 0x03, 0x00]), // LD BC,0x0003
        (0x0011, &[0x3E, 0x22]),       // LD A,0x22 -- search target
        (0x0013, &[0xED, 0xB1]),       // CPIR
        (0x0015, &[0x76]),             // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..20 {
        new_cpu.step(&mut new_mem);
        reference.step(&mut reference_mem);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0015");
    assert_eq!(new_cpu.registers().bc(), 1, "CPIR should have stopped with BC=1 (found early)");
    assert_eq!(
        new_mem.read(0x9100),
        0x11,
        "LDIR should have copied the buffer's first byte to the destination"
    );
}

/// Steps `cpu` one whole instruction, servicing MREQ the normal way and
/// IORQ with a fixed `io_read_value` for every port read (a write's value
/// is discarded) -- `zx_core::Cpu::step()` doesn't service IORQ at all, so
/// this is the block-I/O-specific equivalent of it, mirroring
/// `ReferenceCpu::step_with_io()` exactly so both cores see identical port
/// behavior.
fn step_new_cpu_with_io(cpu: &mut Cpu, pins: u64, mem: &mut impl Memory, io_read_value: u8) -> u64 {
    use zx_core::pins::{get_addr, get_data, set_data, IORQ, MREQ, RD, WR};
    let mut pins = cpu.tick(pins);
    loop {
        if pins & IORQ != 0 {
            if pins & RD != 0 {
                pins = set_data(pins, io_read_value);
            }
        } else if pins & MREQ != 0 {
            let addr = get_addr(pins);
            if pins & RD != 0 {
                pins = set_data(pins, mem.read(addr));
            } else if pins & WR != 0 {
                mem.write(addr, get_data(pins));
            }
        }
        if cpu.is_instruction_boundary(pins) {
            return pins;
        }
        pins = cpu.tick(pins);
    }
}

#[test]
fn ed_block_io_ops_match_the_real_z80h_core() {
    // OTIR (writes a 3-byte buffer out to a port, B 3->0) then INIR (reads
    // 3 bytes from a port into a different buffer, B 3->0) -- both
    // repeating forms, so this exercises the "repeat vs fall through"
    // PC-rewind logic block_io_flags() shares with LDIR/CPIR, plus the
    // flag formula itself (untested until now: INI/IND/OUTI/OUTD and
    // their repeating forms were unimplemented before this).
    const IO_READ_VALUE: u8 = 0x5A;
    let mut mem_bytes = [0u8; 0x10000];
    mem_bytes[0x9000..0x9003].copy_from_slice(&[0xAA, 0xBB, 0xCC]);
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x21, 0x00, 0x90]), // LD HL,0x9000
        (0x0003, &[0x01, 0x41, 0x03]), // LD BC,0x0341 (B=3, C=0x41 -- port, arbitrary)
        (0x0006, &[0xED, 0xB3]),       // OTIR
        (0x0008, &[0x21, 0x00, 0x91]), // LD HL,0x9100
        (0x000B, &[0x01, 0x41, 0x03]), // LD BC,0x0341
        (0x000E, &[0xED, 0xB2]),       // INIR
        (0x0010, &[0x76]),             // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);
    let mut new_pins = new_cpu.pins();

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..20 {
        new_pins = step_new_cpu_with_io(&mut new_cpu, new_pins, &mut new_mem, IO_READ_VALUE);
        reference.step_with_io(&mut reference_mem, IO_READ_VALUE);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x0010");
    assert_eq!(new_cpu.registers().bc(), 0x0041, "OTIR/INIR should both have counted B down to 0, C left untouched");
    assert_eq!(
        new_mem.read(0x9100),
        IO_READ_VALUE,
        "INIR should have written the port's value into the destination buffer"
    );
}

#[test]
fn ed_single_shot_block_io_ops_match_the_real_z80h_core() {
    // The non-repeating siblings (INI, IND, OUTI, OUTD) -- a different
    // (shorter, no repeat-branch) mcycle shape than INIR/OTIR's own, so
    // this covers a genuinely different generated code path, not just the
    // same block_io_flags() call again.
    const IO_READ_VALUE: u8 = 0xC3;
    let mut mem_bytes = [0u8; 0x10000];
    let program: &[(u16, &[u8])] = &[
        (0x0000, &[0x21, 0x00, 0x90]), // LD HL,0x9000 -- INI destination
        (0x0003, &[0x01, 0x41, 0x05]), // LD BC,0x0541 (B=5, C=0x41 -- port, arbitrary)
        (0x0006, &[0xED, 0xA2]),       // INI (B->4)
        (0x0008, &[0x21, 0x10, 0x90]), // LD HL,0x9010 -- IND destination
        (0x000B, &[0xED, 0xAA]),       // IND (B->3)
        (0x000D, &[0x21, 0x20, 0x90]), // LD HL,0x9020 -- OUTI source
        (0x0010, &[0x36, 0x77]),       // LD (HL),0x77
        (0x0012, &[0xED, 0xA3]),       // OUTI (B->2)
        (0x0014, &[0x21, 0x30, 0x90]), // LD HL,0x9030 -- OUTD source
        (0x0017, &[0x36, 0x88]),       // LD (HL),0x88
        (0x0019, &[0xED, 0xAB]),       // OUTD (B->1)
        (0x001B, &[0x76]),             // HALT
    ];
    for (addr, bytes) in program {
        let start = *addr as usize;
        mem_bytes[start..start + bytes.len()].copy_from_slice(bytes);
    }

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);
    let mut new_pins = new_cpu.pins();

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    for step in 0..20 {
        new_pins = step_new_cpu_with_io(&mut new_cpu, new_pins, &mut new_mem, IO_READ_VALUE);
        reference.step_with_io(&mut reference_mem, IO_READ_VALUE);

        if let Some(detail) = diff(&new_cpu.registers(), &reference.registers()) {
            panic!("step {step}: registers diverged from the real z80.h core\n{detail}");
        }
    }
    assert!(new_cpu.halted, "program should have reached HALT at 0x001B");
    assert_eq!(new_cpu.registers().bc(), 0x0141, "INI/IND/OUTI/OUTD should each have decremented B once, C left untouched");
    assert_eq!(new_mem.read(0x9000), IO_READ_VALUE, "INI should have written the port's value to (HL)");
    assert_eq!(new_mem.read(0x9010), IO_READ_VALUE, "IND should have written the port's value to (HL)");
}
