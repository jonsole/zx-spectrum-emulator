//! `Engine`: owns the one live `Spectrum48K`, a command queue, and an event
//! broadcast channel. Ported from `zxspectrum/engine/actor.py`.

use crate::commands::{Command, Event, State};
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use zx_core::{Registers, Spectrum48K};

/// How many instructions a `Run` executes between checks for an incoming
/// `pause()` (or any other queued command) -- keeps a long-running program
/// from starving the executor. Matches `actor.py`'s `_RUN_YIELD_EVERY`.
const RUN_YIELD_EVERY: u64 = 2000;

const EVENT_CHANNEL_CAPACITY: usize = 64;

#[derive(Clone)]
pub struct Engine {
    tx: mpsc::Sender<Command>,
    events: broadcast::Sender<Event>,
    /// Deliberately NOT routed through the command queue: `Run`'s handler
    /// monopolizes the actor loop until it yields, so a `Pause` sent
    /// through the same queue could never be dequeued while `Run` is in
    /// flight -- it would deadlock waiting for the very thing it's
    /// supposed to interrupt. Setting the flag directly (mirroring
    /// `actor.py`'s own comment, quoted here verbatim) lets it take effect
    /// on `Run`'s next yield regardless of queue backlog.
    pause_requested: Arc<AtomicBool>,
    /// Same reasoning and same bypass as `pause_requested`: `Run`'s handler
    /// monopolizes the actor loop until it yields or stops, so a toggle
    /// routed through the command queue would sit stuck behind an in-flight
    /// `Run` for as long as the game keeps playing -- exactly when a caller
    /// most wants to see the overlay appear. Synced into
    /// `machine.ula.contention_overlay_enabled` at the same points the
    /// screen gets re-rendered (after every command, and at `Run`'s own
    /// yield cadence), so it never needs the machine to be idle to take
    /// effect. (Confirmed live: an earlier queued-command version of this
    /// silently never applied while a real game was running.)
    contention_overlay_requested: Arc<AtomicBool>,
    /// The latest rendered screen, refreshed by the actor task after every
    /// command AND periodically during a long `Run` (same cadence as its
    /// own pause-check yield). Deliberately NOT routed through the command
    /// queue either: Python's screen-stream server reads `machine`
    /// directly for the same reason (streaming shouldn't stall behind a
    /// live `run()`), safe there only because asyncio is single-threaded;
    /// here a `watch` channel gives the same "always read the latest
    /// snapshot, never block on the actor" property under real threads,
    /// without a second ad hoc locking scheme alongside the command queue.
    screen: watch::Receiver<Vec<u8>>,
    /// The full 64K address space, refreshed at the same points `screen`
    /// is -- backs disassembly, which needs fast, synchronous, random-
    /// access memory reads and (like the screen stream) shouldn't stall
    /// behind a long-running `Run`. Same reasoning as `screen`'s own doc
    /// comment, just for a different reader.
    memory: watch::Receiver<Vec<u8>>,
}

impl Engine {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel(64);
        let (events, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let pause_requested = Arc::new(AtomicBool::new(false));
        let contention_overlay_requested = Arc::new(AtomicBool::new(false));
        let (screen_tx, screen) = watch::channel(Vec::new());
        let (memory_tx, memory) = watch::channel(Vec::new());
        let engine =
            Engine { tx, events, pause_requested, contention_overlay_requested, screen, memory };
        engine.spawn_actor(rx, screen_tx, memory_tx);
        engine
    }

    /// The latest rendered screen (raw RGB, `SCREEN_HEIGHT*SCREEN_WIDTH*3`
    /// bytes) without going through the command queue -- see the `screen`
    /// field doc comment.
    pub fn watch_screen(&self) -> watch::Receiver<Vec<u8>> {
        self.screen.clone()
    }

    /// The full 64K address space without going through the command queue
    /// -- see the `memory` field doc comment.
    pub fn watch_memory(&self) -> watch::Receiver<Vec<u8>> {
        self.memory.clone()
    }

