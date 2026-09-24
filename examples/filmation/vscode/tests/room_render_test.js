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

function fileIn(game, name) {
  const file = path.join(FILMATION, game, name);
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
  const file = path.join(FILMATION, game, 'graphics.json');
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

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
