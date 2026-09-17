// What a snapshot or tape file is, read from its header: which Spectrum it
// needs, and what a tape holds. No vscode API, so it is tested from plain
// Node (node tests/program_info_test.js); program_view.js shows it.

'use strict';

const SNA_48K = 49179;
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

// A .tap is length-prefixed blocks; a header block (flag 0, 19 bytes with its
// checksum) names the file that follows.
function describeTap(bytes) {
  const files = [];
  let blocks = 0;
  let at = 0;
  while (at + 2 <= bytes.length) {
    const length = word(bytes, at);
    const start = at + 2;
    if (length === 0 || start + length > bytes.length) {
      return { kind: 'unknown', problem: `The block at offset ${at} runs past the end of the file.` };
    }
    blocks++;
    if (length === 19 && bytes[start] === 0) {
      const type = bytes[start + 1];
      files.push((TAP_TYPES[type] || 'Type ' + type) + ': ' + headerName(bytes, start + 2));
    }
    at = start + length;
  }
  if (blocks === 0) {
    return { kind: 'unknown', problem: 'This tape holds no blocks.' };
  }
  return { kind: 'tape', format: '.tap', model: '48K', needs128: false,
           details: [blocks + ' block' + (blocks === 1 ? '' : 's')].concat(files) };
}

function describeTzx(bytes) {
  const signature = String.fromCharCode(...bytes.subarray(0, 7));
  if (signature !== 'ZXTape!' || bytes[7] !== 0x1A) {
    return { kind: 'unknown', problem: 'Not a TZX tape (no "ZXTape!" signature).' };
  }
  return { kind: 'tape', format: `.tzx version ${bytes[8]}.${String(bytes[9]).padStart(2, '0')}`,
           model: '48K', needs128: false, details: [] };
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
  return {
    sld: stem + '.sld',
    asm: ['.asm', '.s', '.a80'].map((ext) => stem + ext)
  };
}

module.exports = {
  looksLikeText, describeProgram, pickRom, launchConfigFor, debugInfoCandidates
};
