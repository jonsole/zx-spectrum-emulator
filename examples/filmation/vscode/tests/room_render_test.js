// Tests for room_render.js -- the projection, the depth list, the per-graphic
// nudge and the sprite sheet lookup. Plain Node, no vscode API and no test
// framework:
//
//   node examples/filmation/vscode/tests/room_render_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" examples/filmation/vscode/tests/room_render_test.js)
//
// room_render.js is a second implementation of what the engine already does,
// so these hold it to the original rather than to itself. The projection's
// expected numbers are worked out from object_place's eight instructions, and
// the depth tests are the worked examples in engine/depth.md, numbers and
// outcomes as that document states them -- not captured from this code.
//
// The last group runs against the two games' real sprites.json. The
// sheet is gitignored and only exists after a build, so those skip without it.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const r = require('../room_render');
const m = require('../room_model');
const layout = require('../game_layout');

const FILMATION = path.join(__dirname, '..', '..');
const GAMES = ['knightlore', 'pentagram'];

let failures = 0;
let skipped = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    if (err && err.skip) {
      skipped++;
      console.log('skip ' + name + ' -- ' + err.message);
      return;
    }
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

function skip(why) {
  const err = new Error(why);
  err.skip = true;
  throw err;
}

// A castle is its rooms and the templates they place, merged the way both
// editors merge them.
function castleOf(game) {
  return m.withTemplates(m.parseAtlas(fileIn(game, 'rooms.json')),
                         m.parseTemplates(fileIn(game, 'templates.json')));
}

// A game's JSON, from its metadata/ -- or its top, for a game laid out flat.
function fileIn(game, name) {
  const file = path.join(layout.metadataOf(path.join(FILMATION, game)), name);
  if (!fs.existsSync(file)) skip(game + '/' + name + ' is not here');
  return fs.readFileSync(file, 'utf8');
}

// A box, the way an object record holds one: U and V are centres with
// half-widths, Z is a base with a height.
function box(u, v, z, sizeU, sizeV, sizeZ) {
  return {
    u: u, v: v, z: z,
    sizeU: sizeU === undefined ? 0 : sizeU,
    sizeV: sizeV === undefined ? 0 : sizeV,
    sizeZ: sizeZ === undefined ? 0 : sizeZ
  };
}

// --- the projection -------------------------------------------------------
//
// object_place is:
//
//     C = U + V - 128 + ADJ_X
//     A = (V - U + 128) >> 1;  A += Z;  A = -A;  A += 40;  B = A - ADJ_Y
//
// all in eight bits. The numbers below are that arithmetic done by hand.

test('project: Alien 8\u2019s origin with its floor at 64 draws where Knight Lore\u2019s does at 128', function () {
  // Knight Lore subtracts 104 from the game's upward Y, Alien 8 40 with its
  // floor 64 lower: the same rows, so an origin 64 less gives the same
  // picture for pieces 64 lower. 296 is the default, and 40 the same byte.
  for (const [u, v, z] of [[128, 128, 128], [72, 184, 140], [200, 60, 176]]) {
    const kl = r.project({ u: u, v: v, z: z }, { x: -12, y: -5 });
    assert.deepStrictEqual(r.project({ u: u, v: v, z: z }, { x: -12, y: -5 }, 296), kl);
    assert.deepStrictEqual(r.project({ u: u, v: v, z: z - 64 }, { x: -12, y: -5 }, 232), kl);
    assert.deepStrictEqual(r.floorPoint(u, v, z - 64, 232), r.floorPoint(u, v, z));
  }
});

test('project: the middle of the floor', function () {
  // U 128, V 128, Z 128, no nudge.
  //   x = 128 + 128 - 128 = 128
  //   (128 - 128 + 128) >> 1 = 64;  64 + 128 = 192;  40 - 192 = -152 = 104
  const at = r.project(box(128, 128, 128), { x: 0, y: 0 });
  assert.strictEqual(at.x, 128);
  assert.strictEqual(at.y, 104);
});

