// The templates panel as its host assembles it.
//
//   node examples/filmation/vscode/tests/templates_page_test.js
//
// templates_view.js opens with require('vscode'), so this does what it does to
// the page and runs the result against a fake DOM and both games' real
// castles: the page opens, every template can be picked and draws, a click on
// the picture picks a piece, and each thing the panel can do to a template
// comes back as a whole rooms.json that still reads as a castle.
//
// The same lesson room_page_test.js learned: a page assembled by string
// replacement fails at runtime, and a fake canvas that swallows every call
// will pass a page that draws nothing. This one counts what reached it.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const m = require('../room_model');
const layout = require('../game_layout');
const sheetFiles = require('../sheet_files');

const EXT = path.join(__dirname, '..');
const FILMATION = path.join(EXT, '..');
const GAMES = ['knightlore', 'pentagram'];
const INLINED = ['sheet_model.js', 'room_model.js', 'room_render.js'];

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

// The files where the host finds them: the pair in the game's metadata/, and
// the artwork wherever rooms.json's meta.sprites says, relative to it.
function bootFor(game) {
  const here = layout.metadataOf(path.join(FILMATION, game));
  const rooms = path.join(here, 'rooms.json');
  const templates = path.join(here, 'templates.json');
  if (!fs.existsSync(rooms)) skip(game + '/rooms.json is not here');
  if (!fs.existsSync(templates)) skip(game + '/templates.json is not here');
  const text = fs.readFileSync(rooms, 'utf8');
  const templatesText = fs.readFileSync(templates, 'utf8');
  const named = m.spriteFilesOf(JSON.parse(text));
  const read = (name) => {
    const file = layout.within(here, name);
    return file && fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  };
  const png = layout.within(here, named.sheet) || '';
  const dataUri = (file) => fs.existsSync(file)
    ? 'data:image/png;base64,' + fs.readFileSync(file).toString('base64') : null;
  const graphics = read(named.graphics);
  const graphicsFile = layout.within(here, named.graphics);
  // The other sheets, found as the host finds them.
  const { others, otherPngs } = sheetFiles.otherSheets(graphics, path.dirname(graphicsFile), dataUri);
  // What templates_view.js sends: the document, templates.json, and the
  // rooms beside it.
  return {
    templates: JSON.parse(templatesText),
    rooms: JSON.parse(text),
    eol: templatesText.indexOf('\r\n') >= 0 ? '\r\n' : '\n',
    roomsEol: text.indexOf('\r\n') >= 0 ? '\r\n' : '\n',
    sheet: read(named.atlas),
    graphics: graphics,
    sheetPng: dataUri(png),
    others: others,
    otherPngs: otherPngs,
    // What templates_view.js's codeReferences finds; the page only reads it.
    codeRefs: { sceneryTemplates: {}, objectTemplates: { 8: { label: 'FG_GUARD_EW',
                                                             files: ['movers.s'] } } },
    template: null
  };
}

// What the host injects, and the markers filled in the order it fills them.
function assemble(boot) {
  let html = fs.readFileSync(path.join(EXT, 'templates_view.html'), 'utf8');
  for (const name of INLINED) {
    html = html.replace('/*@' + name + '@*/', () =>
      fs.readFileSync(path.join(EXT, name), 'utf8'));
  }
  return html.replace('/*@host@*/', '');
}

function scriptOf(html) {
  const open = html.indexOf('>', html.indexOf('<script')) + 1;
  return html.slice(open, html.indexOf('</script>', open));
}

// A DOM that records rather than renders, and a 2d context that counts.
// `hooks.imageData`, given, answers getImageData -- (x, y, w, h) to an object
// with its `data` -- which is how a test makes a sprite read as blank. Every
// colour a stroke is drawn in is counted too, in `painted.colours`.
function fakeDom(hooks) {
  const listeners = [];
  const painted = { colours: {} };
  function context() {
    return new Proxy({}, {
      get: (target, key) => (key in target ? target[key]
        : function () {
          painted[key] = (painted[key] || 0) + 1;
          if (key === 'getImageData' && hooks && hooks.imageData) {
            return hooks.imageData.apply(null, arguments);
          }
          return undefined;
        }),
      set: (target, key, value) => {
        target[key] = value;
        if (key === 'strokeStyle') painted.colours[value] = (painted.colours[value] || 0) + 1;
        return true;
      }
    });
  }
  function element(tag) {
    const node = {
      tagName: String(tag).toUpperCase(), children: [], style: {}, dataset: {},
      _classes: new Set(), textContent: '', title: '', value: '', type: '',
      checked: false, disabled: false, placeholder: '', width: 0, height: 0,
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      set innerHTML(v) { this.children.length = 0; },
      get innerHTML() { return ''; },
      appendChild(child) { this.children.push(child); return child; },
      addEventListener(kind, fn) { listeners.push({ node: this, kind: kind, fn: fn }); },
      getContext: () => context(),
      // Its size on the screen, which for a canvas is what its style says --
      // not its drawing size. The page stretches the picture to fit, so a
      // click has to be converted, and this is what makes the tests do it.
      getBoundingClientRect() {
        const w = parseInt(this.style.width, 10);
        const h = parseInt(this.style.height, 10);
        return { left: 0, top: 0, width: w > 0 ? w : this.width, height: h > 0 ? h : this.height };
      },
      focus() {}
    };
    node.classList = {
      add: (c) => node._classes.add(c),
      remove: (c) => node._classes.delete(c),
      contains: (c) => node._classes.has(c)
    };
    return node;
  }
  const byId = { list: element('div'), main: element('div'), dialog: element('div') };
  const document = {
    createElement: element,
    createTextNode: (text) => { const n = element('#text'); n.textContent = text; return n; },
    getElementById: (id) => byId[id] || null
  };
  return { element, byId, document, listeners, painted };
}

