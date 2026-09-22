// Which of a Filmation castle's templates the game's own code depends on.
//
// Plain Node, no vscode API, so tests/template_refs_test.js can run it against
// the real sources. templates_view.js asks it once per open panel.

'use strict';

const fs = require('fs');
const path = require('path');

// Sources the build writes. They define the template labels rather than use
// them, so they are no evidence that the game's own code depends on one.
const GENERATED = new Set(['room_data.s', 'sprite_data.s', 'sprite_table.s',
                           'sprite_adj_gen.s', 'graphics_gen.s', 'font.s',
                           'specials_gen.s']);

// The template labels a game's rooms_source.py writes: BG_/FG_ for Knight
// Lore, SCN_/OBJ_ for Pentagram. Scenery first, then objects.
const LABEL_KINDS = [
  { group: 'sceneryTemplates', prefix: /^(BG|SCN)_/ },
  { group: 'objectTemplates', prefix: /^(FG|OBJ)_/ }
];

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// Which templates the game's hand-written code refers to, by table position.
//
// Knight Lore's movers.s gives a template its behaviour by label -- DB
// FG_GUARD_EW, MOVE_GUARD_U -- and room_build.s tests scenery labels as ranges.
// Renaming such a template changes its label, and the build then stops on the
// label the code still uses. The panel says so before that happens.
//
// The labels are read from the generated room_data.s, where the k-th BG_ (or
// SCN_) EQU is scenery template k: by order of appearance rather than value,
// because Pentagram's object EQUs are byte offsets. room_data.s may be a build
// behind the document, but a template's position does not move -- nothing
// renumbers one -- so position is what is reported.
function codeReferences(here) {
  const out = { sceneryTemplates: {}, objectTemplates: {} };
  const generated = readIfThere(path.join(here, 'room_data.s'));
  if (!generated) return out;

  const labels = new Map();           // label -> { group, index }
  const seen = { sceneryTemplates: 0, objectTemplates: 0 };
  for (const line of generated.split(/\r?\n/)) {
    const found = /^([A-Z][A-Z0-9_]*)\s+EQU\s/.exec(line);
    if (!found) continue;
    for (const kind of LABEL_KINDS) {
      if (kind.prefix.test(found[1])) {
        labels.set(found[1], { group: kind.group, index: seen[kind.group]++ });
        break;
      }
    }
  }

  const sources = [];
  for (const dir of [here, path.join(here, 'tests'), path.join(here, '..', 'engine')]) {
    let names = [];
    try {
      names = fs.readdirSync(dir);
    } catch (err) {
      continue;
    }
    for (const name of names) {
      if (name.endsWith('.s') && !GENERATED.has(name)) sources.push(path.join(dir, name));
    }
  }

  for (const file of sources) {
    const text = readIfThere(file) || '';
    const words = new Set(text.match(/\b[A-Z][A-Z0-9_]+\b/g) || []);
    // A file that defines the label for itself -- a test standing up its own
    // FG_BLOCK -- does not depend on the generated one, and a rename leaves it
    // building.
    const own = new Set();
    for (const found of text.matchAll(/^\s*([A-Z][A-Z0-9_]*)\s+EQU\b/gm)) own.add(found[1]);
    for (const [label, where] of labels) {
      if (!words.has(label) || own.has(label)) continue;
      const entry = out[where.group][where.index] ||
                    (out[where.group][where.index] = { label: label, files: [] });
      entry.files.push(path.relative(here, file).replace(/\\/g, '/'));
    }
  }
  return out;
}

module.exports = { codeReferences, GENERATED };
