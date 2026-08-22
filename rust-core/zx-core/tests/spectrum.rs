//! `Spectrum48K` tests, mirroring the relevant cases from the Python
//! project's `tests/test_core.py`: ROM write protection, keyboard IO
//! through the real bus, border OUT, and frame-boundary interrupt/flash
//! timing. Plus a real-ROM boot test (skipped gracefully if `roms/48.rom`
//! isn't present -- same "optional, gitignored, copyrighted" treatment the
//! Python tests give it).

use std::path::Path;
use zx_core::flags::FLAG_C;
use zx_core::spectrum::Spectrum48K;

fn load_program(m: &mut Spectrum48K, addr: u16, code: &[u8]) {
    m.write_memory(addr, code);
    let mut regs = m.registers();
    regs.pc = addr;
    m.set_registers(regs);
}

fn set_sp(m: &mut Spectrum48K, sp: u16) {
    let mut regs = m.registers();
    regs.sp = sp;
    m.set_registers(regs);
}

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
fn border_is_rendered_into_the_full_canvas() {
    let mut machine = Spectrum48K::new();
    // LD A,3 ; OUT ($FE),A ; HALT -- solid border=3 (magenta) for the
    // whole frame, CPU then idles (no further port writes). 0x0000-0x3FFF
    // is ROM (writes there silently no-op, matching real hardware), so the
    // program has to live in RAM -- same pattern as this file's other
    // tests that need real instructions to execute (see `load_program`).
    load_program(&mut machine, 0x8000, &[0x3E, 0x03, 0xD3, 0xFE, 0x76]);
    machine.run_frame();

    let screen = machine.render_screen();
    assert_eq!(
        screen.len(),
        zx_core::ula::FULL_SCREEN_WIDTH * zx_core::ula::FULL_SCREEN_HEIGHT * 3,
        "render_screen() should return the full bordered canvas"
    );
    let expected_magenta = (0xCDu8, 0u8, 0xCDu8); // color(index=3, bright=false)
    let px = |x: usize, y: usize| {
        let idx = (y * zx_core::ula::FULL_SCREEN_WIDTH + x) * 3;
        (screen[idx], screen[idx + 1], screen[idx + 2])
    };
    assert_eq!(px(0, 0), expected_magenta, "top-left corner is border");
    assert_eq!(
        px(zx_core::ula::FULL_SCREEN_WIDTH - 1, zx_core::ula::FULL_SCREEN_HEIGHT - 1),
        expected_magenta,
        "bottom-right corner is border"
    );
    // Just left of the paper area, roughly vertically centered -- still
    // border, should also be magenta.
    let mid_y = zx_core::ula::BORDER_TOP_LINES + zx_core::ula::SCREEN_HEIGHT / 2;
    assert_eq!(px(0, mid_y), expected_magenta, "left border beside the paper area");
}

