// What a snapshot or tape file is, read from its header: which Spectrum it
// needs, and what a tape holds. No vscode API, so it is tested from plain
// Node (node tests/program_info_test.js); program_view.js shows it.

'use strict';

const SNA_HEADER_BYTES = 27;
const SNA_48K = SNA_HEADER_BYTES + 0xC000;
const SNA_128K_SIZES = [131103, 147487];

// .z80's hardware byte, by header version: what each value means.
const Z80_V2_MODELS = { 0: '48K', 1: '48K + Interface 1', 2: 'SamRam', 3: '128K', 4: '128K + Interface 1' };
const Z80_V3_MODELS = {
  0: '48K', 1: '48K + Interface 1', 2: 'SamRam', 3: '48K + M.G.T.', 4: '128K',
  5: '128K + Interface 1', 6: '128K + M.G.T.', 7: '+3', 8: '+3', 9: 'Pentagon', 12: '+2', 13: '+2A'
};

// Whether a file is text rather than a binary image: no NUL bytes and hardly
// any control characters in its first few kilobytes. `.z80` is a snapshot
// extension and an assembly source extension both, and a source file opened
// as a snapshot would be no use to anyone.
function looksLikeText(bytes) {
  const n = Math.min(bytes.length, 4096);
  if (n === 0) {
    return true;
  }
  let odd = 0;
  for (let i = 0; i < n; i++) {
    const b = bytes[i];
    if (b === 0) {
      return false;
    }
    if (b < 9 || (b > 13 && b < 32)) {
      odd++;
    }
  }
  return odd / n < 0.02;
}

function word(bytes, at) {
  return bytes[at] | (bytes[at + 1] << 8);
}

function hex4(value) {
  return '$' + value.toString(16).toUpperCase().padStart(4, '0');
}

function describeSna(bytes) {
  if (bytes.length === SNA_48K) {
    return { kind: 'snapshot', format: '.sna', model: '48K', needs128: false, details: [] };
  }
  if (SNA_128K_SIZES.includes(bytes.length)) {
    const pc = word(bytes, SNA_48K);
    return { kind: 'snapshot', format: '.sna', model: '128K', needs128: true, details: ['PC ' + hex4(pc)] };
  }
  return { kind: 'unknown', problem: `A .sna is ${SNA_48K} bytes (48K) or ${SNA_128K_SIZES.join(' or ')} ` +
    `(128K); this one is ${bytes.length}.` };
}

function describeZ80(bytes) {
  if (bytes.length < 30) {
    return { kind: 'unknown', problem: 'Too short for a .z80 snapshot.' };
  }
  const pc = word(bytes, 6);
  if (pc !== 0) {
    const compressed = (bytes[12] === 255 ? 1 : bytes[12]) & 0x20;
    return { kind: 'snapshot', format: '.z80 version 1', model: '48K', needs128: false,
             details: ['PC ' + hex4(pc), compressed ? 'compressed' : 'not compressed'] };
  }
  if (bytes.length < 35) {
    return { kind: 'unknown', problem: 'Too short for a .z80 snapshot.' };
  }
  const extra = word(bytes, 30);
  const version = extra === 23 ? 2 : (extra === 54 || extra === 55) ? 3 : 0;
  if (!version) {
    return { kind: 'unknown', problem: `Not a .z80 snapshot this can read (extra header length ${extra}).` };
  }
  const hardware = bytes[34];
  const table = version === 2 ? Z80_V2_MODELS : Z80_V3_MODELS;
  const model = table[hardware] || `hardware ${hardware}`;
  const needs128 = /^(128K|\+2|\+3)/.test(model);
  // Bit 7 of byte 37 turns a 48K into a 16K or a 128K into a +2 in some
  // emulators; it does not change which ROM is needed here.
  return { kind: 'snapshot', format: `.z80 version ${version}`, model, needs128,
           details: ['PC ' + hex4(word(bytes, 32))] };
}

const TAP_TYPES = ['Program', 'Number array', 'Character array', 'Bytes'];

function headerName(bytes, at) {
  let name = '';
  for (let i = 0; i < 10; i++) {
    const c = bytes[at + i];
    name += c >= 32 && c < 127 ? String.fromCharCode(c) : '?';
  }
  return name.trimEnd();
}

