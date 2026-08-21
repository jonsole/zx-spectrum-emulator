/// Bus the CPU reads/writes through. A real machine (48K memory map, ROM
/// protection, contended timing) implements this later; `FlatMemory` below
/// is just enough to exercise the CPU in isolation, same role as the bare
/// `bytearray` the Python core's step-1 smoke test used directly.
pub trait Memory {
    fn read(&mut self, addr: u16) -> u8;
    fn write(&mut self, addr: u16, value: u8);
}

pub struct FlatMemory(pub [u8; 0x10000]);

impl Default for FlatMemory {
    fn default() -> Self {
        FlatMemory([0; 0x10000])
    }
}

impl Memory for FlatMemory {
    fn read(&mut self, addr: u16) -> u8 {
        self.0[addr as usize]
    }

    fn write(&mut self, addr: u16, value: u8) {
        self.0[addr as usize] = value;
    }
}
