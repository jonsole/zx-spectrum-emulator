//! Z80 disassembler -- decodes bytes into mnemonic text. Ported near-
//! verbatim from `zxspectrum/core/disassembler.py`, which backs DAP's
//! `disassemble` request. Implements the documented Z80 instruction set via
//! the standard bit-field decomposition of the opcode byte (x/y/z/p/q --
//! see http://www.z80.info/decoding.htm), covering unprefixed, CB, ED, DD,
//! FD, and the DD CB d / FD CB d double-prefixed forms. Undocumented
//! opcodes that don't correspond to a documented instruction decode as a
//! raw `DEFB` byte.
//!
//! This module only decodes bytes into text -- it doesn't know about
//! breakpoints, PC, or the running machine; callers pass a `read(addr) ->
//! u8` callable (typically bound to a live memory snapshot) and a start
//! address.

const R: [&str; 8] = ["B", "C", "D", "E", "H", "L", "(HL)", "A"];
const RP: [&str; 4] = ["BC", "DE", "HL", "SP"];
const RP2: [&str; 4] = ["BC", "DE", "HL", "AF"];
const CC: [&str; 8] = ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"];
const ALU: [&str; 8] = ["ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP "];
const ROT: [&str; 8] = ["RLC ", "RRC ", "RL ", "RR ", "SLA ", "SRA ", "SLL ", "SRL "];
const IM: [u8; 8] = [0, 0, 1, 2, 0, 0, 1, 2];

fn block_name(z: u8, y: u8) -> &'static str {
    const BLOCK: [[&str; 4]; 4] = [
        ["LDI", "LDD", "LDIR", "LDDR"],
        ["CPI", "CPD", "CPIR", "CPDR"],
        ["INI", "IND", "INIR", "INDR"],
        ["OUTI", "OUTD", "OTIR", "OTDR"],
    ];
    BLOCK[z as usize][(y - 4) as usize]
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instruction {
    pub addr: u16,
    pub length: u8,
    pub text: String,
    pub raw: Vec<u8>,
}

fn signed8(v: u8) -> i8 {
    v as i8
}

/// Reads successive bytes starting at `addr` (wrapping at the 64K address
/// space, mirroring Python's `self._read(self.pos & 0xFFFF)`), tracking how
/// many were consumed.
struct Cursor {
    start: u16,
    pos: u16,
}

impl Cursor {
    fn new(addr: u16) -> Self {
        Cursor { start: addr, pos: addr }
    }

    fn byte(&mut self, read: &impl Fn(u16) -> u8) -> u8 {
        let v = read(self.pos);
        self.pos = self.pos.wrapping_add(1);
        v
    }

    fn word(&mut self, read: &impl Fn(u16) -> u8) -> u16 {
        let lo = self.byte(read);
        let hi = self.byte(read);
        (lo as u16) | ((hi as u16) << 8)
    }

    fn length(&self) -> u8 {
        self.pos.wrapping_sub(self.start) as u8
    }
}

pub fn disassemble_one(read: &impl Fn(u16) -> u8, addr: u16) -> Instruction {
    let mut c = Cursor::new(addr);
    let text = decode(&mut c, read, None);
    let length = c.length();
    let raw = (0..length).map(|i| read(addr.wrapping_add(i as u16))).collect();
    Instruction { addr, length, text, raw }
}

/// Decode `count` consecutive instructions starting at `addr`.
pub fn disassemble_range(read: &impl Fn(u16) -> u8, addr: u16, count: usize) -> Vec<Instruction> {
    let mut out = Vec::with_capacity(count);
    let mut a = addr;
    for _ in 0..count {
        let inst = disassemble_one(read, a);
        a = a.wrapping_add(inst.length as u16);
        out.push(inst);
    }
    out
}

