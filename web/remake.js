// The Filmation Knight Lore made from a visitor's own copy of the original:
// what web/knightlore.html does with the file it is given, kept apart from
// the page so that web/tests/knightlore_test.js can run it from Node.
//
// The site carries the remake with its font, its sprites' rows and its DAY
// lettering left blank (web/knightlore_template.py says why those are the
// whole of the difference). This reads them out of the copy as kl_extract.py
// does, checks them against the hashes of what the build puts in the image,
// puts them in -- the sprites the way sprite_sheet.py and sprite_source.py
// turn them round -- and writes the .z80 build.py would have.
'use strict';

(function (root) {
    const RAM_START = 0x4000;
    const RAM_SIZE = 0xC000;
    const SNA_48K_SIZE = 27 + RAM_SIZE;
    const Z80_V1_HEADER = 30;
    const PAGE_SIZE = 0x4000;
    /// The .z80 pages a 48K machine has, and where each one sits.
    const Z80_PAGES_48K = { 8: 0x4000, 4: 0x8000, 5: 0xC000 };
    /// Hardware bytes (header byte 34) that are a 48K: plain and with
    /// Interface 1, and in version 3 files with an M.G.T. as well.
    const Z80_HARDWARE_48K_V2 = [0, 1];
    const Z80_HARDWARE_48K_V3 = [0, 1, 3];

    /// What the visitor is told; the page shows its message as it is.
    class RemakeError extends Error {}

    /// ED ED n b is n copies of b; everything else is itself.
    function z80Decompress(data, size) {
        const out = new Uint8Array(size);
        let at = 0;
        let length = 0;
        while (at < data.length && length < size) {
            if (data[at] === 0xED && at + 1 < data.length && data[at + 1] === 0xED) {
                for (let n = 0; n < data[at + 2] && length < size; n++) {
                    out[length++] = data[at + 3];
                }
                at += 4;
            } else {
                out[length++] = data[at++];
            }
        }
        if (length !== size) {
            throw new RemakeError('a .z80 page unpacked to ' + length + ' bytes, not ' + size);
        }
        return out;
    }

    function loadZ80(raw) {
        const memory = new Uint8Array(0x10000);
        const pc = raw[6] | (raw[7] << 8);
        if (pc !== 0) {
            // Version 1: 48K only, one block from $4000, compressed if bit 5
            // of byte 12 is set (byte 12 of 255 means 1, for old files).
            const flags = raw[12] !== 0xFF ? raw[12] : 1;
            let body = raw.subarray(Z80_V1_HEADER);
            if (flags & 0x20) {
                const n = body.length;
                if (n >= 4 && body[n - 4] === 0 && body[n - 3] === 0xED && body[n - 2] === 0xED
                        && body[n - 1] === 0) {
                    body = body.subarray(0, n - 4);
                }
                body = z80Decompress(body, RAM_SIZE);
            } else if (body.length < RAM_SIZE) {
                throw new RemakeError('this .z80 is shorter than 48K of RAM');
            }
            memory.set(body.subarray(0, RAM_SIZE), RAM_START);
            return memory;
        }
        const extra = raw[30] | (raw[31] << 8);
        const hardware = raw[34];
        const allowed = extra === 23 ? Z80_HARDWARE_48K_V2 : Z80_HARDWARE_48K_V3;
        if (!allowed.includes(hardware)) {
            throw new RemakeError('this .z80 is of a 128K (hardware ' + hardware
                                  + '): use one taken on a 48K');
        }
        let at = 32 + extra;
        const seen = new Set();
        while (at + 3 <= raw.length) {
            const length = raw[at] | (raw[at + 1] << 8);
            const page = raw[at + 2];
            at += 3;
            let data;
            if (length === 0xFFFF) {
                data = raw.subarray(at, at + PAGE_SIZE);
                at += PAGE_SIZE;
            } else {
                data = z80Decompress(raw.subarray(at, at + length), PAGE_SIZE);
                at += length;
            }
            if (page in Z80_PAGES_48K) {
                memory.set(data, Z80_PAGES_48K[page]);
                seen.add(page);
            }
        }
        if (seen.size !== Object.keys(Z80_PAGES_48K).length) {
            throw new RemakeError("this .z80 is missing some of a 48K's RAM");
        }
        return memory;
    }

    /// The 64K address space from a 48K .sna or .z80, the ROM left as zeros:
    /// examples/filmation/original.py's load_snapshot, in the browser.
    function readSnapshot(raw, name) {
        const suffix = String(name || '').toLowerCase().split('.').pop();
        if (suffix === 'sna') {
            if (raw.length !== SNA_48K_SIZE) {
                throw new RemakeError(name + ' is ' + raw.length + ' bytes; a 48K .sna is '
                                      + SNA_48K_SIZE);
            }
            const memory = new Uint8Array(0x10000);
            memory.set(raw.subarray(27), RAM_START);
            return memory;
        }
        if (suffix === 'z80') {
            return loadZ80(raw);
        }
        throw new RemakeError(name + ' is not a snapshot (.sna or .z80)');
    }

    /// ED ED n b for a run of five or more, or of two or more EDs. A lone ED
    /// goes out literally along with the byte after it, so that no decoder
    /// can take the pair for a run marker. build.py's z80_compress.
    function z80Compress(data) {
        const out = [];
        let i = 0;
        while (i < data.length) {
            const b = data[i];
            let run = 1;
            while (i + run < data.length && data[i + run] === b && run < 255) {
                run++;
            }
            if (run >= 5 || (b === 0xED && run >= 2)) {
                out.push(0xED, 0xED, run, b);
                i += run;
            } else if (b === 0xED) {
                out.push(data[i]);
                if (i + 1 < data.length) {
                    out.push(data[i + 1]);
                }
                i += 2;
            } else {
                out.push(b);
                i++;
            }
        }
        return out;
    }

    /// 48K of RAM from $4000 as a version 3 .z80 about to run from `pc` --
    /// build.py's z80_snapshot, byte for byte.
    function z80Snapshot(ram, pc) {
        const EXTRA = 54;
        const header = new Uint8Array(30 + 2 + EXTRA);
        header[10] = 0x3F;                  // I, as the ROM leaves it
        header[29] = 1;                     // IM 1; IFF1 and IFF2 stay 0
        header[30] = EXTRA;
        header[32] = pc & 0xFF;
        header[33] = pc >> 8;
        header[34] = 0;                     // hardware: 48K
        header[61] = 0xFF;                  // the ROM is paged in
        header[62] = 0xFF;
        const parts = [header];
        for (const [page, offset] of [[8, 0x0000], [4, 0x4000], [5, 0x8000]]) {
            const packed = z80Compress(ram.subarray(offset, offset + PAGE_SIZE));
            parts.push(Uint8Array.of(packed.length & 0xFF, packed.length >> 8, page),
                       Uint8Array.from(packed));
        }
        let total = 0;
        for (const part of parts) {
            total += part.length;
        }
        const out = new Uint8Array(total);
        let at = 0;
        for (const part of parts) {
            out.set(part, at);
            at += part.length;
        }
        return out;
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

    /// Turns the sprite record at `at` back the way the tape holds it if the
    /// game has mirrored it left to right, as it does in place when it draws
    /// one. original.py's unmirror, for Knight Lore's one flag.
    function unmirror(memory, at, mirrored) {
        if (!(memory[at] & mirrored)) {
            return;
        }
        const width = memory[at] & 0x1F;
        const height = memory[at + 1];
        for (let r = 0; r < height; r++) {
            const row = at + 2 + r * width * 2;
            const pairs = [];
            for (let c = 0; c < width; c++) {
                pairs.push([memory[row + 2 * c], memory[row + 2 * c + 1]]);
            }
            pairs.reverse();
            for (let c = 0; c < width; c++) {
                memory[row + 2 * c] = reverseBits(pairs[c][0]);
                memory[row + 2 * c + 1] = reverseBits(pairs[c][1]);
            }
        }
        memory[at] &= ~mirrored & 0xFF;
    }

    /// The game's sprite records, as kl_extract.py walks them: every one
    /// turned back the right way round, then the ones that are not empty, in
    /// address order, with where each sits and its size.
    function sprites(memory, info) {
        let p = info.sprites_start;
        while (p < info.sprites_end) {
            const width = memory[p] & 0x1F;
            const height = memory[p + 1];
            if (width && height) {
                unmirror(memory, p, info.mirrored);
            }
            p += 2 + width * height * 2;
        }
        const records = [];
        p = info.sprites_start;
        while (p < info.sprites_end) {
            const width = memory[p] & 0x1F;
            const height = memory[p + 1];
            const length = 2 + width * height * 2;
            if (width && height) {
                records.push({ at: p, w: width, h: height });
            }
            p += length;
        }
        if (p !== info.sprites_end) {
            throw new RemakeError('this is not Knight Lore: its sprites do not end where '
                                  + "Knight Lore's do");
        }
        return records;
    }

    /// The record a graphic number draws, through the copy's own table.
    function recordOf(memory, info, records, graphic) {
        const pointer = info.sprite_table + 2 * graphic;
        const address = memory[pointer] | (memory[pointer + 1] << 8);
        return records.findIndex((record) => record.at === address);
    }

    /// Turns a record upside down: the game does it to the menu's corner as
    /// it draws the frame, and records it nowhere.
    function turnOver(memory, record) {
        const stride = record.w * 2;
        const rows = [];
        for (let r = 0; r < record.h; r++) {
            rows.push(memory.slice(record.at + 2 + r * stride, record.at + 2 + (r + 1) * stride));
        }
        rows.reverse();
        rows.forEach((row, r) => memory.set(row, record.at + 2 + r * stride));
    }

    /// Every sprite's rows as the build emits them, one after another in the
    /// template's order: the record found through the copy's own graphic
    /// table, its rows top row first where the game stores them bottom row
    /// first, the blank rows the sheet trimmed off left off, and the mask
    /// inverted.
    function spriteRows(info, memory, records) {
        let total = 0;
        for (const sprite of info.sprites) {
            total += sprite.w * sprite.h * 2;
        }
        const out = new Uint8Array(total);
        let to = 0;
        const used = new Set();
        for (const sprite of info.sprites) {
            const n = recordOf(memory, info, records, sprite.graphic);
            const record = records[n];
            if (record === undefined || used.has(n) || record.w !== sprite.w
                    || record.h !== sprite.h + sprite.trim) {
                throw new RemakeError("this copy's sprites are not laid out as Knight Lore's are");
            }
            used.add(n);
            const stride = record.w * 2;
            for (let row = record.h - 1; row >= 0; row--) {
                const from = record.at + 2 + row * stride;
                for (let b = 0; b < stride; b += 2) {
                    if (row < sprite.trim) {
                        // Below the sprite's bottom: trimmed, and blank.
                        if (memory[from + b] || memory[from + b + 1]) {
                            throw new RemakeError("this copy's sprites are not Knight Lore's");
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

    /// The sprites' rows from the copy, checked against the hash of the rows
    /// the build emits -- trying the menu's corner both ways up -- and written
    /// where the template keeps them.
    async function putSprites(ram, info, memory, different) {
        const records = sprites(memory, info);
        let rows = spriteRows(info, memory, records);
        if (await sha256(rows) !== info.sprite_rows_sha256) {
            const corner = recordOf(memory, info, records, info.menu_corner_graphic);
            if (corner >= 0) {
                turnOver(memory, records[corner]);
                rows = spriteRows(info, memory, records);
            }
        }
        if (await sha256(rows) !== info.sprite_rows_sha256) {
            throw new RemakeError(different + 'its sprites are different (a different release, '
                                  + 'or a crack?)');
        }
        let from = 0;
        for (const sprite of info.sprites) {
            const length = sprite.w * sprite.h * 2;
            ram.set(rows.subarray(from, from + length), sprite.at - RAM_START);
            from += length;
        }
    }

    async function sha256(bytes) {
        const digest = await crypto.subtle.digest('SHA-256', bytes);
        return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
    }

    /// The remake from the bytes of the visitor's copy: the .z80, or a
    /// RemakeError saying why not.
    async function remake(template, info, original, name) {
        if (template.length !== RAM_SIZE) {
            throw new RemakeError('the remake did not load whole (' + template.length + ' bytes)');
        }
        const memory = readSnapshot(original, name);
        const different = name + ' is not the copy of Knight Lore the remake was made from: ';
        const font = memory.slice(info.font_source, info.font_source + info.font_length);
        if (await sha256(font) !== info.font_sha256) {
            throw new RemakeError(different + 'its font is different (a different release, or a crack?)');
        }
        const day = memory.slice(info.day_source, info.day_source + info.day_length);
        if (await sha256(day) !== info.day_sha256) {
            throw new RemakeError(different + 'its DAY lettering is different');
        }
        const ram = Uint8Array.from(template);
        ram.set(font, info.font_at - RAM_START);
        ram.set(day, info.day_at - RAM_START);
        await putSprites(ram, info, memory, different);
        return z80Snapshot(ram, info.start);
    }

    const api = { RemakeError, readSnapshot, z80Snapshot, remake, sha256 };
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    } else {
        root.KnightLoreRemake = api;
    }
})(typeof self !== 'undefined' ? self : this);
