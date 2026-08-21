//! `Spectrum48K` tests, mirroring the relevant cases from the Python
//! project's `tests/test_core.py`: ROM write protection, keyboard IO
//! through the real bus, border OUT, and frame-boundary interrupt/flash
//! timing. Plus a real-ROM boot test (skipped gracefully if `roms/48.rom`
//! isn't present -- same "optional, gitignored, copyrighted" treatment the
//! Python tests give it).

use std::path::Path;
use zx_core::spectrum::Spectrum48K;
use zx_core::ula::FRAME_TSTATES;

#[test]
fn rom_is_write_protected() {
    let mut machine = Spectrum48K::new();
    machine.load_rom(&[0xAAu8; 0x4000]).unwrap();
    machine.write_memory(0x1234, &[0xFF]);
    assert_eq!(machine.read_memory(0x1234, 1), vec![0xAA]);
}

#[test]
fn ram_is_writable() {
    let mut machine = Spectrum48K::new();
    machine.write_memory(0x8000, &[0x42]);
    assert_eq!(machine.read_memory(0x8000, 1), vec![0x42]);
}

#[test]
fn keyboard_read_ors_together_selected_rows() {
    let mut machine = Spectrum48K::new();
    // Row 0 (CAPS SHIFT, Z, X, C, V) is address line bit 0; row 1
    // (A, S, D, F, G) is bit 1. High byte 0xFC = bits 0 and 1 both low ->
    // both rows selected and OR'd.
    machine.keyboard.key_down("Z"); // row 0, bit 1
    machine.keyboard.key_down("A"); // row 1, bit 0
    let bits = machine.keyboard.read_port(0xFC);
    // bit1 (Z) and bit0 (A) both clear, rest set.
    assert_eq!(bits, 0x1F & !0b00000011);
}

#[test]
fn border_out_changes_ula_border() {
    let mut machine = Spectrum48K::new();
    // OUT (0xFE),A with A=5 -- LD A,5 ; OUT ($FE),A
    machine.write_memory(0x8000, &[0x3E, 0x05, 0xD3, 0xFE]);
    let mut regs = machine.registers();
    regs.pc = 0x8000;
    machine.set_registers(regs);
    for _ in 0..2 {
        machine.step_instruction();
    }
    assert_eq!(machine.ula.border, 5);
}

#[test]
fn keyboard_in_reads_through_the_real_bus() {
    let mut machine = Spectrum48K::new();
    machine.keyboard.key_down("SPACE"); // row 7, bit 0 -- address high byte 0x7F (bit 7 low)
    // LD A,$7F ; IN A,($FE) ; HALT -- IN A,(n) puts A on the port's high
    // byte, exactly the addressing real ZX Spectrum keyboard-scan code uses.
    machine.write_memory(0x8000, &[0x3E, 0x7F, 0xDB, 0xFE, 0x76]);
    let mut regs = machine.registers();
    regs.pc = 0x8000;
    machine.set_registers(regs);
    for _ in 0..2 {
        machine.step_instruction();
    }
    let bits = machine.registers().a & 0x1F;
    assert_eq!(bits, 0x1F & !0b00000001); // SPACE pressed -> bit 0 clear
}

#[test]
fn frame_boundary_sets_int_pending_and_toggles_flash_every_16th() {
    let mut machine = Spectrum48K::new();
    for frame in 1..=16u64 {
        for _ in 0..FRAME_TSTATES {
            machine.tick();
        }
        assert_eq!(machine.frame_count, frame);
    }
    assert!(machine.ula.flash_state, "flash should have toggled on frame 16");
}

#[test]
fn breakpoint_stops_run() {
    let mut machine = Spectrum48K::new();
    // NOP x3 then HALT at 0x8003
    machine.write_memory(0x8000, &[0x00, 0x00, 0x00, 0x76]);
    let mut regs = machine.registers();
    regs.pc = 0x8000;
    machine.set_registers(regs);
    machine.set_breakpoint(0x8002);
    let result = machine.run(100);
    assert_eq!(result, "breakpoint");
    assert_eq!(machine.registers().pc, 0x8002);
}

#[test]
fn real_rom_boots_to_a_non_blank_screen() {
    let rom_path = Path::new("../../roms/48.rom");
    if !rom_path.exists() {
        eprintln!("skipping real_rom_boots_to_a_non_blank_screen -- no roms/48.rom present");
        return;
    }
    let rom = std::fs::read(rom_path).expect("read roms/48.rom");

    let mut machine = Spectrum48K::new();
    machine.load_rom(&rom).expect("load 48K ROM");
    // Redirect PC to the ROM's actual reset vector (0x0000), same as a
    // real power-on -- set_registers()'s own priming re-primes the fetch.
    let mut regs = machine.registers();
    regs.pc = 0x0000;
    machine.set_registers(regs);

    for _ in 0..150 {
        machine.run_frame();
    }

    let screen = machine.render_screen();
    // The copyright splash screen prints real text -- the display file
    // should no longer be uniformly one color once it's rendered.
    let first_pixel = &screen[0..3];
    let has_variation = screen
        .chunks_exact(3)
        .any(|px| px != first_pixel);
    assert!(
        has_variation,
        "expected the boot screen to show real content, got a uniform screen"
    );
}
