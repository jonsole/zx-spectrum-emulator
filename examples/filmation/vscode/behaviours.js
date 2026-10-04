// The behaviours a Filmation game's object templates can be given, read out
// of the game's own movers.s.
//
// Plain Node, no vscode API, so tests/behaviours_test.js runs it against the
// real source. templates_view.js asks it once per open panel, for the
// templates editor's "moves" list -- which sets templates.json's meta.movers,
// from which the game's build writes mover_of.

'use strict';

const fs = require('fs');
const path = require('path');

// A behaviour is a MOVE_ name movers.s gives a number of its own:
//
//     MOVE_PUSHED      EQU     18
//
// A name given another name only marks where a band of them begins or ends --
// MOVE_LOOSE EQU MOVE_CARRIED -- and is no behaviour of its own, and 0 is
// nothing at all, which the list offers as "doesn't move" anyway.
//
// The bands are the engine's: BEHAVIOUR_DEADLY to BEHAVIOUR_HARMLESS kill what
// they touch, and BEHAVIOUR_LOOSE and up can be pushed and carried -- which is
// what makes a weight mean anything. Each is resolved through however many
// names it is given by.
const NAME = /^[A-Z][A-Z0-9_]*$/;

function numberOf(expr) {
  if (/^\d+$/.test(expr)) return Number(expr);
  if (/^\$[0-9A-Fa-f]+$/.test(expr)) return parseInt(expr.slice(1), 16);
  if (/^0x[0-9A-Fa-f]+$/.test(expr)) return parseInt(expr.slice(2), 16);
  return null;
}

function parseBehaviours(text) {
  const said = new Map();
  for (const line of String(text || '').split(/\r?\n/)) {
    const found = /^([A-Z][A-Z0-9_]*)\s+EQU\s+([^;]*?)\s*(;.*)?$/.exec(line);
    if (found) said.set(found[1], found[2]);
  }
  function resolve(name, seen) {
    const expr = said.get(name);
    if (expr === undefined) return null;
    const n = numberOf(expr);
    if (n !== null) return n;
    if (!NAME.test(expr) || seen.has(name)) return null;
    seen.add(name);
    return resolve(expr, seen);
  }
  const deadly = resolve('BEHAVIOUR_DEADLY', new Set());
  const harmless = resolve('BEHAVIOUR_HARMLESS', new Set());
  const loose = resolve('BEHAVIOUR_LOOSE', new Set());
  const list = [];
  for (const [name, expr] of said) {
    if (!/^MOVE_/.test(name)) continue;
    const value = numberOf(expr);
    if (value === null || value === 0) continue;
    list.push({
      name: name,
      label: behaviourLabel(name),
      value: value,
      kills: deadly !== null && harmless !== null && value >= deadly && value < harmless,
      loose: loose !== null && value >= loose
    });
  }
  list.sort(function (a, b) { return a.value - b.value; });
  return { list: list, loose: loose };
}

// A game's behaviours, from movers.s at the top of its folder, or null when
// it has none to read.
function behavioursOf(gameDir) {
  let text;
  try {
    text = fs.readFileSync(path.join(gameDir, 'movers.s'), 'utf8');
  } catch (err) {
    return null;
  }
  const found = parseBehaviours(text);
  return found.list.length ? found : null;
}

// How the list shows one: MOVE_SPIKE_BALL as "spike ball".
function behaviourLabel(name) {
  return String(name).replace(/^MOVE_/, '').toLowerCase().replace(/_/g, ' ');
}

if (typeof module !== 'undefined') {
  module.exports = { parseBehaviours, behavioursOf, behaviourLabel };
}
