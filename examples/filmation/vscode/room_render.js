// The room designer's picture: where a piece lands on screen, what order the
// pieces are drawn in, and which part of the sprite sheet each one comes from.
//
// This is a second implementation of three things the engine already does --
// object_place's projection, depth_cmp and depth_insert's scan, and
// room_adjust's per-graphic nudge -- and that is the risk it carries. It is
// here because a designer has to redraw while an object is being dragged, and
// a round trip through the emulator cannot. Every routine below names the one
// it mirrors; when that one changes, this has to change with it, and
// tests/room_render_test.js is what notices.
//
// What it does NOT do is draw. It answers "what goes where, in what order,
// from which rectangle of sprites.png", and the page blits. That keeps the
// whole of it testable under plain Node with no canvas.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node examples/filmation/vscode/tests/room_render_test.js). The page gets it inlined
// as source, which is why nothing here may use require() and why the export at
// the bottom is guarded.

'use strict';

// object_place's origins. The Y one is 296 mod 256 -- the origin Knight Lore
// itself uses -- and everything below is byte arithmetic because the engine's
// is: a piece high enough or far enough out wraps, and the designer should
// show the same wrap rather than a tidier picture the game will not draw.
const WORLD_X_ORIGIN = 128;
const WORLD_Y_ORIGIN = 40;
const WORLD_V_BIAS = 128;       // added before the shift, so the SRL is safe

const SCREEN_WIDTH = 256;
const SCREEN_ROWS = 192;        // the last row an object may be drawn on

function byteOf(n) {
  return ((n % 256) + 256) % 256;
}

// A byte read as a signed nudge, which is how the pairs table is written.
function signedOf(n) {
  const b = byteOf(n);
  return b > 127 ? b - 256 : b;
}

// --- the projection -------------------------------------------------------

// object_place, line for line:
//
//     x = U + V - 128 + ADJ_X
//     y = 40 - ((V - U + 128) / 2 + Z) - ADJ_Y
//
// x is the sprite's LEFT pixel column and y is its BASE -- the row just past
// its bottom, not its top -- so that a world Z on the floor stands on the
// floor. object_update works the top out as base - height, and so does this.
//
// The two ADJ bytes are subtracted and added the way the engine does, in eight
// bits: ADJ_Y is subtracted because the artwork's Y is bottom-up and the
// screen's is not.
function project(piece, adj) {
  const adjX = adj ? adj.x : 0;
  const adjY = adj ? adj.y : 0;
  const x = byteOf(byteOf(piece.u + piece.v) - WORLD_X_ORIGIN + adjX);
  let a = byteOf(piece.v - piece.u + WORLD_V_BIAS) >> 1;
  a = byteOf(a + piece.z);
  a = byteOf(WORLD_Y_ORIGIN - a);
  const y = byteOf(a - adjY);
  return { x: x, y: y };
}

// --- depth ----------------------------------------------------------------
//
// depth_cmp, from engine/depth.s and the walkthrough in engine/depth.md.
//
// Each axis votes, and a floor axis that separates the two boxes also adds a
// term to a running total. Agreement is what makes an answer certain: one vote
// on its own, or several that all say the same thing, is certain; axes that
// disagree, or boxes that interpenetrate, fall back on the total and are only
// a guess.
//
// U and V are centres with half-widths and Z is a base with a height. Two
// boxes that only touch count as apart, which is what lets a stack of cubes
// each exactly SIZE_Z above the last sort cleanly.
const VOTE_NEARER = 1;
const VOTE_FURTHER = 2;

function depthCompare(us, them) {
  let votes = 0;
  let total = 0;

  // U grows towards the viewer.
  if (them.u + them.sizeU <= us.u - us.sizeU) {
    votes |= VOTE_NEARER;
    total += us.u - them.u;
  } else if (them.u - them.sizeU >= us.u + us.sizeU) {
    votes |= VOTE_FURTHER;
    total += us.u - them.u;
  }

  // V grows away from it, so the same test means the opposite thing.
  if (them.v + them.sizeV <= us.v - us.sizeV) {
    votes |= VOTE_FURTHER;
    total += them.v - us.v;
  } else if (them.v - them.sizeV >= us.v + us.sizeV) {
    votes |= VOTE_NEARER;
    total += them.v - us.v;
  }

  // Z votes but adds no term. The case that settled it: the knight pushing a
  // table from behind, where his body's box starts at the table's top, so Z
  // says nearer by 12 and U says further by 11. With Z counted he was drawn
  // over the table; the floor is what the picture goes by.
  if (them.z + them.sizeZ <= us.z) {
    votes |= VOTE_NEARER;
  } else if (them.z >= us.z + us.sizeZ) {
    votes |= VOTE_FURTHER;
  }

  if (votes === VOTE_NEARER) return { further: false, certain: true };
  if (votes === VOTE_FURTHER) return { further: true, certain: true };
  // The axes disagree, or nothing separates them: go by the total, and say so.
  return { further: total < 0, certain: false };
}

