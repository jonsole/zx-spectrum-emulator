//! DAP (Debug Adapter Protocol) TCP server, ported from
//! `zxspectrum/server/dap.py`. Real base-protocol framing
//! (`Content-Length: N\r\n\r\n{json}`), a per-connection request loop, and
//! a second, independent per-connection task forwarding `Engine` events as
//! unsolicited `stopped`/`continued` DAP events -- events and responses are
//! written through one shared, ordered channel to the same writer task, so
//! (matching the reference, which the same way lets its own two coroutines'
//! writes interleave) the two can legitimately arrive in either order, and
//! any client must tolerate that.
//!
//! Stack traces are always a single synthetic frame at PC (still no
//! call-stack tracking -- `Spectrum48K` doesn't track one yet, matching
//! this project's own original v1 scope), labeled with the disassembled
//! instruction there. When debug info is available for the address --
//! either the currently-loaded program's own (attached via `launch`'s
//! `sld`/`asm` args, or the MCP `load_debug_info` tool) or the ROM's own
//! (built by `scripts/build_rom_source.py`, always available once built) --
//! that frame also gets a `source`/`line`, and source-line breakpoints
//! (set by clicking the gutter in that file) resolve to addresses via the
//! same SLD data. The loaded program's own debug info takes priority; the
//! ROM's is checked as a fallback so calling from a loaded program into a
//! ROM routine still resolves.

use base64::Engine as _;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use zx_engine::{Engine, Event};

use crate::rom_source::Sources;

const THREAD_ID: i64 = 1;

// Reserved width (label name + ":" + a 2-space gap) for the label column
// folded into each disassembled line -- fixed regardless of whether that
// particular line has a label, so mnemonics all start in the same column
// instead of only the labeled lines being indented. 12 chars comfortably
// fits real ROM/game routine names (e.g. "START_NEW", "LD_EDGE_1"); a
// longer one just doesn't pad further.
const LABEL_COLUMN_WIDTH: usize = 12 + 3; // 12 + len(":  ")

pub async fn serve(engine: Engine, sources: Sources, host: &str, port: u16) -> io::Result<()> {
    let listener = TcpListener::bind((host, port)).await?;
    println!("DAP server listening on {host}:{port}");
    loop {
        let (stream, _) = listener.accept().await?;
        let engine = engine.clone();
        let sources = sources.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, engine, sources).await {
                eprintln!("DAP connection error: {e}");
            }
        });
    }
}

async fn read_message(reader: &mut BufReader<tokio::net::tcp::OwnedReadHalf>) -> Option<Value> {
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line).await.ok()?;
        if n == 0 {
            return None; // EOF
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().ok();
            }
        }
    }
    let length = content_length?;
    let mut buf = vec![0u8; length];
    reader.read_exact(&mut buf).await.ok()?;
    serde_json::from_slice(&buf).ok()
}

fn frame_message(message: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(message).expect("DAP message is valid JSON");
    let mut out = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    out.extend_from_slice(&body);
    out
}

#[derive(Default)]
struct ConnectionState {
    // setBreakpoints (source-line) and setInstructionBreakpoints each
    // replace only their own category per the DAP spec, but the engine
    // itself just has one flat address set -- tracked per-category here
    // and reconciled by sync_breakpoints() so setting one kind doesn't wipe
    // out the other within this connection.
    source_breakpoints: HashMap<String, HashSet<u16>>,
    instruction_breakpoints: HashSet<u16>,
    known_breakpoints: HashSet<u16>,
}