function open(game, hooks, adjust) {
  const boot = bootFor(game);
  if (adjust) adjust(boot);
  const dom = fakeDom(hooks);
  const saved = [];
  const shown = [];
  const renamed = [];
  const sandbox = {
    window: {
      addEventListener(kind, fn) { dom.listeners.push({ node: 'window', kind: kind, fn: fn }); }
    },
    document: dom.document,
    console: console,
    // The page waits for the sheet before it draws a piece.
    Image: function () {
      const self = this;
      this.width = 640;
      this.height = 1023;
      Object.defineProperty(this, 'src', {
        set(v) { this._src = v; if (self.onload) self.onload(); },
        get() { return this._src; }
      });
    }
  };
  sandbox.window.templatesHost = {
    boot: boot,
    save: (text) => saved.push(text),
    rename: (templates, rooms) => renamed.push({ templates: templates, rooms: rooms }),
    showRoom: (n) => shown.push(n),
    picked() {},
    onReload() {}
  };
  vm.createContext(sandbox);
  new vm.Script(scriptOf(assemble(boot))).runInContext(sandbox);
  return { dom, saved, shown, renamed, boot };
}

// Every node under one, depth first.
function walk(node, out) {
  out = out || [];
  for (const child of node.children || []) {
    out.push(child);
    walk(child, out);
  }
  return out;
}

function textIn(node) {
  return (node.textContent || '') + walk(node).map((n) => n.textContent || '').join(' ');
}

function clicksOn(dom, node) {
  return dom.listeners.filter((l) => l.node === node && l.kind === 'click');
}

// A button in the main area by its label.
function button(dom, label) {
  return walk(dom.byId.main).find((n) => n.tagName === 'BUTTON' && n.textContent === label);
}

// The Add dialog's tiles, and its buttons by their labels.
function tiles(dom) {
  return walk(dom.byId.dialog).filter((n) => n._classes && n._classes.has('tile'));
}

function dialogButton(dom, label) {
  return walk(dom.byId.dialog).find((n) => n.tagName === 'BUTTON' && n.textContent === label);
}

// The list rows, which are what picks a template.
function rows(dom) {
  return walk(dom.byId.list).filter((n) => n._classes && n._classes.has('row'));
}

// ---------------------------------------------------------------------------

for (const game of GAMES) {
  test(game + ': the page opens and lists every template', () => {
    const { dom, boot } = open(game);
    const want = Object.keys(boot.templates.sceneryTemplates).length +
                 Object.keys(boot.templates.objectTemplates).length;
    assert.strictEqual(rows(dom).length, want);
    assert.ok(/templates/.test(textIn(dom.byId.list)));
  });

  test(game + ': every template can be picked, and draws', () => {
    const { dom, boot } = open(game);
    if (!boot.sheetPng) skip(game + '/sprites.png is not here');
    const names = Object.keys(boot.templates.sceneryTemplates)
      .concat(Object.keys(boot.templates.objectTemplates));
    let drawn = 0;
    for (let i = 0; i < names.length; i++) {
      const row = rows(dom)[i];
      const before = dom.painted.drawImage || 0;
      clicksOn(dom, row).slice(-1)[0].fn({});
      if ((dom.painted.drawImage || 0) > before) drawn++;
      assert.ok(textIn(dom.byId.main).indexOf('index $') >= 0, names[i] + ' opened');
    }
    // Some templates draw nothing of their own -- a spare entry whose graphic
    // is below two is placed by something else -- but nearly all draw.
    assert.ok(drawn > names.length * 0.8, drawn + ' of ' + names.length + ' drew');
  });
}

test('knightlore: a template the code refers to says so before a rename', () => {
  const { dom, boot } = open('knightlore');
  const at = Object.keys(boot.templates.objectTemplates).indexOf('object_guard_ew');
  const row = rows(dom)[Object.keys(boot.templates.sceneryTemplates).length + at];
  clicksOn(dom, row).slice(-1)[0].fn({});
  assert.ok(/FG_GUARD_EW/.test(textIn(dom.byId.main)), 'warns about the label');
  assert.ok(/movers\.s/.test(textIn(dom.byId.main)), 'and says where');
});

test('knightlore: a click on the picture picks the piece under it', () => {
  const { dom } = open('knightlore');

  // Each click re-renders, and a real page lays the new picture out the same
  // size as the old; the fake one has to be told. So every click sizes the
  // picture that is showing NOW -- an awkward size, so the stretch is by no
  // whole number -- and aims at it as it is on the screen.
  function clickAt(fx, fy) {
    const stage = walk(dom.byId.main).find((n) => n._classes && n._classes.has('stage'));
    const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
    stage.clientWidth = 613;
    stage.clientHeight = 401;
    for (const l of dom.listeners) if (l.node === 'window' && l.kind === 'resize') l.fn({});
    const shown = canvas.getBoundingClientRect();
    assert.ok(shown.width !== canvas.width, 'shown at a different size than drawn');
    const press = dom.listeners.filter((l) => l.node === canvas && l.kind === 'mousedown')
      .slice(-1)[0];
    press.fn({ clientX: shown.width * fx, clientY: shown.height * fy, preventDefault() {} });
    up(dom);
    const rows = walk(dom.byId.main).filter((n) => n.tagName === 'TR');
    const picked = rows.filter((n) => n._classes.has('on'));
    return picked.length === 1 ? rows.indexOf(picked[0]) : -1;
  }

  // scenery_arch_n is two pieces side by side: the left one is piece 1, the
  // right one piece 0. The picture has a margin, so aim inside each.
  assert.strictEqual(clickAt(0.65, 0.45), 0, 'the right half is piece 0');
  assert.strictEqual(clickAt(0.3, 0.45), 1, 'the left half is piece 1');
  assert.strictEqual(clickAt(0.65, 0.45), 0, 'and back again');
});

