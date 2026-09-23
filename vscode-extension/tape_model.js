// The tape designer's pure half: the two files a tape is designed in, the
// loading schemes it can be built for, what it costs on tape, what its screen
// looks like part way through loading, and whether it can load at all.
//
// A `*.tape.json` is the tape -- its scheme, its blocks keyed by name in tape
// order, where it jumps -- and a `*.screen.json` its loading screen: a picture,
// and the order its character-cell rectangles are sent in. For a loader that
// sends a screen in pieces, like the fast loader in examples/zx-tape-loader,
// that order is the reveal, the picture appearing rectangle by rectangle in the
// time each one's bytes take to arrive.
//
// Everything here mirrors what builds the tape -- the fast loader's loader.py
// (gen_block's runs, scr_header's 18-bit headers, dme_byte's fixed-length bits,
// check_design's rules) and the emulator's scripts/tape_rom.py (the standard
// loader's BASIC and .tap, its rules) -- because a cost or a verdict here that
// the builder disagreed with would make the designer a liar.
// tests/tape_model_test.js holds them to each other.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node tests/tape_model_test.js). The page gets it inlined as source the way
// graphics_model.js is, which is why nothing here may use require() and why
// the export at the bottom is guarded.

'use strict';

const BITMAP_BYTES = 6144;
const ATTR_BYTES = 768;
const SCREEN_BYTES = BITMAP_BYTES + ATTR_BYTES;
const COLUMNS = 32;
const ROWS = 24;

// scr_header() writes a 13-bit offset and a 5-bit length-1, so a run costs 18
// bits of header and its bytes cost 8 each. dme_byte() spends the same time on
// a 1 (one whole pulse) as on a 0 (two half pulses), so every bit is the same
// 672 T-states and what a pattern costs depends only on how many bits it is,
// never on what the picture happens to be.
const HEADER_BITS = 18;
const BIT_TSTATES = (69888 / 8) / 13;
const CPU_HZ = 3500000;

// The 5-bit all-ones value that ends the screen and hands over to the control
// blocks -- tape.s reads it as a block address MSB that has gone negative.
const END_BITS = 5;

// The display file's own order, as loader.py's get_pixel_address computes it.
function pixelAddress(x, line) {
  return ((line & 0xC0) << 5) + ((line & 0x07) << 8) + ((line & 0x38) << 2) + x;
}

function attrAddress(x, line) {
  return ((line & 0xF8) << 2) + x;
}

// A rectangle the loader can actually send: inside the screen, at least one
// cell, and no wider than the 5-bit length field can describe.
function clampRegion(region) {
  const x = Math.max(0, Math.min(COLUMNS - 1, Math.round(region.x || 0)));
  const y = Math.max(0, Math.min(ROWS - 1, Math.round(region.y || 0)));
  const w = Math.max(1, Math.min(COLUMNS - x, Math.round(region.w || 1)));
  const h = Math.max(1, Math.min(ROWS - y, Math.round(region.h || 1)));
  return { x, y, w, h };
}

function sameRegion(a, b) {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
}

// Whether a cell has any ink in it at all -- the test both the automatic pass
// and the coverage report use for "is there anything here to reveal".
function cellHasInk(screen, col, row) {
  for (let line = row * 8; line < row * 8 + 8; line++) {
    if (screen[pixelAddress(col, line)]) {
      return true;
    }
  }
  return false;
}

// loader.py's analyse_screen_regions: reveal top to bottom, skip character
// rows with nothing in them, and bound each run of non-blank rows to the
// columns that actually have content. This is the pattern the designer starts
// from, so it is worth matching exactly -- a seed that differed from what
// convert_tape.py does on its own would be a confusing place to start editing.
function autoRegions(screen) {
  const bounds = [];
  for (let row = 0; row < ROWS; row++) {
    let min = null;
    let max = null;
    for (let col = 0; col < COLUMNS; col++) {
      if (cellHasInk(screen, col, row)) {
        if (min === null) {
          min = col;
        }
        max = col;
      }
    }
    bounds.push([min, max]);
  }

  const regions = [];
  let start = null;
  let min = 0;
  let max = 0;
  bounds.push([null, null]);
  for (let row = 0; row < bounds.length; row++) {
    const rowMin = bounds[row][0];
    const rowMax = bounds[row][1];
    if (rowMin === null) {
      if (start !== null) {
        regions.push({ x: min, y: start, w: max - min + 1, h: row - start });
        start = null;
      }
    } else if (start === null) {
      start = row;
      min = rowMin;
      max = rowMax;
    } else {
      min = Math.min(min, rowMin);
      max = Math.max(max, rowMax);
    }
  }
  return regions;
}