fn decode(c: &mut Cursor, read: &impl Fn(u16) -> u8, index: Option<&'static str>) -> String {
    let op = c.byte(read);

    if op == 0xCB {
        // Under a DD/FD prefix this is the DD CB d op / FD CB d op form --
        // `index` must carry through so decode_cb knows to read a
        // displacement byte and target (IX+d)/(IY+d) instead of a plain r.
        return decode_cb(c, read, index);
    }
    if op == 0xED {
        return decode_ed(c, read);
    }
    if op == 0xDD {
        return decode(c, read, Some("IX"));
    }
    if op == 0xFD {
        return decode(c, read, Some("IY"));
    }

    let x = op >> 6;
    let y = (op >> 3) & 0x07;
    let z = op & 0x07;
    let p = (y >> 1) as usize;
    let q = y & 0x01;

    let rp = |i: usize| -> String {
        if let Some(idx) = index {
            if i == 2 {
                return idx.to_string();
            }
        }
        RP[i].to_string()
    };

    // (HL) becomes (IX+d)/(IY+d) under a DD/FD prefix; H/L become the
    // undocumented IXH/IXL/IYH/IYL only when NOT the (HL) memory slot.
    // A nested `fn` (not a closure) since closures can't take an
    // `impl Trait` parameter -- `index` is threaded through explicitly at
    // each call site instead of captured.
    fn rr(
        i: u8,
        c: &mut Cursor,
        read: &impl Fn(u16) -> u8,
        index: Option<&'static str>,
    ) -> String {
        let Some(idx) = index else {
            return R[i as usize].to_string();
        };
        if i == 6 {
            let d = signed8(c.byte(read));
            let sign = if d >= 0 { "+" } else { "-" };
            return format!("({idx}{sign}{})", (d as i16).abs());
        }
        if i == 4 {
            return format!("{idx}H");
        }
        if i == 5 {
            return format!("{idx}L");
        }
        R[i as usize].to_string()
    }

    if x == 0 {
        if z == 0 {
            if y == 0 {
                return "NOP".to_string();
            }
            if y == 1 {
                return "EX AF,AF'".to_string();
            }
            if y == 2 {
                let d = signed8(c.byte(read));
                return format!("DJNZ ${}", addr_rel(c, d));
            }
            if y == 3 {
                let d = signed8(c.byte(read));
                return format!("JR ${}", addr_rel(c, d));
            }
            let d = signed8(c.byte(read));
            return format!("JR {},${}", CC[(y - 4) as usize], addr_rel(c, d));
        }
        if z == 1 {
            if q == 0 {
                let nn = c.word(read);
                return format!("LD {},0x{nn:04X}", rp(p));
            }
            return format!("ADD {},{}", index.unwrap_or("HL"), rp(p));
        }
        if z == 2 {
            if q == 0 {
                if p == 0 {
                    return "LD (BC),A".to_string();
                }
                if p == 1 {
                    return "LD (DE),A".to_string();
                }
                if p == 2 {
                    let nn = c.word(read);
                    return format!("LD (0x{nn:04X}),{}", index.unwrap_or("HL"));
                }
                let nn = c.word(read);
                return format!("LD (0x{nn:04X}),A");
            }
            if p == 0 {
                return "LD A,(BC)".to_string();
            }
            if p == 1 {
                return "LD A,(DE)".to_string();
            }
            if p == 2 {
                let nn = c.word(read);
                return format!("LD {},(0x{nn:04X})", index.unwrap_or("HL"));
            }
            let nn = c.word(read);
            return format!("LD A,(0x{nn:04X})");
        }
        if z == 3 {
            return format!("{} {}", if q == 0 { "INC" } else { "DEC" }, rp(p));
        }
        if z == 4 {
            return format!("INC {}", rr(y, c, read, index));
        }
        if z == 5 {
            return format!("DEC {}", rr(y, c, read, index));
        }
        if z == 6 {
            let dest = rr(y, c, read, index);
            let n = c.byte(read);
            return format!("LD {dest},0x{n:02X}");
        }
        // z == 7
        return ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"][y as usize].to_string();
    }

    if x == 1 {
        if z == 6 && y == 6 {
            return "HALT".to_string();
        }
        if index.is_some() && (y == 6 || z == 6) {
            // A genuine (IX+d)/(IY+d) memory access is involved -- these are
            // the DOCUMENTED "LD r,(IX+d)"/"LD (IX+d),r" instructions, where
            // r=H or r=L means the REAL H/L register, not IXH/IXL. (The
            // undocumented IXH/IXL substitution only applies to *pure*
            // register-to-register moves, handled by the rr() branch below.)
            let idx = index.unwrap();
            let d = signed8(c.byte(read));
            let sign = if d >= 0 { "+" } else { "-" };
            let mem = format!("({idx}{sign}{})", (d as i16).abs());
            return if y == 6 {
                format!("LD {mem},{}", R[z as usize])
            } else {
                format!("LD {},{mem}", R[y as usize])
            };
        }
        let dest = rr(y, c, read, index); // evaluated before the source: at most one
        return format!("LD {dest},{}", rr(z, c, read, index)); // of y/z can be 6 here
    }

    if x == 2 {
        return format!("{}{}", ALU[y as usize], rr(z, c, read, index));
    }

    // x == 3
    if z == 0 {
        return format!("RET {}", CC[y as usize]);
    }
    if z == 1 {
        if q == 0 {
            return format!("POP {}", if p == 2 && index.is_some() { index.unwrap() } else { RP2[p] });
        }
        if p == 0 {
            return "RET".to_string();
        }
        if p == 1 {
            return "EXX".to_string();
        }
        if p == 2 {
            return format!("JP ({})", index.unwrap_or("HL"));
        }
        return format!("LD SP,{}", index.unwrap_or("HL"));
    }
    if z == 2 {
        let nn = c.word(read);
        return format!("JP {},0x{nn:04X}", CC[y as usize]);
    }
    if z == 3 {
        if y == 0 {
            let nn = c.word(read);
            return format!("JP 0x{nn:04X}");
        }
        // y == 1 (opcode 0xCB) is unreachable here -- it's intercepted at
        // the top of decode() before the x/y/z decomposition, since it
        // needs to consume a displacement byte first under DD/FD.
        if y == 2 {
            let n = c.byte(read);
            return format!("OUT (0x{n:02X}),A");
        }
        if y == 3 {
            let n = c.byte(read);
            return format!("IN A,(0x{n:02X})");
        }
        if y == 4 {
            return format!("EX (SP),{}", index.unwrap_or("HL"));
        }
        if y == 5 {
            return "EX DE,HL".to_string();
        }
        if y == 6 {
            return "DI".to_string();
        }
        return "EI".to_string();
    }
    if z == 4 {
        let nn = c.word(read);
        return format!("CALL {},0x{nn:04X}", CC[y as usize]);
    }
    if z == 5 {
        if q == 0 {
            return format!("PUSH {}", if p == 2 && index.is_some() { index.unwrap() } else { RP2[p] });
        }
        if p == 0 {
            let nn = c.word(read);
            return format!("CALL 0x{nn:04X}");
        }
        if p == 1 {
            return decode(c, read, Some("IX"));
        }
        if p == 2 {
            return decode_ed(c, read);
        }
        return decode(c, read, Some("IY"));
    }
    if z == 6 {
        let n = c.byte(read);
        return format!("{}0x{n:02X}", ALU[y as usize]);
    }
    // z == 7
    format!("RST 0x{:02X}", y * 8)
}

