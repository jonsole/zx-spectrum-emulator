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

function bootFor(game) {
  const here = path.join(FILMATION, game);
  const rooms = path.join(here, 'rooms.json');
  const templates = path.join(here, 'templates.json');
  if (!fs.existsSync(rooms)) skip(game + '/rooms.json is not here');
  if (!fs.existsSync(templates)) skip(game + '/templates.json is not here');
  const text = fs.readFileSync(rooms, 'utf8');
  const templatesText = fs.readFileSync(templates, 'utf8');
  const read = (name) => {
    const file = path.join(here, name);
    return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  };
  const png = path.join(here, 'sprites.png');
  // What templates_view.js sends: the document, templates.json, and the
  // rooms beside it.
  return {
    templates: JSON.parse(templatesText),
    rooms: JSON.parse(text),
    eol: templatesText.indexOf('\r\n') >= 0 ? '\r\n' : '\n',
    roomsEol: text.indexOf('\r\n') >= 0 ? '\r\n' : '\n',
    sheet: read('sprites.json'),
    graphics: read('graphics.json'),
    sheetPng: fs.existsSync(png)
      ? 'data:image/png;base64,' + fs.readFileSync(png).toString('base64') : null,
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
function fakeDom() {
  const listeners = [];
  const painted = {};
  function context() {
    return new Proxy({}, {
      get: (target, key) => (key in target ? target[key]
        : function () { painted[key] = (painted[key] || 0) + 1; }),
      set: (target, key, value) => { target[key] = value; return true; }
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
  const byId = { list: element('div'), main: element('div') };
  const document = {
    createElement: element,
    createTextNode: (text) => { const n = element('#text'); n.textContent = text; return n; },
    getElementById: (id) => byId[id] || null
  };
  return { element, byId, document, listeners, painted };
}

function open(game) {
  const boot = bootFor(game);
  const dom = fakeDom();
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

  // Add a piece to it.
  clicksOn(dom, button(dom, 'Add piece')).slice(-1)[0].fn({});
  atlas = lastSaved(saved);
  assert.strictEqual(atlas.sceneryTemplates.my_wall.length, 1);

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

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
