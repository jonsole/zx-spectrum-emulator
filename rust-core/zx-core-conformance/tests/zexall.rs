//! Runs the real ZEXALL/ZEXDOC Z80 exerciser (github.com/agn453/ZEXALL,
//! fetched via `scripts/fetch_zexall.py`) against `zx_core::Cpu` through a
//! minimal CP/M BDOS shim -- only functions 2 (single-char output) and 9
//! ($-terminated string output), the only two ZEXALL itself uses.
//!
//! `#[ignore]`d for now: unprefixed, ED-prefixed, CB-prefixed, and DD/FD
//! (IX/IY, including the DDCB/FDCB double-prefix bit-op form) opcodes are
//! all implemented and pin/register-verified against the real z80.h (see
//! differential.rs). This is the real "is this core accurate" bar,
//! complementary to differential.rs: that file checks agreement with z80.h
//! specifically, this checks agreement with known-correct Z80 semantics
//! directly (so it would catch a bug the two cores happened to share, which
//! a differential test against z80.h alone never could -- concretely
//! already true twice: this harness caught DD/FD being silently mishandled
//! as a no-op instead of properly panicking, and separately `begin_fetch()`
//! missing a `prefix_active = false` reset that let `step()` silently
//! swallow one extra instruction after every DDCB/FDCB op -- neither was
//! ever exercised by the differential tests).
//!
//! **Both the real zexdoc.z80 AND its stricter sibling zexall.z80 (which
//! checks the undocumented flag bits fully instead of masking them out) now
//! pass in full: every test group in both suites reports `OK`, zero
//! `ERROR`s.** DD/FD and DDCB/FDCB (and everything else) are confirmed
//! correct against known-correct Z80 semantics, not just against z80.h --
//! the strongest correctness claim this project can currently make. Getting
//! here involved one genuine near-miss: what initially
//! LOOKED like a stuck/infinite loop partway through the `add ix` group
//! turned out to be a false alarm, traced via a PC-hit histogram
//! and a counter on how often zexdoc's own `test:` routine (0x1D2A) got
//! re-entered -- the call rate was dead steady (~261 calls/million
//! instructions, no slowdown) the whole time, which is the signature of
//! "genuinely needs a bigger instruction budget," not "stuck." Confirmed by
//! raising `MAX_INSTRUCTIONS` and watching it complete. zexdoc's own CRC-
//! based per-test-case verification is legitimately instruction-heavy (a
//! per-bit `updcrc` loop dominates the profile), and later groups scan a
//! large combinatorial register/flag space, so a full run is slow (tens of
//! minutes) but not stuck -- don't mistake a large `MAX_INSTRUCTIONS` cap
//! being hit for a regression without first checking whether progress
//! (however slow) is still happening, e.g. via the same kind of targeted
//! `eprintln!`-on-a-known-address technique used to root-cause this.

use std::path::Path;
use zx_core::{Cpu, FlatMemory, Memory};

const BDOS_ENTRY: u16 = 0x0005;
const WARM_BOOT: u16 = 0x0000;
const LOAD_ADDR: u16 = 0x0100;
// zexdoc's own CRC-based verification is legitimately instruction-heavy
// (see the module doc comment) -- a full run needs well over a billion
// emulated Z80 instructions even with every opcode this project supports
// implemented correctly, so this cap exists purely as a "something is
// actually broken" backstop, not a realistic completion estimate.
const MAX_INSTRUCTIONS: u64 = 20_000_000_000;

