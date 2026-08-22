//! Command/Event shapes, ported from `zxspectrum/engine/commands.py`. Unlike
//! Python's single generic `submit()` (which returns whatever the handler
//! puts in a duck-typed future), each `Command` variant here carries its
//! OWN typed `oneshot::Sender` for its own reply type -- more idiomatic
//! Rust than mirroring Python's dynamic dispatch literally, and every
//! `Engine` call ends up strongly typed instead of needing a downcast.

use tokio::sync::oneshot;
use zx_core::Registers;

/// Full state snapshot, mirrors `commands.py`'s `State` dataclass (returned
/// as `GetState`'s reply, not fanned out as an event -- same as Python).
#[derive(Debug, Clone, serde::Serialize)]
pub struct State {
    pub pc: u16,
    pub registers: Registers,
    pub breakpoints: Vec<u16>,
    pub running: bool,
    pub border: u8,
    /// Sum of memory + IO contention delay T-states over the last fully
    /// completed frame -- a numeric readout of contention even without
    /// the visual overlay (see `Command::SetContentionOverlay`).
    pub contended_tstates_last_frame: u32,
    /// Return addresses for CALL/RST frames currently unwound below `pc`,
    /// oldest first -- see `Spectrum48K::call_stack`.
    pub call_stack: Vec<u16>,
}

pub enum Command {
    Step {
        instructions: u32,
        ticks: Option<u32>,
        reply: oneshot::Sender<Registers>,
    },
    Run {
        reply: oneshot::Sender<State>,
    },
    Reset {
        reply: oneshot::Sender<Registers>,
    },
    // These carry a `oneshot::Sender<()>` purely so the caller can `await`
    // the command actually being APPLIED before proceeding (matching
    // Python's `submit()`-for-everything, which every `Engine` method uses
    // even for side-effect-only commands) -- not because they return a
    // meaningful value.
    SetBreakpoint {
        addr: u16,
        reply: oneshot::Sender<()>,
    },
    ClearBreakpoint {
        addr: u16,
        reply: oneshot::Sender<()>,
    },
    ReadMemory {
        addr: u16,
        length: usize,
        reply: oneshot::Sender<Vec<u8>>,
    },
    WriteMemory {
        addr: u16,
        data: Vec<u8>,
        reply: oneshot::Sender<()>,
    },
    GetRegisters {
        reply: oneshot::Sender<Registers>,
    },
    SetRegisters {
        regs: Registers,
        reply: oneshot::Sender<Registers>,
    },
    GetScreen {
        reply: oneshot::Sender<Vec<u8>>,
    },
    GetState {
        reply: oneshot::Sender<State>,
    },
    LoadRom {
        data: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    LoadSnapshot {
        data: Vec<u8>,
        reply: oneshot::Sender<Result<Registers, String>>,
    },
}

/// Fanned out to every `Engine::subscribe()`r, mirrors `commands.py`'s
/// `Stopped`/`Continued`/`ResetEvent`. `reason` matches Python's string
/// values (`"step"`/`"breakpoint"`/`"pause"`/`"entry"`) exactly, so a DAP
/// layer translating to `stopped`'s `reason` field needs no remapping.
#[derive(Debug, Clone)]
pub enum Event {
    Stopped { reason: &'static str, pc: u16 },
    Continued,
    Reset,
}