test('project: U sends a piece down the screen and V up it', function () {
  const middle = r.project(box(128, 128, 0), { x: 0, y: 0 });
  const alongU = r.project(box(144, 128, 0), { x: 0, y: 0 });
  const alongV = r.project(box(128, 144, 0), { x: 0, y: 0 });
  // Both floor axes move it right by their own amount...
  assert.strictEqual(r.byteOf(alongU.x - middle.x), 16);
  assert.strictEqual(r.byteOf(alongV.x - middle.x), 16);
  // ...and half as far up or down, in opposite directions. Screen Y grows
  // downwards, so +U is +8 here and +V is -8.
  assert.strictEqual(r.byteOf(alongU.y - middle.y), 8);
  assert.strictEqual(r.byteOf(middle.y - alongV.y), 8);
});

test('project: Z raises a piece without moving it sideways', function () {
  const floor = r.project(box(128, 128, 100), { x: 0, y: 0 });
  const raised = r.project(box(128, 128, 112), { x: 0, y: 0 });
  assert.strictEqual(raised.x, floor.x);
  assert.strictEqual(r.byteOf(floor.y - raised.y), 12, 'a level is 12 units');
});

test('project: a step along the line of sight changes nothing on screen', function () {
  // (1, -1, 1) is the direction the camera looks along, so a move that way
  // changes depth and not the picture. depth.md leans on this.
  const before = r.project(box(100, 100, 100), { x: 0, y: 0 });
  const after = r.project(box(101, 99, 101), { x: 0, y: 0 });
  assert.deepStrictEqual(after, before);
});

test('project: the nudge moves x with it and y against it', function () {
  // ADJ_X is added and ADJ_Y subtracted -- the artwork's Y is bottom-up and
  // the screen's is not.
  const plain = r.project(box(128, 128, 128), { x: 0, y: 0 });
  const nudged = r.project(box(128, 128, 128), { x: -12, y: -8 });
  assert.strictEqual(r.byteOf(nudged.x - plain.x), r.byteOf(-12));
  assert.strictEqual(r.byteOf(nudged.y - plain.y), 8);
});

// --- depth_cmp ------------------------------------------------------------
//
// The two worked examples in engine/depth.md, section 4.

test('depthCompare: the worked example that is certain', function () {
  // "The placed object is at U 60, the candidate at U 40, both with half-width
  // 5, same V and Z, so V and Z overlap." -> B = 1: certainly nearer.
  const us = box(60, 100, 0, 5, 5, 10);
  const them = box(40, 100, 0, 5, 5, 10);
  assert.deepStrictEqual(r.depthCompare(us, them), { further: false, certain: true });
});

test('depthCompare: the worked example that is a guess', function () {
  // "The placed object is at U 70, V 90. The candidate is at U 40, V 50. All
  // half-widths are 5, and Z overlaps." U says nearer (+30), V says further
  // (-40) -> B = 3, HL = -10: probably further.
  const us = box(70, 90, 0, 5, 5, 10);
  const them = box(40, 50, 0, 5, 5, 10);
  assert.deepStrictEqual(r.depthCompare(us, them), { further: true, certain: false });
});

test('depthCompare: two boxes that only touch are apart', function () {
  // "A box from 36 to 44 and one from 44 to 52 do not overlap on that axis."
  // This is what lets a stack of cubes sort cleanly on Z.
  const lower = box(128, 128, 36, 4, 4, 8);
  const upper = box(128, 128, 44, 4, 4, 8);
  assert.deepStrictEqual(r.depthCompare(upper, lower), { further: false, certain: true });
  assert.deepStrictEqual(r.depthCompare(lower, upper), { further: true, certain: true });
});

