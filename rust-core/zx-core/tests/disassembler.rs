//! `disassembler` tests, ported directly from `tests/test_disassembler.py`
//! (same cases, same expected strings) -- this module is a mechanical
//! translation of `disassembler.py`, so verifying it against the exact same
//! fixture set the Python version already proved correct is the right bar,
//! not a re-derivation from the Z80 spec.

use std::cell::RefCell;
use zx_core::{annotate_symbols, disassemble_one, disassemble_range, Instruction};

fn mem(data: &[u8], base: u16) -> impl Fn(u16) -> u8 {
    let mut buf = vec![0u8; 0x10000];
    buf[base as usize..base as usize + data.len()].copy_from_slice(data);
    move |addr: u16| buf[addr as usize]
}

fn dis(data: &[u8], addr: u16) -> Instruction {
    disassemble_one(&mem(data, addr), addr)
}

#[test]
fn basic_instructions() {
    let cases: &[(&[u8], &str, u8)] = &[
        (&[0x00], "NOP", 1),
        (&[0x76], "HALT", 1),
        (&[0x3E, 0x42], "LD A,0x42", 2),
        (&[0x47], "LD B,A", 1),
        (&[0x21, 0x34, 0x12], "LD HL,0x1234", 3),
        (&[0xC3, 0x00, 0x80], "JP 0x8000", 3),
        (&[0xCD, 0x00, 0x80], "CALL 0x8000", 3),
        (&[0xC9], "RET", 1),
        (&[0xF3], "DI", 1),
        (&[0xFB], "EI", 1),
        (&[0xAF], "XOR A", 1),
        (&[0x80], "ADD A,B", 1),
        (&[0xFE, 0x10], "CP 0x10", 2),
        (&[0xC5], "PUSH BC", 1),
        (&[0xE1], "POP HL", 1),
        (&[0x09], "ADD HL,BC", 1),
        (&[0x23], "INC HL", 1),
        (&[0x3C], "INC A", 1),
        (&[0x2A, 0x00, 0x5C], "LD HL,(0x5C00)", 3),
        (&[0x32, 0x00, 0x40], "LD (0x4000),A", 3),
        (&[0xD3, 0xFE], "OUT (0xFE),A", 2),
        (&[0xDB, 0xFE], "IN A,(0xFE)", 2),
        (&[0xF7], "RST 0x30", 1),
    ];
    for (data, expected_text, expected_len) in cases {
        let inst = dis(data, 0);
        assert_eq!(&inst.text, expected_text, "{data:02X?} -> {:?}", inst.text);
        assert_eq!(inst.length, *expected_len);
    }
}

#[test]
fn relative_jumps_compute_absolute_target() {
    // JR +5 from address 0x8000: target = 0x8000 + 2 (instruction length) + 5
    let inst = dis(&[0x18, 0x05], 0x8000);
    assert_eq!(inst.text, "JR $0x8007");
    assert_eq!(inst.length, 2);

    // JR -3 (0xFD as signed = -3): target = addr + 2 - 3
    let inst = dis(&[0x18, 0xFD], 0x8000);
    assert_eq!(inst.text, "JR $0x7FFF");
}

#[test]
fn cb_prefixed() {
    let cases: &[(&[u8], &str, u8)] = &[
        (&[0xCB, 0x00], "RLC B", 2),
        (&[0xCB, 0x47], "BIT 0,A", 2),
        (&[0xCB, 0x86], "RES 0,(HL)", 2),
        (&[0xCB, 0xFF], "SET 7,A", 2),
        (&[0xCB, 0x27], "SLA A", 2),
    ];
    for (data, expected_text, expected_len) in cases {
        let inst = dis(data, 0);
        assert_eq!(&inst.text, expected_text);
        assert_eq!(inst.length, *expected_len);
    }
}

#[test]
fn ed_prefixed() {
    let cases: &[(&[u8], &str, u8)] = &[
        (&[0xED, 0x44], "NEG", 2),
        (&[0xED, 0x4D], "RETI", 2),
        (&[0xED, 0x45], "RETN", 2),
        (&[0xED, 0x46], "IM 0", 2),
        (&[0xED, 0x56], "IM 1", 2),
        (&[0xED, 0x5E], "IM 2", 2),
        (&[0xED, 0xB0], "LDIR", 2),
        (&[0xED, 0xA0], "LDI", 2),
        (&[0xED, 0xB8], "LDDR", 2),
        (&[0xED, 0x42], "SBC HL,BC", 2),
        (&[0xED, 0x4A], "ADC HL,BC", 2),
        (&[0xED, 0x43, 0x00, 0x80], "LD (0x8000),BC", 4),
        (&[0xED, 0x47], "LD I,A", 2),
        (&[0xED, 0x57], "LD A,I", 2),
        // The specific opcode that panicked the whole server against real
        // Manic Miner gameplay before this pass (ED 58 = IN E,(C)) -- and
        // its sibling OUT (C),r -- covered here at the disassembler level
        // too (the CPU-level behavior is covered separately in
        // zx-core/tests/spectrum.rs).
        (&[0xED, 0x58], "IN E,(C)", 2),
        (&[0xED, 0x70], "IN (C)", 2),
        (&[0xED, 0x59], "OUT (C),E", 2),
        (&[0xED, 0x71], "OUT (C),0", 2),
    ];
    for (data, expected_text, expected_len) in cases {
        let inst = dis(data, 0);
        assert_eq!(&inst.text, expected_text);
        assert_eq!(inst.length, *expected_len);
    }
}