fn run_zexall_com(path: &Path) -> String {
    let program = std::fs::read(path).unwrap_or_else(|e| {
        panic!("couldn't read {path:?}: {e} -- run `python scripts/fetch_zexall.py` first")
    });

    let mut mem = FlatMemory::default();
    mem.0[WARM_BOOT as usize] = 0x76; // HALT -- marks CP/M's warm boot vector
    // ZEXALL's own first instructions are `LD HL,(6); LD SP,HL` -- the
    // standard CP/M idiom for reading "top of TPA" into SP. Address 6-7
    // being left at zero (FlatMemory's default) means ZEXALL immediately
    // overwrites SP with garbage before it even reaches its own test loop,
    // regardless of what SP gets set to below -- found by reading the real
    // zexdoc.z80 source directly after the exerciser got stuck in what
    // looked like an infinite loop with no core-level explanation.
    mem.0[6] = 0x00;
    mem.0[7] = 0xFE; // SP will become 0xFE00 -- headroom below the loaded program's code, above it
    let load = LOAD_ADDR as usize;
    mem.0[load..load + program.len()].copy_from_slice(&program);

    let mut cpu = Cpu::new();
    let mut regs = cpu.registers();
    regs.pc = LOAD_ADDR;
    cpu.set_registers(regs, &mut mem);

    let mut output = String::new();
    let mut instructions = 0u64;

    loop {
        if cpu.registers().pc == WARM_BOOT {
            break;
        }
        if cpu.registers().pc == BDOS_ENTRY {
            handle_bdos_call(&mut cpu, &mut mem, &mut output);
            continue;
        }
        cpu.step(&mut mem);
        instructions += 1;
        assert!(
            instructions < MAX_INSTRUCTIONS,
            "exceeded {MAX_INSTRUCTIONS} instructions without reaching warm boot -- \
             probably stuck, not just slow"
        );
    }

    output
}

fn handle_bdos_call(cpu: &mut Cpu, mem: &mut FlatMemory, output: &mut String) {
    let regs = cpu.registers();
    match regs.c {
        2 => {
            print!("{}", regs.e as char);
            output.push(regs.e as char);
        }
        9 => {
            let mut addr = regs.de();
            loop {
                let byte = mem.read(addr);
                if byte == b'$' {
                    break;
                }
                print!("{}", byte as char);
                output.push(byte as char);
                addr = addr.wrapping_add(1);
            }
        }
        other => panic!("unhandled BDOS function {other} at PC={:#06x}", regs.pc),
    }
    use std::io::Write;
    std::io::stdout().flush().ok();

    // Simulate the RET that would normally follow `CALL 5`: pop the return
    // address ZEXALL's own CALL pushed, and continue from there.
    let mut regs = cpu.registers();
    let ret_addr = mem.read(regs.sp) as u16 | ((mem.read(regs.sp.wrapping_add(1)) as u16) << 8);
    regs.sp = regs.sp.wrapping_add(2);
    regs.pc = ret_addr;
    cpu.set_registers(regs, mem);
}

/// **Confirmed passing in full (2026-08-22): every group in the real
/// zexdoc.z80 suite reports `OK`, zero `ERROR`s, in ~1073s.** `#[ignore]`d
/// purely because of that runtime (zexdoc's own CRC-based per-test-case
/// verification is inherently instruction-heavy, see the module doc
/// comment), not because anything is missing or suspected broken -- run
/// explicitly with `cargo test --test zexall zexdoc_reports_no_errors --
/// --ignored --nocapture` when re-verifying after a core change.
#[test]
#[ignore = "passes in full, but takes ~18 minutes -- run explicitly, see doc comment above"]
fn zexdoc_reports_no_errors() {
    let output = run_zexall_com(Path::new("../../.zexall-src/zexdoc.com"));
    print!("{output}");
    assert!(
        !output.contains("ERROR"),
        "zexdoc reported at least one ERROR:\n{output}"
    );
}

/// zexdoc.z80's stricter sibling: checks the undocumented flag bits fully
/// instead of masking them out. **Confirmed passing in full (2026-08-22):
/// every group reports `OK`, zero `ERROR`s, in ~1055s.** `#[ignore]`d for
/// the same reason as `zexdoc_reports_no_errors` above -- runtime, not
/// doubt.
#[test]
#[ignore = "passes in full, but takes ~18 minutes -- run explicitly, see doc comment above"]
fn zexall_reports_no_errors() {
    let output = run_zexall_com(Path::new("../../.zexall-src/zexall.com"));
    print!("{output}");
    assert!(
        !output.contains("ERROR"),
        "zexall reported at least one ERROR:\n{output}"
    );
}
