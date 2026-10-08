// Checks web/remake.js -- what web/knightlore.html makes the remake with --
// against the build it stands in for.
//
//   node web/tests/knightlore_test.js <site> <reference>
//
// `site` is where web/knightlore_template.py wrote knightlore/ (default
// web/site), `reference` where it wrote its test original (--reference).
//
// The test original is made from the carried sprite sheet, its sprites in a
// different order and two of them mirrored, and the real kl_extract.py and
// sprite_sheet.py have already been run on it and given back the carried
// sheet: as far as the build is concerned it is Knight Lore, with a patterned
// font. So given it, the page has to make the .z80 build.py made with that
// font, byte for byte -- in every form of 48K snapshot, read as
// examples/filmation/original.py reads them, which is checked against
// original.py itself.
'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const remake = require('../remake.js');

const ROOT = path.resolve(__dirname, '..', '..');
const site = path.resolve(process.argv[2] || path.join(ROOT, 'web', 'site'));
const reference = process.argv[3] && path.resolve(process.argv[3]);
if (!reference) {
    console.error('usage: node web/tests/knightlore_test.js <site> <reference>');
    process.exit(2);
}

const template = new Uint8Array(fs.readFileSync(path.join(site, 'knightlore', 'template.bin')));
const info = JSON.parse(fs.readFileSync(path.join(site, 'knightlore', 'template.json'), 'utf8'));
const testOriginal = new Uint8Array(fs.readFileSync(path.join(reference, 'original.sna')));
const pins = JSON.parse(fs.readFileSync(path.join(reference, 'pins.json'), 'utf8'));
const built = Buffer.from(fs.readFileSync(path.join(reference, 'knightlore.z80')));

/// The template's own facts, with the hash of the test original's font in
/// place of the real game's. The sprites and the DAY lettering are checked
/// against what the build put in the image, which the test original gives.
const pinned = Object.assign({}, info, { font_sha256: pins['font.bin'] });

const RAM = testOriginal.subarray(27);

/// A version 1 .z80: PC in the header, the RAM in one block, compressed and
/// ended with 00 ED ED 00 as the format has it.
function z80v1(ram) {
    const header = new Uint8Array(30);
    header[7] = 0x80;                       // PC $8000: not zero, so version 1
    header[12] = 0x20;                      // compressed
    const packed = [];
    for (let i = 0; i < ram.length;) {
        let run = 1;
        while (i + run < ram.length && ram[i + run] === ram[i] && run < 255) {
            run++;
        }
        if (run >= 5 || (ram[i] === 0xED && run >= 2)) {
            packed.push(0xED, 0xED, run, ram[i]);
            i += run;
        } else if (ram[i] === 0xED) {
            packed.push(ram[i]);
            if (i + 1 < ram.length) {
                packed.push(ram[i + 1]);
            }
            i += 2;
        } else {
            packed.push(ram[i]);
            i++;
        }
    }
    return Uint8Array.from([...header, ...packed, 0x00, 0xED, 0xED, 0x00]);
}

/// A version 3 .z80 with its pages stored uncompressed (length $FFFF).
function z80v3Raw(ram, hardware) {
    const header = new Uint8Array(30 + 2 + 54);
    header[30] = 54;
    header[33] = 0x80;
    header[34] = hardware;
    const parts = [header];
    for (const [page, offset] of [[8, 0], [4, 0x4000], [5, 0x8000]]) {
        parts.push(Uint8Array.of(0xFF, 0xFF, page), ram.subarray(offset, offset + 0x4000));
    }
    return new Uint8Array(Buffer.concat(parts));
}

/// What original.py makes of a file: the SHA-256 of its 64K, or "error".
function originalPy(file) {
    const script = [
        'import hashlib, sys',
        'sys.path.insert(0, sys.argv[1])',
        'import original',
        'try:',
        '    print(hashlib.sha256(original.load_snapshot(sys.argv[2])).hexdigest())',
        'except original.OriginalError as e:',
        '    print("error")',
    ].join('\n');
    const python = process.env.PYTHON || 'python3';
    return childProcess.execFileSync(python, ['-I', '-c', script,
                                              path.join(ROOT, 'examples', 'filmation'), file],
                                     { encoding: 'utf8' }).trim();
}