fn addr_rel(c: &Cursor, displacement: i8) -> String {
    format!("0x{:04X}", c.pos.wrapping_add_signed(displacement as i16))
}

fn decode_cb(c: &mut Cursor, read: &impl Fn(u16) -> u8, index: Option<&'static str>) -> String {
    let (op, target) = if let Some(idx) = index {
        let d = signed8(c.byte(read));
        let op = c.byte(read);
        let sign = if d >= 0 { "+" } else { "-" };
        (op, format!("({idx}{sign}{})", (d as i16).abs()))
    } else {
        let op = c.byte(read);
        (op, R[(op & 0x07) as usize].to_string())
    };

    let x = op >> 6;
    let y = (op >> 3) & 0x07;
    let z = op & 0x07;

    let mut text = if x == 0 {
        format!("{}{target}", ROT[y as usize])
    } else if x == 1 {
        return format!("BIT {y},{target}"); // BIT never writes back, so no undoc copy form
    } else if x == 2 {
        format!("RES {y},{target}")
    } else {
        format!("SET {y},{target}")
    };

    // DD CB d/FD CB d forms where the low 3 bits aren't the (IX+d) slot
    // itself are undocumented: they also copy the result into R[z].
    if index.is_some() && z != 6 {
        text.push_str(&format!(",{}", R[z as usize]));
    }
    text
}