// The runs gen_block() would emit for one rectangle, in the order it emits
// them: the attribute row at the top of each character row, then one run per
// pixel line with its leading and trailing blank bytes stripped off -- which
// is why a wide rectangle over a narrow drawing costs little more than a tight
// one, and why a line with nothing on it costs nothing at all.
function regionRuns(screen, region) {
  const r = clampRegion(region);
  const runs = [];
  for (let line = r.y * 8; line < (r.y + r.h) * 8; line++) {
    if (line % 8 === 0) {
      const at = BITMAP_BYTES + attrAddress(r.x, line);
      runs.push({ offset: at, length: r.w, attr: true });
    }
    let offset = pixelAddress(r.x, line);
    let length = r.w;
    while (length > 0 && !screen[offset]) {
      offset++;
      length--;
    }
    while (length > 0 && !screen[offset + length - 1]) {
      length--;
    }
    if (length > 0) {
      runs.push({ offset, length, attr: false });
    }
  }
  return runs;
}

// Every run of a whole pattern, each tagged with the rectangle it belongs to
// and the bit it starts at, so a point in time maps back to both a rectangle
// and a part-loaded run.
function patternRuns(screen, regions) {
  const runs = [];
  let at = 0;
  for (let i = 0; i < regions.length; i++) {
    const own = regionRuns(screen, regions[i]);
    for (let k = 0; k < own.length; k++) {
      const bits = HEADER_BITS + own[k].length * 8;
      runs.push({ region: i, offset: own[k].offset, length: own[k].length,
                  attr: own[k].attr, bits, at });
      at += bits;
    }
  }
  return runs;
}

// The bits a whole pattern takes, including the sentinel that ends the screen.
function totalBits(runs) {
  let bits = END_BITS;
  for (const run of runs) {
    bits += run.bits;
  }
  return bits;
}

function seconds(bits) {
  return bits * BIT_TSTATES / CPU_HZ;
}

// Which bytes have arrived once `bits` of the pattern have played: whole runs
// for everything finished, and byte by byte through the run in progress, so
// the preview reveals a long run the way the loader really does rather than
// snapping it into place at the end.
function loadedAt(runs, bits) {
  const loaded = new Uint8Array(SCREEN_BYTES);
  for (const run of runs) {
    if (run.at >= bits) {
      break;
    }
    const through = Math.floor(Math.max(0, bits - run.at - HEADER_BITS) / 8);
    const count = Math.min(run.length, through);
    for (let i = 0; i < count; i++) {
      loaded[run.offset + i] = 1;
    }
  }
  return loaded;
}

// What a pattern does and does not do to the picture. `missed` counts cells
// with ink in them that no rectangle ever sends -- content that will simply
// not be there when loading finishes -- `blank` the covered cells with nothing
// in them, and `repeated` the bytes one rectangle sends after another already
// sent them, which is time spent drawing the same thing twice.
function coverage(screen, regions) {
  const sent = new Uint8Array(SCREEN_BYTES);
  let repeated = 0;
  for (const region of regions) {
    for (const run of regionRuns(screen, region)) {
      for (let i = 0; i < run.length; i++) {
        if (sent[run.offset + i]) {
          repeated++;
        }
        sent[run.offset + i] = 1;
      }
    }
  }

  const covered = new Uint8Array(COLUMNS * ROWS);
  for (const region of regions) {
    const r = clampRegion(region);
    for (let row = r.y; row < r.y + r.h; row++) {
      for (let col = r.x; col < r.x + r.w; col++) {
        covered[row * COLUMNS + col] = 1;
      }
    }
  }

  let missed = 0;
  let blank = 0;
  for (let row = 0; row < ROWS; row++) {
    for (let col = 0; col < COLUMNS; col++) {
      const ink = cellHasInk(screen, col, row);
      if (!covered[row * COLUMNS + col]) {
        if (ink) {
          missed++;
        }
      } else if (!ink) {
        blank++;
      }
    }
  }
  return { sent, covered, missed, blank, repeated };
}

// --- the rest of the tape ----------------------------------------------------

// What the loader needs of memory while it runs -- loader.py's constants of
// the same names, which its builder checks against the assembler's symbols.
// The loader is 433 bytes wherever it is put. Its stack is BASIC's, where the
// loader's CLEAR left it: $5F41 by default, just above the BASIC, or wherever
// the tape's `stack` says. SP sits $17 below the CLEAR address while the loader
// runs (and the program is entered with it there), and LD_BITS -> DELAY_CALL
// nest two calls below that, so the four bytes under SP are live throughout.
// Above SP is BASIC's own return path, which matters only if a load fails and
// goes back -- as does the BASIC loader itself.
const LOADER_SIZE = 0x1B1;
const LOADER_DEFAULT = 0xFFFF - LOADER_SIZE;
const STACK_DEFAULT = 0x5F41;
const STACK_SP = 0x17;
const STACK_DEPTH = 4;
const BASIC_LOADER = [0x5C00, 0x5EC1];