// Each thing the panel does has to come back as a castle that still parses,
// round-trips through the build's own layout, and has the change in it.
// What the panel saves is templates.json, whole.
function lastSaved(saved) {
  assert.ok(saved.length, 'nothing was saved');
  const text = saved[saved.length - 1];
  const templates = m.parseTemplates(text);
  const castle = m.withTemplates({ meta: {}, roomDimensions: {}, rooms: [] }, templates);
  assert.strictEqual(m.serializeTemplates(castle, m.eolOf(text)), text,
                     'the saved file is not in the generator’s layout');
  return templates;
}

test('knightlore: New, Add, Duplicate and Delete come back as a castle', () => {
  const { dom, saved } = open('knightlore');

  // New, from the scenery adder in the list.
  const adders = walk(dom.byId.list).filter((n) => n.tagName === 'INPUT');
  adders[0].value = 'my_wall';
  const newButton = walk(dom.byId.list).filter((n) => n.textContent === 'New')[0];
  clicksOn(dom, newButton)[0].fn({});
  let atlas = lastSaved(saved);
  assert.deepStrictEqual(atlas.sceneryTemplates.my_wall, []);
  assert.strictEqual(Object.keys(atlas.sceneryTemplates).slice(-1)[0], 'my_wall',
                     'on the end of the table');

  // Add a piece to it: Add... opens the graphics as pictures, a click picks
  // one, and nothing is saved until the dialog's Add.
  const before = saved.length;
  clicksOn(dom, button(dom, 'Add…')).slice(-1)[0].fn({});
  assert.strictEqual(dom.byId.dialog.style.display, 'flex', 'Add… opened nothing');
  const tile = tiles(dom).find((t) => /^wall\.castle\.1 /.test(t.title));
  assert.ok(tile, 'wall.castle.1 is not in the picker');
  clicksOn(dom, tile).slice(-1)[0].fn({});
  assert.strictEqual(saved.length, before, 'picking is not yet adding');
  clicksOn(dom, dialogButton(dom, 'Add')).slice(-1)[0].fn({});
  assert.strictEqual(dom.byId.dialog.style.display, 'none', 'the dialog stayed open');
  atlas = lastSaved(saved);
  assert.strictEqual(atlas.sceneryTemplates.my_wall.length, 1);
  assert.strictEqual(atlas.sceneryTemplates.my_wall[0].graphic, 'wall.castle.1');

  // Duplicate it.
  const copyAs = walk(dom.byId.main).find((n) => n.placeholder === 'copy as…');
  copyAs.value = 'my_wall_2';
  clicksOn(dom, button(dom, 'Duplicate')).slice(-1)[0].fn({});
  atlas = lastSaved(saved);
  assert.deepStrictEqual(atlas.sceneryTemplates.my_wall_2, atlas.sceneryTemplates.my_wall);

  // The copy is last and unused, so it can go; nothing else moves.
  const del = button(dom, 'Delete');
  assert.strictEqual(del.disabled, false, del.title);
  clicksOn(dom, del).slice(-1)[0].fn({});
  atlas = lastSaved(saved);
  assert.strictEqual(atlas.sceneryTemplates.my_wall_2, undefined);
  assert.ok(atlas.sceneryTemplates.my_wall, 'the other one stayed');
});

test('the Add dialog filters the graphics by name, and a double click adds one', () => {
  const { dom, saved, boot } = open('knightlore');
  pickTemplate(dom, boot, 'sceneryTemplates', 'scenery_arch_n');
  clicksOn(dom, button(dom, 'Add…')).slice(-1)[0].fn({});
  const all = tiles(dom).length;
  assert.strictEqual(all, m.graphicNumbers(boot.sheet, boot.graphics).size,
                     'one tile a graphic that draws something');
  const filter = walk(dom.byId.dialog).find((n) => n.placeholder === 'Filter by name…');
  filter.value = 'DOOR.FOREST';
  dom.listeners.filter((l) => l.node === filter && l.kind === 'input')[0].fn({});
  assert.deepStrictEqual(tiles(dom).map((t) => t.title.split(' ')[0]),
                         ['door.forest.1', 'door.forest.2'], 'the filter ignores case');
  const was = boot.templates.sceneryTemplates.scenery_arch_n.length;
  dom.listeners.filter((l) => l.node === tiles(dom)[1] && l.kind === 'dblclick')[0].fn({});
  const atlas = lastSaved(saved);
  assert.strictEqual(atlas.sceneryTemplates.scenery_arch_n.length, was + 1);
  assert.strictEqual(atlas.sceneryTemplates.scenery_arch_n[was].graphic, 'door.forest.2');
});

test('lightkeep: a piece from another sheet is drawn, and offered to add', () => {
  const { dom, boot } = open('lightkeep');
  if (!boot.otherPngs.doors) skip('lightkeep/art/melkhior/doors.png has not been converted here');
  // A Melkhior doorway is all three of its pieces from the doors sheet: with
  // only the game's own picture it drew none of them.
  const before = dom.painted.drawImage || 0;
  pickTemplate(dom, boot, 'sceneryTemplates', 'scenery_melkhior_door_n');
  assert.ok((dom.painted.drawImage || 0) - before >= 3, 'the doorway drew nothing');
  clicksOn(dom, button(dom, 'Add…')).slice(-1)[0].fn({});
  const door = tiles(dom).find((t) => /^doors\.DoorTop1\.0 /.test(t.title));
  assert.ok(door, 'the lintel is not offered');
  const art = walk(door).find((n) => n._classes && n._classes.has('art'));
  assert.ok(art && art._classes.has('sheet-doors'), 'not drawn from the doors sheet');
});

