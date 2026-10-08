// The Filmation Pentagram made from a visitor's own copy of the original:
// what web/pentagram.html does with the file it is given, kept apart from the
// page so that web/tests/pentagram_test.js can run it from Node. remake.js,
// Knight Lore's, has the snapshot reading and the .z80 writing this shares.
//
// The site carries the remake with everything of Ultimate's left blank -- the
// font, the sprites' rows, the castle, the quest and the sound
// (web/pentagram_template.py says why that is the whole of the difference).
// This reads them out of the copy as pg_extract.py does -- from its tape's
// `game` block, or a 48K snapshot with the sprites the game has flipped
// turned back -- makes of them what the build makes, checks it, puts it in,
// and writes the .z80 build.py would have.
'use strict';

(function (root) {
    const base = typeof module === 'object' && module.exports
        ? require('./remake.js') : root.KnightLoreRemake;
    const { RemakeError, readSnapshot, z80Snapshot, sha256 } = base;

    const RAM_START = 0x4000;
    const RAM_SIZE = 0xC000;
    const TZX_SIGNATURE = 'ZXTape!\x1a';

    // --- the copy ----------------------------------------------------------------

    /// A .tap's or .tzx's data blocks, flag and checksum included:
    /// examples/filmation/original.py's tape_blocks.
    function tapeBlocks(raw, name) {
        const blocks = [];
        if (name.toLowerCase().endsWith('.tap')) {
            for (let at = 0; at + 2 <= raw.length;) {
                const length = raw[at] | (raw[at + 1] << 8);
                blocks.push(raw.subarray(at + 2, at + 2 + length));
                at += 2 + length;
            }
            return blocks;
        }
        if (String.fromCharCode(...raw.subarray(0, 8)) !== TZX_SIGNATURE) {
            throw new RemakeError(name + ' is not a TZX file');
        }
        let at = 10;                    // the signature, then the version
        while (at < raw.length) {
            const id = raw[at++];
            if (id === 0x10) {          // standard speed data
                const length = raw[at + 2] | (raw[at + 3] << 8);
                blocks.push(raw.subarray(at + 4, at + 4 + length));
                at += 4 + length;
            } else if (id === 0x11) {   // turbo speed data
                const length = raw[at + 0x0F] | (raw[at + 0x10] << 8) | (raw[at + 0x11] << 16);
                blocks.push(raw.subarray(at + 0x12, at + 0x12 + length));
                at += 0x12 + length;
            } else if (id === 0x30) {   // text description
                at += 1 + raw[at];
            } else if (id === 0x32) {   // archive info
                at += 2 + (raw[at] | (raw[at + 1] << 8));
            } else {
                throw new RemakeError(name + ': a TZX block of a kind Pentagram\'s tape does '
                                      + 'not have ($' + id.toString(16).toUpperCase() + ')');
            }
        }
        return blocks;
    }

    /// The 64K address space with the tape's `game` block loaded into it:
    /// pg_extract.py's load_tape.
    function loadTape(raw, name, info) {
        const blocks = tapeBlocks(raw, name);
        for (let n = 0; n < blocks.length; n++) {
            const block = blocks[n];
            if (block.length !== 19 || block[0] !== 0x00 || block[1] !== 3) {
                continue;
            }
            const called = String.fromCharCode(...block.subarray(2, 12)).trimEnd();
            if (called !== info.game_name) {
                continue;
            }
            const address = block[14] | (block[15] << 8);
            if (address !== info.game_start || n + 1 >= blocks.length) {
                throw new RemakeError(name + ': its `game` does not load where Pentagram\'s does');
            }
            const data = blocks[n + 1].subarray(1, blocks[n + 1].length - 1);
            const memory = new Uint8Array(0x10000);
            memory.set(data.subarray(0, 0x10000 - address), address);
            return memory;
        }
        throw new RemakeError(name + ' has no CODE block called `' + info.game_name + '`');
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

    /// Turns the sprite record at `at` back the way the tape holds it, if the
    /// game has flipped it: original.py's unmirror. A left-right mirror
    /// reverses each row's cells and the bits in every byte; an upside-down
    /// one reverses the rows.
    function unmirror(memory, at, leftRight, upsideDown) {
        const flags = memory[at] & (leftRight | upsideDown);
        if (!flags) {
            return;
        }
        const width = memory[at] & 0x1F;
        const height = memory[at + 1];
        const stride = 2 * width;
        let rows = [];
        for (let r = 0; r < height; r++) {
            rows.push(Array.from(memory.subarray(at + 2 + r * stride, at + 2 + (r + 1) * stride)));
        }
        if (flags & leftRight) {
            rows = rows.map((row) => {
                const out = [];
                for (let c = width - 1; c >= 0; c--) {
                    out.push(reverseBits(row[2 * c]), reverseBits(row[2 * c + 1]));
                }
                return out;
            });
        }
        if (flags & upsideDown) {
            rows.reverse();
        }
        rows.forEach((row, r) => memory.set(row, at + 2 + r * stride));
        memory[at] &= ~flags & 0xFF;
    }

    /// The copy's address space: from the tape as it is, or from a snapshot
    /// with every sprite the game has flipped turned back.
    function loadOriginal(raw, name, info) {
        const lower = name.toLowerCase();
        if (lower.endsWith('.tap') || lower.endsWith('.tzx')) {
            return loadTape(raw, name, info);
        }
        const memory = readSnapshot(raw, name);
        for (const [start, end] of info.sprite_runs) {
            for (let at = start; at < end;) {
                const width = memory[at] & 0x1F;
                const height = memory[at + 1];
                if (!width || !height) {
                    break;
                }
                unmirror(memory, at, info.flip_left_right, info.flip_upside_down);
                at += 2 + width * height * 2;
            }
        }
        return memory;
    }

    // --- the sprites ---------------------------------------------------------------

    /// The game's sprite records, walked run by run: pg_extract.py's sprites.
    function sprites(memory, info, different) {
        const records = [];
        for (const [start, end] of info.sprite_runs) {
            let at = start;
            while (at < end) {
                const width = memory[at] & 0x1F;
                const height = memory[at + 1];
                if (!width || !height || memory[at] & info.flags_mask) {
                    throw new RemakeError(different + 'its sprites are not where Pentagram\'s are');
                }
                records.push({ at, w: width, h: height });
                at += 2 + width * height * 2;
            }
            if (at !== end) {
                throw new RemakeError(different + 'its sprites are not where Pentagram\'s are');
            }
        }
        return records;
    }

    /// Every drawn sprite's rows as the build emits them, in the template's
    /// order: the record found through the copy's own graphic table, its rows
    /// top row first, the trimmed blank rows left off, the mask inverted.
    function spriteRows(memory, info, records, different) {
        const index = new Map(records.map((record, n) => [record.at, n]));
        let total = 0;
        for (const sprite of info.sprites) {
            total += sprite.w * sprite.h * 2;
        }
        const out = new Uint8Array(total);
        let to = 0;
        for (const sprite of info.sprites) {
            const pointer = info.sprite_table + 2 * sprite.graphic;
            const record = records[index.get(memory[pointer] | (memory[pointer + 1] << 8))];
            if (record === undefined || record.w !== sprite.w || record.h !== sprite.h + sprite.trim) {
                throw new RemakeError(different + 'its sprites are not laid out as Pentagram\'s are');
            }
            const stride = record.w * 2;
            for (let row = record.h - 1; row >= 0; row--) {
                const from = record.at + 2 + row * stride;
                for (let b = 0; b < stride; b += 2) {
                    if (row < sprite.trim) {
                        if (memory[from + b] || memory[from + b + 1]) {
                            throw new RemakeError(different + 'its sprites are different');
                        }
                        continue;
                    }
                    out[to++] = 0xFF ^ memory[from + b];
                    out[to++] = memory[from + b + 1];
                }
            }
        }
        return out;
    }

    // --- the castle ------------------------------------------------------------------
    //
    // rooms.py decodes the game's tables into rooms.json and templates.json;
    // rooms_source.py encodes those again, in the remake's layout, as
    // room_data.s. Done here straight from the copy's tables, to the same
    // bytes -- web/tests/pentagram_test.js checks the two against each other
    // on every build.

    function readCastle(memory, castle) {
        const word = (at) => memory[at] | (memory[at + 1] << 8);
        const chains = (table, count, stride) => {
            const out = [];
            for (let i = 0; i < count; i++) {
                const entries = [];
                for (let p = word(table + 2 * i); memory[p]; p += stride) {
                    entries.push(Array.from(memory.subarray(p, p + stride)));
                }
                out.push(entries);
            }
            return out;
        };
        const rooms = [];
        for (let at = castle.directory; at < castle.directory_end;) {
            const length = memory[at + 1];
            const end = at + 1 + length;
            let left = length - 2;
            let p = at + 3;
            const scenery = [];
            const objects = [];
            let inScenery = true;
            let page = 0;
            while (left > 0) {
                const entry = memory[p++];
                left--;
                if (inScenery) {
                    if (entry === castle.section_end) {
                        inScenery = false;
                        continue;
                    }
                    scenery.push({ template: entry, destination: memory[p++] });
                    left--;
                    continue;
                }
                const index = (entry >> 2) & 0x3E;
                if (index === castle.page_escape) {
                    p++;
                    left--;
                    page += castle.page_step;
                    continue;
                }
                const positions = [];
                for (let n = 0; n < (entry & 7) + 1 && left > 0; n++) {
                    positions.push(memory[p++]);
                    left--;
                }
                objects.push({ index: index + page, positions });
            }
            if (p !== end) {
                throw new RemakeError('a room record runs past its end');
            }
            rooms.push({ number: memory[at], attr: memory[at + 2], scenery, objects });
            at = end;
        }
        return {
            shapes: Array.from(memory.subarray(castle.size_table, castle.size_table + 9)),
            scenery: chains(castle.scenery_table, castle.scenery_count, castle.scenery_block),
            objects: chains(castle.object_table, castle.object_count, castle.object_block),
            rooms,
        };
    }

    /// The castle as room_data.s assembles: Pentagram's rooms_source.py, to
    /// bytes. Returns them, with the three counts the code is sized by.
    function castleBytes(memory, castle) {
        const data = readCastle(memory, castle);
        const flags = castle.flags;
        const out = [];
        const word = (value) => out.push(value & 0xFF, value >> 8);

        out.push(...data.shapes);

        // One block a template, the first of any that are the same emitted
        // once and the rest pointing at it.
        const emit = (templates, record) => {
            const firstOf = new Map();
            const at = [];
            templates.forEach((entries, index) => {
                const key = JSON.stringify(entries);
                if (firstOf.has(key)) {
                    at.push(at[firstOf.get(key)]);
                    return;
                }
                firstOf.set(key, index);
                at.push(castle.at + out.length);
                for (const entry of entries) {
                    out.push(...record(entry, index));
                }
                out.push(0);
            });
            return at;
        };
        const ours = (game, background) => (game & flags.game_mirror ? flags.flip : 0)
            | (background ? flags.background : 0);

        const scenery = emit(data.scenery, (entry, index) =>
            entry.slice(0, 7).concat([ours(entry[7], castle.scenery_background[index])]));
        scenery.forEach(word);
        // An object's five bytes, and the placement nudge Pentagram has none of.
        const objects = emit(data.objects, (entry) =>
            entry.slice(0, 4).concat([ours(entry[4], false), 0]));
        objects.forEach(word);

        let biggest = 0;
        let most = 0;
        for (const room of data.rooms) {
            let body = 0;
            let placed = 0;
            for (const piece of room.scenery) {
                body += castle.scenery_doorway[piece.template] ? 2 : 1;
                placed += data.scenery[piece.template].length;
            }
            for (const group of room.objects) {
                body += 1 + group.positions.length;
                placed += group.positions.length * data.objects[group.index / 2].length;
            }
            biggest = Math.max(biggest, body);
            most = Math.max(most, placed);
            out.push(room.number, 2 + body,
                     ((room.scenery.length - castle.scenery_bias) << castle.scenery_shift | room.attr) & 0xFF);
            for (const piece of room.scenery) {
                out.push(piece.template);
                if (castle.scenery_doorway[piece.template]) {
                    out.push(piece.destination);
                }
            }
            for (const group of room.objects) {
                out.push((group.index << 2 | (group.positions.length - 1)) & 0xFF, ...group.positions);
            }
        }
        return { bytes: Uint8Array.from(out), count: data.rooms.length, biggest, most };
    }

    // --- the quest and the sound -----------------------------------------------------

    /// quest.bin as pg_extract.py writes it, and what quest_source.py makes of
    /// it: each record cut down to the fields the remake keeps, the spots and
    /// the targets as they are.
    function quest(memory, q) {
        const table = memory.subarray(q.table, q.table + q.records * q.record_length);
        const spots = memory.subarray(q.spots, q.spots + q.spots_length);
        const targets = memory.subarray(q.targets, q.targets + q.targets_length);
        const records = [];
        for (let n = 0; n < q.records; n++) {
            for (const i of q.kept) {
                records.push(table[n * q.record_length + i]);
            }
        }
        const packed = new Uint8Array(table.length + spots.length + targets.length);
        packed.set(table);
        packed.set(spots, table.length);
        packed.set(targets, table.length + spots.length);
        return { packed, records: Uint8Array.from(records), spots, targets };
    }

    /// sound.bin as pg_extract.py writes it, and what sound_source.py makes of
    /// it: the jingles, the note table as far as the highest note the tunes
    /// play, and the tunes the game plays, each ended by $FF. Null for the
    /// tunes when the copy's are not the shape the remake was laid out for.
    function sound(memory, s) {
        const jingles = memory.subarray(s.jingles, s.jingles + s.jingles_length);
        const rest = memory.subarray(s.notes, s.tunes_end);
        const packed = new Uint8Array(jingles.length + rest.length);
        packed.set(jingles);
        packed.set(rest, jingles.length);
        const tunes = {};
        let at = s.tunes;
        for (const name of s.names) {
            let end = at;
            while (end < s.tunes_end && memory[end] !== 0xFF) {
                end++;
            }
            tunes[name] = memory.subarray(at, end + 1);    // with its $FF
            at = end + 1;
        }
        let highest = 0;
        for (const name of s.played.concat(['title'])) {
            for (const b of tunes[name].subarray(0, tunes[name].length - 1)) {
                highest = Math.max(highest, b & 0x3F);
            }
        }
        const shaped = highest === s.highest
            && s.names.every((name) => tunes[name].length === s.lengths[name] + 1);
        const notes = memory.subarray(s.notes + 3, s.notes + 3 + 3 * s.highest);
        return { packed, jingles, notes, tunes: shaped ? tunes : null };
    }

    // --- the whole -----------------------------------------------------------------

    /// The remake from the bytes of the visitor's copy: the .z80, or a
    /// RemakeError saying why not.
    async function remake(template, info, original, name) {
        if (template.length !== RAM_SIZE) {
            throw new RemakeError('the remake did not load whole (' + template.length + ' bytes)');
        }
        const memory = loadOriginal(original, name, info);
        const different = name + ' is not the copy of Pentagram the remake was made from: ';
        const ram = Uint8Array.from(template);
        const put = (bytes, at) => ram.set(bytes, at - RAM_START);

        const font = memory.slice(info.font.source, info.font.source + info.font.length);
        if (await sha256(font) !== info.font.sha256) {
            throw new RemakeError(different + 'its font is different (a different release, or a crack?)');
        }
        put(font, info.font.at);

        const q = quest(memory, info.quest);
        if (await sha256(q.packed) !== info.quest.sha256) {
            throw new RemakeError(different + 'its quest is different (or a snapshot taken after '
                                  + 'a game was started?)');
        }
        put(q.records, info.quest.at);
        put(q.spots, info.quest.spots_at);
        put(q.targets, info.quest.targets_at);

        const s = sound(memory, info.sound);
        if (await sha256(s.packed) !== info.sound.sha256 || s.tunes === null) {
            throw new RemakeError(different + 'its tunes are different');
        }
        put(s.jingles, info.sound.jingles_at);
        put(s.notes, info.sound.notes_at);
        for (const tune of info.sound.played.concat(['title'])) {
            put(s.tunes[tune], info.sound.tune_at[tune]);
        }

        const rows = spriteRows(memory, info, sprites(memory, info, different), different);
        if (await sha256(rows) !== info.sprite_rows_sha256) {
            throw new RemakeError(different + 'its sprites are different (a different release, or a crack?)');
        }
        let from = 0;
        for (const sprite of info.sprites) {
            const length = sprite.w * sprite.h * 2;
            put(rows.subarray(from, from + length), sprite.at);
            from += length;
        }

        const castle = castleBytes(memory, info.castle);
        if (castle.bytes.length !== info.castle.length || castle.count !== info.castle.room_count
                || castle.biggest !== info.castle.max_body || castle.most !== info.castle.max_objects
                || await sha256(castle.bytes) !== info.castle.sha256) {
            throw new RemakeError(different + 'its rooms are different');
        }
        put(castle.bytes, info.castle.at);

        return z80Snapshot(ram, info.start);
    }

    const api = { RemakeError, tapeBlocks, loadOriginal, remake, sha256, z80Snapshot };
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    } else {
        root.PentagramRemake = api;
    }
})(typeof self !== 'undefined' ? self : this);