#[test]
fn border_change_mid_frame_only_affects_pixels_drawn_after_it() {
    // Real hardware latches a border write at the next 8-pixel boundary,
    // not instantly -- so a change partway through a frame should produce
    // a real split in the rendered border: some of it the old color, some
    // the new, not a uniform "whichever was set last" result (which is
    // what a naive snapshot-at-render-time implementation would show).
    //
    // `Spectrum48K::tstates` counts up from the interrupt, not from the
    // top-left of the picture (see `FRAME_TOP_LEFT_TSTATE`'s doc comment):
    // canvas row 0's own leftmost pixel is actually drawn LATE within a
    // given `tstates` sweep, and the very next T-state wraps straight back
    // to it for the following frame, so "row 0" and "the last row" sit
    // right next to each other in wall-clock terms -- a bad pair of points
    // to probe for a mid-frame split. Instead this test picks two ordinary
    // rows, well apart from that wraparound and from each other, and
    // converts each one's own leftmost pixel (column 0, so the T-state
    // offset within its line is exactly 0 -- no rounding) to an absolute
    // T-state explicitly via `FRAME_TOP_LEFT_TSTATE`, rather than assuming
    // raster position tracks `tstates` directly.
    let mut machine = Spectrum48K::new();
    machine.write_memory(0x0000, &[0x76]); // HALT -- idle, no port writes
    let mut regs = machine.registers();
    regs.pc = 0x0000;
    machine.set_registers(regs);

    machine.ula.border = 1; // blue, for a full stable baseline frame first
    machine.run_frame();

    let early_row = 10;
    let late_row = zx_core::ula::FULL_SCREEN_HEIGHT - 10;
    let tstate_of_row_start = |row: usize| {
        let shifted = (row as u32) * zx_core::contention::LINE_TSTATES;
        (shifted + zx_core::ula::FRAME_TOP_LEFT_TSTATE) % zx_core::ula::FRAME_TSTATES
    };
    assert!(
        tstate_of_row_start(early_row) < tstate_of_row_start(late_row),
        "test rows must be in wall-clock order across a single sweep"
    );

    // Run up to (not including) late_row's own leftmost pixel with border
    // still blue -- this also draws early_row's leftmost pixel blue along
    // the way, since it comes first.
    let switch_tstate = tstate_of_row_start(late_row);
    while machine.tstates != switch_tstate {
        machine.tick();
    }
    machine.ula.border = 2; // red, for the rest of this same frame
    let starting_frame = machine.frame_count;
    while machine.frame_count == starting_frame {
        machine.tick();
    }

    let screen = machine.render_screen();
    let blue = (0u8, 0u8, 0xCDu8);
    let red = (0xCDu8, 0u8, 0u8);
    let px = |x: usize, y: usize| {
        let idx = (y * zx_core::ula::FULL_SCREEN_WIDTH + x) * 3;
        (screen[idx], screen[idx + 1], screen[idx + 2])
    };
    assert_eq!(px(0, early_row), blue, "row drawn before the switch stayed blue");
    assert_eq!(px(0, late_row), red, "row drawn after the switch became red");
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
fn im1_interrupt_pushes_pc_and_jumps_to_0x0038() {
    let mut machine = Spectrum48K::new();
    load_program(&mut machine, 0x8000, &[0x00; 8]); // NOP loop -- any instruction boundary will do
    set_sp(&mut machine, 0xFF00);
    let mut regs = machine.registers();
    regs.iff1 = true;
    regs.iff2 = true;
    regs.im = 1;
    machine.set_registers(regs);

    machine.run_frame(); // sets int_pending at the frame boundary

    // The interrupt can only be accepted at the next instruction boundary,
    // not mid-instruction -- give it a few more NOPs' worth of ticks.
    for _ in 0..50 {
        machine.tick();
        if machine.registers().pc == 0x0038 {
            break;
        }
    }

    let regs = machine.registers();
    assert_eq!(regs.pc, 0x0038, "IM1 always jumps to the fixed RST 38h vector");
    assert!(!regs.iff1, "interrupts are disabled on entry to the ISR");
    assert_eq!(regs.sp, 0xFEFE, "SP decremented by 2 to push the return address");
    let pushed = machine.read_memory(0xFEFE, 2);
    let ret_addr = (pushed[0] as u16) | ((pushed[1] as u16) << 8);
    assert!(ret_addr >= 0x8000, "pushed return address should point back into the NOP loop");
}

#[test]
fn im2_interrupt_jumps_through_the_vector_table() {
    let mut machine = Spectrum48K::new();
    load_program(&mut machine, 0x8000, &[0x00; 8]); // NOP loop
    set_sp(&mut machine, 0xFF00);

    // The ZX Spectrum ULA's floating bus always presents 0xFF during
    // interrupt acknowledge, so with I=0x90 the vector address is always
    // 0x90FF regardless of which device (notionally) raised the
    // interrupt -- point it at an ISR that just halts, so PC settles
    // somewhere directly observable.
    machine.write_memory(0x90FF, &[0x00, 0x91]); // vector -> 0x9100
    machine.write_memory(0x9100, &[0x76]); // HALT

    let mut regs = machine.registers();
    regs.iff1 = true;
    regs.iff2 = true;
    regs.im = 2;
    regs.i = 0x90;
    machine.set_registers(regs);

    machine.run_frame();
    for _ in 0..50 {
        machine.tick();
        if machine.registers().pc == 0x9100 {
            break;
        }
    }

    assert_eq!(machine.registers().pc, 0x9100, "IM2 should jump through the vector table to the ISR");
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
    // render_screen() includes the border -- only the pasted-in paper
    // region (not the border, which is unset/black here) should match.
    use zx_core::ula::{BORDER_LEFT_PX, BORDER_TOP_LINES, FULL_SCREEN_WIDTH, SCREEN_HEIGHT, SCREEN_WIDTH};
    for y in 0..SCREEN_HEIGHT {
        for x in 0..SCREEN_WIDTH {
            let idx = ((BORDER_TOP_LINES + y) * FULL_SCREEN_WIDTH + BORDER_LEFT_PX + x) * 3;
            let px = (screen[idx], screen[idx + 1], screen[idx + 2]);
            assert_eq!(px, expected_red, "paper pixel ({x},{y}) didn't match the hand-decoded reference color");
        }
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
    // render_screen() includes the border -- offset into the pasted-in
    // paper region.
    use zx_core::ula::{BORDER_LEFT_PX, BORDER_TOP_LINES, FULL_SCREEN_WIDTH};
    let pixel_at = |x: usize, y: usize| {
        let idx = ((BORDER_TOP_LINES + y) * FULL_SCREEN_WIDTH + BORDER_LEFT_PX + x) * 3;
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

// call_stack tests below are ported directly from `tests/test_core.py`'s
// own (matching addresses/opcodes/assertions), added there alongside
// `machine.py`'s real multi-frame call-stack tracing this session.

#[test]
fn call_stack_tracks_a_call_and_its_return() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // 0x8000: CALL 0x9000 (3 bytes, returns to 0x8003) ; 0x9000: RET
    load_program(&mut m, 0x8000, &[0xCD, 0x00, 0x90]);
    m.write_memory(0x9000, &[0xC9]); // RET

    m.step_instruction(); // CALL 0x9000
    assert_eq!(m.call_stack, vec![0x8003]);
    assert_eq!(m.registers().pc, 0x9000);

    m.step_instruction(); // RET
    assert!(m.call_stack.is_empty());
    assert_eq!(m.registers().pc, 0x8003);
}

#[test]
fn call_stack_tracks_nested_calls_in_order() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // 0x8000: CALL 0x9000 (-> 0x8003)
    // 0x9000: CALL 0x9100 (-> 0x9003)
    // 0x9003: RET
    // 0x9100: RET
    load_program(&mut m, 0x8000, &[0xCD, 0x00, 0x90]);
    m.write_memory(0x9000, &[0xCD, 0x00, 0x91]);
    m.write_memory(0x9003, &[0xC9]);
    m.write_memory(0x9100, &[0xC9]);

    m.step_instruction(); // CALL 0x9000
    assert_eq!(m.call_stack, vec![0x8003]);
    m.step_instruction(); // CALL 0x9100
    assert_eq!(m.call_stack, vec![0x8003, 0x9003]);
    m.step_instruction(); // RET (inside 0x9100) -> back to 0x9003
    assert_eq!(m.call_stack, vec![0x8003]);
    assert_eq!(m.registers().pc, 0x9003);
    m.step_instruction(); // RET (at 0x9003) -> back to 0x8003
    assert!(m.call_stack.is_empty());
    assert_eq!(m.registers().pc, 0x8003);
}

#[test]
fn call_stack_tracks_rst() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // RST 0x10 (0xD7, 1 byte, returns to 0x8001) -- whatever's at 0x0010
    // (unwritten ROM = 0x00 = NOP here) doesn't matter for this test.
    load_program(&mut m, 0x8000, &[0xD7]);

    m.step_instruction();
    assert_eq!(m.call_stack, vec![0x8001]);
    assert_eq!(m.registers().pc, 0x0010);
}

#[test]
fn call_stack_ignores_a_conditional_call_that_is_not_taken() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // XOR A (sets Z) ; CALL NZ,0x9000 -- NZ is false, so the call must not
    // be taken: no frame pushed, and SP/PC just fall through normally.
    load_program(&mut m, 0x8000, &[0xAF, 0xC4, 0x00, 0x90]);

    m.step_instruction(); // XOR A
    let sp_before = m.registers().sp;
    m.step_instruction(); // CALL NZ,0x9000 (not taken)
    assert!(m.call_stack.is_empty());
    assert_eq!(m.registers().pc, 0x8004);
    assert_eq!(m.registers().sp, sp_before);
}

