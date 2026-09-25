// What the tape designer's two editors share: reading a picture, resolving the
// paths a design names, assembling their pages, and finding what builds a tape.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const model = require('./tape_model');
const info = require('./program_info');

// What a loading screen can come from: a raw screen dump, or anything the
// program editor already knows how to find a loading screen inside.
const PICTURES = ['.scr', '.tap', '.tzx', '.sna', '.z80'];

// A .scr with no attributes is only the bitmap. The ROM's own cleared screen
// is black on white, so that is what the missing half becomes -- as
// scripts/tape_screen.py's screen_from_file does too, so the tape carries what
// the designer showed.
const DEFAULT_ATTR = 0x38;

function fileExists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch (err) {
    return false;
  }
}

function readScreen(filePath) {
  let bytes;
  try {
    bytes = fs.readFileSync(filePath);
  } catch (err) {
    return { screen: null, problem: path.basename(filePath) + ' could not be read: ' + err.message };
  }
  const name = path.basename(filePath);
  if (/\.scr$/i.test(name)) {
    if (bytes.length < model.BITMAP_BYTES) {
      return { screen: null, problem: name + ' is too short to be a screen (' + bytes.length + ' bytes).' };
    }
    const screen = Buffer.alloc(model.SCREEN_BYTES, DEFAULT_ATTR);
    bytes.copy(screen, 0, 0, Math.min(bytes.length, model.SCREEN_BYTES));
    return { screen, problem: null };
  }
  const found = info.programScreen(name, bytes);
  if (!found) {
    return { screen: null, problem: 'No loading screen was found in ' + name + '.' };
  }
  return { screen: Buffer.from(found.screen), problem: null };
}

// Paths in a design are relative to the file that names them, so a project
// stays movable.
function resolve(fromUri, file) {
  if (!file) {
    return '';
  }
  return path.isAbsolute(file) ? file : path.resolve(path.dirname(fromUri.fsPath), file);
}

function relativeTo(fromPath, file) {
  const relative = path.relative(path.dirname(fromPath), file);
  // One on another drive has no relative form at all.
  if (!relative || path.isAbsolute(relative)) {
    return file;
  }
  return relative.split(path.sep).join('/');
}

async function pickPicture(title) {
  const picked = await vscode.window.showOpenDialog({
    title,
    openLabel: 'Use this picture',
    canSelectMany: false,
    filters: { 'Spectrum screens': PICTURES.map((ext) => ext.slice(1)) }
  });
  return picked && picked.length ? picked[0].fsPath : null;
}

// A page with its CSP and the model inlined: the same shape extension.js gives
// its viewer pages -- one inline <style>, one inline <script>, and a nonce on
// the script.
function pageHtml(file) {
  const source = fs.readFileSync(path.join(__dirname, 'tape_model.js'), 'utf8');
  const nonce = crypto.randomBytes(16).toString('hex');
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
              'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; ' +
              'font-src data:; img-src data:;">';
  return fs.readFileSync(path.join(__dirname, file), 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">')
    .replace('/*@tape_model.js@*/', () => source);
}

// --- what builds a tape ------------------------------------------------------

function setting(name) {
  return vscode.workspace.getConfiguration('zxspectrum.tapeDesigner').get(name) || '';
}

// scripts/build_tape.py: the setting, or the one in the repository this
// extension is part of -- it is installed as a link to vscode-extension/, so
// the scripts are beside it -- or one in a workspace folder, or the copy a
// release carries in its own builder/ folder, with the fast loader beside it.
function findBuilder() {
  const set = setting('builder');
  if (set) {
    return fileExists(set) ? set : null;
  }
  const candidates = [path.join(__dirname, '..', 'scripts', 'build_tape.py')];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    candidates.push(path.join(folder.uri.fsPath, 'scripts', 'build_tape.py'));
  }
  candidates.push(path.join(__dirname, 'builder', 'build_tape.py'));
  return candidates.find(fileExists) || null;
}

// The Python it runs with: the setting, else the repository's own virtual
// environment -- .venv-win on Windows in this repo, .venv elsewhere -- which is
// where numpy is, else whatever `python` is on the PATH.
function findPython(builder) {
  const set = setting('python');
  if (set) {
    return set;
  }
  const inVenv = process.platform === 'win32' ? ['Scripts', 'python.exe'] : ['bin', 'python'];
  const roots = [path.dirname(path.dirname(builder || ''))];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    roots.push(folder.uri.fsPath);
  }
  for (const root of roots) {
    for (const venv of ['.venv-win', '.venv', 'venv']) {
      const guess = path.join(root, venv, ...inVenv);
      if (fileExists(guess)) {
        return guess;
      }
    }
  }
  return 'python';
}

// sjasmplus, which the zx-tape-loader scheme needs only to move its loader:
// the setting, or tools/sjasmplus beside the builder in a checkout -- or
// null, for the caller to ask zxspectrum.sjasmplusPath, which finds one on
// the PATH or fetches one.
function findSjasmplus(builder) {
  const set = setting('sjasmplus');
  if (set) {
    return set;
  }
  const exe = process.platform === 'win32' ? 'sjasmplus.exe' : 'sjasmplus';
  const guess = path.join(path.dirname(path.dirname(builder || '')), 'tools', 'sjasmplus', exe);
  return fileExists(guess) ? guess : null;
}

// zx-tape-loader's own loader.tap, for timing its BASIC bootstrap.
function fastLoaderTap(builder) {
  // The submodule in a checkout, or the copy beside a release's builder.
  const taps = [
    path.join(path.dirname(path.dirname(builder || '')), 'examples', 'zx-tape-loader', 'loader.tap'),
    path.join(path.dirname(builder || ''), 'zx-tape-loader', 'loader.tap'),
  ];
  const tap = taps.find(fileExists) || taps[0];
  try {
    return fs.readFileSync(tap);
  } catch (err) {
    return null;
  }
}

module.exports = {
  PICTURES, fileExists, readScreen, resolve, relativeTo, pickPicture, pageHtml,
  findBuilder, findPython, findSjasmplus, fastLoaderTap
};