// The loader's live stack and BASIC's return path above it, as [start, end)
// spans, for a CLEAR address -- loader.py's stack_spans.
function stackSpans(stack) {
  const sp = stack - STACK_SP;
  return { live: [sp - STACK_DEPTH, sp], basic: [sp, stack + 1] };
}

const LIVE_STACK = stackSpans(STACK_DEFAULT).live;
const BASIC_STACK = stackSpans(STACK_DEFAULT).basic;
const SCREEN_MEMORY = [0x4000, 0x5B00];

// What fast_leader(), mem_header() and end_blocks() put round the screen and
// the data: a 1024-pulse leader and two sync pulses, 32 bits of header a block,
// and a 32-bit end marker followed by a tail of 32 more bit-length pulses.
const LEADER_PULSES = 1024;
const LEADER_TSTATES = 2168;
const SYNC_TSTATES = 600;
const BLOCK_HEADER_BITS = 32;
const TAIL_PULSES = 32;

// An address as a design writes it -- "$7000", "#7000", "0x7000", "28672" or a
// plain number. null for nothing at all, NaN for something that isn't one.
function parseAddress(value) {
  if (value === null || value === undefined) {
    return null;
  }
  let number = NaN;
  if (typeof value === 'number') {
    number = value;
  } else if (typeof value === 'string') {
    const text = value.trim();
    if (text === '') {
      return null;
    }
    if (/^[$#][0-9a-f]+$/i.test(text)) {
      number = parseInt(text.slice(1), 16);
    } else if (/^0x[0-9a-f]+$/i.test(text)) {
      number = parseInt(text.slice(2), 16);
    } else if (/^[0-9]+$/.test(text)) {
      number = parseInt(text, 10);
    }
  }
  return Number.isInteger(number) && number >= 0 && number <= 0xFFFF ? number : NaN;
}

function formatAddress(value) {
  return '$' + value.toString(16).toUpperCase().padStart(4, '0');
}

// --- the two files a tape is designed in -------------------------------------
//
// A tape is a `*.tape.json`: which loading scheme it is for, what it loads and
// where, and where it jumps. Its loading screen is a `*.screen.json` of its own
// -- the picture and the order its rectangles are sent in -- because it is a
// different thing, edited in a different editor with its own undo. Paths are
// relative to the file that names them, so a project stays movable, and
// everything is a reference rather than a copy: rebuild the artwork or the
// code and the design picks up the new bytes.

// The loading schemes a tape can be built for. Each says what it can do --
// whether a screen can be revealed in a designed order, whether the loader has
// an address of its own -- and has its own checks (checkTape), costs and
// builder (scripts/build_tape.py).
const SCHEMES = {
  'zx-tape-loader': {
    title: 'zx-tape-loader (fast)',
    description: 'The fast loader in examples/zx-tape-loader: its own denser encoding, a countdown while ' +
                 'it loads, and the screen revealed in a designed order.',
    screenOrder: true,
    loaderAddress: true
  },
  rom: {
    title: 'Standard ROM loader',
    description: 'The Spectrum\'s own LOAD "": a BASIC loader, the screen with LOAD ""SCREEN$ and each ' +
                 'block with LOAD ""CODE, at normal speed, as a .tap any emulator reads.',
    screenOrder: false,
    loaderAddress: false
  }
};
const DEFAULT_SCHEME = 'zx-tape-loader';

function emptyTape() {
  return { meta: { version: 1 }, scheme: DEFAULT_SCHEME, loaderAddress: null, stack: null, loadingScreen: null,
           blocks: [], entry: null, output: null };
}

function emptyScreen() {
  return { meta: { version: 1 }, picture: '', order: [] };
}

function readJson(text, what) {
  try {
    const raw = JSON.parse(text);
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      return { raw, problem: null };
    }
    return { raw: null, problem: what + ' is a JSON object.' };
  } catch (err) {
    return { raw: null, problem: 'This is not JSON: ' + err.message };
  }
}