// The files a tape's header blocks name, as { flag, data } blocks from
// tapBlocks or tzxBlocks: a header is flag 0 and 17 bytes between the flag
// and the checksum.
function headerFiles(blocks) {
  const files = [];
  for (const b of blocks) {
    if (b.flag === 0 && b.data.length === 17) {
      const type = b.data[0];
      files.push((TAP_TYPES[type] || 'Type ' + type) + ': ' + headerName(b.data, 1));
    }
  }
  return files;
}

// A .tap is length-prefixed blocks; a header block (flag 0, 19 bytes with its
// checksum) names the file that follows. Plenty of tapes in the wild end in a
// few stray bytes; those are noted rather than taken as the file being bad.
function describeTap(bytes) {
  const files = headerFiles(tapBlocks(bytes));
  let blocks = 0;
  let at = 0;
  let stray = 0;
  while (at + 2 <= bytes.length) {
    const length = word(bytes, at);
    const start = at + 2;
    if (length === 0 || start + length > bytes.length) {
      if (blocks === 0) {
        return { kind: 'unknown', problem: `The block at offset ${at} runs past the end of the file.` };
      }
      stray = bytes.length - at;
      break;
    }
    blocks++;
    at = start + length;
  }
  if (blocks === 0) {
    return { kind: 'unknown', problem: 'This tape holds no blocks.' };
  }
  const details = [blocks + ' block' + (blocks === 1 ? '' : 's')].concat(files);
  if (stray) {
    details.push(`${stray} stray byte${stray === 1 ? '' : 's'} at the end, ignored`);
  }
  return { kind: 'tape', format: '.tap', model: '48K', needs128: false, details };
}

function describeTzx(bytes) {
  const signature = String.fromCharCode(...bytes.subarray(0, 7));
  if (signature !== 'ZXTape!' || bytes[7] !== 0x1A) {
    return { kind: 'unknown', problem: 'Not a TZX tape (no "ZXTape!" signature).' };
  }
  const labels = tzxLabels(bytes);
  const details = [];
  const credit = [labels.title, labels.publisher, labels.year].filter(Boolean);
  if (credit.length) {
    details.push(credit.join(', '));
  }
  details.push(labels.dataBlocks + ' data block' + (labels.dataBlocks === 1 ? '' : 's'));
  details.push(...headerFiles(tzxBlocks(bytes)));
  if (labels.dataBlocks) {
    details.push('Loader: ' + labels.loader);
  }
  return { kind: 'tape', format: `.tzx version ${bytes[8]}.${String(bytes[9]).padStart(2, '0')}`,
           model: '48K', needs128: false, details };
}

// What the file is, from its extension and its bytes. `kind` is snapshot,
// tape or unknown (with a `problem` saying why).
function describeProgram(fileName, bytes) {
  const ext = (fileName.match(/\.[^.\\/]*$/) || [''])[0].toLowerCase();
  if (ext === '.sna') {
    return describeSna(bytes);
  }
  if (ext === '.z80') {
    return describeZ80(bytes);
  }
  if (ext === '.tap') {
    return describeTap(bytes);
  }
  if (ext === '.tzx') {
    return describeTzx(bytes);
  }
  return { kind: 'unknown', problem: `${ext || 'This file'} is not a snapshot or a tape.` };
}

// The ROM a program needs, from a list of candidates and their sizes: a
// 32K pair for a 128K, a 16K ROM otherwise. `size(path)` answers, or null.
function pickRom(roms, needs128, size) {
  const wanted = needs128 ? 32768 : 16384;
  return roms.find((rom) => size(rom) === wanted) || null;
}

// A launch configuration for a program opened from the Explorer.
// `debugInfo` is { sld, asm } when both sit beside the program.
function launchConfigFor(filePath, fileName, info, rom, debugInfo, stopOnEntry) {
  const config = {
    type: 'zxspectrum',
    request: 'launch',
    name: 'ZX Spectrum: ' + fileName,
    stopOnEntry: stopOnEntry === true
  };
  if (rom) {
    config.rom = rom;
  }
  if (info.needs128) {
    config.machine = '128';
  }
  if (info.kind === 'tape') {
    config.tape = filePath;
    config.tapeAutoStart = true;
  } else {
    config.snapshot = filePath;
  }
  if (debugInfo && debugInfo.sld && debugInfo.asm) {
    config.sld = debugInfo.sld;
    config.asm = debugInfo.asm;
  }
  return config;
}