async function main() {
    // The template is the one the site carries, and it holds none of the
    // sprites' pixels.
    assert.strictEqual(await remake.sha256(template), info.template_sha256, 'template.bin');
    for (const sprite of info.sprites) {
        const at = sprite.at - 0x4000;
        assert.ok(template.subarray(at, at + sprite.w * sprite.h * 2).every((b) => b === 0),
                  'the template has a sprite\'s rows at $' + sprite.at.toString(16));
    }
    const font = template.subarray(info.font_at - 0x4000, info.font_at - 0x4000 + info.font_length);
    assert.ok(font.every((b) => b === 0), 'the template has a font');
    const day = template.subarray(info.day_at - 0x4000, info.day_at - 0x4000 + info.day_length);
    assert.ok(day.every((b) => b === 0), 'the template has the DAY lettering');
    console.log('ok the template holds no sprite rows, no font and no DAY lettering');

    // Every form of snapshot reads as original.py reads it, and makes
    // build.py's .z80.
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'knightlore-test-'));
    const forms = {
        'copy.sna': testOriginal,
        'v1.z80': z80v1(RAM),
        'v3.z80': remake.z80Snapshot(RAM, 0x8000),
        'v3raw.z80': z80v3Raw(RAM, 0),
    };
    for (const [name, bytes] of Object.entries(forms)) {
        const file = path.join(temp, name);
        fs.writeFileSync(file, bytes);
        const memory = remake.readSnapshot(bytes, name);
        assert.strictEqual(await remake.sha256(memory), originalPy(file),
                           name + ' reads as original.py reads it');
        const made = await remake.remake(template, pinned, bytes, name);
        assert.deepStrictEqual(Buffer.from(made), built, name + ': not the .z80 build.py made');
        console.log('ok ' + name + ' makes build.py\'s .z80');
    }

    // A copy saved at the menu can hold the frame's corner upside down, and
    // the game leaves flags set in the sprites' width bytes or not: neither
    // reaches the image, so neither stops the copy making the game.
    const turned = Uint8Array.from(testOriginal);
    const tableAt = 27 + info.sprite_table - 0x4000 + 2 * info.menu_corner_graphic;
    const corner = 27 + (turned[tableAt] | (turned[tableAt + 1] << 8)) - 0x4000;
    const cw = turned[corner] & 0x1F;
    const ch = turned[corner + 1];
    const rows = [];
    for (let r = 0; r < ch; r++) {
        rows.push(turned.slice(corner + 2 + r * cw * 2, corner + 2 + (r + 1) * cw * 2));
    }
    rows.reverse().forEach((row, r) => turned.set(row, corner + 2 + r * cw * 2));
    for (let p = info.sprites_start; p < info.sprites_end;) {
        const at = 27 + p - 0x4000;
        const w = turned[at] & 0x1F;
        if (w) {
            turned[at] |= 0xA0;             // flags, but not the mirrored one
        }
        p += 2 + w * turned[at + 1] * 2;
    }
    assert.deepStrictEqual(Buffer.from(await remake.remake(template, pinned, turned, 'menu.sna')), built,
                           'a copy saved at the menu');
    console.log('ok a copy with its menu corner upside down and flags set makes it too');

    // A 128K snapshot is refused, as original.py refuses it.
    const big = path.join(temp, 'big.z80');
    fs.writeFileSync(big, z80v3Raw(RAM, 4));
    assert.throws(() => remake.readSnapshot(new Uint8Array(fs.readFileSync(big)), 'big.z80'),
                  remake.RemakeError);
    assert.strictEqual(originalPy(big), 'error');
    console.log('ok a 128K snapshot is refused');

    // The copy is checked: against the real game's hashes the test original
    // is not Knight Lore...
    await assert.rejects(remake.remake(template, info, testOriginal, 'copy.sna'),
                         (e) => e instanceof remake.RemakeError && /font is different/.test(e.message));
    // ...and a copy with one sprite pixel changed is refused for its sprites.
    const changed = Uint8Array.from(testOriginal);
    const first = info.sprites[0];
    changed[27 + info.sprites_start - 0x4000 + 2 + first.w * 2 * first.trim + 1] ^= 0x01;
    await assert.rejects(remake.remake(template, pinned, changed, 'changed.sna'),
                         (e) => e instanceof remake.RemakeError && /sprites are different/.test(e.message));
    console.log('ok a copy is checked, font and sprites');

    fs.rmSync(temp, { recursive: true });
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