#[test]
fn dd_ix_prefixed() {
    let cases: &[(&[u8], &str, u8)] = &[
        (&[0xDD, 0x21, 0x00, 0x80], "LD IX,0x8000", 4),
        (&[0xDD, 0x7E, 0x05], "LD A,(IX+5)", 3),
        (&[0xDD, 0x77, 0xFB], "LD (IX-5),A", 3),
        (&[0xDD, 0x23], "INC IX", 2),
        (&[0xDD, 0xE1], "POP IX", 2),
        (&[0xDD, 0xE5], "PUSH IX", 2),
        (&[0xDD, 0x64], "LD IXH,IXH", 2),
        (&[0xFD, 0x21, 0x00, 0x80], "LD IY,0x8000", 4),
        (&[0xFD, 0x6E, 0x02], "LD L,(IY+2)", 3),
    ];
    for (data, expected_text, expected_len) in cases {
        let inst = dis(data, 0);
        assert_eq!(&inst.text, expected_text);
        assert_eq!(inst.length, *expected_len);
    }
}

#[test]
fn dd_cb_displacement_bit_ops() {
    // DD CB d op: RLC (IX+3)
    let inst = dis(&[0xDD, 0xCB, 0x03, 0x06], 0);
    assert_eq!(inst.text, "RLC (IX+3)");
    assert_eq!(inst.length, 4);

    // BIT 5,(IX+3) -- never has an undocumented copy-to-register suffix
    let inst = dis(&[0xDD, 0xCB, 0x03, 0x6E], 0);
    assert_eq!(inst.text, "BIT 5,(IX+3)");

    // SET 0,(IY-2) with the undocumented copy into B
    let inst = dis(&[0xFD, 0xCB, 0xFE, 0xC0], 0);
    assert_eq!(inst.text, "SET 0,(IY-2),B");
}

#[test]
fn disassemble_range_walks_variable_length_instructions() {
    let program = [0x00, 0x3E, 0x42, 0xC3, 0x00, 0x80]; // NOP; LD A,n; JP nn
    let instructions = disassemble_range(&mem(&program, 0), 0, 3);
    let texts: Vec<&str> = instructions.iter().map(|i| i.text.as_str()).collect();
    assert_eq!(texts, ["NOP", "LD A,0x42", "JP 0x8000"]);
    let addrs: Vec<u16> = instructions.iter().map(|i| i.addr).collect();
    assert_eq!(addrs, [0, 1, 3]);
}

#[test]
fn annotate_symbols_appends_exact_match_with_no_offset() {
    let resolve = |addr: u16| (addr == 0x8000).then(|| ("MY_ROUTINE".to_string(), 0));
    assert_eq!(annotate_symbols("CALL 0x8000", resolve), "CALL 0x8000 (MY_ROUTINE)");
}

#[test]
fn annotate_symbols_appends_offset_when_not_exactly_on_the_symbol() {
    let resolve = |addr: u16| (addr == 0x4567).then(|| ("MY_TABLE".to_string(), 4));
    assert_eq!(annotate_symbols("LD HL,0x4567", resolve), "LD HL,0x4567 (MY_TABLE+4)");
}

#[test]
fn annotate_symbols_leaves_text_unchanged_when_unresolved() {
    assert_eq!(annotate_symbols("CALL 0x8000", |_| None), "CALL 0x8000");
}

#[test]
fn annotate_symbols_ignores_2_digit_operands() {
    // 8-bit immediates/ports/RST vectors are never wide enough to look
    // like a 4-hex-digit address, so a resolver that would match anything
    // must never be consulted for them.
    let called = RefCell::new(false);
    let resolve = |_addr: u16| {
        *called.borrow_mut() = true;
        Some(("SHOULD_NOT_MATCH".to_string(), 0))
    };
    assert_eq!(annotate_symbols("OUT (0xFE),A", &resolve), "OUT (0xFE),A");
    assert_eq!(annotate_symbols("RST 0x30", &resolve), "RST 0x30");
    assert!(!*called.borrow());
}

#[test]
fn annotate_symbols_handles_multiple_addresses_in_one_instruction() {
    let resolve = |addr: u16| match addr {
        0x8000 => Some(("SRC".to_string(), 0)),
        0x9000 => Some(("DST".to_string(), 0)),
        _ => None,
    };
    assert_eq!(
        annotate_symbols("LD (0x9000),0x8000", resolve),
        "LD (0x9000) (DST),0x8000 (SRC)"
    );
}

#[test]
fn annotate_symbols_labels_memory_indirect_operand_after_the_closing_paren() {
    // "(0x5C0E)" -- a memory-indirect operand -- should annotate as
    // "(0x5C0E) (TVDATA)", not the more confusing "(0x5C0E (TVDATA))".
    let resolve = |addr: u16| (addr == 0x5C0E).then(|| ("TVDATA".to_string(), 0));
    assert_eq!(annotate_symbols("LD HL,(0x5C0E)", resolve), "LD HL,(0x5C0E) (TVDATA)");
}

#[test]
fn real_rom_reset_vector_matches_known_disassembly() {
    // The first bytes of every genuine Sinclair 48K ROM: DI; XOR A; LD DE,0xFFFF; JP 0x11CB
    let rom_start = [0xF3, 0xAF, 0x11, 0xFF, 0xFF, 0xC3, 0xCB, 0x11];
    let instructions = disassemble_range(&mem(&rom_start, 0), 0, 4);
    let texts: Vec<&str> = instructions.iter().map(|i| i.text.as_str()).collect();
    assert_eq!(texts, ["DI", "XOR A", "LD DE,0xFFFF", "JP 0x11CB"]);
}