// The debug info beside a program: name.sld and a source of the same name.
function debugInfoCandidates(filePath) {
  const stem = filePath.replace(/\.[^.\\/]*$/, '');
  const exts = ['.asm', '.s', '.a80'];
  // A build that writes into a folder of its own -- examples/filmation's
  // output/ -- leaves the snapshot and the .sld there and the entry source
  // one level up, so that is looked in too, after the snapshot's own folder.
  const cut = Math.max(stem.lastIndexOf('/'), stem.lastIndexOf('\\'));
  const dir = cut >= 0 ? stem.slice(0, cut) : '';
  const up = Math.max(dir.lastIndexOf('/'), dir.lastIndexOf('\\'));
  const above = up >= 0 ? dir.slice(0, up) + stem.slice(cut) : null;
  return {
    sld: stem + '.sld',
    asm: exts.map((ext) => stem + ext).concat(above ? exts.map((ext) => above + ext) : [])
  };
}

// ---- the picture -------------------------------------------------------------
//
// What the program's screen looks like: the 6912 bytes of display file and
// attributes at $4000 in a snapshot, or the loading screen a tape carries.
// Returns { screen, border, source } or null when there is none to show.

const SCREEN_BYTES = 6912;

// .z80's run-length scheme: ED ED nn bb is nn copies of bb; anything else is
// itself. `out` is filled from the start; returns how many bytes were written.
function unpackZ80(bytes, start, end, out) {
  let o = 0;
  let i = start;
  while (i < end && o < out.length) {
    if (bytes[i] === 0xED && i + 1 < end && bytes[i + 1] === 0xED && i + 3 < end) {
      const count = bytes[i + 2];
      const value = bytes[i + 3];
      for (let n = 0; n < count && o < out.length; n++) {
        out[o++] = value;
      }
      i += 4;
    } else {
      out[o++] = bytes[i++];
    }
  }
  return o;
}

function snaScreen(bytes) {
  if (bytes.length !== SNA_48K && !SNA_128K_SIZES.includes(bytes.length)) {
    return null;
  }
  // RAM starts at $4000 straight after the header -- on a 128K too, whose
  // first three pages are the ones paged in, and $4000 is always page 5.
  return { screen: bytes.subarray(SNA_HEADER_BYTES, SNA_HEADER_BYTES + SCREEN_BYTES),
           border: bytes[26] & 7, source: 'the snapshot' };
}

function z80Screen(bytes) {
  const info = describeZ80(bytes);
  if (info.kind !== 'snapshot') {
    return null;
  }
  const flags = bytes[12] === 255 ? 1 : bytes[12];
  const border = (flags >> 1) & 7;
  const screen = new Uint8Array(SCREEN_BYTES);
  if (word(bytes, 6) !== 0) {
    // Version 1: all 48K of RAM from offset 30, compressed or not; the
    // screen is its first 6912 bytes.
    if (flags & 0x20) {
      unpackZ80(bytes, 30, bytes.length, screen);
    } else {
      screen.set(bytes.subarray(30, 30 + SCREEN_BYTES));
    }
    return { screen, border, source: 'the snapshot' };
  }
  // Versions 2 and 3: memory blocks, each a length, a page number and the
  // (usually compressed) 16K. Page 8 is $4000 on a 48K, and RAM page 5 --
  // which is $4000 -- on a 128K.
  let at = 30 + 2 + word(bytes, 30);
  while (at + 3 <= bytes.length) {
    const length = word(bytes, at);
    const page = bytes[at + 2];
    const start = at + 3;
    const size = length === 0xFFFF ? 16384 : length;
    if (page === 8) {
      if (length === 0xFFFF) {
        screen.set(bytes.subarray(start, start + SCREEN_BYTES));
      } else {
        const whole = new Uint8Array(16384);
        unpackZ80(bytes, start, Math.min(start + size, bytes.length), whole);
        screen.set(whole.subarray(0, SCREEN_BYTES));
      }
      return { screen, border, source: 'the snapshot' };
    }
    at = start + size;
  }
  return null;
}

// The data blocks a tape holds, in order: { flag, data, raw } -- `data`
// without the flag byte and checksum, `raw` with them. For a .tzx only the block types that carry
// standard-shaped data are read; the rest are stepped over.
function tapBlocks(bytes) {
  const blocks = [];
  let at = 0;
  while (at + 2 <= bytes.length) {
    const length = word(bytes, at);
    const start = at + 2;
    if (length < 2 || start + length > bytes.length) {
      break;
    }
    blocks.push({ flag: bytes[start], data: bytes.subarray(start + 1, start + length - 1),
                  raw: bytes.subarray(start, start + length) });
    at = start + length;
  }
  return blocks;
}