// A `*.tape.json`. Blocks are keyed by name, in tape order: the name is the
// block's identity, so it is the key rather than a field of it.
function parseTape(text) {
  const problems = [];
  const tape = emptyTape();
  const { raw, problem } = readJson(text, 'A tape');
  if (!raw) {
    return { tape, problems: [problem] };
  }
  const address = (value, what) => {
    const parsed = parseAddress(value);
    if (Number.isNaN(parsed)) {
      problems.push(what + ' ' + JSON.stringify(value) + ' is not an address.');
      return null;
    }
    return parsed;
  };
  if (raw.meta && typeof raw.meta === 'object') {
    tape.meta = raw.meta;
  }
  if (raw.scheme !== undefined) {
    if (SCHEMES[raw.scheme]) {
      tape.scheme = raw.scheme;
    } else {
      problems.push('"' + raw.scheme + '" is not a loading scheme this knows: ' +
                    Object.keys(SCHEMES).join(', ') + '.');
    }
  }
  tape.loaderAddress = address(raw.loaderAddress, 'The loader address');
  tape.entry = address(raw.entry, 'The entry address');
  tape.stack = address(raw.stack, 'The stack address');
  if (typeof raw.loadingScreen === 'string' && raw.loadingScreen) {
    tape.loadingScreen = raw.loadingScreen;
  }
  if (typeof raw.output === 'string' && raw.output) {
    tape.output = raw.output;
  }
  if (raw.blocks && typeof raw.blocks === 'object' && !Array.isArray(raw.blocks)) {
    for (const name of Object.keys(raw.blocks)) {
      const block = raw.blocks[name];
      if (!block || typeof block !== 'object' || typeof block.file !== 'string') {
        problems.push('Block "' + name + '" needs a "file".');
        continue;
      }
      tape.blocks.push({
        name,
        file: block.file,
        address: address(block.address, 'Block "' + name + '"\'s address'),
        offset: Number.isInteger(block.offset) && block.offset >= 0 ? block.offset : 0,
        length: Number.isInteger(block.length) && block.length > 0 ? block.length : null
      });
    }
  } else if (raw.blocks !== undefined) {
    problems.push('"blocks" is an object of blocks keyed by name.');
  }
  return { tape, problems };
}

function addressText(value) {
  return value === null || value === undefined || Number.isNaN(value) ? 'null' : JSON.stringify(formatAddress(value));
}

// One block per line, in tape order: a diff should read as the tape changing.
function serializeTape(tape) {
  const lines = ['{', '  "meta": ' + JSON.stringify(tape.meta || { version: 1 }) + ',',
                 '  "scheme": ' + JSON.stringify(tape.scheme || DEFAULT_SCHEME) + ','];
  if (SCHEMES[tape.scheme] && SCHEMES[tape.scheme].loaderAddress) {
    lines.push('  "loaderAddress": ' + addressText(tape.loaderAddress) + ',');
  }
  lines.push('  "loadingScreen": ' + (tape.loadingScreen ? JSON.stringify(tape.loadingScreen) : 'null') + ',');
  const blocks = tape.blocks.map((block) => {
    let text = '    ' + JSON.stringify(block.name) + ': { "file": ' + JSON.stringify(block.file) +
               ', "address": ' + addressText(block.address);
    if (block.offset) {
      text += ', "offset": ' + block.offset;
    }
    if (block.length) {
      text += ', "length": ' + block.length;
    }
    return text + ' }';
  });
  lines.push('  "blocks": {' + (blocks.length ? '\n' + blocks.join(',\n') + '\n  }' : '}') + ',');
  lines.push('  "entry": ' + addressText(tape.entry) + ',');
  lines.push('  "stack": ' + addressText(tape.stack) + (tape.output ? ',' : ''));
  if (tape.output) {
    lines.push('  "output": ' + JSON.stringify(tape.output));
  }
  lines.push('}');
  return lines.join('\n') + '\n';
}

// A `*.screen.json`: the picture, and the order its rectangles are sent in.
function parseScreen(text) {
  const problems = [];
  const screen = emptyScreen();
  const { raw, problem } = readJson(text, 'A loading screen');
  if (!raw) {
    return { screen, problems: [problem] };
  }
  if (raw.meta && typeof raw.meta === 'object') {
    screen.meta = raw.meta;
  }
  if (typeof raw.picture === 'string') {
    screen.picture = raw.picture;
  } else {
    problems.push('"picture" names the .scr, .sna, .z80, .tap or .tzx the screen comes from.');
  }
  if (Array.isArray(raw.order)) {
    for (const region of raw.order) {
      if (!region || typeof region !== 'object' ||
          !['x', 'y', 'w', 'h'].every((key) => typeof region[key] === 'number')) {
        problems.push('A rectangle needs a numeric x, y, w and h, in character cells.');
        continue;
      }
      const clamped = clampRegion(region);
      if (!sameRegion(clamped, region)) {
        problems.push('The rectangle ' + region.x + ',' + region.y + ' ' + region.w + 'x' + region.h +
                      ' does not fit the screen, and has been brought inside it.');
      }
      screen.order.push(clamped);
    }
  } else if (raw.order !== undefined) {
    problems.push('"order" is a list of {x, y, w, h} rectangles.');
  }
  return { screen, problems };
}

// One rectangle per line, because the order is the point.
function serializeScreen(screen) {
  const order = screen.order.map((region) => {
    const r = clampRegion(region);
    return '    { "x": ' + r.x + ', "y": ' + r.y + ', "w": ' + r.w + ', "h": ' + r.h + ' }';
  });
  return '{\n' +
    '  "meta": ' + JSON.stringify(screen.meta || { version: 1 }) + ',\n' +
    '  "picture": ' + JSON.stringify(screen.picture || '') + ',\n' +
    '  "order": [' + (order.length ? '\n' + order.join(',\n') + '\n  ]' : ']') + '\n' +
    '}\n';
}