// depth_insert's scan, and background_insert before it.
//
// The list is kept furthest first and is never sorted: each piece is scanned
// into place, and it ends up just after the last candidate it was nearer than,
// unless a certain "further" stopped the scan first. The insertion point lags
// the cursor on purpose -- a guessed "further" is not trusted enough to commit
// to, so the scan looks past it in case something later says so with more
// authority.
//
// One piece into a list that is already in order, scanning from `from` -- the
// index the sorted run starts at, which is where sort_head points. This is the
// whole of depth_insert_from, and it is a seam in its own right: moving one
// object is a relink, not a re-sort, here exactly as in the engine.
function insertPlaced(list, piece, from) {
  const start = from || 0;
  let at = start;
  for (let i = start; i < list.length; i++) {
    const answer = depthCompare(piece, list[i]);
    if (!answer.further) {
      at = i + 1;                   // nearer than this one, so it goes after
    } else if (answer.certain) {
      break;                        // a certain "further" stops the scan
    }
    // a guessed "further" moves the cursor on, but not the insertion point
  }
  list.splice(at, 0, piece);
  return at;
}

// A whole room, in the order room_build.s ends up with.
//
// Background scenery -- walls and trees, which nothing can ever be behind --
// goes in a run at the front in room order and is never compared with
// anything: background_insert links each one after the last and moves
// sort_head past it. The sorted run starts after them, and the draw loop knows
// nothing about the split -- it walks one chain, and the background simply
// comes out first.
function depthOrder(pieces) {
  const list = [];
  for (const piece of pieces) {
    if (piece.background) list.push(piece);
  }
  const sorted = list.length;       // where sort_head points, once
  for (const piece of pieces) {
    if (!piece.background) insertPlaced(list, piece, sorted);
  }
  return list;
}

// --- the per-graphic nudge ------------------------------------------------

// The per-graphic pixel nudge, as adj.py harvested it from a running game.
//
// The nudges are in graphics.json, beside the sprite each graphic number
// draws: two halves of one fact -- how that number is drawn -- and both keyed
// by graphic number. This reads only the nudge half; spriteFor above found the
// artwork through the sprite half of the same table.
//
// A nudge for every graphic that has one, and a second pair for the four whose
// mirror image wants a different one. The game wants it packed -- a table of
// distinct pairs, an index a graphic long, and a short exception list -- and
// sprite_source.py does that packing on the way to sprite_adj_gen.s. Nothing
// here needs to know about it.
//
// A graphic the file does not mention is not nudged, which is what entry 0 of
// the packed table means.
function readSpriteAdj(graphics_json) {
  const graphics = new Map();
  // graphics.json is keyed by the graphic's NAME and carries the number the
  // game knows it by; room_adjust is indexed by that number, so it is what
  // this is keyed by.
  const table = (graphics_json && graphics_json.graphics) || {};
  for (const name of Object.keys(table)) {
    const entry = table[name] || {};
    if (!Number.isInteger(entry.number)) continue;
    const plain = { x: entry.x || 0, y: entry.y || 0 };
    graphics.set(entry.number, {
      plain: plain,
      mirrored: entry.mirrored
        ? { x: entry.mirrored.x || 0, y: entry.mirrored.y || 0 }
        : plain
    });
  }
  return { graphics: graphics };
}

// room_adjust: the nudge a graphic is drawn with, which way round it is drawn
// being the only thing that can change it -- four graphics want a different
// one mirrored, and everything else uses the one pair either way.
function adjFor(adj, graphic, mirrored) {
  const found = adj && adj.graphics && adj.graphics.get(graphic);
  if (!found) return { x: 0, y: 0 };
  return mirrored ? found.mirrored : found.plain;
}

// --- the sprite sheet -----------------------------------------------------

// Which rectangle of sprites.png a graphic is drawn from. sprite_sheet.py
// numbers the sheet the way the game numbers its graphics and carries the
// mapping in the atlas, so several graphic numbers sharing one bitmap -- 186
// valid graphics over 103 sprites, in Knight Lore -- all land on the same
// rectangle. A graphic the game never uses maps to nothing.
// sheetIndex and spriteFor are sheet_model.js's -- it is the one place that
// knows what sprites.json and graphics.json look like, and three files want
// that. In the page it is inlined above this one, so they are simply in
// scope; under Node each file is its own module, so they are pulled in.
// `var` rather than `const` because this runs at the top level of a script
// that already has them when inlined.
if (typeof require !== 'undefined' && typeof module !== 'undefined') {
  // eslint-disable-next-line no-var, vars-on-top
  var { sheetIndex, spriteFor, spritesByName, graphicTable } =
    require('./sheet_model');
}