async fn handle_connection(stream: TcpStream, engine: Engine, sources: Sources) -> io::Result<()> {
    let (read_half, write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut writer = write_half;

    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer_task = tokio::spawn(async move {
        while let Some(bytes) = out_rx.recv().await {
            if writer.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });

    // Subscribe BEFORE entering the request loop -- mirrors `dap.py`'s own
    // race-avoidance ("subscribe first, so an event published as a side
    // effect of handling the very first request can't be missed").
    let mut events_rx = engine.subscribe();
    let seq = Arc::new(AtomicI64::new(1));

    let forward_tx = out_tx.clone();
    let forward_seq = seq.clone();
    let forward_task = tokio::spawn(async move {
        while let Ok(event) = events_rx.recv().await {
            if let Some(body) = event_body(&event) {
                let msg = envelope_event(&forward_seq, body.0, body.1);
                if forward_tx.send(frame_message(&msg)).is_err() {
                    break;
                }
            }
        }
    });

    let mut state = ConnectionState::default();
    loop {
        let Some(request) = read_message(&mut reader).await else {
            break;
        };
        let command = request["command"].as_str().unwrap_or("").to_string();
        let response = handle_request(&request, &engine, &sources, &mut state, &seq).await;
        let success = response.get("success").and_then(Value::as_bool).unwrap_or(false);
        if out_tx.send(frame_message(&response)).is_err() {
            break;
        }
        if command == "initialize" && success {
            // Per the DAP spec: the adapter sends `initialized` right after
            // its `initialize` response, signaling it's ready for
            // `setBreakpoints`/`setInstructionBreakpoints`/etc. Real DAP
            // clients (VS Code included) gate sending those requests on
            // this event -- without it, breakpoints set in the UI are
            // never actually transmitted to the server at all, so
            // `continue` runs straight past them. (Missing here until
            // this fix; a hand-written test client that doesn't wait for
            // it never noticed.)
            let msg = envelope_event(&seq, "initialized", json!({}));
            if out_tx.send(frame_message(&msg)).is_err() {
                break;
            }
        }
    }

    forward_task.abort();
    drop(out_tx);
    writer_task.await.ok();
    Ok(())
}

/// (event name, body) for an `Engine` event, or `None` if it has no direct
/// DAP equivalent (matches `ResetEvent` in the Python reference, which is
/// always paired with a separate `Stopped(reason="entry")` that DOES map).
fn event_body(event: &Event) -> Option<(&'static str, Value)> {
    match event {
        Event::Stopped { reason, pc } => Some((
            "stopped",
            json!({
                "reason": reason,
                "threadId": THREAD_ID,
                "allThreadsStopped": true,
                "description": format!("0x{pc:04X}"),
            }),
        )),
        Event::Continued => Some((
            "continued",
            json!({ "threadId": THREAD_ID, "allThreadsContinued": true }),
        )),
        Event::Reset => None,
    }
}

fn envelope_event(seq: &AtomicI64, event: &str, body: Value) -> Value {
    let n = seq.fetch_add(1, Ordering::Relaxed);
    json!({ "seq": n, "type": "event", "event": event, "body": body })
}

fn envelope_response(seq: &AtomicI64, request_seq: i64, command: &str, success: bool, body: Value) -> Value {
    let n = seq.fetch_add(1, Ordering::Relaxed);
    json!({
        "seq": n,
        "type": "response",
        "request_seq": request_seq,
        "success": success,
        "command": command,
        "body": body,
    })
}

fn try_parse_hex_addr(s: &str) -> Option<u16> {
    let s = s.trim();
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    u16::from_str_radix(s, 16).ok()
}

/// Mirrors `dap.py`'s `_as_addr`: a hex-string-or-int address plus a signed
/// offset, wrapped to 16 bits. Returns `None` on a malformed/missing
/// value -- callers that must never error on that (e.g. `disassemble`, hit
/// by a real VS Code bug when this happens, see its handler) rely on this;
/// callers that just want a best-effort address use `.unwrap_or(0)`.
fn as_addr(value: Option<&Value>, offset: i64) -> Option<u16> {
    let base: i64 = match value? {
        Value::String(s) => try_parse_hex_addr(s)? as i64,
        Value::Number(n) => n.as_i64().or_else(|| n.as_u64().map(|u| u as i64))?,
        _ => return None,
    };
    Some(base.wrapping_add(offset).rem_euclid(0x10000) as u16)
}

async fn handle_request(
    req: &Value,
    engine: &Engine,
    sources: &Sources,
    state: &mut ConnectionState,
    seq: &Arc<AtomicI64>,
) -> Value {
    let command = req["command"].as_str().unwrap_or("");
    let request_seq = req["seq"].as_i64().unwrap_or(0);
    let empty = json!({});
    let arguments = req.get("arguments").unwrap_or(&empty);

    let (success, body) = match command {
        "initialize" => (
            true,
            json!({
                "supportsConfigurationDoneRequest": true,
                "supportsInstructionBreakpoints": true,
                "supportsReadMemoryRequest": true,
                "supportsWriteMemoryRequest": true,
                "supportsDisassembleRequest": true,
                "supportsSteppingGranularity": false,
            }),
        ),
        "launch" => {
            if let Some(rom_path) = arguments.get("rom").and_then(Value::as_str) {
                match std::fs::read(rom_path) {
                    Ok(data) => {
                        if let Err(e) = engine.load_rom(data).await {
                            return envelope_response(seq, request_seq, command, false, json!({"message": e}));
                        }
                    }
                    Err(e) => {
                        return envelope_response(
                            seq,
                            request_seq,
                            command,
                            false,
                            json!({"message": format!("couldn't read ROM {rom_path}: {e}")}),
                        );
                    }
                }
            }
            if let Some(snapshot_path) = arguments.get("snapshot").and_then(Value::as_str) {
                match std::fs::read(snapshot_path) {
                    Ok(data) => {
                        if let Err(e) = engine.load_snapshot(data).await {
                            return envelope_response(seq, request_seq, command, false, json!({"message": e}));
                        }
                    }
                    Err(e) => {
                        return envelope_response(
                            seq,
                            request_seq,
                            command,
                            false,
                            json!({"message": format!("couldn't read snapshot {snapshot_path}: {e}")}),
                        );
                    }
                }
            } else {
                engine.reset().await;
            }
            // Source-level debug info for the loaded program (as opposed to
            // the ROM's own, always available separately once built) --
            // only acted on when both args are present, same as the Python
            // reference. Unlike the Python engine, this doesn't get
            // auto-cleared by a later launch/snapshot with no sld/asm of
            // its own; a fresh `load_debug_info` (or another `launch` that
            // does pass sld/asm) is what replaces it.
            let sld_path = arguments.get("sld").and_then(Value::as_str);
            let asm_path = arguments.get("asm").and_then(Value::as_str);
            if let (Some(sld), Some(asm)) = (sld_path, asm_path) {
                if let Err(e) = sources.debug_info.load(Path::new(sld), Path::new(asm)) {
                    return envelope_response(seq, request_seq, command, false, json!({"message": e}));
                }
            }
            (true, json!({}))
        }
        "attach" | "configurationDone" | "disconnect" => (true, json!({})),
        "setInstructionBreakpoints" => {
            let requested: HashSet<u16> = arguments
                .get("breakpoints")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|bp| {
                            let offset = bp.get("offset").and_then(Value::as_i64).unwrap_or(0);
                            as_addr(bp.get("instructionReference"), offset)
                        })
                        .collect()
                })
                .unwrap_or_default();
            let breakpoints: Vec<Value> = requested
                .iter()
                .map(|addr| json!({"verified": true, "instructionReference": format!("0x{addr:04X}")}))
                .collect();
            state.instruction_breakpoints = requested;
            sync_breakpoints(engine, state).await;
            (true, json!({ "breakpoints": breakpoints }))
        }
        "setBreakpoints" => {
            let source_path =
                arguments.get("source").and_then(|s| s.get("path")).and_then(Value::as_str).unwrap_or("");
            let rom_source = sources.source_for_path(source_path);

            let mut addrs = HashSet::new();
            let mut results = Vec::new();
            for bp in arguments.get("breakpoints").and_then(Value::as_array).into_iter().flatten() {
                let Some(line) = bp.get("line").and_then(Value::as_u64) else { continue };
                let line = line as u32;
                let addr = rom_source.as_ref().and_then(|s| s.line_to_addr.get(&line).copied());
                match addr {
                    None => results.push(json!({
                        "verified": false, "line": line, "message": "no instruction at this line",
                    })),
                    Some(addr) => {
                        addrs.insert(addr);
                        results.push(json!({
                            "verified": true, "line": line, "instructionReference": format!("0x{addr:04X}"),
                        }));
                    }
                }
            }
            state.source_breakpoints.insert(source_path.to_string(), addrs);
            sync_breakpoints(engine, state).await;
            (true, json!({ "breakpoints": results }))
        }
        "continue" => {
            let engine = engine.clone();
            tokio::spawn(async move {
                engine.run().await;
            });
            (true, json!({ "allThreadsContinued": true }))
        }
        "next" => {
            // Step over: a plain single step already steps INTO a CALL/RST
            // (it just executes the instruction, which pushes the return
            // address and jumps) -- that's exactly `stepIn`'s semantics, so
            // this only needs to special-case CALL/RST. For those, run
            // (rather than single-step) until a breakpoint set at the
            // instruction immediately after the call/rst is hit, which is
            // where execution lands once the subroutine returns. Spawned in
            // the background (mirroring `continue`, below) rather than
            // awaited inline, so a subroutine that never returns can't wedge
            // this connection's request loop -- a `pause` request can still
            // interrupt it, and the eventual `stopped` event reaches the
            // client via the connection's separate event-forwarding task.
            let regs = engine.get_registers().await;
            let mem = engine.watch_memory().borrow().clone();
            let read = |a: u16| mem[a as usize];
            let inst = zx_core::disassemble_one(&read, regs.pc);
            if inst.text.starts_with("CALL") || inst.text.starts_with("RST") {
                let return_addr = regs.pc.wrapping_add(inst.length as u16);
                // Don't clear a breakpoint the user actually set there.
                let already_set = state.known_breakpoints.contains(&return_addr);
                let engine = engine.clone();
                tokio::spawn(async move {
                    if !already_set {
                        engine.set_breakpoint(return_addr).await;
                    }
                    engine.run().await;
                    if !already_set {
                        engine.clear_breakpoint(return_addr).await;
                    }
                });
            } else {
                engine.step(1, None).await;
            }
            (true, json!({}))
        }
        "stepIn" | "stepOut" => {
            engine.step(1, None).await;
            (true, json!({}))
        }
        "pause" => {
            engine.pause();
            (true, json!({}))
        }
        "threads" => (true, json!({ "threads": [{"id": THREAD_ID, "name": "Z80"}] })),
        "stackTrace" => {
            let regs = engine.get_registers().await;
            let mem = engine.watch_memory().borrow().clone();
            let frame = build_frame(sources, &mem, 0, regs.pc);
            (true, json!({ "stackFrames": [frame], "totalFrames": 1 }))
        }
        "scopes" => (
            true,
            json!({
                "scopes": [
                    {"name": "Registers", "variablesReference": 1000, "expensive": false},
                    {"name": "Flags", "variablesReference": 1001, "expensive": false},
                ]
            }),
        ),
        "variables" => {
            let reference = arguments.get("variablesReference").and_then(Value::as_i64).unwrap_or(0);
            let regs = engine.get_registers().await;
            let variables = match reference {
                1000 => register_variables(&regs),
                1001 => flag_variables(&regs),
                _ => vec![],
            };
            (true, json!({ "variables": variables }))
        }
        "readMemory" => {
            let offset = arguments.get("offset").and_then(Value::as_i64).unwrap_or(0);
            let addr = as_addr(arguments.get("memoryReference"), offset).unwrap_or(0);
            let count = arguments.get("count").and_then(Value::as_u64).unwrap_or(0) as usize;
            let data = engine.read_memory(addr, count).await;
            (
                true,
                json!({
                    "address": format!("0x{addr:04X}"),
                    "data": base64::engine::general_purpose::STANDARD.encode(&data),
                }),
            )
        }
        "writeMemory" => {
            let offset = arguments.get("offset").and_then(Value::as_i64).unwrap_or(0);
            let addr = as_addr(arguments.get("memoryReference"), offset).unwrap_or(0);
            let data = arguments
                .get("data")
                .and_then(Value::as_str)
                .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                .unwrap_or_default();
            let written = data.len();
            engine.write_memory(addr, data).await;
            (true, json!({ "bytesWritten": written }))
        }
        "disassemble" => {
            let offset = arguments.get("offset").and_then(Value::as_i64).unwrap_or(0);
            match as_addr(arguments.get("memoryReference"), offset) {
                None => {
                    // VS Code's Disassembly View can internally generate a
                    // "disassemblyNotAvailable" placeholder request with an
                    // empty memoryReference (e.g. while a scroll event
                    // races session setup) -- a known VS Code bug
                    // (microsoft/vscode#270361) means a *failed* response
                    // to that specific request can permanently wedge the
                    // view's internal loading lock, silently breaking all
                    // future auto-scroll-to-PC behavior for the rest of
                    // that view's lifetime. A harmless empty result avoids
                    // ever triggering that, regardless of whether the
                    // user's VS Code build already has the upstream fix.
                    (true, json!({ "instructions": [] }))
                }
                Some(base_addr) => (true, disassemble(sources, engine, arguments, base_addr).await),
            }
        }
        other => (false, json!({ "message": format!("unsupported request: {other}") })),
    };

    envelope_response(seq, request_seq, command, success, body)
}

