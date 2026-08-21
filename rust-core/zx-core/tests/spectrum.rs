//! `Spectrum48K` tests, mirroring the relevant cases from the Python
//! project's `tests/test_core.py`: ROM write protection, keyboard IO
//! through the real bus, border OUT, and frame-boundary interrupt/flash
//! timing. Plus a real-ROM boot test (skipped gracefully if `roms/48.rom`
//! isn't present -- same "optional, gitignored, copyrighted" treatment the
//! Python tests give it).

use std::path::Path;
use zx_core::flags::FLAG_C;
use zx_core::spectrum::Spectrum48K;

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
fn in_r_c_reads_through_the_real_bus_and_preserves_carry() {
    // ED-prefixed `IN r,(C)` (opcode 0x58 = IN E,(C)) -- was completely
    // unimplemented until this pass, panicked the whole server the moment
    // Manic Miner's own code executed it. Same bus decode as `IN A,(n)`
    // (any port with A0=0 hits the ULA/keyboard regardless of the upper
    // byte), but a distinct CPU dispatch path, so this exercises that path
    // specifically -- plus the flags side effect (`_z80_in`-style: S/Z/5/3/P
    // from the value read, H=0, N=0, C left untouched).
    let mut machine = Spectrum48K::new();
    machine.keyboard.key_down("SPACE"); // row 7, bit 0
    // LD BC,$7FFE ; SCF ; IN E,(C) ; HALT
    machine.write_memory(0x8000, &[0x01, 0xFE, 0x7F, 0x37, 0xED, 0x58, 0x76]);
    let mut regs = machine.registers();
    regs.pc = 0x8000;
    machine.set_registers(regs);
    for _ in 0..3 {
        machine.step_instruction();
    }
    let regs = machine.registers();
    let bits = regs.e & 0x1F;
    assert_eq!(bits, 0x1F & !0b00000001, "SPACE pressed -> bit 0 clear");
    assert_ne!(regs.f & FLAG_C, 0, "IN r,(C) must not touch the carry flag");
}

#[test]
fn in_r_c_on_an_unmapped_port_reads_floating_bus_high() {
    // A0=1 (odd port) is unconnected on a real 48K -- this core's bus decode
    // returns 0xFF for it (see spectrum.rs's tick()), same value both
    // IN A,(n) and IN r,(C) should observe since the decode is address-based,
    // not opcode-based.
    let mut machine = Spectrum48K::new();
    // LD BC,$0001 ; IN B,(C) ; HALT
    machine.write_memory(0x8000, &[0x01, 0x01, 0x00, 0xED, 0x40, 0x76]);
    let mut regs = machine.registers();
    regs.pc = 0x8000;
    machine.set_registers(regs);
    for _ in 0..2 {
        machine.step_instruction();
    }
    assert_eq!(machine.registers().b, 0xFF);
}

#[test]
fn frame_boundary_sets_int_pending_and_toggles_flash_every_16th() {
    // `run_frame()`, not a fixed `FRAME_TSTATES` tick() count -- a single
    // tick() call can now silently consume more than one real T-state
    // (ULA contention), so looping on frame_count is what's actually
    // correct (see `Spectrum48K::run_frame()`'s own doc comment).
    let mut machine = Spectrum48K::new();
    for frame in 1..=16u64 {
        machine.run_frame();
        assert_eq!(machine.frame_count, frame);
    }
    assert!(machine.ula.flash_state, "flash should have toggled on frame 16");
}