// Every block of a .tzx in order: visit(id, p) with `p` the offset of the
// block's body, just past its ID byte.
function walkTzx(bytes, visit) {
  const dword = (p) => word(bytes, p) + word(bytes, p + 2) * 65536;
  const triple = (p) => word(bytes, p) + bytes[p + 2] * 65536;
  let at = 10;
  while (at < bytes.length) {
    const id = bytes[at];
    const p = at + 1;
    visit(id, p);
    let next;
    switch (id) {
      case 0x10: next = p + 4 + word(bytes, p + 2); break;
      case 0x11: next = p + 18 + triple(p + 15); break;
      case 0x14: next = p + 10 + triple(p + 7); break;
      case 0x12: next = p + 4; break;
      case 0x13: next = p + 1 + bytes[p] * 2; break;
      case 0x15: next = p + 8 + triple(p + 5); break;
      case 0x18: case 0x19: next = p + 4 + dword(p); break;
      case 0x20: case 0x23: case 0x24: next = p + 2; break;
      case 0x21: case 0x30: next = p + 1 + bytes[p]; break;
      case 0x22: case 0x25: case 0x27: next = p; break;
      case 0x26: next = p + 2 + word(bytes, p) * 2; break;
      case 0x28: case 0x32: next = p + 2 + word(bytes, p); break;
      case 0x2A: next = p + 4; break;
      case 0x2B: next = p + 5; break;
      case 0x31: next = p + 2 + bytes[p + 1]; break;
      case 0x33: next = p + 1 + bytes[p] * 3; break;
      case 0x35: next = p + 20 + dword(p + 16); break;
      case 0x5A: next = p + 9; break;
      default: next = p + 4 + dword(p); break;  // the spec's rule for unknown blocks
    }
    if (!(next > at)) {
      break;
    }
    at = next;
  }
}

function tzxBlocks(bytes) {
  const blocks = [];
  const data = (start, length) => {
    if (length >= 2 && start + length <= bytes.length) {
      blocks.push({ flag: bytes[start], data: bytes.subarray(start + 1, start + length - 1),
                    raw: bytes.subarray(start, start + length) });
    }
  };
  walkTzx(bytes, (id, p) => {
    if (id === 0x10) {
      data(p + 4, word(bytes, p + 2));
    } else if (id === 0x11) {
      data(p + 18, word(bytes, p + 15) + bytes[p + 17] * 65536);
    } else if (id === 0x14) {
      data(p + 10, word(bytes, p + 7) + bytes[p + 9] * 65536);
    }
  });
  return blocks;
}

// The blocks that put data on the tape, of every encoding: standard, turbo,
// pure data, direct recording, CSW and generalized.
const TZX_DATA_IDS = [0x10, 0x11, 0x14, 0x15, 0x18, 0x19];

// Archive info fields (block $32) by ID, from the TZX spec.
const TZX_TITLE = 0x00;
const TZX_PUBLISHER = 0x01;
const TZX_YEAR = 0x03;
const TZX_LOADER = 0x07;       // "protection scheme / loader"

// What a .tzx says about itself: the archive info's title, publisher and
// year, how many data blocks it holds, and its loader. The loader is the one
// the archive info names; failing that, the one its groups are named after --
// the convention is "SpeedLock 1 Block 1", "SpeedLock 1 Block 2" and so on;
// failing that, "standard" when every block is at the ROM's timings, which
// is all that can honestly be said without recognising a loader's code.
function tzxLabels(bytes) {
  const info = {};
  let group = null;
  let dataBlocks = 0;
  let standard = true;
  walkTzx(bytes, (id, p) => {
    if (TZX_DATA_IDS.includes(id)) {
      dataBlocks++;
      standard = standard && id === 0x10;
    } else if (id === 0x32 && p + 3 <= bytes.length) {
      let q = p + 3;
      for (let n = 0; n < bytes[p + 2] && q + 2 <= bytes.length; n++) {
        info[bytes[q]] = String.fromCharCode(...bytes.subarray(q + 2, q + 2 + bytes[q + 1]))
          .replace(/\r\n?/g, ' / ').trim();
        q += 2 + bytes[q + 1];
      }
    } else if (id === 0x21 && group === null && p < bytes.length) {
      const name = String.fromCharCode(...bytes.subarray(p + 1, p + 1 + bytes[p]));
      const loader = name.match(/^(.+?)\s+block\s+\d+\s*$/i);
      if (loader) {
        group = loader[1];
      }
    }
  });
  let loader = info[TZX_LOADER] || group;
  if (!loader) {
    loader = standard ? 'standard (every block at the ROM\'s timings)' : 'custom (the tape doesn\'t name it)';
  }
  return { title: info[TZX_TITLE], publisher: info[TZX_PUBLISHER], year: info[TZX_YEAR], dataBlocks, loader };
}