// --- the standard ROM loader's tape ------------------------------------------
//
// scripts/tape_rom.py's, byte for byte: tests/tape_model_test.js compares the
// two. A BASIC program autostarting at line 10 --
//   CLEAR stack: POKE 23739,111: LOAD ""SCREEN$: LOAD ""CODE ...: RANDOMIZE USR entry
// -- then the screen, then each block as CODE at its own address. POKE
// 23739,111 points the print channel at a RET, so the ROM's "Bytes:" messages
// don't print over the picture as each block is found. The CLEAR is the tape's
// `stack`, or just below the lowest block when it has none.

const PROG = 0x5CCB;                 // where a 48K's BASIC program starts, with no microdrive
const ROM_HEADROOM = 0x100;          // room above it for the variables, workspace and machine stack
// How far below the CLEAR a block must keep clear of the ROM's stack: loading
// goes $11 below it and USR enters the program $17 below it (both measured on
// the emulator), and BASIC takes interrupts between loads. tape_rom.ROM_STACK.
const ROM_STACK = 0x40;
const TOKEN = { CLEAR: 0xFD, POKE: 0xF4, LOAD: 0xEF, SCREEN: 0xAA, CODE: 0xAF, RANDOMIZE: 0xF9, USR: 0xC0 };

function basicNumber(value) {
  const digits = Array.from(String(value)).map((c) => c.charCodeAt(0));
  return digits.concat([0x0E, 0x00, 0x00, value & 0xFF, (value >> 8) & 0xFF, 0x00]);
}

// The ROM loader's CLEAR: the tape's stack, or just below the lowest block, or
// null for no CLEAR at all -- tape_rom.clear_address.
function romClear(tape, lengths) {
  if (tape.stack !== null && tape.stack !== undefined && !Number.isNaN(tape.stack)) {
    return tape.stack;
  }
  const addresses = tape.blocks.map((b, i) => (lengths[i] ? b.address : null))
    .filter((a) => a !== null && !Number.isNaN(a));
  return addresses.length ? Math.min.apply(null, addresses) - 1 : null;
}

// The loader program's bytes, for the addresses given. `hasScreen` adds the
// LOAD ""SCREEN$.
function romLoaderProgram(tape, lengths, hasScreen) {
  const body = [];
  const statement = (bytes) => {
    if (body.length) {
      body.push(0x3A);
    }
    body.push(...bytes);
  };
  const clear = romClear(tape, lengths);
  if (clear !== null) {
    statement([TOKEN.CLEAR].concat(basicNumber(clear)));
  }
  statement([TOKEN.POKE].concat(basicNumber(23739), [0x2C], basicNumber(111)));
  if (hasScreen) {
    statement([TOKEN.LOAD, 0x22, 0x22, TOKEN.SCREEN]);
  }
  for (let i = 0; i < tape.blocks.length; i++) {
    statement([TOKEN.LOAD, 0x22, 0x22, TOKEN.CODE]);
  }
  if (tape.entry !== null && !Number.isNaN(tape.entry)) {
    statement([TOKEN.RANDOMIZE, TOKEN.USR].concat(basicNumber(tape.entry)));
  }
  body.push(0x0D);
  return [0x00, 10, body.length & 0xFF, body.length >> 8].concat(body);
}

function tapName(name) {
  const ascii = Array.from(String(name)).map((c) => (c.charCodeAt(0) < 128 ? c.charCodeAt(0) : 0x3F));
  return ascii.slice(0, 10).concat(Array(Math.max(0, 10 - ascii.length)).fill(0x20));
}

function tapBlock(flag, payload) {
  let check = flag;
  for (const byte of payload) {
    check ^= byte;
  }
  const length = payload.length + 2;
  return [length & 0xFF, length >> 8, flag].concat(Array.from(payload), [check]);
}

function codeHeader(name, length, address) {
  return [3].concat(tapName(name), [length & 0xFF, length >> 8, address & 0xFF, address >> 8, 0x00, 0x80]);
}

// The whole .tap. `picture` is the 6912-byte screen or null; `data[i]` block
// i's bytes.
function romTap(tape, picture, data, programName) {
  const lengths = data.map((d) => (d ? d.length : null));
  const program = romLoaderProgram(tape, lengths, !!picture);
  const out = [];
  out.push(...tapBlock(0x00, [0].concat(tapName(programName), [program.length & 0xFF, program.length >> 8,
                                                                10, 0, program.length & 0xFF, program.length >> 8])));
  out.push(...tapBlock(0xFF, program));
  if (picture) {
    out.push(...tapBlock(0x00, codeHeader('screen', SCREEN_BYTES, 16384)));
    out.push(...tapBlock(0xFF, picture));
  }
  tape.blocks.forEach((block, i) => {
    if (data[i]) {
      out.push(...tapBlock(0x00, codeHeader(block.name, data[i].length, block.address)));
      out.push(...tapBlock(0xFF, data[i]));
    }
  });
  return Uint8Array.from(out);
}