test('knightlore: a template rooms use cannot be deleted, and says why', () => {
  const { dom } = open('knightlore');
  const del = button(dom, 'Delete');
  assert.strictEqual(del.disabled, true);
  assert.ok(/places it/.test(del.title), del.title);
});

test('knightlore: a room it is placed in shows that room in the designer', () => {
  const { dom, shown } = open('knightlore');
  const go = walk(dom.byId.main).find((n) => n.tagName === 'BUTTON' && n.textContent === '$00');
  assert.ok(go, 'scenery_arch_n is placed in room $00');
  clicksOn(dom, go)[0].fn({});
  assert.deepStrictEqual(shown, [0]);
});

// --- moving a piece -------------------------------------------------------

function on(dom, kind) {
  return dom.listeners.filter((l) => l.node === 'window' && l.kind === kind);
}

function key(dom, name, mods) {
  const event = Object.assign({ key: name, target: { tagName: 'CANVAS' },
                                preventDefault() {} }, mods || {});
  for (const l of on(dom, 'keydown')) l.fn(event);
}

function up(dom) {
  for (const l of on(dom, 'mouseup')) l.fn({});
}

// Pick a template by name from the list.
function pickTemplate(dom, boot, group, name) {
  const scenery = Object.keys(boot.templates.sceneryTemplates);
  const at = group === 'sceneryTemplates' ? scenery.indexOf(name)
    : scenery.length + Object.keys(boot.templates.objectTemplates).indexOf(name);
  clicksOn(dom, rows(dom)[at]).slice(-1)[0].fn({});
}

test('knightlore: the arrows move a scenery piece, Ctrl lifts it, Shift goes further', () => {
  const { dom, saved, boot } = open('knightlore');
  const was = boot.templates.sceneryTemplates.scenery_arch_n[0];
  const start = { u: was.u, v: was.v, z: was.z };

  key(dom, 'ArrowRight');
  let piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.u, start.u + 1);

  key(dom, 'ArrowUp');
  piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.v, start.v + 1);
  assert.strictEqual(piece.z, start.z, 'a plain arrow does not lift');

  key(dom, 'ArrowUp', { ctrlKey: true });
  piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.z, start.z + 1, 'Ctrl+Up lifts');
  assert.strictEqual(piece.v, start.v + 1, '...and does not also move along V');

  key(dom, 'ArrowDown', { ctrlKey: true, shiftKey: true });
  piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.z, start.z + 1 - 8, 'Shift makes it eight');

  key(dom, ']');
  piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.z, start.z + 1 - 8 + 1, '] lifts too');
});

test('knightlore: the arrows move an object piece by its nudge', () => {
  const { dom, saved, boot } = open('knightlore');
  pickTemplate(dom, boot, 'objectTemplates', 'object_block');
  key(dom, 'ArrowRight');
  let piece = lastSaved(saved).objectTemplates.object_block[0];
  assert.strictEqual(piece.offsets.halfU, true, 'half a cell along U');
  key(dom, 'ArrowUp', { ctrlKey: true });
  piece = lastSaved(saved).objectTemplates.object_block[0];
  assert.strictEqual(piece.offsets.raiseZ, 4, 'a lift of four');
  key(dom, 'ArrowUp', { ctrlKey: true, shiftKey: true });
  piece = lastSaved(saved).objectTemplates.object_block[0];
  assert.strictEqual(piece.offsets.raiseZ, 4 + 12, 'Shift lifts a whole level');
});

test('knightlore: a key in a text field is left to the field', () => {
  const { dom, saved } = open('knightlore');
  key(dom, 'ArrowRight', { target: { tagName: 'INPUT' } });
  assert.strictEqual(saved.length, 0);
});

test('knightlore: Delete removes the selected piece', () => {
  const { dom, saved } = open('knightlore');
  key(dom, 'Delete');
  assert.strictEqual(lastSaved(saved).sceneryTemplates.scenery_arch_n.length, 1);
});

test('knightlore: a drag moves the piece, and saves once when it is let go', () => {
  const { dom, saved, boot } = open('knightlore');
  const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
  const press = dom.listeners.filter((l) => l.node === canvas && l.kind === 'mousedown')
    .slice(-1)[0];
  const start = boot.templates.sceneryTemplates.scenery_arch_n[0];
  const was = { u: start.u, v: start.v, z: start.z };

  // Pick up the right half -- piece 0 -- and drag it twenty screen pixels
  // right, in three moves.
  const x = canvas.width * 0.65;
  const y = canvas.height * 0.45;
  press.fn({ clientX: x, clientY: y, preventDefault() {} });
  for (const step of [6, 13, 20]) {
    for (const l of on(dom, 'mousemove')) l.fn({ clientX: x + step, clientY: y });
  }
  assert.strictEqual(saved.length, 0, 'nothing saved while it is held');
  up(dom);
  assert.strictEqual(saved.length, 1, 'one save for the whole drag');

  // Twenty canvas pixels at the picture's scale is 20 / scale world-pixels
  // across, which is that many units of U + V, split evenly.
  const piece = lastSaved(saved).sceneryTemplates.scenery_arch_n[0];
  assert.strictEqual(piece.z, was.z, 'a drag keeps its height');
  assert.ok((piece.u - was.u) + (piece.v - was.v) > 0, 'it moved right');
  assert.ok(Math.abs((piece.u - was.u) - (piece.v - was.v)) <= 1, 'straight across');
});

