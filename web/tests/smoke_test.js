// Runs the built module from Node: loads the ROMs, then a 48K and a 128K
// .z80 and a .sna, and runs frames of each. What a page would do, without the
// page -- and what would have caught every .z80 overflowing the module's
// stack, which only a .z80 did.
//
//   node web/tests/smoke_test.js [site] [roms]
//
// `site` is what web/build.py wrote (default web/site), `roms` a directory
// holding 48.rom and 128.rom (default: site/roms).
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const site = path.resolve(process.argv[2] || path.join(__dirname, '..', 'site'));
const roms = path.resolve(process.argv[3] || path.join(site, 'roms'));

const BANK_SIZE = 0x4000;
const FRAMES = 50;

/// A program that sets the border to `colour` and spins: DI, LD A,colour,
/// OUT ($FE),A, JR $. Everything it leaves the screen showing is the border.
function program(colour) {
    return [0xF3, 0x3E, colour, 0xD3, 0xFE, 0x18, 0xFE];
}

/// A version 3 .z80 -- the layout cpp-core's save_z80 writes and
/// examples/filmation's build scripts make -- with PC at `pc` and every page
/// stored uncompressed (length $FFFF). `pages` is [page number, 16K] pairs.
function z80(pc, hardware, pages) {
    const header = new Uint8Array(30 + 2 + 54);
    header[8] = 0x00;
    header[9] = 0xFF;                       // SP $FF00
    header[30] = 54;                        // the extra header's length
    header[32] = pc & 0xFF;
    header[33] = pc >> 8;
    header[34] = hardware;
    const parts = [header];
    for (const [page, data] of pages) {
        parts.push(Uint8Array.of(0xFF, 0xFF, page), data);
    }
    return Buffer.concat(parts);
}

/// A 48K .sna: 27 bytes of registers, then the 48K of RAM. PC is popped off
/// the stack, so SP points at it.
function sna(pc, ram) {
    const header = new Uint8Array(27);
    const sp = 0xFE00;
    header[23] = sp & 0xFF;
    header[24] = sp >> 8;
    header[25] = 1;                         // IM 1
    const body = Uint8Array.from(ram);
    body[sp - 0x4000] = pc & 0xFF;
    body[sp - 0x4000 + 1] = pc >> 8;
    return Buffer.concat([header, body]);
}

async function main() {
    const createZx = require(path.join(site, 'zx.js'));
    const zx = await createZx();

    function call(fn, bytes) {
        const p = zx._zx_alloc(bytes.length);
        zx.HEAPU8.set(bytes, p);
        const error = fn(p, bytes.length);
        zx._zx_free(p);
        return error ? zx.UTF8ToString(error) : null;
    }

    for (const name of ['48.rom', '128.rom']) {
        assert.strictEqual(call(zx._zx_load_rom, fs.readFileSync(path.join(roms, name))), null, name);
    }

    const width = zx._zx_screen_width();

    /// Runs FRAMES frames and checks the top-left pixel -- border -- is the
    /// Spectrum's `colour` at normal brightness.
    function runs(name, colour) {
        let samples = 0;
        for (let i = 0; i < FRAMES; i++) {
            zx._zx_run_frame();
            samples += zx._zx_audio_length();
        }
        const screen = zx._zx_screen();
        const rgb = Array.from(zx.HEAPU8.subarray(screen, screen + 3));
        // Spectrum colour bits: 1 blue, 2 red, 4 green.
        const want = [colour & 2, colour & 4, colour & 1].map((on) => on !== 0);
        assert.deepStrictEqual(rgb.map((c) => c > 0x80), want, name + ': border ' + rgb);
        assert.ok(samples > FRAMES * 800, name + ': ' + samples + ' samples in ' + FRAMES + ' frames');
        assert.ok(width * zx._zx_screen_height() > 0);
        console.log('ok ' + name + ' (' + (zx._zx_is_128k() ? '128K' : '48K') + ')');
    }

    const PC = 0x8000;

    // 48K: pages 8, 4 and 5 are $4000, $8000 and $C000.
    const ram48 = [new Uint8Array(BANK_SIZE), new Uint8Array(BANK_SIZE), new Uint8Array(BANK_SIZE)];
    ram48[1].set(program(2));
    assert.strictEqual(call(zx._zx_load_snapshot, z80(PC, 0, [[8, ram48[0]], [4, ram48[1]], [5, ram48[2]]])), null);
    assert.strictEqual(zx._zx_is_128k(), 0);
    runs('48K .z80', 2);

    // 128K: pages 3 to 10 are banks 0 to 7, and $8000 is always bank 2.
    const banks = [];
    for (let bank = 0; bank < 8; bank++) {
        const data = new Uint8Array(BANK_SIZE);
        if (bank === 2) {
            data.set(program(4));
        }
        banks.push([3 + bank, data]);
    }
    assert.strictEqual(call(zx._zx_load_snapshot, z80(PC, 4, banks)), null);
    assert.strictEqual(zx._zx_is_128k(), 1);
    runs('128K .z80', 4);

    const ram = new Uint8Array(3 * BANK_SIZE);
    ram.set(program(1), PC - 0x4000);
    assert.strictEqual(call(zx._zx_load_snapshot, sna(PC, ram)), null);
    runs('48K .sna', 1);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