// --- what the whole tape costs ---------------------------------------------

function blockBits(length) {
  return BLOCK_HEADER_BITS + 8 * length;
}

// The fast part of a zx-tape-loader tape, from the start of the leader to the
// end of the tail: `screenBits` is totalBits() of the screen's runs (which
// already counts the end-of-screen marker), or END_BITS with no screen.
function fastSeconds(screenBits, blockLengths) {
  let bits = screenBits + BLOCK_HEADER_BITS;
  for (const length of blockLengths) {
    bits += blockBits(length || 0);
  }
  const tstates = LEADER_PULSES * LEADER_TSTATES + 2 * SYNC_TSTATES +
                  (bits + TAIL_PULSES) * BIT_TSTATES;
  return tstates / CPU_HZ;
}

// A tape at the ROM's own speed, from its .tap bytes: std_block()'s leader,
// sync and bits (a 1 is 1710+1718 T-states, a 0 855+855), with
// encode_tap_file()'s second of silence between blocks. zx-tape-loader's
// BASIC bootstrap, and the whole of a standard ROM tape.
function romTapeSeconds(tap) {
  let tstates = 0;
  let at = 0;
  let first = true;
  while (at + 2 <= tap.length) {
    const length = tap[at] | (tap[at + 1] << 8);
    const block = tap.subarray ? tap.subarray(at + 2, at + 2 + length) : tap.slice(at + 2, at + 2 + length);
    if (!first) {
      tstates += 1000000;
    }
    first = false;
    tstates += (block[0] ? 3184 : 4096) * 2168 + 667 + 735;
    for (const byte of block) {
      for (let bit = 7; bit >= 0; bit--) {
        tstates += (byte >> bit) & 1 ? 1710 + 1718 : 1710;
      }
    }
    at += 2 + length;
  }
  return tstates / CPU_HZ;
}

// --- whether it can load ---------------------------------------------------

function overlaps(aStart, aEnd, bStart, bEnd) {
  return aStart < bEnd && bStart < aEnd;
}

function blockLabel(block, start, end) {
  // Not wrapped at $FFFF: a block that runs off the end says how far.
  return 'block "' + block.name + '" (' + formatAddress(start) + '-' + formatAddress(end - 1) + ')';
}

// What every scheme checks of a block, and of the entry: the parts of
// check_design (zx-tape-loader) and tape_rom.check (rom) they share, word for
// word. `vital` is the scheme's own list of what a block must not land on.
function checkBlocks(tape, lengths, hasScreen, vital, errors, warnings) {
  tape.blocks.forEach((block, i) => {
    const length = lengths[i];
    if (block.address === null || Number.isNaN(block.address)) {
      errors.push('block "' + block.name + '" has no address to load at');
      return;
    }
    if (length === null || length === undefined) {
      errors.push('block "' + block.name + '"\'s file can\'t be read');
      return;
    }
    const start = block.address;
    const end = start + length;
    const name = blockLabel(block, start, end);
    if (!length) {
      errors.push(name + ' is empty');
      return;
    }
    if (start < 0x4000) {
      errors.push(name + ' starts in the ROM');
    }
    if (end > 0x10000) {
      errors.push(name + ' runs past $FFFF');
    }
    vital(block, start, end, name);
    if (hasScreen && overlaps(start, end, SCREEN_MEMORY[0], SCREEN_MEMORY[1])) {
      warnings.push(name + ' loads over the loading screen');
    }
    for (let j = 0; j < i; j++) {
      const other = tape.blocks[j];
      if (other.address !== null && !Number.isNaN(other.address) && lengths[j] &&
          overlaps(start, end, other.address, other.address + lengths[j])) {
        warnings.push(name + ' loads over part of block "' + other.name + '"');
      }
    }
  });
  if (tape.entry === null || tape.entry === undefined || Number.isNaN(tape.entry)) {
    errors.push('there is no entry address to jump to once the tape has loaded');
  } else if (!tape.blocks.some((block, i) => lengths[i] && block.address !== null &&
                               block.address <= tape.entry && tape.entry < block.address + lengths[i])) {
    warnings.push('the entry address ' + formatAddress(tape.entry) + ' is not in any block this tape loads');
  }
}

function loaderAt(tape) {
  return tape.loaderAddress === null || tape.loaderAddress === undefined ? LOADER_DEFAULT : tape.loaderAddress;
}