// --- the bar between the picture and the pieces -----------------------------

function byClass(dom, name) {
  return walk(dom.byId.main).find((n) => n._classes && n._classes.has(name));
}

test('knightlore: the bar sets how tall the picture pane is', () => {
  const { dom } = open('knightlore');
  const top = byClass(dom, 'top');
  const bar = byClass(dom, 'split');
  assert.ok(top && bar, 'two panes and a bar');
  assert.ok(byClass(dom, 'bottom'), 'and the pieces in a pane of their own');
  const was = parseInt(top.style.height, 10);

  const press = dom.listeners.filter((l) => l.node === bar && l.kind === 'mousedown')[0];
  press.fn({ clientY: 500, preventDefault() {} });
  for (const l of on(dom, 'mousemove')) l.fn({ clientX: 0, clientY: 600 });
  up(dom);
  assert.strictEqual(parseInt(top.style.height, 10), was + 100, 'dragged down 100');

  // ...and never so small the picture is lost.
  press.fn({ clientY: 600, preventDefault() {} });
  for (const l of on(dom, 'mousemove')) l.fn({ clientX: 0, clientY: -5000 });
  up(dom);
  assert.strictEqual(parseInt(top.style.height, 10), 160);
});

test('knightlore: the picture fills its pane exactly, not in whole steps', () => {
  const { dom } = open('knightlore');
  const stage = byClass(dom, 'stage');
  const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
  const px = (v) => parseInt(v, 10);

  // Sizes chosen so a whole-step fit would leave a lot of the pane empty.
  for (const [w, h] of [[1000, 700], [1337, 555], [613, 401]]) {
    stage.clientWidth = w;
    stage.clientHeight = h;
    for (const l of on(dom, 'resize')) l.fn({});
    const shownW = px(canvas.style.width);
    const shownH = px(canvas.style.height);
    // It fits inside the pane...
    assert.ok(shownW <= w && shownH <= h, shownW + 'x' + shownH + ' in ' + w + 'x' + h);
    // ...and fills it along one side, to within the margin the stage keeps.
    assert.ok(w - shownW <= 10 || h - shownH <= 10,
              shownW + 'x' + shownH + ' does not fill ' + w + 'x' + h);
    // Drawn at a whole scale at least as big as it is shown, so nothing blurs.
    assert.ok(canvas.width >= shownW && canvas.height >= shownH);
  }
});

test('knightlore: the pane size is kept when another template is picked', () => {
  const { dom, boot } = open('knightlore');
  const bar = byClass(dom, 'split');
  const press = dom.listeners.filter((l) => l.node === bar && l.kind === 'mousedown')[0];
  press.fn({ clientY: 500, preventDefault() {} });
  for (const l of on(dom, 'mousemove')) l.fn({ clientX: 0, clientY: 560 });
  up(dom);
  const set = byClass(dom, 'top').style.height;
  pickTemplate(dom, boot, 'objectTemplates', 'object_block');
  assert.strictEqual(byClass(dom, 'top').style.height, set);
});

// --- showing a template in its rooms ------------------------------------------

function showSelect(dom) {
  return walk(dom.byId.main).find((n) => n.tagName === 'SELECT' &&
    walk(n).some((o) => o.value === 'alone'));
}

function show(dom, value) {
  const choice = showSelect(dom);
  choice.value = value;
  dom.listeners.filter((l) => l.node === choice && l.kind === 'change')[0].fn({});
}

test('knightlore: the picture can be shown on each floor and in each room placing it', () => {
  const { dom, boot } = open('knightlore');
  const values = walk(showSelect(dom)).map((o) => o.value).filter(Boolean);
  assert.ok(values.indexOf('alone') >= 0);
  for (const shape of Object.keys(boot.rooms.roomDimensions)) {
    assert.ok(values.indexOf('shape:' + shape) >= 0, 'offers the ' + shape + ' floor');
  }
  // Every room that places scenery_arch_n, and no other.
  const placing = boot.rooms.rooms.filter((r) =>
    r.scenery.some((s) => s.template === 'scenery_arch_n')).map((r) => 'room:' + r.number);
  const offered = values.filter((v) => v.indexOf('room:') === 0);
  assert.deepStrictEqual(offered, placing);
});

test('knightlore: on a floor, the floor is drawn under it', () => {
  const { dom } = open('knightlore');
  const before = dom.painted.stroke || 0;
  show(dom, 'alone');
  const alone = (dom.painted.stroke || 0) - before;
  show(dom, 'shape:narrowU');
  const floored = (dom.painted.stroke || 0) - before - alone;
  // A narrow room is 32 cells and its edge; the selection outline is strokeRect.
  assert.ok(floored >= 33, floored + ' strokes for a narrow floor');
});

