/// Bus the CPU reads/writes through. `FlatMemory` below is just enough to
/// exercise the CPU in isolation (differential/smoke tests), same role as
/// the bare `bytearray` the Python core's step-1 smoke test used directly.
/// `Spectrum48KMemory` (also below) is the real 48K machine's own map.
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

/// The 48K Spectrum's real memory map: 16K ROM (write-protected) +
/// 48K RAM. Mirrors `zxspectrum/core/memory.py` exactly.
pub const ROM_SIZE: usize = 0x4000;
pub const RAM_SIZE: usize = 0xC000;

pub struct Spectrum48KMemory {
    pub rom: [u8; ROM_SIZE],
    pub ram: [u8; RAM_SIZE],
}

impl Default for Spectrum48KMemory {
    fn default() -> Self {
        Spectrum48KMemory {
            rom: [0; ROM_SIZE],
            ram: [0; RAM_SIZE],
        }
    }
}

impl Spectrum48KMemory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn load_rom(&mut self, data: &[u8]) -> Result<(), String> {
        if data.len() != ROM_SIZE {
            return Err(format!(
                "ROM must be exactly {ROM_SIZE} bytes, got {}",
                data.len()
            ));
        }
        self.rom.copy_from_slice(data);
        Ok(())
    }
}

impl Memory for Spectrum48KMemory {
    fn read(&mut self, addr: u16) -> u8 {
        let addr = addr as usize;
        if addr < ROM_SIZE {
            self.rom[addr]
        } else {
            self.ram[addr - ROM_SIZE]
        }
    }

    fn write(&mut self, addr: u16, value: u8) {
        let addr = addr as usize;
        if addr >= ROM_SIZE {
            self.ram[addr - ROM_SIZE] = value;
        }
    }
}
