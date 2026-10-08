// Checks web/remake_pentagram.js -- what web/pentagram.html makes the remake
// with -- against the build it stands in for.
//
//   node web/tests/pentagram_test.js <site> <reference>
//
// `site` is where web/pentagram_template.py wrote pentagram/ (default
// web/site), `reference` where it wrote its test tape (--reference).
//
// The test tape is made from the carried files -- the sprite sheet, which
// gives back the game's own sprites byte for byte, and the castle -- with a
// patterned font, quest and sound, and the real pg_extract.py, rooms.py and
// sprite_sheet.py have already been run on it and given back the carried
// sheet and castle. Given it as a .tap, as a .tzx, or as a snapshot with
// sprites flipped as the game flips them, the page has to make the .z80
// build.py made with the same patterns, byte for byte.
'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const remake = require('../remake_pentagram.js');

const ROOT = path.resolve(__dirname, '..', '..');
const site = path.resolve(process.argv[2] || path.join(ROOT, 'web', 'site'));
const reference = process.argv[3] && path.resolve(process.argv[3]);
if (!reference) {
    console.error('usage: node web/tests/pentagram_test.js <site> <reference>');
    process.exit(2);
}

const template = new Uint8Array(fs.readFileSync(path.join(site, 'pentagram', 'template.bin')));
const info = JSON.parse(fs.readFileSync(path.join(site, 'pentagram', 'template.json'), 'utf8'));
const tap = new Uint8Array(fs.readFileSync(path.join(reference, 'pentagram.tap')));
const pins = JSON.parse(fs.readFileSync(path.join(reference, 'pins.json'), 'utf8'));
const built = Buffer.from(fs.readFileSync(path.join(reference, 'pentagram.z80')));

/// The template's own facts, with the hashes of the test tape's font, quest
/// and sound in place of the real game's.
const pinned = JSON.parse(JSON.stringify(info));
pinned.font.sha256 = pins['font.bin'];
pinned.quest.sha256 = pins['quest.bin'];
pinned.sound.sha256 = pins['sound.bin'];

/// The .tap's blocks as a .tzx: standard speed data blocks, a second's pause.
function tzx(tapBytes) {
    const parts = [Buffer.from('ZXTape!\x1a\x01\x14', 'latin1')];
    for (let at = 0; at < tapBytes.length;) {
        const length = tapBytes[at] | (tapBytes[at + 1] << 8);
        parts.push(Uint8Array.of(0x10, 0xE8, 0x03), tapBytes.subarray(at, at + 2 + length));
        at += 2 + length;
    }
    return new Uint8Array(Buffer.concat(parts));
}

function reverseBits(byte) {
    let out = 0;
    for (let bit = 0; bit < 8; bit++) {
        if (byte & (1 << bit)) {
            out |= 0x80 >> bit;
        }
    }
    return out;
}

/// The record at `at` flipped as the game flips one in place, flag and all.
function flip(memory, at, leftRight, upsideDown) {
    const w = memory[at] & 0x1F;
    const h = memory[at + 1];
    let rows = [];
    for (let r = 0; r < h; r++) {
        rows.push(Array.from(memory.subarray(at + 2 + r * w * 2, at + 2 + (r + 1) * w * 2)));
    }
    if (leftRight) {
        rows = rows.map((row) => {
            const out = [];
            for (let c = w - 1; c >= 0; c--) {
                out.push(reverseBits(row[2 * c]), reverseBits(row[2 * c + 1]));
            }
            return out;
        });
        memory[at] |= info.flip_left_right;
    }
    if (upsideDown) {
        rows.reverse();
        memory[at] |= info.flip_upside_down;
    }
    rows.forEach((row, r) => memory.set(row, at + 2 + r * w * 2));
}

/// The tape's memory as a 48K .sna, with three sprites flipped: one each
/// way and one both.
function flippedSna(memory) {
    const ram = Uint8Array.from(memory.subarray(0x4000));
    const view = new Uint8Array(0x10000);
    view.set(ram, 0x4000);
    const [start] = info.sprite_runs[0];
    let at = start;
    const ways = [[true, false], [false, true], [true, true]];
    for (const [lr, ud] of ways) {
        flip(view, at, lr, ud);
        at += 2 + (view[at] & 0x1F) * view[at + 1] * 2;
    }
    const out = new Uint8Array(27 + 0xC000);
    out.set(view.subarray(0x4000), 27);
    return out;
}

