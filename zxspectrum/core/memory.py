"""48K Spectrum memory map: 16K ROM (0x0000-0x3FFF) + 48K RAM (0x4000-0xFFFF)."""
from __future__ import annotations

ROM_SIZE = 0x4000
RAM_SIZE = 0xC000
ADDR_SPACE = 0x10000

SCREEN_BASE = 0x4000
SCREEN_SIZE = 0x1B00  # 6144-byte bitmap + 768-byte attributes


class Memory:
    def __init__(self) -> None:
        self.rom = bytearray(ROM_SIZE)
        self.ram = bytearray(RAM_SIZE)

    def load_rom(self, data: bytes) -> None:
        if len(data) != ROM_SIZE:
            raise ValueError(f"ROM must be exactly {ROM_SIZE} bytes, got {len(data)}")
        self.rom[:] = data

    def read(self, addr: int) -> int:
        addr &= 0xFFFF
        if addr < ROM_SIZE:
            return self.rom[addr]
        return self.ram[addr - ROM_SIZE]

    def write(self, addr: int, value: int) -> None:
        addr &= 0xFFFF
        if addr < ROM_SIZE:
            return  # ROM is read-only
        self.ram[addr - ROM_SIZE] = value & 0xFF

    def read_block(self, addr: int, length: int) -> bytes:
        return bytes(self.read(addr + i) for i in range(length))

    def write_block(self, addr: int, data: bytes) -> None:
        for i, b in enumerate(data):
            self.write(addr + i, b)