fn decode_ed(c: &mut Cursor, read: &impl Fn(u16) -> u8) -> String {
    let op = c.byte(read);
    let x = op >> 6;
    let y = (op >> 3) & 0x07;
    let z = op & 0x07;
    let p = (y >> 1) as usize;
    let q = y & 0x01;

    if x == 1 {
        if z == 0 {
            return if y == 6 { "IN (C)".to_string() } else { format!("IN {},(C)", R[y as usize]) };
        }
        if z == 1 {
            return if y == 6 { "OUT (C),0".to_string() } else { format!("OUT (C),{}", R[y as usize]) };
        }
        if z == 2 {
            return format!("{} HL,{}", if q == 0 { "SBC" } else { "ADC" }, RP[p]);
        }
        if z == 3 {
            let nn = c.word(read);
            return if q == 0 {
                format!("LD (0x{nn:04X}),{}", RP[p])
            } else {
                format!("LD {},(0x{nn:04X})", RP[p])
            };
        }
        if z == 4 {
            return "NEG".to_string();
        }
        if z == 5 {
            return if y == 1 { "RETI".to_string() } else { "RETN".to_string() };
        }
        if z == 6 {
            return format!("IM {}", IM[y as usize]);
        }
        if z == 7 {
            return ["LD I,A", "LD R,A", "LD A,I", "LD A,R", "RRD", "RLD", "NOP", "NOP"][y as usize]
                .to_string();
        }
    }

    if x == 2 && z <= 3 && y >= 4 {
        return block_name(z, y).to_string();
    }

    format!("DEFB 0xED,0x{op:02X}")
}

// Every 16-bit address-shaped operand this module emits is formatted as
// exactly 4 uppercase hex digits (0x{:04X}) -- jump/call targets, (nn)
// memory operands, and 16-bit LD immediates. 8-bit immediates, I/O ports,
// and RST vectors use 2 digits and never match, which is what keeps this
// from misfiring on those. A trailing ")" is captured separately so a
// memory-indirect operand like "(0x5C0E)" gets annotated as
// "(0x5C0E) (TVDATA)" -- the label after the closing paren, not nested
// inside it. Hand-rolled rather than the `regex` crate: `zx-core` is meant
// to stay wasm-clean and dependency-light, and the pattern (literal "0x"
// + exactly 4 hex digits + a word boundary) is simple enough to scan by
// hand without real risk of drifting from the reference behavior.
fn is_hex_digit(b: u8) -> bool {
    b.is_ascii_digit() || (b'A'..=b'F').contains(&b)
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Append a resolved symbol name after every 4-hex-digit address in `text`,
/// e.g. "CALL 0x8000" -> "CALL 0x8000 (START)", "LD HL,0x4567" -> "LD
/// HL,0x4567 (MY_TABLE+4)", "LD HL,(0x5C0E)" -> "LD HL,(0x5C0E) (TVDATA)".
/// `resolve` is typically `RomSource::symbol_at` bound to a caller's active
/// debug sources, passed as a callback so this module stays free of any
/// dependency on the (server-side) source/symbol machinery.
pub fn annotate_symbols(text: &str, resolve: impl Fn(u16) -> Option<(String, u16)>) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'0' && i + 1 < bytes.len() && bytes[i + 1] == b'x' {
            let hex_start = i + 2;
            let hex_end = hex_start + 4;
            if hex_end <= bytes.len()
                && bytes[hex_start..hex_end].iter().all(|&b| is_hex_digit(b))
                && !(hex_end < bytes.len() && is_word_byte(bytes[hex_end]))
            {
                let addr = u16::from_str_radix(&text[hex_start..hex_end], 16).unwrap();
                let closing_paren = hex_end < bytes.len() && bytes[hex_end] == b')';
                out.push_str(&text[i..hex_end]);
                if let Some((name, offset)) = resolve(addr) {
                    if closing_paren {
                        out.push(')');
                    }
                    out.push_str(" (");
                    out.push_str(&name);
                    if offset != 0 {
                        out.push('+');
                        out.push_str(&offset.to_string());
                    }
                    out.push(')');
                } else if closing_paren {
                    out.push(')');
                }
                i = hex_end + if closing_paren { 1 } else { 0 };
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}