/// What pg_extract.py's load_original makes of a file: the SHA-256 of the
/// game's block of it, from $5E00 to $D89D.
function pgExtract(file) {
    const script = [
        'import hashlib, sys',
        'sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])',
        'import pg_extract',
        'm = pg_extract.load_original(sys.argv[3])',
        'print(hashlib.sha256(bytes(m[0x5E00:0xD89E])).hexdigest())',
    ].join('\n');
    const python = process.env.PYTHON || 'python3';
    const filmation = path.join(ROOT, 'examples', 'filmation');
    return childProcess.execFileSync(python, ['-I', '-c', script, filmation,
                                              path.join(filmation, 'pentagram'), file],
                                     { encoding: 'utf8' }).trim().split('\n').pop();
}

async function main() {
    // The template is the one the site carries, and holds none of the
    // original.
    assert.strictEqual(await remake.sha256(template), info.template_sha256, 'template.bin');
    const blank = (at, length) => template.subarray(at - 0x4000, at - 0x4000 + length).every((b) => b === 0);
    assert.ok(blank(info.font.at, info.font.length), 'the template has the font');
    for (const sprite of info.sprites) {
        assert.ok(blank(sprite.at, sprite.w * sprite.h * 2), 'the template has a sprite');
    }
    assert.ok(blank(info.castle.at, info.castle.length), 'the template has the castle');
    assert.ok(blank(info.quest.at, info.quest.records * info.quest.kept.length), 'the template has the quest');
    assert.ok(blank(info.quest.spots_at, info.quest.spots_length), 'the template has the quest spots');
    assert.ok(blank(info.quest.targets_at, info.quest.targets_length), 'the template has the targets');
    assert.ok(blank(info.sound.jingles_at, info.sound.jingles_length), 'the template has the jingles');
    assert.ok(blank(info.sound.notes_at, info.sound.highest * 3), 'the template has the notes');
    for (const tune of info.sound.played.concat(['title'])) {
        assert.ok(blank(info.sound.tune_at[tune], info.sound.lengths[tune] + 1), 'the template has a tune');
    }
    console.log('ok the template holds no font, sprites, castle, quest or sound');

    // The tape, as .tap and as .tzx, makes build.py's .z80; so does a
    // snapshot with sprites flipped, which the page turns back as
    // pg_extract.py does.
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'pentagram-test-'));
    const memory = remake.loadOriginal(tap, 'pentagram.tap', info);
    const forms = {
        'pentagram.tap': tap,
        'pentagram.tzx': tzx(tap),
        'flipped.sna': flippedSna(memory),
    };
    for (const [name, bytes] of Object.entries(forms)) {
        const file = path.join(temp, name);
        fs.writeFileSync(file, bytes);
        const read = remake.loadOriginal(bytes, name, info);
        assert.strictEqual(await remake.sha256(read.subarray(0x5E00, 0xD89E)), pgExtract(file),
                           name + ' reads as pg_extract.py reads it');
        const made = await remake.remake(template, pinned, bytes, name);
        assert.deepStrictEqual(Buffer.from(made), built, name + ': not the .z80 build.py made');
        console.log('ok ' + name + ' makes build.py\'s .z80');
    }

    // The copy is checked: against the real game's hashes the test tape is
    // not Pentagram...
    await assert.rejects(remake.remake(template, info, tap, 'pentagram.tap'),
                         (e) => e instanceof remake.RemakeError && /font is different/.test(e.message));
    // ...and with one byte of any part changed, it is refused for that part.
    const sna = forms['flipped.sna'];
    const poke = (address, why) => {
        const bytes = Uint8Array.from(sna);
        bytes[27 + address - 0x4000] ^= 0x01;
        return assert.rejects(remake.remake(template, pinned, bytes, 'changed.sna'),
                              (e) => e instanceof remake.RemakeError && why.test(e.message),
                              'a change at $' + address.toString(16));
    };
    await poke(info.font.source + 5, /font is different/);
    await poke(info.quest.spots + 3, /quest is different/);
    await poke(info.sound.tunes + 2, /tunes are different/);
    const last = info.sprite_runs[2][0] + 2 + 9;     // a row of a sprite in the third run
    await poke(last, /sprites are different/);
    await poke(info.castle.directory + 3, /rooms are different/);
    console.log('ok a copy is checked: font, quest, sound, sprites and rooms');

    fs.rmSync(temp, { recursive: true });
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
