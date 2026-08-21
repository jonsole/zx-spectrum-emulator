//! Bit positions within the Z80 flags register (`Registers::f`).

pub const FLAG_C: u8 = 1 << 0;
pub const FLAG_N: u8 = 1 << 1;
pub const FLAG_PV: u8 = 1 << 2;
pub const FLAG_3: u8 = 1 << 3;
pub const FLAG_H: u8 = 1 << 4;
pub const FLAG_5: u8 = 1 << 5;
pub const FLAG_Z: u8 = 1 << 6;
pub const FLAG_S: u8 = 1 << 7;
