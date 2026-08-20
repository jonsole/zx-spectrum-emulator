"""8x5 ZX Spectrum keyboard matrix, read through port 0xFE.

Reading port 0xFE presents the high byte of the port address on A8-A15;
each address line held low selects one half-row, and the response's low 5
bits report that row's key state (0 = pressed, 1 = released). If several
address lines are low at once the rows are OR'd together, matching real
hardware.
"""
from __future__ import annotations

# Each row: (address line bit within the high byte, [5 key names in bit 0..4 order])
ROWS: list[tuple[int, list[str]]] = [
    (0, ["CAPS SHIFT", "Z", "X", "C", "V"]),
    (1, ["A", "S", "D", "F", "G"]),
    (2, ["Q", "W", "E", "R", "T"]),
    (3, ["1", "2", "3", "4", "5"]),
    (4, ["0", "9", "8", "7", "6"]),
    (5, ["P", "O", "I", "U", "Y"]),
    (6, ["ENTER", "L", "K", "J", "H"]),
    (7, ["SPACE", "SYM SHIFT", "M", "N", "B"]),
]

_KEY_TO_POS: dict[str, tuple[int, int]] = {
    name: (row, bit)
    for row, (_, names) in enumerate(ROWS)
    for bit, name in enumerate(names)
}


class Keyboard:
    def __init__(self) -> None:
        # bit set = released (matches hardware idle-high convention)
        self._row_state = [0x1F] * 8

    def key_down(self, key: str) -> None:
        row, bit = _KEY_TO_POS[key.upper()]
        self._row_state[row] &= ~(1 << bit) & 0x1F

    def key_up(self, key: str) -> None:
        row, bit = _KEY_TO_POS[key.upper()]
        self._row_state[row] |= 1 << bit

    def key_up_all(self) -> None:
        self._row_state = [0x1F] * 8

    def read_port(self, high_byte: int) -> int:
        bits = 0x1F
        for row, (addr_bit, _) in enumerate(ROWS):
            if not (high_byte & (1 << addr_bit)):
                bits &= self._row_state[row]
        return bits