test('depthCompare: two axes agreeing are certain, not a guess', function () {
  // "Agreement is what makes an answer certain, not the number of axes." An
  // earlier engine called anything other than exactly one separating axis a
  // guess, and a guard with a spike to its east and below it was drawn wrong.
  const us = box(100, 100, 40, 4, 4, 8);
  const them = box(60, 100, 20, 4, 4, 8);   // further along U and below on Z
  assert.deepStrictEqual(r.depthCompare(us, them), { further: false, certain: true });
});

test('depthCompare: Z votes but adds no term', function () {
  // The knight pushing a table from behind: his body's box starts at the
  // table's top, so Z says nearer by 12 and U says further by 11. With Z's
  // term counted the body was drawn over the table.
  // The body has no width of its own here, so U separates by exactly the 11
  // the walkthrough quotes: 117 against the table's near face at 120.
  const body = box(117, 128, 40, 0, 4, 12);
  const table = box(128, 128, 28, 8, 8, 12);
  const answer = r.depthCompare(body, table);
  assert.strictEqual(answer.certain, false, 'U and Z disagree, so it is a guess');
  assert.strictEqual(answer.further, true, 'the floor is what the picture goes by');
});

test('depthCompare: boxes that interpenetrate are always a guess', function () {
  const us = box(128, 128, 0, 8, 8, 8);
  const them = box(130, 130, 2, 8, 8, 8);
  assert.strictEqual(r.depthCompare(us, them).certain, false);
});

// --- depth_insert ---------------------------------------------------------
//
// The worked examples in engine/depth.md, section 6.

test('depthOrder: the plain insert', function () {
  // "The list holds A, B and C at U 20, 40 and 60, all half-width 4. X is
  // inserted at U 50." -> A, B, X, C
  const A = box(20, 128, 0, 4, 4, 8); A.name = 'A';
  const B = box(40, 128, 0, 4, 4, 8); B.name = 'B';
  const C = box(60, 128, 0, 4, 4, 8); C.name = 'C';
  const X = box(50, 128, 0, 4, 4, 8); X.name = 'X';
  const list = [A, B, C];
  r.insertPlaced(list, X, 0);
  assert.deepStrictEqual(list.map(function (p) { return p.name; }),
                         ['A', 'B', 'X', 'C']);
});

test('depthOrder: the insertion point lags the cursor past a guess', function () {
  // "vs P nearer -> at = P; vs Q further, a guess -> at stays at P, cursor
  // moves on; vs R nearer -> at = R  ->  P, Q, R, X"
  const P = box(50, 128, 0, 4, 4, 10); P.name = 'P';
  const Q = box(250, 136, 0, 4, 4, 10); Q.name = 'Q';   // U further, V nearer
  const R = box(60, 128, 0, 4, 4, 10); R.name = 'R';
  const X = box(100, 128, 0, 4, 4, 10); X.name = 'X';

  assert.strictEqual(r.depthCompare(X, P).further, false, 'P: nearer');
  const vsQ = r.depthCompare(X, Q);
  assert.deepStrictEqual(vsQ, { further: true, certain: false }, 'Q: a guess');
  assert.strictEqual(r.depthCompare(X, R).further, false, 'R: nearer');

  const list = [P, Q, R];
  r.insertPlaced(list, X, 0);
  assert.deepStrictEqual(list.map(function (p) { return p.name; }),
                         ['P', 'Q', 'R', 'X']);
});

test('depthOrder: a certain "further" stops the scan where it stands', function () {
  // "Had R said further, certain instead, the scan would have stopped at R and
  // linked X after P, giving P, X, Q, R."
  const P = box(50, 128, 0, 4, 4, 10); P.name = 'P';
  const Q = box(250, 136, 0, 4, 4, 10); Q.name = 'Q';
  const R = box(250, 128, 0, 4, 4, 10); R.name = 'R';   // plainly further
  const X = box(100, 128, 0, 4, 4, 10); X.name = 'X';

  assert.deepStrictEqual(r.depthCompare(X, R), { further: true, certain: true });
  const list = [P, Q, R];
  r.insertPlaced(list, X, 0);
  assert.deepStrictEqual(list.map(function (p) { return p.name; }),
                         ['P', 'X', 'Q', 'R']);
});