async fn sync_breakpoints(engine: &Engine, state: &mut ConnectionState) {
    let mut desired: HashSet<u16> = state.instruction_breakpoints.clone();
    for addrs in state.source_breakpoints.values() {
        desired.extend(addrs);
    }
    let to_set: Vec<u16> = desired.difference(&state.known_breakpoints).copied().collect();
    let to_clear: Vec<u16> = state.known_breakpoints.difference(&desired).copied().collect();
    for addr in to_set {
        engine.set_breakpoint(addr).await;
    }
    for addr in to_clear {
        engine.clear_breakpoint(addr).await;
    }
    state.known_breakpoints = desired;
}

fn build_frame(sources: &Sources, mem: &[u8], frame_id: i64, addr: u16) -> Value {
    let read = |a: u16| mem[a as usize];
    let inst = zx_core::disassemble_one(&read, addr);
    let text = zx_core::annotate_symbols(&inst.text, |a| sources.resolve_symbol(a));
    let name = format!("0x{addr:04X}: {text}");

    let mut frame = json!({
        "id": frame_id,
        "name": name,
        "instructionPointerReference": format!("0x{addr:04X}"),
        "line": 0,
        "column": 0,
    });

    // First source (loaded program, then ROM) with an exact address match
    // wins -- symbol_at() alone would find SOME nearest label from a
    // source that doesn't actually cover this address at all (e.g. it only
    // has entries far below PC), which would mislabel the frame rather
    // than just showing no source for it.
    for source in sources.active() {
        let Some(&line) = source.addr_to_line.get(&addr) else { continue };
        if let Some((sym_name, sym_offset)) = source.symbol_at(addr, None) {
            let label = if sym_offset != 0 { format!("{sym_name}+{sym_offset}") } else { sym_name };
            frame["name"] = json!(format!("{label}  {name}"));
        }
        frame["source"] = json!({
            "name": source.asm_path.file_name().map(|n| n.to_string_lossy().into_owned()),
            "path": source.asm_path.to_string_lossy(),
        });
        frame["line"] = json!(line);
        frame["column"] = json!(1);
        break;
    }
    frame
}

