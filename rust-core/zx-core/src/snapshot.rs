//! `.sna` snapshot loading (48K, fixed 49179-byte layout). Ported from
//! `zxspectrum/core/snapshot.py`.
//!
//! `.sna` has no PC field -- the format represents a machine paused as if
//! by a RETN, so PC lives on top of the stack at `[SP]` and must be popped
//! (`SP += 2`) during load.

use crate::memory::RAM_SIZE;
use crate::registers::Registers;

pub const HEADER_SIZE: usize = 27;
pub const SNA_48K_SIZE: usize = HEADER_SIZE + RAM_SIZE;

pub struct SnaImage {
    pub regs: Registers,
    pub border: u8,
    /// 49152 bytes covering 0x4000-0xFFFF.
    pub ram: Vec<u8>,
}

fn word(lo: u8, hi: u8) -> u16 {
    (lo as u16) | ((hi as u16) << 8)
}

pub fn parse_sna(data: &[u8]) -> Result<SnaImage, String> {
    if data.len() != SNA_48K_SIZE {
        return Err(format!(
            ".sna must be exactly {SNA_48K_SIZE} bytes (48K, no header), got {}",
            data.len()
        ));
    }
    let hdr = &data[..HEADER_SIZE];
    let ram = data[HEADER_SIZE..].to_vec();

    let iff1 = hdr[19] & 0x04 != 0;
    let sp = word(hdr[23], hdr[24]);

    let mut regs = Registers {
        i: hdr[0],
        l_: hdr[1],
        h_: hdr[2],
        e_: hdr[3],
        d_: hdr[4],
        c_: hdr[5],
        b_: hdr[6],
        f_: hdr[7],
        a_: hdr[8],
        l: hdr[9],
        h: hdr[10],
        e: hdr[11],
        d: hdr[12],
        c: hdr[13],
        b: hdr[14],
        iy: word(hdr[15], hdr[16]),
        ix: word(hdr[17], hdr[18]),
        iff1,
        iff2: iff1,
        r: hdr[20],
        f: hdr[21],
        a: hdr[22],
        sp,
        pc: 0,
        im: hdr[25],
        wz: 0,
    };
    let border = hdr[26] & 0x07;

    // Pop PC off the stack (the defining quirk of .sna).
    let stack_offset = sp.wrapping_sub(0x4000) as usize;
    if stack_offset + 1 >= ram.len() {
        return Err(format!(".sna SP=0x{sp:04X} does not point into RAM; can't pop PC"));
    }
    regs.pc = (ram[stack_offset] as u16) | ((ram[stack_offset + 1] as u16) << 8);
    regs.sp = sp.wrapping_add(2);

    Ok(SnaImage { regs, border, ram })
}