    fn spawn_actor(
        &self,
        rx: mpsc::Receiver<Command>,
        screen_tx: watch::Sender<Vec<u8>>,
        memory_tx: watch::Sender<Vec<u8>>,
    ) {
        let events = self.events.clone();
        let pause_requested = self.pause_requested.clone();
        let contention_overlay_requested = self.contention_overlay_requested.clone();
        tokio::spawn(actor_loop(
            rx,
            events,
            pause_requested,
            contention_overlay_requested,
            screen_tx,
            memory_tx,
        ));
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    /// See the `pause_requested` field doc comment -- bypasses the queue
    /// entirely, matching `actor.py`'s `pause()`.
    pub fn pause(&self) {
        self.pause_requested.store(true, Ordering::Relaxed);
    }

    /// See the `contention_overlay_requested` field doc comment -- bypasses
    /// the queue entirely, same as `pause()`, so it can take effect even
    /// while a `Run` is in flight.
    pub fn set_contention_overlay(&self, enabled: bool) {
        self.contention_overlay_requested.store(enabled, Ordering::Relaxed);
    }

    /// `ticks`, when set, steps that many of the CPU's own T-states rather
    /// than whole instructions (sub-instruction debugging). Note this
    /// means N *CPU-visible* T-states, not necessarily N real T-states of
    /// wall-clock/frame time: ULA contention can make a single
    /// `Spectrum48K::tick()` call silently consume more than one real
    /// T-state (see `Spectrum48K::advance_tstate()`'s doc comment) while
    /// the CPU's own state machine only ever advances by one per call --
    /// which is exactly the semantic wanted here, single-stepping through
    /// the CPU's own dispatch steps regardless of contention.
    pub async fn step(&self, instructions: u32, ticks: Option<u32>) -> Registers {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::Step { instructions, ticks, reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn run(&self) -> State {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::Run { reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn reset(&self) -> Registers {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::Reset { reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn set_breakpoint(&self, addr: u16) {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::SetBreakpoint { addr, reply }).await.ok();
        rx.await.ok();
    }

    pub async fn clear_breakpoint(&self, addr: u16) {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::ClearBreakpoint { addr, reply }).await.ok();
        rx.await.ok();
    }

    pub async fn read_memory(&self, addr: u16, length: usize) -> Vec<u8> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::ReadMemory { addr, length, reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn write_memory(&self, addr: u16, data: Vec<u8>) {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::WriteMemory { addr, data, reply }).await.ok();
        rx.await.ok();
    }

    pub async fn get_registers(&self) -> Registers {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::GetRegisters { reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn set_registers(&self, regs: Registers) -> Registers {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::SetRegisters { regs, reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn key_down(&self, key: String) {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::KeyDown { key, reply }).await.ok();
        rx.await.ok();
    }

    pub async fn key_up(&self, key: String) {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::KeyUp { key, reply }).await.ok();
        rx.await.ok();
    }

    /// Raw RGB bytes (`SCREEN_HEIGHT * SCREEN_WIDTH * 3`) -- PNG-encoding
    /// happens in the server layer, not here.
    pub async fn get_screen(&self) -> Vec<u8> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::GetScreen { reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn get_state(&self) -> State {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::GetState { reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn load_rom(&self, data: Vec<u8>) -> Result<(), String> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::LoadRom { data, reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }

    pub async fn load_snapshot(&self, data: Vec<u8>) -> Result<Registers, String> {
        let (reply, rx) = oneshot::channel();
        self.tx.send(Command::LoadSnapshot { data, reply }).await.ok();
        rx.await.expect("actor task dropped the reply channel")
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

async fn actor_loop(
    mut rx: mpsc::Receiver<Command>,
    events: broadcast::Sender<Event>,
    pause_requested: Arc<AtomicBool>,
    contention_overlay_requested: Arc<AtomicBool>,
    screen_tx: watch::Sender<Vec<u8>>,
    memory_tx: watch::Sender<Vec<u8>>,
) {
    let mut machine = Spectrum48K::new();
    // Always false wherever a caller can observe it -- see the comment in
    // the `Run` handler below.
    let running = false;
    machine.ula.contention_overlay_enabled = contention_overlay_requested.load(Ordering::Relaxed);
    screen_tx.send_replace(machine.render_screen());
    memory_tx.send_replace(machine.read_memory(0, 0x10000));

    while let Some(cmd) = rx.recv().await {
        match cmd {
            Command::Step { instructions, ticks, reply } => {
                let mut panic_msg = None;
                if let Some(ticks) = ticks {
                    for _ in 0..ticks {
                        if let Err(e) = step_tick_catching_panics(&mut machine) {
                            panic_msg = Some(e);
                            break;
                        }
                    }
                } else {
                    for _ in 0..instructions {
                        if let Err(e) = step_instruction_catching_panics(&mut machine) {
                            panic_msg = Some(e);
                            break;
                        }
                    }
                }
                if let Some(msg) = panic_msg {
                    eprintln!("step: CPU panicked mid-instruction, stopping early: {msg}");
                }
                let pc = machine.registers().pc;
                let _ = events.send(Event::Stopped { reason: "step", pc });
                reply.send(machine.registers()).ok();
            }
            Command::Run { reply } => {
                pause_requested.store(false, Ordering::Relaxed);
                // `running` would be `true` for the duration of this loop,
                // but nothing can observe that: the actor loop is a single
                // task processing one command at a time (matching
                // `actor.py`'s own single-coroutine `_loop()`), so no OTHER
                // command -- including `GetState` -- can be dequeued and
                // see `running=true` until this handler itself returns,
                // at which point it's already false again. Not a bug, just
                // an inherent property of the single-actor-loop design;
                // `running` is always `false` in any state a caller can
                // actually read.
                let _ = events.send(Event::Continued);

                let mut reason = "breakpoint";
                let mut count: u64 = 0;
                loop {
                    if pause_requested.load(Ordering::Relaxed) {
                        reason = "pause";
                        break;
                    }
                    // A CPU dispatch panic (e.g. a still-undiscovered
                    // unimplemented opcode) is caught here rather than left
                    // to unwind the whole actor task -- letting it kill this
                    // task would drop every future command's reply channel,
                    // wedging the WHOLE server for every client, not just
                    // the one that hit the bad opcode.
                    if let Err(e) = step_instruction_catching_panics(&mut machine) {
                        eprintln!("run: CPU panicked mid-instruction, stopping: {e}");
                        reason = "error";
                        break;
                    }
                    count += 1;
                    if machine.breakpoints.contains(&machine.registers().pc) {
                        break;
                    }
                    if count % RUN_YIELD_EVERY == 0 {
                        machine.ula.contention_overlay_enabled =
                            contention_overlay_requested.load(Ordering::Relaxed);
                        screen_tx.send_replace(machine.render_screen());
                        memory_tx.send_replace(machine.read_memory(0, 0x10000));
                        tokio::task::yield_now().await;
                    }
                }
                let pc = machine.registers().pc;
                let _ = events.send(Event::Stopped { reason, pc });
                reply.send(state_snapshot(&machine, running)).ok();
            }
            Command::Reset { reply } => {
                machine.reset();
                let _ = events.send(Event::Reset);
                let pc = machine.registers().pc;
                let _ = events.send(Event::Stopped { reason: "entry", pc });
                reply.send(machine.registers()).ok();
            }
            Command::SetBreakpoint { addr, reply } => {
                machine.set_breakpoint(addr);
                reply.send(()).ok();
            }
            Command::ClearBreakpoint { addr, reply } => {
                machine.clear_breakpoint(addr);
                reply.send(()).ok();
            }
            Command::ReadMemory { addr, length, reply } => {
                reply.send(machine.read_memory(addr, length)).ok();
            }
            Command::WriteMemory { addr, data, reply } => {
                machine.write_memory(addr, &data);
                reply.send(()).ok();
            }
            Command::GetRegisters { reply } => {
                reply.send(machine.registers()).ok();
            }
            Command::SetRegisters { regs, reply } => {
                machine.set_registers(regs);
                let pc = machine.registers().pc;
                let _ = events.send(Event::Stopped { reason: "step", pc });
                reply.send(machine.registers()).ok();
            }
            Command::KeyDown { key, reply } => {
                machine.keyboard.key_down(&key);
                reply.send(()).ok();
            }
            Command::KeyUp { key, reply } => {
                machine.keyboard.key_up(&key);
                reply.send(()).ok();
            }
            Command::GetScreen { reply } => {
                reply.send(machine.render_screen()).ok();
            }
            Command::GetState { reply } => {
                reply.send(state_snapshot(&machine, running)).ok();
            }
            Command::LoadRom { data, reply } => {
                reply.send(machine.load_rom(&data)).ok();
            }
            Command::LoadSnapshot { data, reply } => {
                let result = machine.load_snapshot(&data).map(|()| machine.registers());
                if result.is_ok() {
                    let pc = machine.registers().pc;
                    let _ = events.send(Event::Stopped { reason: "entry", pc });
                }
                reply.send(result).ok();
            }
        }
        // Cheap enough to do after every individual command (unlike inside
        // Run's tight per-instruction loop, where it's throttled to the
        // same cadence as the existing yield check above).
        machine.ula.contention_overlay_enabled = contention_overlay_requested.load(Ordering::Relaxed);
        screen_tx.send_replace(machine.render_screen());
        memory_tx.send_replace(machine.read_memory(0, 0x10000));
    }
}

/// Runs one instruction, converting a CPU dispatch panic (an unimplemented
/// opcode -- `cpu.rs`'s own documented "panic loudly rather than do
/// something silently wrong" policy) into an `Err` instead of unwinding the
/// actor task. See the call sites' comments for why the task must survive
/// this.
fn step_instruction_catching_panics(machine: &mut Spectrum48K) -> Result<(), String> {
    panic::catch_unwind(AssertUnwindSafe(|| machine.step_instruction())).map_err(panic_message)
}

/// Same, for a single T-state (`Step`'s `ticks` mode).
fn step_tick_catching_panics(machine: &mut Spectrum48K) -> Result<(), String> {
    panic::catch_unwind(AssertUnwindSafe(|| machine.tick())).map_err(panic_message)
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "actor panicked with a non-string payload".to_string()
    }
}

fn state_snapshot(machine: &Spectrum48K, running: bool) -> State {
    State {
        pc: machine.registers().pc,
        registers: machine.registers(),
        breakpoints: machine.breakpoints.iter().copied().collect(),
        running,
        border: machine.ula.border,
        contended_tstates_last_frame: machine.ula.contended_tstates_last_frame(),
    }
}
