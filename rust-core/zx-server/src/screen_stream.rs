//! Screen-frame streaming TCP server, ported from
//! `zxspectrum/server/screen_stream.py`: on each connection, loops forever
//! pushing the live display as a length-prefixed PNG frame (4-byte
//! big-endian length + PNG bytes) until the client disconnects. Reads the
//! latest rendered screen via `Engine::watch_screen()` (bypasses the
//! command queue, same reason Python's version reads `machine` directly --
//! streaming shouldn't stall behind a live `run()`).

use image::{ImageBuffer, ImageEncoder, Rgb};
use std::io;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::interval;
use zx_core::ula::{FULL_SCREEN_HEIGHT, FULL_SCREEN_WIDTH};
use zx_engine::Engine;

const FRAME_INTERVAL: Duration = Duration::from_millis(20); // 10fps

pub async fn serve(engine: Engine, host: &str, port: u16) -> io::Result<()> {
    let listener = TcpListener::bind((host, port)).await?;
    println!("Screen stream server listening on {host}:{port}");
    loop {
        let (stream, _) = listener.accept().await?;
        let engine = engine.clone();
        tokio::spawn(async move {
            let _ = handle_connection(stream, engine).await;
        });
    }
}

async fn handle_connection(mut stream: TcpStream, engine: Engine) -> io::Result<()> {
    let mut screen_rx = engine.watch_screen();
    let mut ticker = interval(FRAME_INTERVAL);
    loop {
        ticker.tick().await;
        let rgb = screen_rx.borrow_and_update().clone();
        if rgb.len() != FULL_SCREEN_WIDTH * FULL_SCREEN_HEIGHT * 3 {
            continue; // not primed yet
        }
        let png = encode_png(&rgb);
        let len = (png.len() as u32).to_be_bytes();
        if stream.write_all(&len).await.is_err() {
            break;
        }
        if stream.write_all(&png).await.is_err() {
            break;
        }
    }
    Ok(())
}

pub(crate) fn encode_png(rgb: &[u8]) -> Vec<u8> {
    let image: ImageBuffer<Rgb<u8>, _> =
        ImageBuffer::from_raw(FULL_SCREEN_WIDTH as u32, FULL_SCREEN_HEIGHT as u32, rgb.to_vec())
            .expect("screen buffer is the right size");
    let mut out = Vec::new();
    image::codecs::png::PngEncoder::new(&mut out)
        .write_image(
            &image,
            FULL_SCREEN_WIDTH as u32,
            FULL_SCREEN_HEIGHT as u32,
            image::ExtendedColorType::Rgb8,
        )
        .expect("PNG encoding cannot fail for a valid RGB buffer");
    out
}