test('knightlore: in a room, the rest of it is drawn too, but only the template can be picked', () => {
  const { dom, boot } = open('knightlore');
  const before = dom.painted.drawImage || 0;
  show(dom, 'alone');
  const alone = (dom.painted.drawImage || 0) - before;
  const room = boot.rooms.rooms.find((r) =>
    r.scenery.some((s) => s.template === 'scenery_arch_n'));
  show(dom, 'room:' + room.number);
  const whole = (dom.painted.drawImage || 0) - before - alone;
  assert.ok(whole > alone * 3, 'room $' + room.number.toString(16) + ' drew ' + whole +
            ' sprites against ' + alone + ' on its own');

  // Clicking anywhere on the picture picks a piece of THIS template or nothing:
  // the rest of the room is there to be seen against, not edited.
  const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
  const press = dom.listeners.filter((l) => l.node === canvas && l.kind === 'mousedown')
    .slice(-1)[0];
  const box = canvas.getBoundingClientRect();
  let hits = 0;
  for (let fx = 0.025; fx < 1; fx += 0.05) {
    for (let fy = 0.025; fy < 1; fy += 0.05) {
      press.fn({ clientX: box.width * fx, clientY: box.height * fy, preventDefault() {} });
      up(dom);
      // Whatever was under the pointer, what is selected is one of the arch's
      // own two pieces: a wall stone of another template would have picked a
      // piece number the arch has not got, and no row would be lit.
      const rows = walk(dom.byId.main).filter((n) => n.tagName === 'TR');
      const lit = rows.filter((n) => n._classes.has('on'));
      assert.strictEqual(rows.length, 2);
      assert.strictEqual(lit.length, 1, 'at ' + fx.toFixed(2) + ',' + fy.toFixed(2));
      hits++;
    }
  }
  assert.ok(hits > 300);
});

test('knightlore: the room shown follows the template picked, where it can', () => {
  const { dom, boot } = open('knightlore');
  const room = boot.rooms.rooms.find((r) =>
    r.scenery.some((s) => s.template === 'scenery_arch_n') &&
    r.scenery.some((s) => s.template === 'scenery_arch_e'));
  show(dom, 'room:' + room.number);
  // A template that room also places: the room stays.
  pickTemplate(dom, boot, 'sceneryTemplates', 'scenery_arch_e');
  assert.strictEqual(showSelect(dom).value, 'room:' + room.number);
  // One it does not: the first room that does.
  pickTemplate(dom, boot, 'objectTemplates', 'object_guard_ew');
  assert.ok(/^room:/.test(showSelect(dom).value), showSelect(dom).value);
  assert.notStrictEqual(showSelect(dom).value, 'room:' + room.number);
});