async fn disassemble(sources: &Sources, engine: &Engine, arguments: &Value, base_addr: u16) -> Value {
    let mem = engine.watch_memory().borrow().clone();
    let read = |a: u16| mem[a as usize];

    let instruction_offset = arguments.get("instructionOffset").and_then(Value::as_i64).unwrap_or(0);
    let count = arguments.get("instructionCount").and_then(Value::as_i64).unwrap_or(0).max(0) as usize;

    let start = if instruction_offset > 0 {
        // Walk forward `instruction_offset` instructions from base_addr --
        // unlike the backward case, this is unambiguous (variable-length
        // decoding only needs a direction, not a search).
        let mut addr = base_addr;
        for _ in 0..instruction_offset {
            addr = addr.wrapping_add(zx_core::disassemble_one(&read, addr).length as u16);
        }
        addr
    } else if instruction_offset < 0 {
        find_aligned_backward_start(&read, base_addr, (-instruction_offset) as u32)
    } else {
        base_addr
    };

    let instructions = zx_core::disassemble_range(&read, start, count);
    let result: Vec<Value> = instructions
        .iter()
        .map(|inst| {
            let text = zx_core::annotate_symbols(&inst.text, |a| sources.resolve_symbol(a));
            let label = sources.label_at(inst.addr);
            // DAP has a dedicated "symbol" field for this, which the spec
            // says a client MAY render as a heading above the line -- VS
            // Code's Disassembly View does not, in practice, do that
            // (confirmed live against the Python server: the field
            // arrives but nothing shows), so the label is also folded
            // directly into the instruction text, which every client
            // renders by definition. Every line gets the same fixed-width
            // label column -- labeled or not -- so the actual mnemonics
            // all start in the same column instead of staggering only
            // where a label happens to land.
            let label_prefix = label.as_deref().map(|l| format!("{l}:")).unwrap_or_default();
            let text = format!("{label_prefix:<LABEL_COLUMN_WIDTH$}{text}");
            let mut entry = json!({
                "address": format!("0x{:04X}", inst.addr),
                "instructionBytes": inst.raw.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                "instruction": text,
            });
            if let Some(l) = &label {
                entry["symbol"] = json!(l);
            }
            entry
        })
        .collect();
    json!({ "instructions": result })
}

