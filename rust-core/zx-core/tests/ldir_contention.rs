//! Isolated, hand-computable reproduction for the Aquaplane border-timing
//! investigation: an IM2 interrupt wakes a HALT-ed CPU, the ISR does the
//! bare minimum (EI; RET) to return control immediately, and the resumed
//! main code runs a single LDIR copying from *uncontended* memory into the
//! *contended* screen -- isolating write-side memory contention across a
//! real 256-byte block copy, independent of everything else Aquaplane's
//! own code does. The expected T-state cost is computed independently
//! (using only the already-cross-validated `contention::memory_contention_delay`
//! formula, applied by hand to LDIR's own documented per-repeat T-state
//! breakdown -- see `vendor/chips/z80.h`'s generated case list, cross-
//! checked earlier this session), not by re-deriving anything from this
//! core's own dispatch.

use zx_core::ula::memory_contention_delay;
use zx_core::spectrum::Spectrum48K;

#[test]
fn ldir_into_contended_screen_matches_hand_computed_contention() {
    let mut machine = Spectrum48K::new();

    // Main code: EI; HALT; LDIR (uncontended source -> contended dest).
    machine.write_memory(0x8000, &[0xFB, 0x76, 0xED, 0xB0]);
    // Source data (uncontended RAM) -- 256 recognizable bytes.
    let source: Vec<u8> = (0..256u16).map(|i| i as u8).collect();
    machine.write_memory(0x8100, &source);
    // IM2 vector table entry (I=0x82 -> vector address 0x82FF) -> ISR.
    // The ISR lives well clear of 0x8300 (the vector table's OWN
    // high-byte address) -- writing ISR bytes starting exactly there
    // would silently overwrite the vector table entry itself (a real bug
    // found in this exact test: the ISR's own first opcode, 0xFB, was
    // clobbering the vector high byte, sending the interrupt to 0xFB00
    // instead of the ISR).
    machine.write_memory(0x82FF, &[0x00, 0x84]);
    // ISR: EI; RET -- returns immediately, right back into HALT's own
    // next instruction (the LDIR).
    machine.write_memory(0x8400, &[0xFB, 0xC9]);

    let mut regs = machine.registers();
    regs.pc = 0x8000;
    regs.sp = 0xFF00;
    regs.im = 2;
    regs.i = 0x82;
    regs.iff1 = true;
    regs.iff2 = true;
    regs.set_hl(0x8100); // LDIR source
    regs.set_de(0x4000); // LDIR dest -- contended screen memory
    regs.set_bc(0x0100); // 256 bytes
    machine.set_registers(regs);

    // Deliberately NOT `run_frame()` first: the INT pulse is active during
    // T-states 0-31 of every frame, a freshly constructed machine's own
    // included (real hardware doesn't grant a grace period after reset
    // either), so by the time EI's one-instruction delay lifts and HALT
    // starts waiting, the interrupt is already there to wake it -- letting
    // `run_frame()` run first would just burn a whole frame's worth of
    // ticks on the ISR, the LDIR, and then NOP-sliding through whatever
    // comes after 0x8004, before this loop got a chance to observe
    // anything.
    //
    // Let the interrupt actually get serviced (HALT wakes, ISR runs and
    // returns) and PC reach the LDIR instruction itself.
    for _ in 0..100 {
        machine.tick();
        // NOT just "pc == 0x8002" -- HALT displays pc as `halt_addr+1`
        // (0x8002, since HALT is at 0x8001) continuously while still
        // waiting, indistinguishable from genuinely having returned there
        // -- see `Cpu::registers()`'s doc comment.
        if !machine.cpu.halted && machine.registers().pc == 0x8002 {
            break;
        }
    }
    assert!(!machine.cpu.halted, "should have genuinely returned from the ISR, not still be waiting in HALT");
    assert_eq!(machine.registers().pc, 0x8002, "should have reached the LDIR after the interrupt");

    let start_tstate = machine.tstates;

    // Run until BC reaches 0 (all 256 repeats done) -- NOT "PC != 0x8002":
    // PC's own reported value (raw-1, since not halted) actually reads
    // 0x8001 during each repeat's internal rewind phase (every single
    // iteration, not just the last), so checking PC directly breaks on
    // the very first iteration instead of waiting for the whole thing.
    for _ in 0..200000 {
        machine.tick();
        if machine.registers().bc() == 0 {
            break;
        }
    }
    assert_eq!(machine.registers().bc(), 0, "LDIR should have copied all 256 bytes");
    // One more tick to land cleanly on the overlapped fetch of the next
    // instruction (0x8004) instead of mid-way through LDIR's own tail.
    while machine.registers().pc != 0x8004 {
        machine.tick();
    }

    let actual_cost = machine.tstates.wrapping_sub(start_tstate);

    // Verify the copy actually happened correctly (sanity check the test
    // itself, not just timing).
    let copied = machine.read_memory(0x4000, 256);
    assert_eq!(copied, source, "LDIR should have copied the source bytes to the screen");

    // Independently hand-compute the expected cost: each of the 256
    // repeats does pc(4T, uncontended) + pc+1(4T, uncontended) +
    // hl-read(3T, uncontended, source) + de-write(3T + contention delay
    // at ITS OWN T1, dest=screen) + bc--(2T) + repeat-delay(5T, all but
    // the last iteration). Only the de-write's own T1 is a real,
    // contended access (matching "only T1 of an instruction fetch,
    // memory read or write cycle is contended" -- confirmed this
    // session), so LDIR's internal bookkeeping cycles (the 2+5 T-state
    // stretches with zero pin activity) do NOT get their own checks.
    let mut t = start_tstate;
    for i in 0..256u32 {
        let repeating = i < 255;
        t += 4; // pc (ED re-fetch) -- uncontended (0x8002)
        t += 4; // pc+1 (B0 re-fetch) -- uncontended (0x8003)
        t += 3; // hl read -- uncontended (source, 0x8100+)
        let delay = memory_contention_delay(t);
        t += delay + 3; // de write -- contended (dest, screen)
        t += 2; // bc decrement / PV flag bookkeeping
        if repeating {
            t += 5; // repeat delay
        }
    }
    let expected_cost = t - start_tstate;

    println!("start_tstate={start_tstate} actual_cost={actual_cost} expected_cost={expected_cost}");
    assert_eq!(actual_cost, expected_cost, "LDIR's total T-state cost should match the hand-computed expectation");
}
