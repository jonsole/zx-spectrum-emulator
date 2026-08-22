//! Entrypoint: starts the DAP, MCP, and screen-stream servers together
//! against one shared `Engine`, mirroring `zxspectrum/server/main.py`.

mod dap;
mod mcp;
mod rom_source;
mod screen_stream;

use clap::Parser;
use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use rom_source::{DebugInfo, Sources};
use std::sync::Arc;
use zx_engine::Engine;

/// ZX Spectrum 48K emulator server: DAP + MCP + screen-stream, one shared
/// live machine.
#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value = "127.0.0.1")]
    dap_host: String,
    #[arg(long, default_value_t = 4711)]
    dap_port: u16,

    #[arg(long, default_value = "127.0.0.1")]
    mcp_host: String,
    #[arg(long, default_value_t = 8000)]
    mcp_port: u16,

    #[arg(long, default_value = "127.0.0.1")]
    screen_host: String,
    #[arg(long, default_value_t = 8500)]
    screen_port: u16,

    /// Directory containing the built ROM disassembly (rom.asm/rom.sld),
    /// relative to the current working directory -- matches the "run from
    /// rust-core/" convention `.vscode/tasks.json` already uses, so the
    /// default lands on the real `rom_disassembly/` at the project root.
    #[arg(long, default_value = "../rom_disassembly")]
    rom_disassembly_dir: std::path::PathBuf,

    /// Start with the ULA contention overlay already enabled (see the
    /// `set_contention_overlay` MCP tool for toggling it at runtime).
    #[arg(long, default_value_t = false)]
    contention_overlay: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Deterministic marker for VS Code's background-task problem matcher
    // (`.vscode/tasks.json`'s `beginsPattern`) -- printed unconditionally,
    // before any async/build-dependent work, so it fires whether or not
    // `cargo run` needed to rebuild anything first.
    println!("Starting ZX Spectrum Rust server...");
    let args = Args::parse();
    let engine = Engine::new();
    if args.contention_overlay {
        engine.set_contention_overlay(true);
    }
    // Canonicalize -- the default ("../rom_disassembly") is a relative,
    // forward-slash literal; PathBuf::join() only uses the native
    // separator for segments it appends itself, so displaying the result
    // as-is produces a mixed "../rom_disassembly\rom.asm" on Windows,
    // which VS Code's own path handling refused to load as a stackTrace/
    // Disassembly View source ("Could not load source"). Falls back to
    // the raw path if canonicalization fails (e.g. the directory doesn't
    // exist yet because the ROM disassembly hasn't been built) --
    // `Sources`/`get_rom_source()` already tolerate a missing directory.
    let rom_disassembly_dir =
        std::fs::canonicalize(&args.rom_disassembly_dir).unwrap_or(args.rom_disassembly_dir);
    let sources = Sources::new(DebugInfo::default(), rom_disassembly_dir);

    let dap_engine = engine.clone();
    let dap_sources = sources.clone();
    let dap_host = args.dap_host.clone();
    let dap_task = tokio::spawn(async move {
        if let Err(e) = dap::serve(dap_engine, dap_sources, &dap_host, args.dap_port).await {
            eprintln!("DAP server error: {e}");
        }
    });

    let screen_engine = engine.clone();
    let screen_host = args.screen_host.clone();
    let screen_task = tokio::spawn(async move {
        if let Err(e) = screen_stream::serve(screen_engine, &screen_host, args.screen_port).await {
            eprintln!("Screen stream server error: {e}");
        }
    });

    let mcp_engine = engine.clone();
    let mcp_sources = sources.clone();
    let mcp_host = args.mcp_host.clone();
    let mcp_port = args.mcp_port;
    let mcp_task = tokio::spawn(async move {
        if let Err(e) = serve_mcp(mcp_engine, mcp_sources, &mcp_host, mcp_port).await {
            eprintln!("MCP server error: {e}");
        }
    });

    let _ = tokio::join!(dap_task, screen_task, mcp_task);
    Ok(())
}

async fn serve_mcp(engine: Engine, sources: Sources, host: &str, port: u16) -> anyhow::Result<()> {
    let bind_addr = format!("{host}:{port}");
    let session_manager = Arc::new(LocalSessionManager::default());
    let service = StreamableHttpService::new(
        move || Ok(mcp::ZxSpectrumServer::new(engine.clone(), sources.clone())),
        session_manager,
        StreamableHttpServerConfig::default(),
    );
    let router = axum::Router::new().nest_service("/mcp", service);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    println!("MCP server listening on {bind_addr} (streamable-HTTP, /mcp)");
    axum::serve(listener, router).await?;
    Ok(())
}
