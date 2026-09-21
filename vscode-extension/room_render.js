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
// (node vscode-extension/tests/room_render_test.js). The page gets it inlined
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

// Read sprite_adj.s, which adj.py harvests from a running game: a flat table
// of signed pairs, a short list of graphics whose mirror image wants a
// different one, and a page-aligned table of one byte per graphic naming its
// pair. That last one is only as long as the game has graphics -- Knight
// Lore's runs to all 256, Pentagram's stops at 172 -- so adjFor has to cope
// with a graphic past the end rather than assume a full page.
//
// The file is generated and its shape is fixed, but it is still assembler, so
// this is deliberately forgiving: anything it cannot make sense of leaves the
// table short and adjFor falls back on no nudge at all, which is what entry 0
// is for.
function parseSpriteAdj(text) {
  const tables = { sprite_adj_pairs: [], sprite_adj_mirror: [], sprite_adj_index: [] };
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/;.*$/, '');
    const labelled = line.match(/^([a-z_0-9]+):/);
    if (labelled) {
      current = tables.hasOwnProperty(labelled[1]) ? labelled[1] : null;
      continue;
    }
    if (!current) continue;
    const db = line.match(/^\s+DB\s+(.+)$/i);
    if (!db) continue;
    for (const field of db[1].split(',')) {
      const text2 = field.trim();
      if (!text2) continue;
      const value = text2.startsWith('$')
        ? parseInt(text2.slice(1), 16)
        : parseInt(text2, 10);
      if (!Number.isNaN(value)) tables[current].push(value);
    }
  }

  // The mirror list is graphic, then the index to use instead, ending at a
  // lone zero graphic.
  const mirror = new Map();
  const flat = tables.sprite_adj_mirror;
  for (let i = 0; i + 1 < flat.length; i += 2) {
    if (flat[i] === 0) break;
    mirror.set(flat[i], flat[i + 1]);
  }

  return {
    pairs: tables.sprite_adj_pairs.map(signedOf),
    mirror: mirror,
    index: tables.sprite_adj_index
  };
}

// room_adjust: the table is page-aligned, so the graphic number IS the index.
// Bit 7 says this graphic wants a different nudge mirrored, which four of them
// do; everything else uses the one index whichever way round it is drawn. The
// index is already doubled, so it reaches straight into the flat pairs table.
const ADJ_MIRROR_DIFFERS = 0x80;

function adjFor(adj, graphic, mirrored) {
  if (!adj || !adj.index.length) return { x: 0, y: 0 };
  let entry = adj.index[graphic];
  if (entry === undefined) return { x: 0, y: 0 };
  if (mirrored && (entry & ADJ_MIRROR_DIFFERS)) {
    const instead = adj.mirror.get(graphic);
    if (instead !== undefined) entry = instead;
  }
  const at = entry & 0x7F;
  return {
    x: adj.pairs[at] || 0,
    y: adj.pairs[at + 1] || 0
  };
}

// --- the sprite sheet -----------------------------------------------------

// Which rectangle of sprites.png a graphic is drawn from. sprite_sheet.py
// numbers the sheet the way the game numbers its graphics and carries the
// mapping in the atlas, so several graphic numbers sharing one bitmap -- 186
// valid graphics over 103 sprites, in Knight Lore -- all land on the same
// rectangle. A graphic the game never uses maps to nothing.
function sheetIndex(sheet) {
  const zx = sheet && sheet.meta && sheet.meta.zx;
  const game = zx && zx.game;
  return {
    graphicMap: (game && game.graphicMap) || [],
    sprites: (zx && zx.sprites) || [],
    frames: (sheet && sheet.frames) || {}
  };
}

function spriteFor(index, graphic) {
  const n = index.graphicMap[graphic];
  if (n === null || n === undefined) return null;
  const sprite = index.sprites[n];
  if (!sprite) return null;
  const frame = index.frames[sprite.label];
  if (!frame) return null;
  return {
    sprite: sprite.label,
    group: sprite.group,
    rect: frame.frame,
    width: frame.frame.w,
    height: frame.frame.h
  };
}

// --- the draw list --------------------------------------------------------

// Everything the page needs to paint a room, in the order it must paint it:
// the pieces depth-ordered, each with the rectangle to take out of the sheet
// and the rectangle to put it in. A piece whose graphic the sheet has nothing
// for is kept, with no source rectangle, so the designer can say so rather
// than silently leaving a hole.
function drawList(pieces, sheet, adj) {
  const index = sheetIndex(sheet);
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

if (typeof module !== 'undefined') {
  module.exports = {
    WORLD_X_ORIGIN, WORLD_Y_ORIGIN, WORLD_V_BIAS, SCREEN_WIDTH, SCREEN_ROWS,
    VOTE_NEARER, VOTE_FURTHER, ADJ_MIRROR_DIFFERS,
    byteOf, signedOf, project, depthCompare, insertPlaced, depthOrder,
    parseSpriteAdj, adjFor, sheetIndex, spriteFor, drawList, roomBounds
  };
}