test('depthOrder: the background run comes first, in room order', function () {
  const wall1 = box(64, 128, 128, 0, 8, 40); wall1.name = 'wall1'; wall1.background = true;
  const wall2 = box(128, 192, 128, 8, 0, 40); wall2.name = 'wall2'; wall2.background = true;
  // A block nearer than both walls, and one further than either would be if
  // the walls were sorted at all.
  const near = box(180, 80, 128, 8, 8, 12); near.name = 'near';
  const far = box(80, 180, 128, 8, 8, 12); far.name = 'far';

  const order = r.depthOrder([wall1, near, wall2, far]);
  assert.deepStrictEqual(order.slice(0, 2).map(function (p) { return p.name; }),
                         ['wall1', 'wall2'],
                         'the walls keep room order at the front');
  assert.deepStrictEqual(order.slice(2).map(function (p) { return p.name; }),
                         ['far', 'near'],
                         'and the rest are sorted furthest first');
});

// --- the per-graphic nudge ------------------------------------------------

for (const game of GAMES) {
  test(game + ': the sheet\'s nudges read back the way room_adjust reads them', function () {
    const adj = r.readSpriteAdj(graphicsFor(game));
    const atlas = castleOf(game);
    const numbers = m.graphicNumbers(sheetFor(game), graphicsFor(game));
    const boxes = m.graphicBoxes(sheetFor(game), graphicsFor(game));

    // Every graphic a room actually draws has to have an answer, even if that
    // answer is no nudge at all -- a missing one would put the piece out by up
    // to twenty pixels.
    let nudged = 0;
    for (const room of atlas.rooms) {
      for (const piece of m.expandRoom(atlas, room, numbers, boxes)) {
        const at = r.adjFor(adj, piece.graphic, piece.mirrored);
        assert.strictEqual(typeof at.x, 'number', 'graphic ' + piece.graphic);
        assert.strictEqual(typeof at.y, 'number', 'graphic ' + piece.graphic);
        if (at.x || at.y) nudged++;
      }
    }
    assert.ok(nudged > 20, 'only ' + nudged + ' pieces are nudged at all');

    // A graphic the harvest never saw is not nudged, rather than throwing.
    assert.deepStrictEqual(r.adjFor(adj, 255, false), { x: 0, y: 0 });
    assert.deepStrictEqual(r.adjFor(adj, 255, true), { x: 0, y: 0 });
  });

  test(game + ': only the four that differ have a mirrored pair', function () {
    const sheet = sheetFor(game);
    const graphics = graphicsFor(game);
    const said = graphics.graphics;
    const adj = r.readSpriteAdj(graphics);
    let differ = 0;
    // Keyed by name in the file, by the number the game knows it by here.
    for (const name of Object.keys(said)) {
      const g = said[name].number;
      const plain = r.adjFor(adj, g, false);
      const flipped = r.adjFor(adj, g, true);
      if (plain.x !== flipped.x || plain.y !== flipped.y) differ++;
      else {
        assert.deepStrictEqual(flipped, plain,
          'graphic ' + g + ' should read the same either way round');
      }
    }
    // Both games harvested exactly four, which is what let the game pack the
    // rest behind one index.
    assert.strictEqual(differ, 4, 'graphics whose mirror wants a different nudge');
  });
}

// --- the sprite sheet -----------------------------------------------------

function sheetFor(game) {
  return JSON.parse(fileIn(game, 'sprites.json'));
}