// The fast loader's CLEAR address.
function stackAt(tape) {
  return tape.stack === null || tape.stack === undefined || Number.isNaN(tape.stack) ? STACK_DEFAULT : tape.stack;
}

// The first address a standard ROM tape's blocks can load at: above the BASIC
// loader, its variables and the stack CLEAR puts below the lowest block.
function romLowest(tape, lengths, hasScreen) {
  return PROG + romLoaderProgram(tape, lengths, hasScreen).length + ROM_HEADROOM;
}

// What would stop the tape loading, and what is only worth knowing, for its
// scheme. `lengths[i]` is block i's byte count, or null when its file can't
// be read; `hasScreen` whether it has a loading screen.
function checkTape(tape, lengths, hasScreen) {
  const errors = [];
  const warnings = [];
  if (tape.scheme === 'rom') {
    const lowest = romLowest(tape, lengths, hasScreen);
    let stack = tape.stack === undefined || Number.isNaN(tape.stack) ? null : tape.stack;
    if (stack !== null && stack < lowest - 1) {
      errors.push('the stack at ' + formatAddress(stack) + ' must be at ' + formatAddress(lowest - 1) +
                  ' or above: any lower and CLEAR would put it in the BASIC loader\'s own workspace');
      stack = null;
    }
    checkBlocks(tape, lengths, hasScreen, (block, start, end, name) => {
      if (start >= 0x4000 && start < lowest) {
        errors.push(name + ' starts below ' + formatAddress(lowest) + ', which the BASIC loader and ' +
                    'its stack need');
      } else if (stack !== null && overlaps(start, end, stack - ROM_STACK, stack + 1)) {
        errors.push(name + ' would load over the stack (' + formatAddress(stack - ROM_STACK) + '-' +
                    formatAddress(stack) + ')');
      }
    }, errors, warnings);
    return { errors, warnings };
  }
  const at = loaderAt(tape);
  const stack = stackAt(tape);
  const spans = stackSpans(stack);
  if (at < 0x8000 || at + LOADER_SIZE > 0x10000) {
    errors.push('the loader at ' + formatAddress(at) + ' must fit in $8000-$FFFF: below $8000 ' +
                'the ULA\'s contention would stretch its cycle-counted bit loop');
  }
  if (stack < STACK_DEFAULT) {
    errors.push('the stack at ' + formatAddress(stack) + ' must be at ' + formatAddress(STACK_DEFAULT) +
                ' or above: any lower and CLEAR would put it in the BASIC loader\'s own workspace');
  } else if (overlaps(spans.live[0], spans.basic[1], at, at + LOADER_SIZE)) {
    errors.push('the stack at ' + formatAddress(stack) + ' (' + formatAddress(spans.live[0]) + '-' +
                formatAddress(spans.basic[1] - 1) + ') runs into the loader (' + formatAddress(at) + '-' +
                formatAddress(at + LOADER_SIZE - 1) + ')');
  }
  checkBlocks(tape, lengths, hasScreen, (block, start, end, name) => {
    if (overlaps(start, end, at, at + LOADER_SIZE)) {
      errors.push(name + ' would load over the loader itself (' + formatAddress(at) + '-' +
                  formatAddress(at + LOADER_SIZE - 1) + ')');
    }
    if (overlaps(start, end, spans.live[0], spans.live[1])) {
      errors.push(name + ' would load over the loader\'s stack (' + formatAddress(spans.live[0]) + '-' +
                  formatAddress(spans.live[1] - 1) + ')');
    } else if (overlaps(start, end, spans.basic[0], spans.basic[1])) {
      warnings.push(name + ' loads over BASIC\'s stack, so a failed load can\'t return to BASIC');
    } else if (overlaps(start, end, BASIC_LOADER[0], BASIC_LOADER[1])) {
      warnings.push(name + ' loads over the BASIC loader, so a failed load can\'t return to BASIC');
    }
  }, errors, warnings);
  return { errors, warnings };
}

// The 64K as the tape leaves it, for drawing: fixed things first, then the
// blocks in tape order, each [start, end) with what it is.
function memoryMap(tape, lengths, hasScreen) {
  const spans = [
    { start: 0, end: 0x4000, kind: 'rom', label: 'ROM' },
    { start: SCREEN_MEMORY[0], end: SCREEN_MEMORY[1], kind: 'screen', label: 'screen' }
  ];
  if (tape.scheme === 'rom') {
    const lowest = romLowest(tape, lengths, hasScreen);
    spans.push({ start: 0x5C00, end: lowest, kind: 'stack', label: 'BASIC loader and stack' });
    if (tape.stack !== null && tape.stack !== undefined && !Number.isNaN(tape.stack) && tape.stack >= lowest) {
      spans.push({ start: tape.stack - ROM_STACK, end: tape.stack + 1, kind: 'stack', label: 'stack' });
    }
  } else {
    const at = loaderAt(tape);
    const stack = stackSpans(stackAt(tape));
    spans.push({ start: stack.live[0], end: stack.basic[1], kind: 'stack', label: 'stack' });
    spans.push({ start: at, end: at + LOADER_SIZE, kind: 'loader', label: 'loader' });
  }
  tape.blocks.forEach((block, i) => {
    if (lengths[i] && block.address !== null && !Number.isNaN(block.address)) {
      spans.push({ start: block.address, end: Math.min(0x10000, block.address + lengths[i]),
                   kind: 'block', label: block.name, index: i });
    }
  });
  return spans;
}

