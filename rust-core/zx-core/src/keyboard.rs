//! 8x5 ZX Spectrum keyboard matrix, read through port 0xFE. Ported directly
//! from `zxspectrum/core/keyboard.py`.
//!
//! Reading port 0xFE presents the high byte of the port address on
//! A8-A15; each address line held low selects one half-row, and the
//! response's low 5 bits report that row's key state (0 = pressed, 1 =
//! released). If several address lines are low at once the rows are OR'd
//! together, matching real hardware.

/// Each row: (address line bit within the high byte, 5 key names in
/// bit 0..4 order).
const ROWS: [(u8, [&str; 5]); 8] = [
    (0, ["CAPS SHIFT", "Z", "X", "C", "V"]),
    (1, ["A", "S", "D", "F", "G"]),
    (2, ["Q", "W", "E", "R", "T"]),
    (3, ["1", "2", "3", "4", "5"]),
    (4, ["0", "9", "8", "7", "6"]),
    (5, ["P", "O", "I", "U", "Y"]),
    (6, ["ENTER", "L", "K", "J", "H"]),
    (7, ["SPACE", "SYM SHIFT", "M", "N", "B"]),
];

fn key_pos(key: &str) -> Option<(usize, u8)> {
    let key = key.to_uppercase();
    for (row, (_, names)) in ROWS.iter().enumerate() {
        if let Some(bit) = names.iter().position(|&n| n == key) {
            return Some((row, bit as u8));
        }
    }
    None
}

pub struct Keyboard {
    /// bit set = released (matches hardware idle-high convention).
    row_state: [u8; 8],
}

impl Default for Keyboard {
    fn default() -> Self {
        Keyboard { row_state: [0x1F; 8] }
    }
}

impl Keyboard {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn key_down(&mut self, key: &str) {
        if let Some((row, bit)) = key_pos(key) {
            self.row_state[row] &= !(1 << bit) & 0x1F;
        }
    }

    pub fn key_up(&mut self, key: &str) {
        if let Some((row, bit)) = key_pos(key) {
            self.row_state[row] |= 1 << bit;
        }
    }

    pub fn key_up_all(&mut self) {
        self.row_state = [0x1F; 8];
    }

    /// Raw row-state snapshot (bit set = released) -- lets a caller mirror
    /// one `Keyboard`'s state into another without re-deriving it through
    /// `key_down`/`key_up`'s name lookup.
    pub fn row_state(&self) -> [u8; 8] {
        self.row_state
    }

    pub fn set_row_state(&mut self, state: [u8; 8]) {
        self.row_state = state;
    }

    pub fn read_port(&self, high_byte: u8) -> u8 {
        let mut bits: u8 = 0x1F;
        for (row, (addr_bit, _)) in ROWS.iter().enumerate() {
            if high_byte & (1 << addr_bit) == 0 {
                bits &= self.row_state[row];
            }
        }
        bits
    }
}
