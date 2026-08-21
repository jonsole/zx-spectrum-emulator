//! MCP server, ported from `zxspectrum/server/mcp_server.py`'s tool
//! surface (all but `get_state`'s a couple of intentionally-out-of-scope
//! neighbors -- see the rust-core plan). Built on `rmcp`, the official MCP
//! Rust SDK, using the streamable-HTTP transport (the modern replacement
//! for the SSE transport the Python version uses -- nothing about matching
//! Python's *behavior* requires matching its transport).

use base64::Engine as _;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerInfo,
};
use rmcp::{tool, tool_handler, tool_router, ErrorData as McpError, ServerHandler};
use serde::Deserialize;
use serde_json::json;
use std::path::Path;
use zx_engine::Engine;

use crate::rom_source::Sources;

fn invalid_params(message: impl Into<String>) -> McpError {
    McpError::invalid_params(message.into(), None)
}

fn json_result(value: &impl serde::Serialize) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(
        serde_json::to_string(value).unwrap_or_default(),
    )])
}

fn text_result(message: impl Into<String>) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(message.into())])
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct LoadRomRequest {
    /// Base64-encoded 16384-byte 48K ROM image.
    pub rom_base64: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct LoadSnapshotRequest {
    /// Base64-encoded 49179-byte `.sna` snapshot.
    pub sna_base64: String,
}

fn default_instructions() -> u32 {
    1
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct StepRequest {
    #[serde(default = "default_instructions")]
    pub instructions: u32,
    /// Sub-instruction T-state granularity -- if set, steps this many
    /// T-states instead of whole instructions.
    pub ticks: Option<u32>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct AddrRequest {
    pub addr: u16,
}

fn default_length() -> usize {
    1
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct ReadMemoryRequest {
    pub addr: u16,
    #[serde(default = "default_length")]
    pub length: usize,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct WriteMemoryRequest {
    pub addr: u16,
    /// Hex-encoded bytes to write.
    pub data_hex: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SetRegistersRequest {
    pub pc: Option<u16>,
    pub sp: Option<u16>,
    pub af: Option<u16>,
    pub bc: Option<u16>,
    pub de: Option<u16>,
    pub hl: Option<u16>,
    pub ix: Option<u16>,
    pub iy: Option<u16>,
    pub im: Option<u8>,
    pub iff1: Option<bool>,
    pub iff2: Option<bool>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct KeyRequest {
    /// Key name, e.g. "A", "ENTER", "CAPS SHIFT", "SYM SHIFT", "SPACE".
    pub key: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SetContentionOverlayRequest {
    /// Whether the screen returned by get_screen (and the screen-stream
    /// panel) should be tinted to show ULA memory/IO contention: red for
    /// memory, blue/cyan for IO, per scanline, scaled by how much
    /// contention that line cost over the last full frame.
    pub enabled: bool,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct LoadDebugInfoRequest {
    /// Path to the program's sjasmplus SLD file.
    pub sld_path: String,
    /// Path to the matching .asm source.
    pub asm_path: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct ResolveSymbolRequest {
    /// Routine/label name, e.g. "KEY_INT".
    pub name: String,
}

#[derive(Clone)]
pub struct ZxSpectrumServer {
    engine: Engine,
    sources: Sources,
    tool_router: ToolRouter<ZxSpectrumServer>,
}

#[tool_router]
impl ZxSpectrumServer {
    pub fn new(engine: Engine, sources: Sources) -> Self {
        Self { engine, sources, tool_router: Self::tool_router() }
    }

    #[tool(description = "Load a 48K ROM image (base64-encoded, exactly 16384 bytes)")]
    async fn load_rom(
        &self,
        Parameters(req): Parameters<LoadRomRequest>,
    ) -> Result<CallToolResult, McpError> {
        let data = base64::engine::general_purpose::STANDARD
            .decode(&req.rom_base64)
            .map_err(|e| invalid_params(e.to_string()))?;
        self.engine.load_rom(data).await.map_err(invalid_params)?;
        Ok(text_result("ROM loaded"))
    }

    #[tool(description = "Load a .sna snapshot (base64-encoded) -- restores RAM, registers, and border")]
    async fn load_snapshot(
        &self,
        Parameters(req): Parameters<LoadSnapshotRequest>,
    ) -> Result<CallToolResult, McpError> {
        let data = base64::engine::general_purpose::STANDARD
            .decode(&req.sna_base64)
            .map_err(|e| invalid_params(e.to_string()))?;
        let regs = self.engine.load_snapshot(data).await.map_err(invalid_params)?;
        Ok(json_result(&json!({"pc": regs.pc, "registers": regs})))
    }

    #[tool(description = "Reset the machine (registers only -- RAM/ROM contents are unaffected)")]
    async fn reset(&self) -> Result<CallToolResult, McpError> {
        let regs = self.engine.reset().await;
        Ok(json_result(&json!({"pc": regs.pc})))
    }

    #[tool(description = "Step one or more whole instructions, or a given number of T-states")]
    async fn step(&self, Parameters(req): Parameters<StepRequest>) -> Result<CallToolResult, McpError> {
        let regs = self.engine.step(req.instructions, req.ticks).await;
        Ok(json_result(&json!({"pc": regs.pc, "registers": regs})))
    }

    #[tool(description = "Run until a breakpoint is hit or pause is called")]
    async fn run(&self) -> Result<CallToolResult, McpError> {
        let state = self.engine.run().await;
        Ok(json_result(&json!({"pc": state.pc, "running": state.running})))
    }

    #[tool(description = "Pause an in-flight run")]
    async fn pause(&self) -> Result<CallToolResult, McpError> {
        self.engine.pause();
        Ok(text_result("paused"))
    }

    #[tool(
        description = "Toggle a screen overlay showing ULA memory/IO contention (red/blue tint per \
                        scanline, scaled by contention cost) -- also visible in get_screen and the \
                        VS Code screen-viewer panel while enabled"
    )]
    async fn set_contention_overlay(
        &self,
        Parameters(req): Parameters<SetContentionOverlayRequest>,
    ) -> Result<CallToolResult, McpError> {
        self.engine.set_contention_overlay(req.enabled);
        Ok(text_result(if req.enabled { "contention overlay enabled" } else { "contention overlay disabled" }))
    }

    #[tool(description = "Set a breakpoint at an address")]
    async fn set_breakpoint(
        &self,
        Parameters(req): Parameters<AddrRequest>,
    ) -> Result<CallToolResult, McpError> {
        self.engine.set_breakpoint(req.addr).await;
        Ok(text_result(format!("breakpoint set at 0x{:04X}", req.addr)))
    }

    #[tool(description = "Clear a breakpoint at an address")]
    async fn clear_breakpoint(
        &self,
        Parameters(req): Parameters<AddrRequest>,
    ) -> Result<CallToolResult, McpError> {
        self.engine.clear_breakpoint(req.addr).await;
        Ok(text_result(format!("breakpoint cleared at 0x{:04X}", req.addr)))
    }

    #[tool(description = "Read memory starting at an address")]
    async fn read_memory(
        &self,
        Parameters(req): Parameters<ReadMemoryRequest>,
    ) -> Result<CallToolResult, McpError> {
        let data = self.engine.read_memory(req.addr, req.length).await;
        let hex: String = data.iter().map(|b| format!("{b:02x}")).collect();
        Ok(json_result(&json!({"addr": req.addr, "hex": hex})))
    }

    #[tool(description = "Write hex-encoded bytes to memory starting at an address")]
    async fn write_memory(
        &self,
        Parameters(req): Parameters<WriteMemoryRequest>,
    ) -> Result<CallToolResult, McpError> {
        let data = decode_hex(&req.data_hex).map_err(invalid_params)?;
        self.engine.write_memory(req.addr, data).await;
        Ok(text_result("memory written"))
    }

    #[tool(description = "Get the full Z80 register set")]
    async fn get_registers(&self) -> Result<CallToolResult, McpError> {
        let regs = self.engine.get_registers().await;
        Ok(json_result(&regs))
    }

    #[tool(
        description = "Set individual Z80 registers (fetch-modify-writeback -- omit fields to leave them unchanged)"
    )]
    async fn set_registers(
        &self,
        Parameters(req): Parameters<SetRegistersRequest>,
    ) -> Result<CallToolResult, McpError> {
        let mut regs = self.engine.get_registers().await;
        if let Some(v) = req.pc {
            regs.pc = v;
        }
        if let Some(v) = req.sp {
            regs.sp = v;
        }
        if let Some(v) = req.af {
            regs.set_af(v);
        }
        if let Some(v) = req.bc {
            regs.set_bc(v);
        }
        if let Some(v) = req.de {
            regs.set_de(v);
        }
        if let Some(v) = req.hl {
            regs.set_hl(v);
        }
        if let Some(v) = req.ix {
            regs.ix = v;
        }
        if let Some(v) = req.iy {
            regs.iy = v;
        }
        if let Some(v) = req.im {
            regs.im = v;
        }
        if let Some(v) = req.iff1 {
            regs.iff1 = v;
        }
        if let Some(v) = req.iff2 {
            regs.iff2 = v;
        }
        let regs = self.engine.set_registers(regs).await;
        Ok(json_result(&regs))
    }

    #[tool(description = "Press a key")]
    async fn key_down(&self, Parameters(req): Parameters<KeyRequest>) -> Result<CallToolResult, McpError> {
        self.engine.key_down(req.key).await;
        Ok(text_result("key down"))
    }

    #[tool(description = "Release a key")]
    async fn key_up(&self, Parameters(req): Parameters<KeyRequest>) -> Result<CallToolResult, McpError> {
        self.engine.key_up(req.key).await;
        Ok(text_result("key up"))
    }

    #[tool(description = "Get the current screen as a PNG image")]
    async fn get_screen(&self) -> Result<CallToolResult, McpError> {
        let rgb = self.engine.get_screen().await;
        let png = crate::screen_stream::encode_png(&rgb);
        let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
        Ok(CallToolResult::success(vec![ContentBlock::image(b64, "image/png".to_string())]))
    }

    #[tool(description = "Get a full state snapshot: pc, registers, breakpoints, running, border")]
    async fn get_state(&self) -> Result<CallToolResult, McpError> {
        let state = self.engine.get_state().await;
        Ok(json_result(&state))
    }

    #[tool(
        description = "Attach source-level debug info (a sjasmplus SLD file + its matching .asm) for \
                        the currently-loaded program -- enables resolve_symbol/resolve_address and \
                        DAP source-level debugging for this program's addresses, alongside the ROM's \
                        own (always available separately, so calls into the ROM still resolve)"
    )]
    async fn load_debug_info(
        &self,
        Parameters(req): Parameters<LoadDebugInfoRequest>,
    ) -> Result<CallToolResult, McpError> {
        self.sources
            .debug_info
            .load(Path::new(&req.sld_path), Path::new(&req.asm_path))
            .map_err(invalid_params)?;
        let source = self.sources.debug_info.get().expect("just loaded");
        Ok(json_result(&json!({
            "symbols": source.symbols.len(),
            "instructions": source.line_to_addr.len(),
        })))
    }

    #[tool(
        description = "Look up a routine/label's address by name, checking the currently-loaded \
                        program's debug info first, then the ROM's own"
    )]
    async fn resolve_symbol(
        &self,
        Parameters(req): Parameters<ResolveSymbolRequest>,
    ) -> Result<CallToolResult, McpError> {
        let sources = self.sources.active();
        for source in &sources {
            if let Some(&addr) = source.symbols.get(&req.name) {
                return Ok(json_result(&json!({"found": true, "address": addr})));
            }
        }
        let reason = if sources.is_empty() {
            "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py".to_string()
        } else {
            format!("no symbol named {:?}", req.name)
        };
        Ok(json_result(&json!({"found": false, "reason": reason})))
    }

    #[tool(
        description = "Find the nearest named routine at or before a 16-bit address, with its offset \
                        (e.g. 0x0005 -> {symbol: START, offset: 5}) -- same sources as resolve_symbol"
    )]
    async fn resolve_address(
        &self,
        Parameters(req): Parameters<AddrRequest>,
    ) -> Result<CallToolResult, McpError> {
        let sources = self.sources.active();
        for source in &sources {
            if let Some((symbol, offset)) = source.symbol_at(req.addr, None) {
                return Ok(json_result(&json!({"found": true, "symbol": symbol, "offset": offset})));
            }
        }
        let reason = if sources.is_empty() {
            "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py".to_string()
        } else {
            "address precedes every known symbol".to_string()
        };
        Ok(json_result(&json!({"found": false, "reason": reason})))
    }
}

#[tool_handler]
impl ServerHandler for ZxSpectrumServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::from_build_env())
            .with_instructions(
                "Headless ZX Spectrum 48K emulator. Load a ROM, then step/run/inspect the same \
                 live machine a DAP client (e.g. VS Code) may also be debugging concurrently.",
            )
    }
}

fn decode_hex(s: &str) -> Result<Vec<u8>, String> {
    if s.len() % 2 != 0 {
        return Err("hex string must have an even length".to_string());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}
