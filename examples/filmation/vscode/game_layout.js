// Where things are in a Filmation game's folder, for the editors' hosts.
//
// The twin of examples/filmation/scripts/layout.py, which has the whole
// picture. The part the editors care about: a game keeps its JSON in
// metadata/, its sprite sheet in art/, and what the build writes in
// generated/, with its hand-written .s and build.py at the top. A folder with
// no metadata/ in it is laid out flat, everything at the top -- that is how the
// room editor in game-disassemblies hands over a castle of its own (Alien 8's),
// so it has to keep working.
//
// Plain Node, no vscode API, so tests/game_layout_test.js can run it and the
// other tests can find the real files the way the hosts do.

'use strict';

const fs = require('fs');
const path = require('path');

const METADATA = 'metadata';
const ART = 'art';
const GENERATED = 'generated';

function isDir(dir) {
  try {
    return fs.statSync(dir).isDirectory();
  } catch (err) {
    return false;
  }
}

// The game's folder, from the directory one of its JSON files sits in: the
// folder above metadata/, or that directory itself when the game is flat. By
// the name alone, so that it holds for a file that is not saved yet.
function gameDirOf(here) {
  return path.basename(here).toLowerCase() === METADATA ? path.dirname(here) : here;
}

// Where a game's JSON is, from its folder.
function metadataOf(game) {
  const inside = path.join(game, METADATA);
  return isDir(inside) ? inside : game;
}

// ...its pictures...
function artOf(game) {
  const inside = path.join(game, ART);
  return isDir(inside) ? inside : game;
}

// ...and the .s its build writes, room_data.s among them.
function generatedOf(game) {
  const inside = path.join(game, GENERATED);
  return isDir(inside) ? inside : game;
}

// A path one of the game's files names, resolved the way the file means it --
// relative to its own directory -- and refused if it leaves the game's folder.
// rooms.json in metadata/ names its picture as ../art/sprites.png, which is
// still the game's; a path that climbs further, or an absolute one, is data
// pointing the editor at something elsewhere on the disk, and gets null. For a
// flat game the bound is the file's own directory, as it always was.
function within(here, name) {
  if (typeof name !== 'string' || !name) return null;
  const bound = gameDirOf(here);
  const full = path.resolve(here, name);
  const inside = path.relative(bound, full);
  if (!inside || inside.startsWith('..') || path.isAbsolute(inside)) return null;
  return full;
}

module.exports = { METADATA, ART, GENERATED, gameDirOf, metadataOf, artOf, generatedOf, within };