// Whether 6912 bytes look like a screen's own attributes: FLASH on no more
// than an eighth of the cells. Loading screens hardly flash -- the Hobbit's,
// Pentagram's, Sweevo's World's and both Daley Thompson games' have not one
// flashing cell -- while bytes that are not plain attributes set bit 7 about
// half the time: an encrypted Speedlock 2 screen (Head Over Heels) on 97% of
// its cells, Knight Lore's rotated attributes on 48%.
const MAX_FLASHING = 768 / 8;

function plausibleScreen(screen) {
  let flashing = 0;
  for (let i = 6144; i < SCREEN_BYTES; i++) {
    if (screen[i] & 0x80) {
      flashing++;
    }
  }
  return flashing <= MAX_FLASHING;
}

// A tape's loading screen: the data block a SCREEN$ header (a Bytes header
// for 6912 bytes at 16384) announces, or else the first headerless block
// that is a flag byte and 6912 bytes, with or without a checksum after them
// -- which is how most custom loaders carry theirs.
//
// A headerless block is only a guess, and a custom loader may not store its
// screen as the display file does. Knight Lore's (a Speedlock 1 tape) holds
// every attribute rotated right a bit -- rotated left, they are ZXDB's
// picture of its screen exactly -- though Ocean's Speedlock 1 tapes store
// theirs plain; the Speedlock 2 on Head Over Heels encrypts the lot. So a
// guess whose attributes don't look like attributes is tried with them
// rotated left, and failing that is no picture rather than a garbled one.
function tapeScreen(blocks) {
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    if (b.flag === 0 && b.data.length === 17 && b.data[0] === 3 &&
        word(b.data, 11) === SCREEN_BYTES && word(b.data, 13) === 16384 &&
        i + 1 < blocks.length && blocks[i + 1].data.length >= SCREEN_BYTES) {
      return { screen: blocks[i + 1].data.subarray(0, SCREEN_BYTES), border: 7,
               source: 'the tape\'s loading screen' };
    }
  }
  const bare = blocks.find((b) => b.flag !== 0 &&
    (b.raw.length === SCREEN_BYTES + 2 || b.raw.length === SCREEN_BYTES + 1));
  if (!bare) {
    return null;
  }
  const screen = bare.raw.subarray(1, 1 + SCREEN_BYTES);
  if (plausibleScreen(screen)) {
    return { screen, border: 7, source: 'the tape\'s loading screen' };
  }
  const rotated = Uint8Array.from(screen);
  for (let i = 6144; i < SCREEN_BYTES; i++) {
    rotated[i] = ((rotated[i] << 1) | (rotated[i] >> 7)) & 0xFF;
  }
  if (plausibleScreen(rotated)) {
    return { screen: rotated, border: 7, source: 'the tape\'s loading screen, its attributes rotated back' };
  }
  return null;
}

function programScreen(fileName, bytes) {
  const ext = (fileName.match(/\.[^.\\/]*$/) || [''])[0].toLowerCase();
  try {
    if (ext === '.sna') {
      return snaScreen(bytes);
    }
    if (ext === '.z80') {
      return z80Screen(bytes);
    }
    if (ext === '.tap') {
      return tapeScreen(tapBlocks(bytes));
    }
    if (ext === '.tzx' && describeTzx(bytes).kind === 'tape') {
      return tapeScreen(tzxBlocks(bytes));
    }
  } catch (err) {
    return null;
  }
  return null;
}

module.exports = {
  looksLikeText, describeProgram, pickRom, launchConfigFor, debugInfoCandidates,
  unpackZ80, programScreen, tapBlocks, tzxBlocks, tzxLabels
};