function graphicsFor(game) {
  const file = path.join(layout.metadataOf(path.join(FILMATION, game)), 'graphics.json');
  if (!fs.existsSync(file)) skip(game + '/graphics.json is not here');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

for (const game of GAMES) {
  test(game + ': every graphic a room draws is on the sheet', function () {
    const atlas = castleOf(game);
    const sheet = sheetFor(game);
    const graphics = graphicsFor(game);
    const index = r.sheetIndex(sheet, graphics);
    const numbers = m.graphicNumbers(sheet, graphics);
    const boxes = m.graphicBoxes(sheet, graphics);
    const missing = new Set();
    for (const room of atlas.rooms) {
      for (const piece of m.expandRoom(atlas, room, numbers, boxes)) {
        if (!r.spriteFor(index, piece.graphic)) missing.add(piece.graphic);
      }
    }
    assert.deepStrictEqual(Array.from(missing), []);
  });

  test(game + ': a sprite is as wide as its width in bytes says', function () {
    const sheet = sheetFor(game);
    const graphics = graphicsFor(game);
    const index = r.sheetIndex(sheet, graphics);
    let checked = 0;
    for (let graphic = 0; graphic < 256; graphic++) {
      const art = r.spriteFor(index, graphic);
      if (!art) continue;
      // The rectangle the sheet gives it is the sprite's own, so these
      // agree by construction -- what this checks is that spriteFor found the
      // right sprite for the graphic, through two files rather than one.
      const sprite = index.byName.get(art.sprite);
      assert.ok(sprite, 'graphic ' + graphic + ' -> ' + art.sprite);
      assert.strictEqual(art.width, sprite.w, 'graphic ' + graphic);
      assert.strictEqual(art.height, sprite.h);
      assert.strictEqual(sprite.w % 8, 0,
        'a sprite is a whole number of bytes wide: ' + art.sprite);
      checked++;
    }
    assert.ok(checked > 50, 'checked ' + checked + ' graphics');
  });

  test(game + ': a real room draws every piece it expands to', function () {
    const atlas = castleOf(game);
    const sheet = sheetFor(game);
    const graphics = graphicsFor(game);
    const adj = r.readSpriteAdj(graphicsFor(game));
    const index = r.sheetIndex(sheet, graphics);
    // The busiest room in the game, which is the one worth looking at.
    let busiest = atlas.rooms[0];
    for (const room of atlas.rooms) {
      if (m.poolUsed(atlas, room) > m.poolUsed(atlas, busiest)) busiest = room;
    }
    const pieces = m.expandRoom(atlas, busiest,
                                m.graphicNumbers(sheet, graphics),
                                m.graphicBoxes(sheet, graphics));
    const list = r.drawList(pieces, index, adj);

    assert.strictEqual(list.length, pieces.length, 'nothing is dropped');
    for (const item of list) {
      assert.ok(item.sprite, 'graphic ' + item.graphic + ' has artwork');
      assert.ok(item.width > 0 && item.height > 0);
      assert.ok(item.x >= 0 && item.x < r.SCREEN_WIDTH);
    }
    // The background run comes out first, and a room with walls has one.
    const background = list.filter(function (i) { return i.piece.background; });
    if (background.length) {
      assert.ok(list.slice(0, background.length).every(function (i) {
        return i.piece.background;
      }), 'the background run is at the front');
    }
  });
}

test('knightlore: the arch over a doorway is drawn behind what walks through it',
  function () {
    // An arch is scenery the knight passes behind, so it is NOT background: it
    // keeps its place in the sort. A block standing in the doorway, nearer
    // along U, has to come out after it.
    const atlas = castleOf('knightlore');
    assert.ok(atlas.sceneryTemplates.scenery_arch_n, 'the arch is there');
    assert.ok(!m.isBackgroundTemplate(atlas, 'scenery_arch_n'),
      'an arch is not background');
  });

// --- the floor --------------------------------------------------------------

test('the floor lines up with what stands on it', () => {
  // A sprite at floor height is placed by project(), which wraps as the engine
  // does; the floor is drawn unwrapped so it does not fold. For anything on a
  // floor the two are the same point.
  for (const z of [128, 140, 176]) {
    for (const [u, v] of [[64, 64], [128, 128], [192, 64], [72, 184], [100, 150]]) {
      const sprite = r.project({ u: u, v: v, z: z }, null);
      const floor = r.floorPoint(u, v, z);
      assert.strictEqual(floor.x & 0xFF, sprite.x, 'x at ' + [u, v, z]);
      assert.strictEqual(floor.y & 0xFF, sprite.y, 'y at ' + [u, v, z]);
    }
  }
});

test('a floor reaches the cells its room does', () => {
  const grid = { cell: m.CELL, origin: m.CELL_ORIGIN, count: m.CELLS, half: m.HALF_CELL };
  assert.strictEqual(r.floorCells({ u: 64, v: 64, z: 128 }, grid).length, 64, 'square');
  assert.strictEqual(r.floorCells({ u: 32, v: 64, z: 128 }, grid).length, 32, 'narrow along U');
  assert.strictEqual(r.floorCells({ u: 64, v: 32, z: 128 }, grid).length, 32, 'narrow along V');
  const outline = r.floorOutline({ u: 64, v: 64, z: 128 });
  assert.strictEqual(outline.length, 4);
  // A diamond: U + V across, so the corners where one axis is at its least
  // and the other at its most sit on the room's centre line, one above the
  // other, and the other two are its left and right points.
  assert.strictEqual(outline[1].x, 128);
  assert.strictEqual(outline[3].x, 128);
  assert.ok(outline[1].y !== outline[3].y);
  assert.strictEqual(outline[0].x, 0);
  assert.strictEqual(outline[2].x, 256);
});

test('a piece off the top of the screen: the game wraps it, the true place does not', () => {
  // object_place: y = 296 - ((V - U + 128) / 2 + Z) - ADJ_Y, in eight bits. In
  // the middle of the floor (V - U + 128) / 2 is 64, so a base at Z 128 is
  // row 296 - 192 = 104, and at Z 240 it is 296 - 304 = -8: above the top,
  // which eight bits make 248, the bottom.
  const middle = { u: 128, v: 128, z: 128 };
  assert.deepStrictEqual(r.projectUnwrapped(middle, null, 296), { x: 128, y: 104 });
  assert.strictEqual(r.project(middle, null, 296).y, 104, 'on the screen the two agree');
  const high = { u: 128, v: 128, z: 240 };
  assert.strictEqual(r.projectUnwrapped(high, null, 296).y, -8);
  assert.strictEqual(r.project(high, null, 296).y, 248);
  // A nudge is signed, whichever way it is written.
  assert.strictEqual(r.projectUnwrapped(middle, { x: -12, y: -4 }, 296).x, 116);
  assert.strictEqual(r.projectUnwrapped(middle, { x: 244, y: 252 }, 296).y, 108);
});

test('why the game draws a piece elsewhere: too far back is not the top of the screen', () => {
  const why = (piece) => r.wrapOf(piece, r.project(piece, null, 296), r.projectUnwrapped(piece, null, 296));
  // At U 67, V 206 -- behind a room's far corner -- V - U + 128 is 267, and
  // object_place's SRL halves the 11 left in eight bits: 5 where 133 is
  // meant, 128 rows lower. Nothing to do with the edge of the screen.
  const behind = { u: 67, v: 206, z: 128 };
  assert.strictEqual(why(behind), 'back');
  assert.strictEqual(r.projectUnwrapped(behind, null, 296).y - r.project(behind, null, 296).y, -128);
  // The far corner itself, V - U = 128, is the first that does it; 127 is fine.
  assert.strictEqual(why({ u: 64, v: 192, z: 128 }), 'back');
  assert.strictEqual(why({ u: 65, v: 192, z: 128 }), null);
  assert.strictEqual(why({ u: 200, v: 60, z: 128 }), 'front');
  // Lifted until its base is above row 0, in the middle of the floor.
  assert.strictEqual(why({ u: 128, v: 128, z: 240 }), 'top');
  assert.strictEqual(why({ u: 128, v: 128, z: 128 }), null);
});

test('the guides cross at a piece and reach across the room, and out to it beyond', () => {
  const square = { u: 64, v: 64, z: 128 };     // floor 64 to 192 both ways
  // Inside: along U at its V from wall to wall, along V at its U likewise.
  let lines = r.floorGuides(100, 150, square);
  assert.deepStrictEqual(lines[0], [r.floorPoint(64, 150, 128), r.floorPoint(192, 150, 128)]);
  assert.deepStrictEqual(lines[1], [r.floorPoint(100, 64, 128), r.floorPoint(100, 192, 128)]);
  // Behind the north wall, at V 206: the line along V runs on out to it.
  lines = r.floorGuides(67, 206, square);
  assert.deepStrictEqual(lines[1], [r.floorPoint(67, 64, 128), r.floorPoint(67, 206, 128)]);
  assert.deepStrictEqual(lines[0], [r.floorPoint(64, 206, 128), r.floorPoint(192, 206, 128)]);
});

// Lightkeep's raised section: an invisible box 32 across U, 128 along V and
// 20 high, its centre at U 80, V 128 on a floor at 128.
const RAISED = { u: 80, v: 128, z: 128, sizeU: 16, sizeV: 64, sizeZ: 20 };

test('a box is eight corners, U by bit 0, V by bit 1, the top by bit 2', () => {
  const box = r.boxOutline(RAISED);
  assert.strictEqual(box.corners.length, 8);
  // Screen x is U + V - 128, whatever the height.
  assert.deepStrictEqual(box.corners.slice(0, 4).map((p) => p.x), [0, 32, 128, 160]);
  assert.deepStrictEqual(box.corners.slice(4).map((p) => p.x), [0, 32, 128, 160]);
  // The top is the base twenty rows up.
  for (let i = 0; i < 4; i++) assert.strictEqual(box.corners[i + 4].y, box.corners[i].y - 20);
  // Each corner is where floorPoint puts it.
  assert.deepStrictEqual(box.corners[0], r.floorPoint(64, 64, 128));
  assert.deepStrictEqual(box.corners[7], r.floorPoint(96, 192, 148));
});

test('a box has twelve edges, and the three at its back corner are hidden', () => {
  const box = r.boxOutline(RAISED);
  assert.strictEqual(box.edges.length, 12);
  const hidden = box.edges.filter((e) => e.hidden);
  assert.strictEqual(hidden.length, 3);
  for (const e of hidden) assert.ok(e.from === r.FAR_BOX_CORNER || e.to === r.FAR_BOX_CORNER);
  // The back corner is -U, +V on the floor: the highest base corner on the
  // screen, since V - U is what lifts a point up it.
  const base = box.corners.slice(0, 4).map((p) => p.y);
  assert.strictEqual(Math.min.apply(null, base), box.corners[r.FAR_BOX_CORNER].y);
});

test('a footing is the box’s base on the floor, and the riser up to the piece', () => {
  const lifted = Object.assign({}, RAISED, { z: 148 });
  const f = r.footing(lifted, 128);
  assert.deepStrictEqual(f.base, [r.floorPoint(64, 64, 128), r.floorPoint(96, 64, 128),
                                  r.floorPoint(96, 192, 128), r.floorPoint(64, 192, 128)]);
  assert.deepStrictEqual(f.foot, r.floorPoint(80, 128, 128));
  // Z moves a point straight up the screen: the riser is vertical, twenty high.
  assert.strictEqual(f.head.x, f.foot.x);
  assert.strictEqual(f.head.y, f.foot.y - 20);
  // A wall piece has no depth along U, and its base is a line.
  const wall = r.footing({ u: 96, v: 84, z: 128, sizeU: 0, sizeV: 20, sizeZ: 20 }, 128);
  assert.deepStrictEqual(wall.base[0], wall.base[1]);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