fn find_aligned_backward_start(read: &impl Fn(u16) -> u8, base_addr: u16, needed_before: u32) -> u16 {
    // Z80 instructions are 1-4 bytes; searching back needed_before * 4
    // bytes comfortably covers every real instruction stream (capped so a
    // huge request -- e.g. VS Code paging in hundreds of instructions of
    // context -- can't make this pathologically slow).
    //
    // The 64KB address space wraps (0xFFFF is immediately followed by
    // 0x0000), which every address computed here masks to 16 bits
    // (`wrapping_sub`/`wrapping_add`) throughout so a base_addr near
    // 0x0000 still searches correctly instead of silently "finding
    // nothing" and falling back to no before-context.
    let max_search = (needed_before.saturating_mul(4) + 16).min(2048);
    for back in 1..=max_search {
        let candidate = base_addr.wrapping_sub(back as u16);
        let mut addr = candidate;
        for _ in 0..needed_before {
            let inst = zx_core::disassemble_one(read, addr);
            addr = addr.wrapping_add(inst.length as u16);
        }
        if addr == base_addr {
            return candidate;
        }
    }
    base_addr
}

fn register_variables(regs: &zx_core::Registers) -> Vec<Value> {
    let entries: [(&str, u32); 16] = [
        ("A", regs.a as u32), ("F", regs.f as u32),
        ("BC", regs.bc() as u32), ("DE", regs.de() as u32), ("HL", regs.hl() as u32),
        ("A'", regs.a_ as u32), ("F'", regs.f_ as u32),
        ("BC'", (((regs.b_ as u16) << 8) | regs.c_ as u16) as u32),
        ("DE'", (((regs.d_ as u16) << 8) | regs.e_ as u16) as u32),
        ("HL'", (((regs.h_ as u16) << 8) | regs.l_ as u16) as u32),
        ("IX", regs.ix as u32), ("IY", regs.iy as u32),
        ("SP", regs.sp as u32), ("PC", regs.pc as u32),
        ("I", regs.i as u32), ("R", regs.r as u32),
    ];
    let mut variables: Vec<Value> = entries
        .into_iter()
        .map(|(name, value)| {
            let width = if value > 0xFF { 4 } else { 2 };
            json!({
                "name": name,
                "value": format!("0x{value:0width$X}", width = width),
                "variablesReference": 0,
                "memoryReference": format!("0x{value:04X}"),
            })
        })
        .collect();
    variables.push(json!({"name": "IM", "value": regs.im.to_string(), "variablesReference": 0}));
    variables.push(json!({"name": "IFF1", "value": regs.iff1.to_string(), "variablesReference": 0}));
    variables.push(json!({"name": "IFF2", "value": regs.iff2.to_string(), "variablesReference": 0}));
    variables
}