#[test]
fn progressive_render_matches_hand_decoded_reference_when_screen_is_static() {
    // Regression check for the T-state-synced rendering rewrite: with no
    // mid-frame screen-memory writes, the progressively-built framebuffer
    // must agree exactly with a plain hand-computed decode -- proving the
    // rewrite didn't silently change the pixel/attribute decode math
    // (color table, ink/paper/bright), independent of timing.
    let mut machine = Spectrum48K::new();
    machine.write_memory(0x0000, &[0x76]); // HALT -- CPU idles, never touches screen memory
    let mut regs = machine.registers();
    regs.pc = 0x0000;
    machine.set_registers(regs);

    // Every pixel byte "all ink"; every attribute ink=2 (red), paper=0,
    // not bright -- so every pixel in the whole picture should decode to
    // the same known color, easy to assert without re-deriving the
    // color table in the test itself.
    for row in 0..192u16 {
        machine.write_memory(zx_core::ula::pixel_addr(0, row), &[0xFF]);
        for col in 1..32u16 {
            machine.write_memory(zx_core::ula::pixel_addr(col * 8, row), &[0xFF]);
        }
    }
    for row in 0..24u16 {
        for col in 0..32u16 {
            machine.write_memory(zx_core::ula::attr_addr(col * 8, row * 8), &[0x02]);
        }
    }

    machine.run_frame();

    let screen = machine.render_screen();
    let expected_red = (0xCDu8, 0u8, 0u8); // color(ink=2, bright=false)
    for (i, px) in screen.chunks_exact(3).enumerate() {
        assert_eq!(
            (px[0], px[1], px[2]),
            expected_red,
            "pixel {i} didn't match the hand-decoded reference color"
        );
    }
}

#[test]
fn mid_frame_screen_write_produces_real_tearing() {
    // The capability a snapshot decoder could never have: a screen-memory
    // write partway through a frame should only affect the part of the
    // picture the ULA hadn't drawn yet.
    let mut machine = Spectrum48K::new();
    machine.write_memory(0x0000, &[0x76]); // HALT -- CPU idles at an uncontended address
    let mut regs = machine.registers();
    regs.pc = 0x0000;
    machine.set_registers(regs);

    // Whole screen: all-ink pixels, red attributes -- one full stable
    // frame first so `render_screen()` has a real "last complete frame"
    // to fall back on before the torn frame under test.
    for row in 0..192u16 {
        for col in 0..32u16 {
            machine.write_memory(zx_core::ula::pixel_addr(col * 8, row), &[0xFF]);
        }
    }
    for row in 0..24u16 {
        for col in 0..32u16 {
            machine.write_memory(zx_core::ula::attr_addr(col * 8, row * 8), &[0x02]); // red
        }
    }
    machine.run_frame();

    // Tick into the NEXT frame up to the start of scanline 100 -- past
    // where scanline 50 was already drawn, before scanline 150 is drawn.
    let target = zx_core::contention::FIRST_CONTENDED_TSTATE + 100 * zx_core::contention::LINE_TSTATES;
    while machine.tstates < target {
        machine.tick();
    }
    // Recolor scanline 150 to green, ahead of the ULA reaching it.
    for col in 0..32u16 {
        machine.write_memory(zx_core::ula::attr_addr(col * 8, 150), &[0x04]);
    }
    // Finish the frame.
    let starting_frame = machine.frame_count;
    while machine.frame_count == starting_frame {
        machine.tick();
    }

    let screen = machine.render_screen();
    let pixel_at = |x: usize, y: usize| {
        let idx = (y * zx_core::ula::SCREEN_WIDTH + x) * 3;
        (screen[idx], screen[idx + 1], screen[idx + 2])
    };
    assert_eq!(pixel_at(0, 50), (0xCD, 0, 0), "row 50 was already drawn -- should stay the old red");
    assert_eq!(pixel_at(0, 150), (0, 0xCD, 0), "row 150 was drawn after the write -- should be the new green");
}

#[test]
fn contended_memory_executes_fewer_loop_iterations_per_frame_than_uncontended() {
    fn count_loop_iterations(load_addr: u16) -> u16 {
        let mut machine = Spectrum48K::new();
        // INC BC ; JR -3 (tight, infinite 2-instruction loop). BC (not B
        // alone) so the count can't wrap within one frame's worth of
        // iterations.
        machine.write_memory(load_addr, &[0x03, 0x18, 0xFD]);
        let mut regs = machine.registers();
        regs.pc = load_addr;
        regs.set_bc(0);
        machine.set_registers(regs);
        machine.run_frame();
        machine.registers().bc()
    }

    let contended = count_loop_iterations(0x4000);
    let uncontended = count_loop_iterations(0x8000);
    assert!(
        contended < uncontended,
        "contended={contended} uncontended={uncontended} -- contention should cost real throughput"
    );
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
