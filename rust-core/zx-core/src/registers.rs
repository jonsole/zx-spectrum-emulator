/// Z80 register file, including the shadow (alternate) register set and
/// the two index registers. Flags are kept as a raw byte (`f`) rather than
/// individual bools, matching how the real hardware and the Python core's
/// `regs.af` view both treat it -- bit layout is defined in `flags.rs`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Registers {
    pub a: u8,
    pub f: u8,
    pub b: u8,
    pub c: u8,
    pub d: u8,
    pub e: u8,
    pub h: u8,
    pub l: u8,

    pub a_: u8,
    pub f_: u8,
    pub b_: u8,
    pub c_: u8,
    pub d_: u8,
    pub e_: u8,
    pub h_: u8,
    pub l_: u8,

    pub ix: u16,
    pub iy: u16,
    pub sp: u16,
    pub pc: u16,

    pub i: u8,
    pub r: u8,
    pub iff1: bool,
    pub iff2: bool,
    pub im: u8,

    /// The internal "MEMPTR" register -- not documented, not directly
    /// readable by any instruction, but several instructions (JP/CALL/
    /// RET, the block instructions, indirect loads, ...) write it as a
    /// side effect, and it feeds a handful of undocumented flag bits
    /// (particularly for CB-prefixed `BIT` on `(HL)`, not implemented
    /// yet). Tracked here so the tick-based core can reproduce it.
    pub wz: u16,
}

impl Registers {
    pub fn af(&self) -> u16 {
        ((self.a as u16) << 8) | self.f as u16
    }

    pub fn set_af(&mut self, value: u16) {
        self.a = (value >> 8) as u8;
        self.f = value as u8;
    }

    pub fn bc(&self) -> u16 {
        ((self.b as u16) << 8) | self.c as u16
    }

    pub fn set_bc(&mut self, value: u16) {
        self.b = (value >> 8) as u8;
        self.c = value as u8;
    }

    pub fn de(&self) -> u16 {
        ((self.d as u16) << 8) | self.e as u16
    }

    pub fn set_de(&mut self, value: u16) {
        self.d = (value >> 8) as u8;
        self.e = value as u8;
    }

    pub fn hl(&self) -> u16 {
        ((self.h as u16) << 8) | self.l as u16
    }

    pub fn set_hl(&mut self, value: u16) {
        self.h = (value >> 8) as u8;
        self.l = value as u8;
    }

    pub fn wzl(&self) -> u8 {
        self.wz as u8
    }

    pub fn set_wzl(&mut self, value: u8) {
        self.wz = (self.wz & 0xFF00) | value as u16;
    }

    pub fn wzh(&self) -> u8 {
        (self.wz >> 8) as u8
    }

    pub fn set_wzh(&mut self, value: u8) {
        self.wz = (self.wz & 0x00FF) | ((value as u16) << 8);
    }

    pub fn spl(&self) -> u8 {
        self.sp as u8
    }

    pub fn set_spl(&mut self, value: u8) {
        self.sp = (self.sp & 0xFF00) | value as u16;
    }

    pub fn sph(&self) -> u8 {
        (self.sp >> 8) as u8
    }

    pub fn set_sph(&mut self, value: u8) {
        self.sp = (self.sp & 0x00FF) | ((value as u16) << 8);
    }

    pub fn ixh(&self) -> u8 {
        (self.ix >> 8) as u8
    }

    pub fn set_ixh(&mut self, value: u8) {
        self.ix = (self.ix & 0x00FF) | ((value as u16) << 8);
    }

    pub fn ixl(&self) -> u8 {
        self.ix as u8
    }

    pub fn set_ixl(&mut self, value: u8) {
        self.ix = (self.ix & 0xFF00) | value as u16;
    }

    pub fn iyh(&self) -> u8 {
        (self.iy >> 8) as u8
    }

    pub fn set_iyh(&mut self, value: u8) {
        self.iy = (self.iy & 0x00FF) | ((value as u16) << 8);
    }

    pub fn iyl(&self) -> u8 {
        self.iy as u8
    }

    pub fn set_iyl(&mut self, value: u8) {
        self.iy = (self.iy & 0xFF00) | value as u16;
    }
}