// --- the draw list --------------------------------------------------------

// Everything the page needs to paint a room, in the order it must paint it:
// the pieces depth-ordered, each with the rectangle to take out of the sheet
// and the rectangle to put it in. A piece whose graphic the sheet has nothing
// for is kept, with no source rectangle, so the designer can say so rather
// than silently leaving a hole.
function drawList(pieces, index, adj) {
  const ordered = depthOrder(pieces);
  return ordered.map(function (piece) {
    const nudge = adjFor(adj, piece.graphic, piece.mirrored);
    const at = project(piece, nudge);
    const art = spriteFor(index, piece.graphic);
    const height = art ? art.height : 0;
    return {
      piece: piece,
      graphic: piece.graphic,
      mirrored: piece.mirrored,
      sprite: art,
      adj: nudge,
      // The base is where object_place put it; the top follows from the art.
      x: at.x,
      base: at.y,
      y: at.y - height,
      width: art ? art.width : 0,
      height: height,
      // The engine draws nothing whose top is already past the bottom row.
      offScreen: at.y - height >= SCREEN_ROWS
    };
  });
}

// The floor a room's shape gives it, for drawing the grid under the pieces.
// room_shape copies the three bytes into room_half_u, room_half_v and
// room_floor_z, and the floor is centred on 128 along both axes.
function roomBounds(size) {
  return {
    minU: WORLD_X_ORIGIN - size.u, maxU: WORLD_X_ORIGIN + size.u,
    minV: WORLD_X_ORIGIN - size.v, maxV: WORLD_X_ORIGIN + size.v,
    floorZ: size.z
  };
}

// --- the floor, for drawing ------------------------------------------------
//
// Where a room's floor lies on the screen: its outline, and the cells inside
// it. Nothing in the game draws a floor, so these are the editors' own overlay.
//
// They use the unwrapped Y origin, 40 + 256. object_place writes its origin as
// 40, which is 296 less a whole byte, and project() wraps the way the engine
// does -- right for a sprite, but a floor drawn that way folds at its far
// corner. Everything at floor height or above wraps to the same place, so the
// floor and the sprites standing on it line up.
const TRUE_Y_ORIGIN = WORLD_Y_ORIGIN + 256;

function floorPoint(u, v, z) {
  return { x: u + v - WORLD_X_ORIGIN, y: TRUE_Y_ORIGIN - (((v - u + WORLD_V_BIAS) >> 1) + z) };
}

// The four corners of a room's floor, as roomBounds says it reaches.
function floorOutline(size) {
  const b = roomBounds(size);
  return [floorPoint(b.minU, b.minV, size.z), floorPoint(b.maxU, b.minV, size.z),
          floorPoint(b.maxU, b.maxV, size.z), floorPoint(b.minU, b.maxV, size.z)];
}

// The cells a room reaches, each as its four corners. The grid's own measures
// -- a cell's size, where cell 0's centre is, how many a side -- are the room
// model's, and passed in rather than declared twice.
function floorCells(size, grid) {
  const b = roomBounds(size);
  const out = [];
  for (let cv = 0; cv < grid.count; cv++) {
    for (let cu = 0; cu < grid.count; cu++) {
      const u = grid.origin + cu * grid.cell;
      const v = grid.origin + cv * grid.cell;
      // A narrow room reaches fewer cells; the rest are wall.
      if (u < b.minU || u > b.maxU || v < b.minV || v > b.maxV) continue;
      const u0 = u - grid.half;
      const v0 = v - grid.half;
      out.push([floorPoint(u0, v0, size.z), floorPoint(u0 + grid.cell, v0, size.z),
                floorPoint(u0 + grid.cell, v0 + grid.cell, size.z),
                floorPoint(u0, v0 + grid.cell, size.z)]);
    }
  }
  return out;
}

if (typeof module !== 'undefined') {
  module.exports = {
    WORLD_X_ORIGIN, WORLD_Y_ORIGIN, WORLD_V_BIAS, SCREEN_WIDTH, SCREEN_ROWS,
    VOTE_NEARER, VOTE_FURTHER,
    byteOf, signedOf, project, depthCompare, insertPlaced, depthOrder,
    readSpriteAdj, adjFor, sheetIndex, spriteFor, drawList, roomBounds,
    TRUE_Y_ORIGIN, floorPoint, floorOutline, floorCells
  };
}
