//! Bindings to the vendored `chips/z80.h` core via the same `shim.c` the
//! Python project's cffi layer uses, so this crate can drive the exact
//! proven C implementation from Rust and diff it against `zx_core::Cpu`.

use zx_core::{Memory, Registers};

const PIN_MREQ: u64 = 1 << 25;
const PIN_IORQ: u64 = 1 << 26;
const PIN_RD: u64 = 1 << 27;
const PIN_WR: u64 = 1 << 28;
const PIN_HALT: u64 = 1 << 29;

fn get_addr(pins: u64) -> u16 {
    (pins & 0xFFFF) as u16
}

fn get_data(pins: u64) -> u8 {
    ((pins >> 16) & 0xFF) as u8
}

fn set_data(pins: u64, data: u8) -> u64 {
    (pins & !0xFF_0000) | ((data as u64) << 16)
}

/// Layout must match `zx_regs_t` in `zxspectrum/_native/shim.h` exactly --
/// same field order and types, both compiled by the same toolchain, so
/// `repr(C)` gives the identical struct layout on both sides of the FFI
/// boundary.
#[repr(C)]
#[derive(Default)]
struct ZxRegs {
    pc: u16,
    sp: u16,
    af: u16,
    bc: u16,
    de: u16,
    hl: u16,
    ix: u16,
    iy: u16,
    ir: u16,
    wz: u16,
    af2: u16,
    bc2: u16,
    de2: u16,
    hl2: u16,
    im: u8,
    iff1: bool,
    iff2: bool,
}

#[repr(C)]
struct ZxCpuHandle {
    _private: [u8; 0],
}

extern "C" {
    fn zx_alloc() -> *mut ZxCpuHandle;
    fn zx_free(c: *mut ZxCpuHandle);
    fn zx_init(c: *mut ZxCpuHandle) -> u64;
    #[allow(dead_code)]
    fn zx_reset(c: *mut ZxCpuHandle) -> u64;
    fn zx_tick(c: *mut ZxCpuHandle, pins: u64) -> u64;
    #[allow(dead_code)]
    fn zx_prefetch(c: *mut ZxCpuHandle, new_pc: u16) -> u64;
    fn zx_opdone(c: *mut ZxCpuHandle) -> bool;
    fn zx_get_regs(c: *mut ZxCpuHandle, out: *mut ZxRegs);
    fn zx_set_regs(c: *mut ZxCpuHandle, inp: *const ZxRegs);
}

/// Safe wrapper around the real `chips/z80.h` core, exposing the same
/// register-snapshot shape as `zx_core::Cpu` so tests can diff them
/// directly.
pub struct ReferenceCpu {
    handle: *mut ZxCpuHandle,
    pins: u64,
}

impl ReferenceCpu {
    pub fn new() -> Self {
        unsafe {
            let handle = zx_alloc();
            let pins = zx_init(handle);
            Self { handle, pins }
        }
    }

    pub fn registers(&self) -> Registers {
        let mut raw = ZxRegs::default();
        unsafe { zx_get_regs(self.handle, &mut raw) };

        let mut regs = Registers::default();
        regs.set_af(raw.af);
        regs.set_bc(raw.bc);
        regs.set_de(raw.de);
        regs.set_hl(raw.hl);
        regs.a_ = (raw.af2 >> 8) as u8;
        regs.f_ = raw.af2 as u8;
        regs.b_ = (raw.bc2 >> 8) as u8;
        regs.c_ = raw.bc2 as u8;
        regs.d_ = (raw.de2 >> 8) as u8;
        regs.e_ = raw.de2 as u8;
        regs.h_ = (raw.hl2 >> 8) as u8;
        regs.l_ = raw.hl2 as u8;
        regs.ix = raw.ix;
        regs.iy = raw.iy;
        regs.sp = raw.sp;
        // Correction for z80.h's overlapped-fetch pipeline: by the time an
        // instruction is reported done, the NEXT opcode's byte has already
        // been fetched, so the raw pc reads one past the address the Rust
        // core (no such pipeline) considers "current" -- EXCEPT while
        // halted: real hardware (and z80.h) freezes the visible PC at
        // halt_addr+1 with no further look-ahead fetch, so raw pc there
        // already IS the corrected value and must not be decremented again.
        // Found empirically by comparing raw vs corrected pc step-by-step
        // through a HALT transition -- matches the Python project's own
        // note that some states (there: an in-flight interrupt push) need
        // the raw value, not the blanket -1.
        regs.pc = if self.pins & PIN_HALT != 0 {
            raw.pc
        } else {
            raw.pc.wrapping_sub(1)
        };
        regs.i = (raw.ir >> 8) as u8;
        regs.r = raw.ir as u8;
        regs.iff1 = raw.iff1;
        regs.iff2 = raw.iff2;
        regs.im = raw.im;
        regs.wz = raw.wz;
        regs
    }

