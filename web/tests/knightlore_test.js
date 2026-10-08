// Checks web/remake.js -- what web/knightlore.html makes the remake with --
// against the build it stands in for.
//
//   node web/tests/knightlore_test.js <site> <reference>
//
// `site` is where web/knightlore_template.py wrote knightlore/ (default
// web/site), `reference` where it kept its patterned build (--reference).
//
// The page's .z80 for the patterned font must be the .z80 build.py wrote for
// that same font, byte for byte: the template is right, the font goes where
// the build puts it, and the .z80 writer is build.py's. Its snapshot reader
// must read every form of 48K snapshot as examples/filmation/original.py
// does, which is checked against original.py itself.
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
const pattern = new Uint8Array(fs.readFileSync(path.join(reference, 'font.bin')));
const built = new Uint8Array(fs.readFileSync(path.join(reference, 'knightlore.z80')));

/// A 48K of RAM with `font` where the original keeps it, and something
/// recognisable everywhere else so that a page landing in the wrong place
/// shows.
function originalRam(font) {
    const ram = new Uint8Array(0xC000);
    for (let n = 0; n < ram.length; n++) {
        ram[n] = (n * 13 + (n >> 8)) & 0xFF;
    }
    // Runs and EDs, so the compressed forms have something to compress.
    ram.fill(0, 0x1000, 0x1400);
    ram.fill(0xED, 0x2000, 0x2003);
    ram.set(font, info.font_source - 0x4000);
    return ram;
}

function sna(ram) {
    const out = new Uint8Array(27 + ram.length);
    out.set(ram, 27);
    return out;
}

/// A version 1 .z80: PC in the header, the RAM in one block, compressed and
/// ended with 00 ED ED 00 as the format has it.
function z80v1(ram) {
    const header = new Uint8Array(30);
    header[6] = 0x00;
    header[7] = 0x80;
    header[12] = 0x20;
    const packed = [];
    const all = new Uint8Array(ram);
    for (let i = 0; i < all.length; i++) {
        let run = 1;
        while (i + run < all.length && all[i + run] === all[i] && run < 255) {
            run++;
        }
        if (run >= 5 || (all[i] === 0xED && run >= 2)) {
            packed.push(0xED, 0xED, run, all[i]);
            i += run - 1;
        } else if (all[i] === 0xED) {
            packed.push(all[i]);
            if (i + 1 < all.length) {
                packed.push(all[i + 1]);
            }
            i++;
        } else {
            packed.push(all[i]);
        }
    }
    return Uint8Array.from([...header, ...packed, 0x00, 0xED, 0xED, 0x00]);
}

/// A version 3 .z80 with its pages stored uncompressed (length $FFFF).
function z80v3Raw(ram, hardware) {
    const header = new Uint8Array(30 + 2 + 54);
    header[30] = 54;
    header[32] = 0x00;
    header[33] = 0x80;
    header[34] = hardware;
    const parts = [header];
    for (const [page, offset] of [[8, 0], [4, 0x4000], [5, 0x8000]]) {
        parts.push(Uint8Array.of(0xFF, 0xFF, page), ram.subarray(offset, offset + 0x4000));
    }
    return Buffer.concat(parts);
}

/// What original.py makes of a file: the SHA-256 of its 64K, or its error.
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
    // The template is the one the site carries, unchanged.
    assert.strictEqual(await remake.sha256(template), info.template_sha256, 'template.bin');

    // The page's .z80 for the patterned font is build.py's.
    assert.deepStrictEqual(Buffer.from(remake.fill(template, info, pattern)), Buffer.from(built),
                           'the page and build.py made different .z80s for the same font');
    console.log('ok the page writes the .z80 build.py does');

    // Every form of snapshot reads as original.py reads it, and gives the font.
    const ram = originalRam(pattern);
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'knightlore-test-'));
    const forms = {
        'copy.sna': sna(ram),
        'v1.z80': z80v1(ram),
        'v3.z80': remake.z80Snapshot(ram, 0x8000),
        'v3raw.z80': z80v3Raw(ram, 0),
    };
    for (const [name, bytes] of Object.entries(forms)) {
        const file = path.join(temp, name);
        fs.writeFileSync(file, bytes);
        const memory = remake.readSnapshot(new Uint8Array(bytes), name);
        assert.strictEqual(await remake.sha256(memory), originalPy(file), name + ' reads as original.py reads it');
        assert.deepStrictEqual(memory.slice(info.font_source, info.font_source + info.font_length),
                               pattern, name + ': the font');
        console.log('ok ' + name);
    }

    // A 128K snapshot is refused, as original.py refuses it.
    const big = path.join(temp, 'big.z80');
    fs.writeFileSync(big, z80v3Raw(ram, 4));
    assert.throws(() => remake.readSnapshot(new Uint8Array(fs.readFileSync(big)), 'big.z80'),
                  remake.RemakeError);
    assert.strictEqual(originalPy(big), 'error');
    console.log('ok a 128K snapshot is refused');

    // The copy is checked: the patterned font is not Knight Lore's...
    await assert.rejects(remake.remake(template, info, forms['v3.z80'], 'v3.z80'),
                         (e) => e instanceof remake.RemakeError && /not the copy/.test(e.message));
    // ...and with its hash in place of the real one, the whole path gives
    // build.py's .z80.
    const pinned = Object.assign({}, info, { font_sha256: await remake.sha256(pattern) });
    for (const name of ['copy.sna', 'v1.z80', 'v3.z80']) {
        const made = await remake.remake(template, pinned, new Uint8Array(forms[name]), name);
        assert.deepStrictEqual(Buffer.from(made), Buffer.from(built), name + ' made the wrong .z80');
    }
    console.log('ok a copy is checked, and makes build.py\'s .z80');

    fs.rmSync(temp, { recursive: true });
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