test('knightlore: a rename changes templates.json and rooms.json together', () => {
  // Rooms name the templates they place, so a rename that reached only one file
  // would leave rooms naming a template that no longer exists.
  const { dom, saved, renamed, boot } = open('knightlore');
  const before = boot.rooms.rooms.filter((r) =>
    r.scenery.some((s) => s.template === 'scenery_arch_n')).length;
  const field = walk(dom.byId.main).find((n) => n.tagName === 'INPUT' &&
                                               n.value === 'scenery_arch_n');
  field.value = 'north_door';
  clicksOn(dom, button(dom, 'Rename')).slice(-1)[0].fn({});

  assert.strictEqual(saved.length, 0, 'not saved as templates.json alone');
  assert.strictEqual(renamed.length, 1);
  const templates = m.parseTemplates(renamed[0].templates);
  const rooms = m.parseAtlas(renamed[0].rooms);
  assert.ok(templates.sceneryTemplates.north_door);
  assert.strictEqual(templates.sceneryTemplates.scenery_arch_n, undefined);
  assert.strictEqual(Object.keys(templates.sceneryTemplates)[0], 'north_door',
                     'and kept its place in the table');

  // Every room that placed it now names it by the new name, and none by the old.
  const after = rooms.rooms.filter((r) =>
    r.scenery.some((s) => s.template === 'north_door')).length;
  assert.ok(before > 5);
  assert.strictEqual(after, before);
  assert.ok(!/scenery_arch_n"/.test(renamed[0].rooms));
  // ...and rooms.json is still in the build's own layout.
  assert.strictEqual(m.serializeAtlas(m.withTemplates(rooms, templates),
                                      m.eolOf(renamed[0].rooms)), renamed[0].rooms);
});


test('knightlore: a piece lifted off the top of the screen says the game wraps it', () => {
  const { dom, saved } = open('knightlore');
  // scenery_arch_n's first leaf, lifted eight at a time until its base is
  // above row 0: (196 - 141 + 128) / 2 + Z is past 296 from Z 206 on.
  assert.ok(!/of the screen: the game draws it wrapped/.test(textIn(dom.byId.main)), 'not before');
  for (let i = 0; i < 12; i++) key(dom, ']', { shiftKey: true });
  assert.ok(lastSaved(saved).sceneryTemplates.scenery_arch_n[0].z >= 220);
  assert.ok(/piece 0 is above the top of the screen/.test(textIn(dom.byId.main)), 'warned');
  for (let i = 0; i < 12; i++) key(dom, '[', { shiftKey: true });
  assert.ok(!/of the screen: the game draws it wrapped/.test(textIn(dom.byId.main)), 'and not once it is back');
});

// --- a piece's box ---------------------------------------------------------

// Lightkeep's `solid` is sixteen pixels by one, every one of them clear. The
// fake canvas reads that sprite as blank and every other as drawn.
const SOLID_BLANK = {
  imageData: (x, y, w, h) => ({
    data: new Uint8ClampedArray(w * h * 4).fill(w === 16 && h === 1 ? 0 : 255)
  })
};

// The row of the pieces table for piece `at`, and an input in its box by axis.
function pieceRow(dom, at) {
  return walk(dom.byId.main).filter((n) => n.tagName === 'TR')[at];
}

function boxInput(dom, at, axis) {
  const span = walk(pieceRow(dom, at)).find((n) => n._classes && n._classes.has('boxsize'));
  assert.ok(span, 'piece ' + at + ' shows no box of its own');
  const label = walk(span).find((n) => n.tagName === 'LABEL' && n.textContent === axis);
  return label.children.find((n) => n.tagName === 'INPUT');
}

function rowButton(dom, at, label) {
  return walk(pieceRow(dom, at)).find((n) => n.tagName === 'BUTTON' && n.textContent === label);
}

function change(dom, input, value) {
  input.value = String(value);
  for (const l of dom.listeners) if (l.node === input && l.kind === 'change') l.fn({});
}

function raised(hooks) {
  const opened = open('lightkeep', hooks);
  if (!opened.boot.templates.sceneryTemplates.scenery_raised_w) {
    skip('lightkeep has no scenery_raised_w');
  }
  pickTemplate(opened.dom, opened.boot, 'sceneryTemplates', 'scenery_raised_w');
  return opened;
}

test('lightkeep: a piece\u2019s own box is edited in its three fields', () => {
  const { dom, saved, boot } = raised(SOLID_BLANK);
  // Whatever the file says now: the fields start from it.
  const was = boot.templates.sceneryTemplates.scenery_raised_w[0];
  assert.strictEqual(Number(boxInput(dom, 0, 'v').value), was.sizeV);
  change(dom, boxInput(dom, 0, 'v'), 70);
  let solid = lastSaved(saved).sceneryTemplates.scenery_raised_w[0];
  assert.deepStrictEqual([solid.sizeU, solid.sizeV, solid.sizeZ], [was.sizeU, 70, was.sizeZ]);
  change(dom, boxInput(dom, 0, 'z'), 300);
  solid = lastSaved(saved).sceneryTemplates.scenery_raised_w[0];
  assert.strictEqual(solid.sizeZ, 127, 'no taller than the graphic\u2019s ninth bit leaves room for');
});

test('lightkeep: a box of its own is dropped, and given again from the graphic\u2019s', () => {
  const { dom, saved, boot } = raised(SOLID_BLANK);
  clicksOn(dom, rowButton(dom, 0, 'graphic\u2019s box')).slice(-1)[0].fn({});
  let solid = lastSaved(saved).sceneryTemplates.scenery_raised_w[0];
  assert.ok(!('sizeU' in solid), 'the graphic\u2019s box again');
  // ...which is what graphics.json gives `solid`, and where a box of its own
  // starts from. A wall stone's comes the same way, flat along U.
  clicksOn(dom, rowButton(dom, 0, 'own box')).slice(-1)[0].fn({});
  solid = lastSaved(saved).sceneryTemplates.scenery_raised_w[0];
  const said = boot.graphics.graphics.solid.size;
  assert.deepStrictEqual([solid.sizeU, solid.sizeV, solid.sizeZ], [said.u, said.v, said.z]);
  clicksOn(dom, rowButton(dom, 1, 'own box')).slice(-1)[0].fn({});
  const stone = lastSaved(saved).sceneryTemplates.scenery_raised_w[1];
  const wall = boot.graphics.graphics[stone.graphic].size;
  assert.deepStrictEqual([stone.sizeU, stone.sizeV, stone.sizeZ], [wall.u, wall.v, wall.z]);
});

test('lightkeep: an invisible piece is picked by a click on its box', () => {
  const { dom, boot } = raised(SOLID_BLANK);
  if (!boot.sheetPng) skip('lightkeep/art/sprites.png is not here');
  // A sweep of clicks over the picture, each starting from piece 1 picked.
  // The invisible piece's sprite is one row of sixteen pixels, which a sweep
  // this coarse would hardly ever land on; its box covers much of the picture.
  let hits = 0;
  let tries = 0;
  for (let fy = 0.05; fy < 1; fy += 0.1) {
    for (let fx = 0.05; fx < 1; fx += 0.1) {
      clicksOn(dom, pieceRow(dom, 1)).slice(-1)[0].fn({ target: { tagName: 'TD' } });
      const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
      const shown = canvas.getBoundingClientRect();
      const press = dom.listeners.filter((l) => l.node === canvas && l.kind === 'mousedown')
        .slice(-1)[0];
      press.fn({ clientX: shown.width * fx, clientY: shown.height * fy, preventDefault() {} });
      up(dom);
      tries++;
      if (pieceRow(dom, 0)._classes.has('on')) hits++;
    }
  }
  assert.ok(hits > tries / 10, 'its box was picked ' + hits + ' times in ' + tries);
});

test('lightkeep: without a blank sprite, the same sweep hardly finds it', () => {
  // The other side of the test above: read as drawn, the piece is its
  // sixteen-by-one sprite, and the sweep's picks come from its box or not at all.
  const { dom, boot } = raised();
  if (!boot.sheetPng) skip('lightkeep/art/sprites.png is not here');
  let hits = 0;
  let tries = 0;
  for (let fy = 0.05; fy < 1; fy += 0.1) {
    for (let fx = 0.05; fx < 1; fx += 0.1) {
      clicksOn(dom, pieceRow(dom, 1)).slice(-1)[0].fn({ target: { tagName: 'TD' } });
      const canvas = walk(dom.byId.main).find((n) => n.tagName === 'CANVAS');
      const shown = canvas.getBoundingClientRect();
      const press = dom.listeners.filter((l) => l.node === canvas && l.kind === 'mousedown')
        .slice(-1)[0];
      press.fn({ clientX: shown.width * fx, clientY: shown.height * fy, preventDefault() {} });
      up(dom);
      tries++;
      if (pieceRow(dom, 0)._classes.has('on')) hits++;
    }
  }
  assert.ok(hits <= tries / 20, 'its sprite was picked ' + hits + ' times in ' + tries);
});

test('lightkeep: the selected piece is drawn with its box, its footing and its riser', () => {
  const { dom, boot } = raised(SOLID_BLANK);
  if (!boot.sheetPng) skip('lightkeep/art/sprites.png is not here');
  // One picture as it stands, on the floor...
  let before = Object.assign({}, dom.painted);
  clicksOn(dom, pieceRow(dom, 0)).slice(-1)[0].fn({ target: { tagName: 'TD' } });
  const drew = (k) => (dom.painted[k] || 0) - (before[k] || 0);
  assert.ok(drew('fill') >= 1, 'the footing is filled');
  // Twelve edges of its box and the footing's four sides, less the first
  // point of each.
  assert.ok(drew('lineTo') >= 12 + 3, 'drew ' + drew('lineTo') + ' lines');
  assert.ok(drew('setLineDash') >= 1, 'its hidden edges dashed');
  const standing = drew('fillRect');
  // ...and one lifted a unit, with the riser up to it: one more rectangle.
  before = Object.assign({}, dom.painted);
  key(dom, ']');
  assert.strictEqual(drew('fillRect'), standing + 1, 'the riser');
});

// The guides that cross on the floor at the selected piece's place.
const GUIDE = 'rgba(255,200,80,.85)';

test('lightkeep: on a floor, guide lines cross at the selected piece’s place', () => {
  const { dom } = raised(SOLID_BLANK);
  const guides = () => dom.painted.colours[GUIDE] || 0;
  // On its own there is no floor to draw them on...
  const alone = guides();
  clicksOn(dom, pieceRow(dom, 4)).slice(-1)[0].fn({ target: { tagName: 'TD' } });
  assert.strictEqual(guides(), alone, 'none on its own');
  // ...and on a floor, or in a room, every picture has them.
  show(dom, 'shape:square');
  const onFloor = guides();
  assert.ok(onFloor > alone, 'on the square floor');
  clicksOn(dom, pieceRow(dom, 4)).slice(-1)[0].fn({ target: { tagName: 'TD' } });
  assert.strictEqual(guides(), onFloor + 1, 'one set a picture');
});


// --- how an object template moves ----------------------------------------

function moverRow(dom) {
  return walk(dom.byId.main).find((n) => n._classes && n._classes.has('mover'));
}

function lightkeepWithBehaviours() {
  const opened = open('lightkeep', null, (boot) => {
    boot.behaviours = require('../behaviours').behavioursOf(path.join(FILMATION, 'lightkeep'));
  });
  if (!opened.boot.templates.meta.movers) skip('lightkeep/templates.json says nothing of its movers');
  if (!opened.boot.behaviours) skip('lightkeep/movers.s is not here');
  pickTemplate(opened.dom, opened.boot, 'objectTemplates', 'object_table');
  return opened;
}

test('lightkeep: an object template says how it moves, and the list is the game\u2019s', () => {
  const { dom, boot } = lightkeepWithBehaviours();
  const row = moverRow(dom);
  assert.ok(row, 'a moves row');
  const choice = walk(row).find((n) => n.tagName === 'SELECT');
  assert.strictEqual(choice.value, 'MOVE_PUSHED');
  const offered = walk(choice).filter((n) => n.tagName === 'OPTION').map((n) => n.value);
  assert.strictEqual(offered[0], '', 'standing still first');
  assert.deepStrictEqual(offered.slice(1), boot.behaviours.list.map((x) => x.name));
  // A table can be pushed, so it has a weight to set.
  const weight = walk(row).find((n) => n.tagName === 'INPUT');
  assert.strictEqual(weight.disabled, false);
});

test('lightkeep: the weight and the behaviour are saved in meta.movers', () => {
  const { dom, saved } = lightkeepWithBehaviours();
  change(dom, walk(moverRow(dom)).find((n) => n.tagName === 'INPUT'), 2);
  assert.deepStrictEqual(lastSaved(saved).meta.movers.object_table, { behaviour: 'MOVE_PUSHED', weight: 2 });
  change(dom, walk(moverRow(dom)).find((n) => n.tagName === 'SELECT'), 'MOVE_SLIDING');
  assert.deepStrictEqual(lastSaved(saved).meta.movers.object_table, { behaviour: 'MOVE_SLIDING', weight: 2 });
  change(dom, walk(moverRow(dom)).find((n) => n.tagName === 'SELECT'), '');
  assert.ok(!('object_table' in lastSaved(saved).meta.movers), 'standing still: no entry');
});

test('lightkeep: something pushed weighs 1 or more, and nothing else weighs anything', () => {
  const { dom, saved } = lightkeepWithBehaviours();
  const weight = () => walk(moverRow(dom)).find((n) => n.tagName === 'INPUT');
  const choice = () => walk(moverRow(dom)).find((n) => n.tagName === 'SELECT');
  assert.strictEqual(Number(weight().value), 1, 'the table weighs 1');
  // Nought is not a weight: the lightest is 1.
  change(dom, weight(), 0);
  assert.strictEqual(lastSaved(saved).meta.movers.object_table.weight, 1);
  // Something that cannot be pushed has none...
  change(dom, choice(), 'MOVE_GHOST');
  assert.deepStrictEqual(lastSaved(saved).meta.movers.object_table, { behaviour: 'MOVE_GHOST' });
  // ...and something that can starts at 1.
  change(dom, choice(), 'MOVE_CARRIED');
  assert.deepStrictEqual(lastSaved(saved).meta.movers.object_table, { behaviour: 'MOVE_CARRIED', weight: 1 });
});

test('lightkeep: something that cannot be pushed has no weight to set', () => {
  const { dom, boot } = lightkeepWithBehaviours();
  pickTemplate(dom, boot, 'objectTemplates', 'object_ghost');
  assert.strictEqual(walk(moverRow(dom)).find((n) => n.tagName === 'INPUT').disabled, true);
});

test('knightlore: a castle whose code keeps its movers has no moves row', () => {
  const { dom, boot } = open('knightlore');
  pickTemplate(dom, boot, 'objectTemplates', 'object_table');
  assert.strictEqual(moverRow(dom), undefined);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