#[test]
fn call_stack_ignores_a_conditional_ret_that_is_not_taken() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // CALL 0x9000 ; at 0x9000: XOR A (sets Z) ; RET NZ (not taken) ; RET
    load_program(&mut m, 0x8000, &[0xCD, 0x00, 0x90]);
    m.write_memory(0x9000, &[0xAF, 0xC0, 0xC9]); // XOR A ; RET NZ ; RET

    m.step_instruction(); // CALL 0x9000
    assert_eq!(m.call_stack, vec![0x8003]);
    m.step_instruction(); // XOR A
    let sp_before = m.registers().sp;
    m.step_instruction(); // RET NZ (not taken)
    assert_eq!(m.call_stack, vec![0x8003]); // unchanged -- still inside the call
    assert_eq!(m.registers().pc, 0x9002);
    assert_eq!(m.registers().sp, sp_before);

    m.step_instruction(); // RET (taken)
    assert!(m.call_stack.is_empty());
    assert_eq!(m.registers().pc, 0x8003);
}

#[test]
fn call_stack_is_cleared_by_reset_and_set_registers() {
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    load_program(&mut m, 0x8000, &[0xCD, 0x00, 0x90]);
    m.write_memory(0x9000, &[0x76]); // HALT -- stay put, don't return
    m.step_instruction();
    assert_eq!(m.call_stack, vec![0x8003]);

    m.reset();
    assert!(m.call_stack.is_empty());

    set_sp(&mut m, 0xFF00);
    load_program(&mut m, 0x8000, &[0xCD, 0x00, 0x90]);
    m.write_memory(0x9000, &[0x76]);
    m.step_instruction();
    assert_eq!(m.call_stack, vec![0x8003]);

    // A debugger redirecting PC directly (not via CALL/RET) also
    // invalidates whatever call chain was tracked before it.
    let mut regs = m.registers();
    regs.pc = 0x8000;
    m.set_registers(regs);
    assert!(m.call_stack.is_empty());
}

#[test]
fn call_stack_is_not_pushed_for_interrupt_entry() {
    // The real hardware stack gets a push on interrupt entry, but
    // call_stack tracking works at the opcode level (classify_step) and
    // there's no CALL/RST opcode actually sitting at the interrupted PC --
    // so this must NOT push a call_stack frame. Deliberately untracked,
    // not a bug: symmetric with RETI/RETN also being untracked (see
    // classify_step's doc comment).
    let mut m = Spectrum48K::new();
    set_sp(&mut m, 0xFF00);
    // A tight NOP loop -- whichever NOP the interrupt lands on on, it's
    // never a CALL/RST/RET.
    load_program(&mut m, 0x8000, &[0x00, 0x18, 0xFE]); // NOP ; JR -2 (infinite NOP loop)
    let mut regs = m.registers();
    regs.iff1 = true;
    regs.iff2 = true;
    regs.im = 1;
    m.set_registers(regs);

    m.run_frame(); // crosses a frame boundary -> the maskable interrupt fires

    assert!(m.call_stack.is_empty());
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