fn flag_variables(regs: &zx_core::Registers) -> Vec<Value> {
    let bits: [(&str, u8); 6] = [
        ("S", 0x80), ("Z", 0x40), ("H", 0x10), ("P/V", 0x04), ("N", 0x02), ("C", 0x01),
    ];
    bits.into_iter()
        .map(|(name, mask)| {
            json!({
                "name": name,
                "value": if regs.f & mask != 0 { "1" } else { "0" },
                "variablesReference": 0,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom_source::DebugInfo;
    use std::path::PathBuf;

    async fn request(
        engine: &Engine,
        sources: &Sources,
        state: &mut ConnectionState,
        seq: &Arc<AtomicI64>,
        command: &str,
        arguments: Value,
    ) -> Value {
        let req = json!({"seq": 1, "type": "request", "command": command, "arguments": arguments});
        handle_request(&req, engine, sources, state, seq).await
    }

    /// `next` (step over) must run PAST a CALL instead of single-stepping
    /// into it (which is `stepIn`'s job) -- regression coverage for the fix
    /// making it set a temporary breakpoint at the return address and run to
    /// it, instead of just calling `engine.step(1, ..)` like every other
    /// step request.
    #[tokio::test]
    async fn next_steps_over_a_call() {
        let engine = Engine::new();
        let sources = Sources::new(DebugInfo::default(), PathBuf::new());
        let mut state = ConnectionState::default();
        let seq = Arc::new(AtomicI64::new(1));

        let base: u16 = 0x8000;
        let callee: u16 = base.wrapping_add(0x100);
        engine.write_memory(base, vec![0xCD, (callee & 0xFF) as u8, (callee >> 8) as u8]).await; // CALL callee
        engine.write_memory(callee, vec![0xC9]).await; // RET

        let mut regs = engine.get_registers().await;
        regs.pc = base;
        regs.sp = 0xFFF0;
        engine.set_registers(regs).await;

        let mut events = engine.subscribe();

        let resp = request(&engine, &sources, &mut state, &seq, "next", json!({"threadId": 1})).await;
        assert_eq!(resp["success"], true);

        // `next`'s run-to-return happens in a spawned background task (so a
        // callee that never returns can't wedge the connection) -- wait for
        // its `stopped` event rather than asserting on registers right away.
        loop {
            if let Event::Stopped { reason: "breakpoint", .. } = events.recv().await.unwrap() {
                break;
            }
        }

        let regs = engine.get_registers().await;
        assert_eq!(regs.pc, base.wrapping_add(3)); // landed after the CALL, not inside it

        // The temporary breakpoint used to land here must not leak.
        let state_snapshot = engine.get_state().await;
        assert!(state_snapshot.breakpoints.is_empty());
    }

    /// A plain `stepIn` request is unaffected by the `next` fix -- it must
    /// still land INSIDE the call, one instruction in.
    #[tokio::test]
    async fn step_in_still_steps_into_a_call() {
        let engine = Engine::new();
        let sources = Sources::new(DebugInfo::default(), PathBuf::new());
        let mut state = ConnectionState::default();
        let seq = Arc::new(AtomicI64::new(1));

        let base: u16 = 0x8000;
        let callee: u16 = base.wrapping_add(0x100);
        engine.write_memory(base, vec![0xCD, (callee & 0xFF) as u8, (callee >> 8) as u8]).await; // CALL callee
        engine.write_memory(callee, vec![0xC9]).await; // RET

        let mut regs = engine.get_registers().await;
        regs.pc = base;
        regs.sp = 0xFFF0;
        engine.set_registers(regs).await;

        let resp = request(&engine, &sources, &mut state, &seq, "stepIn", json!({"threadId": 1})).await;
        assert_eq!(resp["success"], true);

        let regs = engine.get_registers().await;
        assert_eq!(regs.pc, callee);
    }
}