// --- reading a standard tape for its parts ---------------------------------

// loader.py's find_usr_address: the n in a BASIC program's USR n, from ZX
// BASIC's number encoding -- the digits, $0E, then a 5-byte value whose
// small-integer form is 0, sign, low, high, 0.
function findUsrAddress(basic) {
  for (let i = 0; i < basic.length; i++) {
    if (basic[i] !== 0xC0) {
      continue;
    }
    let marker = i + 1;
    while (marker < basic.length && basic[marker] >= 0x30 && basic[marker] <= 0x39) {
      marker++;
    }
    if (marker + 5 < basic.length && basic[marker] === 0x0E && basic[marker + 1] === 0x00) {
      return basic[marker + 3] | (basic[marker + 4] << 8);
    }
  }
  return null;
}

// A name for a block, unique among `taken`: the tape's own file name where it
// has a usable one, and a number after it where two are alike.
function uniqueName(wanted, taken) {
  const base = String(wanted || '').trim() || 'block';
  let name = base;
  for (let n = 2; taken.includes(name); n++) {
    name = base + ' ' + n;
  }
  return name;
}

// What a standard tape carries, for importing into a design: its CODE files
// as named blocks (the loading screen apart), and the entry address its BASIC
// loader's USR gives. `blocks` are the tape's data blocks in order, each
// { flag, data, offset } -- data without the flag and checksum, offset where
// that data starts in the file, which is what a design's block points at.
function tapeContents(blocks, taken) {
  const names = (taken || []).slice();
  const code = [];
  let entry = null;
  let screen = false;
  for (let i = 0; i + 1 < blocks.length; i++) {
    const header = blocks[i];
    if (header.flag !== 0 || header.data.length !== 17) {
      continue;
    }
    const body = blocks[i + 1];
    const type = header.data[0];
    const length = header.data[11] | (header.data[12] << 8);
    const param = header.data[13] | (header.data[14] << 8);
    if (type === 0 && entry === null) {
      entry = findUsrAddress(body.data);
    } else if (type === 3) {
      if (param === 16384 && length === SCREEN_BYTES) {
        screen = true;
      } else {
        const name = uniqueName(String.fromCharCode.apply(null, Array.from(header.data.slice(1, 11))), names);
        names.push(name);
        code.push({ name, address: param, length: Math.min(length, body.data.length), offset: body.offset });
      }
    }
    i++;
  }
  return { code, entry, screen };
}

// The same order as gen_block() calls, for pasting into a bespoke build script
// like zx-tape-loader's build_lunarjetman_tape.py, which spells its screen out
// by hand rather than reading a screen file.
function pythonFor(regions) {
  return regions
    .map((region) => {
      const r = clampRegion(region);
      return 'gen_block(gen, data, ' + r.x + ', ' + r.y + ', ' + r.w + ', ' + r.h + ')';
    })
    .join('\n');
}

if (typeof module !== 'undefined') {
  module.exports = {
    BITMAP_BYTES, ATTR_BYTES, SCREEN_BYTES, COLUMNS, ROWS,
    HEADER_BITS, BIT_TSTATES, CPU_HZ, END_BITS,
    pixelAddress, attrAddress, clampRegion, sameRegion, cellHasInk,
    autoRegions, regionRuns, patternRuns, totalBits, seconds, loadedAt, coverage, pythonFor,
    LOADER_SIZE, LOADER_DEFAULT, LIVE_STACK, BASIC_STACK, SCREEN_MEMORY,
    STACK_DEFAULT, STACK_SP, STACK_DEPTH, BASIC_LOADER, ROM_STACK, stackSpans, stackAt, romClear,
    LEADER_PULSES, BLOCK_HEADER_BITS, TAIL_PULSES, PROG, ROM_HEADROOM,
    SCHEMES, DEFAULT_SCHEME,
    parseAddress, formatAddress, emptyTape, emptyScreen, parseTape, serializeTape, parseScreen, serializeScreen,
    romLoaderProgram, romTap, romLowest, tapBlock, codeHeader,
    blockBits, fastSeconds, romTapeSeconds, checkTape, memoryMap, loaderAt,
    findUsrAddress, uniqueName, tapeContents
  };
}