    pub fn set_registers(&mut self, regs: &Registers, mem: &mut impl Memory) {
        let raw = ZxRegs {
            pc: regs.pc,
            sp: regs.sp,
            af: regs.af(),
            bc: regs.bc(),
            de: regs.de(),
            hl: regs.hl(),
            ix: regs.ix,
            iy: regs.iy,
            ir: ((regs.i as u16) << 8) | regs.r as u16,
            wz: regs.wz,
            af2: ((regs.a_ as u16) << 8) | regs.f_ as u16,
            bc2: ((regs.b_ as u16) << 8) | regs.c_ as u16,
            de2: ((regs.d_ as u16) << 8) | regs.e_ as u16,
            hl2: ((regs.h_ as u16) << 8) | regs.l_ as u16,
            im: regs.im,
            iff1: regs.iff1,
            iff2: regs.iff2,
        };
        unsafe { zx_set_regs(self.handle, &raw) };
        // zx_set_regs only writes the register struct -- like the Python
        // project's own core, a raw pc write needs a prefetch to actually
        // redirect the pipeline (see the pc-correction comment above).
        unsafe { self.pins = zx_prefetch(self.handle, regs.pc) };
        // z80_prefetch() leaves opdone() artifactually true on the very
        // next tick regardless of whether a real instruction completed --
        // the overlapped-fetch pipeline's structural M1|RD state, not a
        // completed op. Exactly one throwaway tick here (servicing memory,
        // since that tick can assert MREQ) matches the Python project's own
        // `Spectrum48K._prime_fetch()`, same root cause, so a later
        // `step()` call always sees one real instruction boundary.
        unsafe { self.pins = zx_tick(self.handle, self.pins) };
        self.service_memory(mem);
    }

    /// The pins as of the most recent `tick()`/`set_registers()` call.
    pub fn pins(&self) -> u64 {
        self.pins
    }

    /// Raw single-T-state tick, matching `zx_core::Cpu::tick()`'s shape
    /// exactly (pure function of `self` + the given pins, no automatic
    /// memory servicing) -- for pin-level differential tests that need to
    /// compare tick-by-tick, not just after whole instructions.
    pub fn tick(&mut self, pins: u64) -> u64 {
        self.pins = unsafe { zx_tick(self.handle, pins) };
        self.pins
    }

    /// Steps exactly one instruction, servicing memory pins the same way
    /// the Python project's `tests/test_z80_smoke.py` does.
    pub fn step(&mut self, mem: &mut impl Memory) {
        unsafe {
            self.pins = zx_tick(self.handle, self.pins);
            self.service_memory(mem);
            while !zx_opdone(self.handle) {
                self.pins = zx_tick(self.handle, self.pins);
                self.service_memory(mem);
            }
        }
    }

    fn service_memory(&mut self, mem: &mut impl Memory) {
        if self.pins & PIN_MREQ != 0 {
            let addr = get_addr(self.pins);
            if self.pins & PIN_RD != 0 {
                self.pins = set_data(self.pins, mem.read(addr));
            } else if self.pins & PIN_WR != 0 {
                mem.write(addr, get_data(self.pins));
            }
        }
    }

    /// Same as `step()`, but also services IORQ -- every port read returns
    /// `io_read_value` (a real device's identity doesn't matter for a
    /// differential test; only that both cores see the SAME byte), and a
    /// port write is a no-op (nothing here needs to inspect what got
    /// written, only the resulting register/flag state). For block I/O
    /// opcodes (INI/IND/INIR/INDR/OUTI/OUTD/OTIR/OTDR), which `step()`
    /// alone can't exercise meaningfully since it never supplies any port
    /// data at all.
    pub fn step_with_io(&mut self, mem: &mut impl Memory, io_read_value: u8) {
        unsafe {
            self.pins = zx_tick(self.handle, self.pins);
            self.service_memory_and_io(mem, io_read_value);
            while !zx_opdone(self.handle) {
                self.pins = zx_tick(self.handle, self.pins);
                self.service_memory_and_io(mem, io_read_value);
            }
        }
    }

    fn service_memory_and_io(&mut self, mem: &mut impl Memory, io_read_value: u8) {
        if self.pins & PIN_IORQ != 0 {
            if self.pins & PIN_RD != 0 {
                self.pins = set_data(self.pins, io_read_value);
            }
            // A write's value is discarded -- see `step_with_io`'s doc
            // comment.
        } else {
            self.service_memory(mem);
        }
    }
}

impl Drop for ReferenceCpu {
    fn drop(&mut self) {
        unsafe { zx_free(self.handle) };
    }
}
