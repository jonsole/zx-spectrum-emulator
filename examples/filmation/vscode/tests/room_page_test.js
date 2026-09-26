// The room designer's page as its two hosts assemble it.
//
//   node examples/filmation/vscode/tests/room_page_test.js
//
// room_view.js cannot be required here -- it opens with require('vscode') --
// so this does what both hosts do to the page and checks the result. The point
// is the seam: the page is built by string replacement, so a mistake in it is
// not a syntax error in any file on disk, it is one in a file that exists only
// at runtime, and the panel opens blank with the reason in a console nobody is
// looking at.
//
// It also runs the assembled page against the real castle, far enough to know
// that the collectables reach the picture: they come from a second file and go
// in after everything the room data made, which is the part no model test can
// see.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const EXT = path.join(__dirname, '..');
const GAMES = ['knightlore', 'pentagram', 'knightlore128'];
const FILMATION = path.join(EXT, '..');

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

// The pure files the page inlines, in the order its markers name them.
// sheet_model.js is first because the two after it use what it defines: in the
// page there are no modules, only one script with everything concatenated.
// Both hosts keep this list; if they ever disagree with the page, the marker
// check below is what says so.
const INLINED = ['sheet_model.js', 'room_model.js', 'room_render.js',
                 'specials_model.js'];

function assemble(boot) {
  const bootJs = 'window.roomHost = (function () {\n' +
    '  return { boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    save: function (t, w) { window.__saved = t; window.__what = w; },\n' +
    '    saveSpecials: function (t) { window.__specials = t; },\n' +
    '    onReload: function () {}, roomChanged: function () {},\n' +
    '    build: function () {} };\n' +
    '})();\n';
  let html = fs.readFileSync(path.join(EXT, 'room_view.html'), 'utf8')
    .replace('<script>', '<script nonce="test">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(EXT, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

function bootFor(game, room) {
  const here = path.join(FILMATION, game);
  const rooms = path.join(here, 'rooms.json');
  if (!fs.existsSync(rooms)) skip(game + '/rooms.json is not here');
  const text = fs.readFileSync(rooms, 'utf8');
  const read = (name) => {
    const file = path.join(here, name);
    return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  };
  return {
    atlas: JSON.parse(text),
    // The templates the rooms place, which are a file of their own.
    templates: read('templates.json'),
    eol: text.indexOf('\r\n') >= 0 ? '\r\n' : '\n',
    sheet: read('sprites.json'),
    graphics: read('graphics.json'),
    // The artwork, as the host sends it: a webview cannot read a file of its
    // own, so the picture travels with the page.
    sheetPng: fs.existsSync(path.join(here, 'sprites.png'))
      ? 'data:image/png;base64,' +
        fs.readFileSync(path.join(here, 'sprites.png')).toString('base64')
      : null,
    specials: read('specials.json'),
    room: room === undefined ? null : room,
    showSave: false,
    buildLabel: 'Build ' + game
  };
}

function scriptOf(html) {
  const open = html.indexOf('>', html.indexOf('<script')) + 1;
  const close = html.indexOf('</script>', open);
  assert.ok(open > 0 && close > open, 'no script in the page');
  return html.slice(open, close);
}

test('the page names exactly the files the hosts inline', () => {
  const raw = fs.readFileSync(path.join(EXT, 'room_view.html'), 'utf8');
  const markers = (raw.match(/\/\*@([a-z_.]+)@\*\//g) || [])
    .map((m) => m.slice(3, -3));
  assert.deepStrictEqual(markers, INLINED.concat(['host']));

  // ...and both hosts agree with it, which is the thing that actually breaks:
  // adding a file to the page and to one host leaves the other opening a page
  // whose script refers to something that is not there.
  const editor = fs.readFileSync(path.join(EXT, 'room_view.js'), 'utf8');
  const browser = fs.readFileSync(
    path.join(EXT, 'room_designer.py'), 'utf8');
  for (const name of INLINED) {
    assert.ok(editor.includes("'" + name + "'"),
              'room_view.js does not inline ' + name);
    assert.ok(browser.includes('"' + name + '"'),
              'room_designer.py does not inline ' + name);
  }
});

test('assembling replaces every marker', () => {
  const html = assemble(bootFor('knightlore'));
  assert.ok(!html.includes('/*@'), 'a marker survived assembly');
  assert.ok(html.includes('function expandRoom('), 'room_model was not inlined');
  assert.ok(html.includes('function depthCompare('), 'room_render was not inlined');
  assert.ok(html.includes('function spriteList('), 'sheet_model was not inlined');
  assert.ok(html.includes('function checkSpecials('), 'specials_model was not inlined');
});

test('the assembled script parses', () => {
  new vm.Script(scriptOf(assemble(bootFor('knightlore'))),
                { filename: 'room_view.assembled.js' });
});

// A 2D context that swallows whatever the page draws. Anything it does not
// already answer becomes a no-op function, because this test is about what
// reaches the panel and the host, not about pixels -- enumerating the canvas
// API here would only mean adding to it every time the drawing changed.
// The calls a page made, so a test can ask whether it actually drew the room.
// Everything else is swallowed: the page paints, and a fake that recorded the
// pixels would be a renderer.
function fakeContext(tally) {
  const own = {
    canvas: { width: 256, height: 192 },
    createImageData: (w, h) => ({ data: new Uint8ClampedArray(4 * (w || 1) * (h || 1)),
                                  width: w || 1, height: h || 1 }),
    getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray(4 * (w || 1) * (h || 1)),
                                     width: w || 1, height: h || 1 }),
    measureText: () => ({ width: 0 })
  };
  return new Proxy(own, {
    get: (target, key) => {
      if (key in target) return target[key];
      return function () {
        if (tally) tally[key] = (tally[key] || 0) + 1;
      };
    },
    set: (target, key, value) => { target[key] = value; return true; }
  });
}

// A DOM big enough to open the page against. It records rather than renders:
// the page only creates elements, sets text, appends and listens.
function fakeDom(ids) {
  const listeners = [];
  const painted = {};
  function element(tag) {
    const node = {
      tagName: String(tag).toUpperCase(), children: [], style: {}, dataset: {},
      _classes: new Set(), value: '', textContent: '', title: '', id: '',
      type: '', min: '', max: '', checked: true, disabled: false, _html: '',
      // Setting it empties the node, as a real one does: the page clears a
      // list that way before it renders it again.
      set innerHTML(v) { this._html = v; if (v === '') this.children = []; },
      get innerHTML() { return this._html; },
      width: 256, height: 192,
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      appendChild(child) { this.children.push(child); return child; },
      removeChild() {},
      addEventListener(kind, fn) { listeners.push({ node: this, kind, fn }); },
      removeEventListener() {},
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 256, height: 192 }),
      getContext: () => fakeContext(painted),
      querySelectorAll: () => [],
      focus() {}, remove() {}, closest: () => null,
      setAttribute() {}, removeAttribute() {}, contains: () => false,
      // The page sizes the canvas to what it is sitting in, so a node has to
      // have somewhere to sit.
      clientWidth: 900, clientHeight: 700, parentElement: null
    };
    node.parentElement = {
      clientWidth: 900, clientHeight: 700,
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 900, height: 700 })
    };
    node.classList = {
      add: (c) => node._classes.add(c),
      remove: (c) => node._classes.delete(c),
      toggle: (c, on) => (on ? node._classes.add(c) : node._classes.delete(c)),
      contains: (c) => node._classes.has(c)
    };
    return node;
  }

  const byId = {};
  for (const id of ids) {
    byId[id] = element('div');
    byId[id].id = id;
  }

  // The tab strip, which is in the static HTML this does not parse. The page
  // finds it with querySelectorAll('.tabs button') and hangs a listener on
  // each, so faking it is what lets a test open a tab and see what it renders.
  const tabs = ['objects', 'scenery', 'collectables'].map((name) => {
    const button = element('button');
    button.dataset.tab = name;
    if (name === 'collectables') byId['tab-collectables'] = button;
    return button;
  });

  const document = {
    createElement: element,
    // Text nodes are appended like elements; the page only ever sets their
    // content, so one that records it is enough.
    createTextNode: (what) => {
      const node = element('#text');
      node.textContent = String(what);
      return node;
    },
    getElementById: (id) => byId[id] || null,
    querySelectorAll: (what) => (/\.tabs button/.test(what) ? tabs : []),
    addEventListener() {},
    body: element('body')
  };
  return { element, byId, document, listeners, tabs, painted };
}

const PAGE_IDS = ['title', 'subtitle', 'state', 'save', 'build', 'grid', 'offmap',
                  'addroom', 'exits', 'starts',
                  'mapnote', 'view', 'inks', 'shape', 'showgrid', 'showboxes',
                  'showscenery', 'zoom', 'poolnote', 'checks', 'panel',
                  'game', 'load', 'undo', 'redo', 'tab-collectables'];

function open(boot) {
  const dom = fakeDom(PAGE_IDS);
  const sandbox = {
    window: {
      addEventListener() {}, removeEventListener() {},
      requestAnimationFrame: (fn) => fn(),
      getComputedStyle: () => ({ getPropertyValue: () => '' }),
      innerWidth: 1200, innerHeight: 900
    },
    document: dom.document,
    console: console,
    // The page waits for the sheet before it draws a piece. Nothing here
    // decodes a PNG, but the load has to finish or the drawing never starts.
    Image: function () {
      this.onload = null;
      this.onerror = null;
      this.width = 640;
      this.height = 1023;
      const self = this;
      Object.defineProperty(this, 'src', {
        set(value) {
          this._src = value;
          if (self.onload) self.onload();
        },
        get() { return this._src; }
      });
    },
    setTimeout: (fn) => fn(),
    alert() {}, confirm: () => true, fetch: () => Promise.resolve({ ok: true })
  };
  sandbox.window.roomHost = {
    boot: boot,
    // The last whole file the page handed over, so a test can read an edit back.
    save(text, what) { sandbox.window.__saved = text; sandbox.window.__what = what; },
    saveSpecials(text) { sandbox.window.__specials = text; },
    onReload() {},
    roomChanged() {},
    build() {}
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  new vm.Script(scriptOf(assemble(boot))).runInContext(sandbox);
  return { sandbox, dom };
}

test('the page opens on the real castle', () => {
  const boot = bootFor('knightlore', 0);
  if (!boot.sheet) skip('knightlore/sprites.json has not been unpacked');
  const { dom } = open(boot);
  assert.ok(/Knight Lore rooms/.test(dom.byId.title.textContent),
            dom.byId.title.textContent);
  assert.ok(/room \$00/.test(dom.byId.subtitle.textContent),
            dom.byId.subtitle.textContent);
});

test('the Collectables tab is offered for Knight Lore and not for Pentagram', () => {
  const kl = bootFor('knightlore', 0);
  if (!kl.sheet) skip('knightlore/sprites.json has not been unpacked');
  assert.ok(kl.specials, 'knightlore should have a specials.json');
  assert.strictEqual(open(kl).dom.byId['tab-collectables'].style.display, '');

  const pg = bootFor('pentagram', 0);
  assert.strictEqual(pg.specials, null, 'pentagram should have no specials.json');
  assert.strictEqual(open(pg).dom.byId['tab-collectables'].style.display, 'none');
});

// Open a tab the way a click would, and hand back what it rendered.
function openTab(page, which) {
  const button = page.dom.tabs.find((b) => b.dataset.tab === which);
  const found = page.dom.listeners.find(
    (l) => l.node === button && l.kind === 'click');
  assert.ok(found, 'nothing is listening on the ' + which + ' tab');
  found.fn();
  return page.dom.byId.panel;
}

function textIn(node) {
  return node.textContent + node.children.map(textIn).join(' ');
}

test('the Collectables tab lists the ones that start in this room', () => {
  const boot = bootFor('knightlore');
  if (!boot.sheet) skip('knightlore/sprites.json has not been unpacked');
  const specials = require('../specials_model');

  // A room the real table actually puts something in, so this is not an empty
  // case dressed up as a pass.
  const entry = specials.collectablesOf(boot.specials)[0];
  const here = specials.inRoom(boot.specials, entry.room);
  assert.ok(here.length >= 1, 'the first collectable should be somewhere');

  const page = open(Object.assign({}, boot, { room: entry.room }));
  const text = textIn(openTab(page, 'collectables'));
  for (const one of here) {
    assert.ok(text.includes('collectable ' + one.index),
              'the panel should name collectable ' + one.index + ', got: ' + text);
  }
  assert.ok(/32 collectables over \d+ rooms/.test(text), text);
  assert.ok(!/wizard/.test(text), 'the wizard’s list is not edited here');

  // ...and a room with none says so rather than showing the last room's.
  const empty = boot.atlas.rooms
    .map((r) => r.number)
    .find((n) => specials.inRoom(boot.specials, n).length === 0);
  assert.notStrictEqual(empty, undefined, 'some room should have none');
  const bare = open(Object.assign({}, boot, { room: empty }));
  assert.ok(/no collectables start in this room/.test(textIn(openTab(bare, 'collectables'))));
});

test('a room over the slot limit is called out', () => {
  const boot = bootFor('knightlore');
  if (!boot.sheet) skip('knightlore/sprites.json has not been unpacked');
  const specials = require('../specials_model');

  // The real table never does this, so it is made to: three in one room, which
  // the game would silently drop the third of.
  const said = JSON.parse(JSON.stringify(boot.specials));
  const room = said.collectables[0].room;
  said.collectables[1].room = room;
  said.collectables[2].room = room;

  const page = open(Object.assign({}, boot, { room: room, specials: said }));
  const text = textIn(openTab(page, 'collectables'));
  assert.ok(/Only the first 2 of these are ever placed/.test(text), text);
});

test('editing a collectable sends the whole file back, and only that file', () => {
  const boot = bootFor('knightlore');
  if (!boot.sheet) skip('knightlore/sprites.json has not been unpacked');
  const specials = require('../specials_model');
  // The row the panel lists first for that room, which is the one the first
  // set of boxes belongs to. collectablesOf gives the table's rows; only
  // inRoom carries the index, which is what an edit is keyed by.
  const room = specials.collectablesOf(boot.specials)[0].room;
  const entry = specials.inRoom(boot.specials, room)[0];

  const page = open(Object.assign({}, boot, { room: room }));
  const panel = openTab(page, 'collectables');

  // The U box of the first collectable listed. The panel builds number inputs
  // in U, V, Z order inside a row of its own.
  const boxes = [];
  (function walk(node) {
    if (node.tagName === 'INPUT' && node.type === 'number') boxes.push(node);
    node.children.forEach(walk);
  })(panel);
  assert.ok(boxes.length >= 3, 'the panel should offer U, V and Z');

  boxes[0].value = String((entry.u + 3) & 0xFF);
  const change = page.dom.listeners.find(
    (l) => l.node === boxes[0] && l.kind === 'change');
  assert.ok(change, 'the U box should be listening');
  change.fn();

  const written = page.sandbox.window.__specials;
  assert.ok(written, 'nothing was sent to the host');
  const after = JSON.parse(written);
  assert.strictEqual(after.collectables[entry.index].u, (entry.u + 3) & 0xFF);
  assert.strictEqual(after.collectables.length, specials.ROWS,
                     'the table must stay a fixed 32 rows');
  assert.deepStrictEqual(after.wanted, boot.specials.wanted,
                         'an edit to one should not disturb the wizard’s list');
});

// --- every tab renders ----------------------------------------------------

// The panel is most of what the designer is, and each tab renders a different
// part of the castle: the object groups, the scenery references, the shared
// templates, the collectables. A reshape of rooms.json that the model followed
// and the page did not would leave the panel empty or throw -- which is what
// happened -- and opening only the tab the page starts on would not notice.
for (const game of GAMES) {
  test(game + ': every tab renders something', () => {
    const boot = bootFor(game);
    const { dom } = open(boot);

    for (const button of dom.tabs) {
      const name = button.dataset.tab;
      if (name === 'collectables' && game !== 'knightlore') continue;

      const clicks = dom.listeners.filter(function (l) {
        return l.node === button && l.kind === 'click';
      });
      assert.strictEqual(clicks.length, 1, name + ' has no click listener');

      dom.byId.panel.children.length = 0;
      clicks[0].fn({ preventDefault() {} });
      assert.ok(dom.byId.panel.children.length > 0,
                'the ' + name + ' tab put nothing in the panel');
    }
  });
}

// --- and it actually draws ------------------------------------------------

// The room is painted on a canvas, so none of the checks above can see it: a
// page that opened, filled its panel and drew nothing at all would pass every
// one of them. This counts what reached the 2d context.
for (const game of GAMES) {
  test(game + ': opening a room paints it', () => {
    const boot = bootFor(game);
    // A sprite sheet is wanted for the pieces themselves; without one the page
    // has the castle but no artwork, and draws the floor and nothing else.
    if (!boot.sheetPng) skip(game + '/sprites.png has not been unpacked');
    const { dom } = open(boot);

    const blits = dom.painted.drawImage || 0;
    assert.ok(blits > 20,
              'the room should be painted from the sheet, but drawImage was ' +
              'called ' + blits + ' times');
  });
}

// --- a castle joined by a table -------------------------------------------

// knightlore128 says its rules in its meta: its exits are a table, so its
// numbers are not places and its doorways are what it is edited through.

// Every node under one, depth first.
function nodesIn(node, out) {
  out = out || [];
  out.push(node);
  node.children.forEach(function (child) { nodesIn(child, out); });
  return out;
}

function listenerOn(dom, node, kind) {
  const found = dom.listeners.find((l) => l.node === node && l.kind === kind);
  assert.ok(found, 'nothing is listening for ' + kind);
  return found.fn;
}

test('knightlore128: the map is walked out of the doorways, north up', () => {
  const { dom } = open(bootFor('knightlore128', 0));
  assert.strictEqual(dom.byId.title.textContent, 'Knight Lore 128K rooms');
  assert.ok(/16 x 16 from the doorways, north up/.test(dom.byId.mapnote.textContent),
            dom.byId.mapnote.textContent);
  // Its exits were generated from Knight Lore's grid, so the walk lays it out
  // as that grid: row $F at the top, so the first cell is room $F0.
  const cells = dom.byId.grid.children;
  assert.strictEqual(cells.length, 256);
  assert.strictEqual(cells.filter((c) => c._classes.has('real')).length, 128);
  const byText = cells.filter((c) => c.textContent === '00')[0];
  assert.strictEqual(cells.indexOf(byText), 15 * 16, 'room 0 is bottom left');
  assert.ok(byText._classes.has('here'));
  // Every one of Knight Lore's rooms fits. Pentagram's two clusters, imported
  // under free numbers and joined to nothing yet, are listed under the map,
  // and so is $25, the room that shows the 128K's own new pieces.
  const listed = dom.byId.offmap.children;
  assert.strictEqual(listed.length, 2, 'a note and the list');
  const unplaced = listed[1].children.map((c) => c.textContent);
  assert.deepStrictEqual(unplaced.slice().sort(),
                         ['05', '06', '07', '11', '13', '15', '16', '17',
                          '19', '1A', '1B', '1C', '1E', '23', '25']);
});

test('knightlore128: a room the walk cannot place is listed under the map', () => {
  const boot = bootFor('knightlore128', 0);
  // Room 1 is reached only from 0 (east) and from 2 (west). With both of
  // those walled up nothing leads to it, so the walk never reaches it -- though
  // its own doorways still lead out.
  for (const r of boot.atlas.rooms) {
    for (const ref of r.scenery) if (ref.destination === 1) ref.destination = null;
  }
  const { dom } = open(boot);
  const listed = nodesIn(dom.byId.offmap).filter((n) => n._classes.has('cell'));
  assert.ok(listed.some((n) => n.textContent === '01'),
            'room 1 should be listed off the map');
  assert.ok(/not on the map/.test(textIn(dom.byId.offmap)));
});

test('knightlore128: a way out is edited as a room number, and empty walls it up', () => {
  const page = open(bootFor('knightlore128', 0));
  const inputs = nodesIn(page.dom.byId.exits).filter((n) => n.tagName === 'INPUT');
  // Room 0 has two doorways, north to $10 and east to 1.
  assert.deepStrictEqual(inputs.map((n) => n.value), ['16', '1']);

  inputs[0].value = '';
  listenerOn(page.dom, inputs[0], 'change')();
  let saved = JSON.parse(page.sandbox.window.__saved);
  assert.deepStrictEqual(saved.rooms[0].scenery[0],
                         { template: 'scenery_arch_n', destination: null });

  // ...and the walled-up doorway is still listed, empty, to be given a room.
  const again = nodesIn(page.dom.byId.exits).filter((n) => n.tagName === 'INPUT');
  assert.deepStrictEqual(again.map((n) => n.value), ['', '1']);
  again[0].value = '0';
  listenerOn(page.dom, again[0], 'change')();
  saved = JSON.parse(page.sandbox.window.__saved);
  assert.strictEqual(saved.rooms[0].scenery[0].destination, 0, '0 is a room here');
});

test('knightlore128: Add room makes the lowest free number and goes to it', () => {
  const page = open(bootFor('knightlore128', 0));
  const nodes = nodesIn(page.dom.byId.addroom);
  const number = nodes.filter((n) => n.tagName === 'INPUT')[0];
  const button = nodes.filter((n) => n.tagName === 'BUTTON')[0];
  assert.strictEqual(button.textContent, 'Add room');
  const free = Number(number.value);
  const taken = new Set(bootFor('knightlore128').atlas.rooms.map((r) => r.number));
  assert.ok(!taken.has(free), 'prefilled with a free number');
  for (let n = 0; n < free; n++) assert.ok(taken.has(n), 'and the lowest: ' + n);

  // A number already used is refused, with the reason, and nothing is saved.
  number.value = '0';
  listenerOn(page.dom, button, 'click')();
  assert.strictEqual(page.sandbox.window.__saved, undefined);
  assert.ok(/already a room 0/.test(textIn(page.dom.byId.addroom)));

  number.value = String(free);
  listenerOn(page.dom, button, 'click')();
  const saved = JSON.parse(page.sandbox.window.__saved);
  assert.strictEqual(page.sandbox.window.__what, 'add room');
  const at = saved.rooms.findIndex((r) => r.number === free);
  assert.ok(at > 0 && saved.rooms[at - 1].number < free && saved.rooms[at + 1].number > free);
  assert.ok(new RegExp('room \\$' + free.toString(16).toUpperCase().padStart(2, '0')).test(
    page.dom.byId.subtitle.textContent), page.dom.byId.subtitle.textContent);
});

test('knightlore: an empty place on the map adds a room there; a room offers Delete', () => {
  const boot = bootFor('knightlore', 0);
  const taken = new Set(boot.atlas.rooms.map((r) => r.number));
  let free = 0;
  while (taken.has(free)) free++;
  const label = free.toString(16).toUpperCase().padStart(2, '0');
  const page = open(boot);
  const cells = () => nodesIn(page.dom.byId.grid).filter((n) => n.tagName === 'BUTTON');
  const buttons = () => nodesIn(page.dom.byId.addroom).filter((n) => n.tagName === 'BUTTON');

  // Knight Lore's map is its numbers, so there is no box to type one in, and
  // on a room the one button is Delete.
  assert.strictEqual(nodesIn(page.dom.byId.addroom).filter((n) => n.tagName === 'INPUT').length, 0);
  assert.deepStrictEqual(buttons().map((b) => b.textContent), ['Delete room $00']);

  // An empty place is picked, not filled...
  const empty = cells().find((c) => c.textContent === label);
  assert.ok(/\bfree\b/.test(empty.className), empty.className);
  listenerOn(page.dom, empty, 'click')();
  assert.strictEqual(page.sandbox.window.__saved, undefined, 'a click alone makes nothing');
  assert.ok(/picked/.test(cells().find((c) => c.textContent === label).className));
  assert.deepStrictEqual(buttons().map((b) => b.textContent), ['Add room $' + label]);

  // ...and Add makes the room and goes to it.
  listenerOn(page.dom, buttons()[0], 'click')();
  let saved = JSON.parse(page.sandbox.window.__saved);
  assert.strictEqual(page.sandbox.window.__what, 'add room');
  assert.ok(saved.rooms.some((r) => r.number === free));
  assert.ok(new RegExp('room \\$' + label).test(page.dom.byId.subtitle.textContent));
  assert.deepStrictEqual(buttons().map((b) => b.textContent), ['Delete room $' + label]);

  // Delete takes it out again, and shows the room before it.
  listenerOn(page.dom, buttons()[0], 'click')();
  saved = JSON.parse(page.sandbox.window.__saved);
  assert.strictEqual(page.sandbox.window.__what, 'delete room');
  assert.ok(!saved.rooms.some((r) => r.number === free));
  assert.ok(/\bfree\b/.test(cells().find((c) => c.textContent === label).className));
});

test('knightlore: Delete says what would lead nowhere, and a start room cannot go', () => {
  const boot = bootFor('knightlore', 0);
  boot.atlas.startRooms = [0x2F, 0x44, 0xB3, 0x8F];
  const page = open(boot);
  const buttons = () => nodesIn(page.dom.byId.addroom).filter((n) => n.tagName === 'BUTTON');
  // Room $00 is joined to $01 and $10, which have doorways back into it, and
  // a collectable starts there.
  assert.ok(textIn(page.dom.byId.addroom).indexOf(
    'deleting it leaves 2 doorways and 1 collectable pointing nowhere') >= 0,
    textIn(page.dom.byId.addroom));

  // The starting rooms are listed under the map, and one goes to its room --
  // where Delete is refused, with the reason.
  const starts = nodesIn(page.dom.byId.starts).filter((n) => n.tagName === 'BUTTON' &&
                                                          /^\$/.test(n.textContent));
  assert.deepStrictEqual(starts.map((b) => b.textContent), ['$2F', '$44', '$B3', '$8F']);
  listenerOn(page.dom, starts[2], 'click')();
  assert.ok(/room \$B3/.test(page.dom.byId.subtitle.textContent), page.dom.byId.subtitle.textContent);
  const here = nodesIn(page.dom.byId.starts).filter((n) => n.tagName === 'BUTTON')[2];
  assert.ok(/here/.test(here.className));
  assert.strictEqual(buttons()[0].textContent, 'Delete room $B3');
  assert.strictEqual(buttons()[0].disabled, true);
  assert.ok(/can start in room \$B3/.test(textIn(page.dom.byId.addroom)));
});

test('knightlore: Change on a starting room, then a room on the map, swaps it in', () => {
  const boot = bootFor('knightlore', 0);
  if (!boot.sheet) skip('knightlore/sprites.json has not been unpacked');
  boot.atlas.startRooms = [0x2F, 0x44, 0xB3, 0x8F];
  const page = open(boot);
  const inStarts = (tag) => nodesIn(page.dom.byId.starts).filter((n) => n.tagName === tag);
  const button = (text) => inStarts('BUTTON').find((b) => b.textContent === text);
  const cell = (label) => nodesIn(page.dom.byId.grid).find((n) => n.tagName === 'BUTTON' && n.textContent === label);
  const click = (node) => listenerOn(page.dom, node, 'click')();

  // Room $00 is not a starting room, so there is nothing to change.
  assert.strictEqual(button('Change').disabled, true);

  // Go to $44 through its button: Change is on, and turns the map into a
  // chooser, with the rooms that cannot start dimmed and saying why.
  click(button('$44'));
  assert.ok(/room \$44/.test(page.dom.byId.subtitle.textContent));
  assert.strictEqual(button('Change').disabled, false);
  click(button('Change'));
  assert.ok(button('Cancel'), 'Change becomes Cancel');
  assert.ok(/instead of \$44/.test(textIn(page.dom.byId.starts)));
  assert.ok(/nostart/.test(cell('03').className), 'a spike in the middle of $03');
  assert.ok(/Sabreman starts/.test(cell('03').title), cell('03').title);
  assert.ok(!/nostart/.test(cell('00').className), '$00 is clear');

  // A blocked room is refused, and the chooser stays open for another.
  click(cell('03'));
  assert.strictEqual(page.sandbox.window.__saved, undefined);
  assert.ok(/not \$03: Sabreman starts in the middle of the floor/.test(textIn(page.dom.byId.starts)));
  assert.ok(button('Cancel'));

  // A clear one takes the slot, and the designer goes to it.
  click(cell('00'));
  const saved = JSON.parse(page.sandbox.window.__saved);
  assert.strictEqual(page.sandbox.window.__what, 'starting room');
  assert.deepStrictEqual(saved.startRooms, [0x2F, 0x00, 0xB3, 0x8F]);
  assert.ok(/room \$00/.test(page.dom.byId.subtitle.textContent));
  assert.ok(button('Change') && !button('Cancel'));

  // Cancel leaves everything as it was.
  click(button('$2F'));
  click(button('Change'));
  click(button('Cancel'));
  assert.ok(button('Change'));
  assert.ok(!/nostart/.test(cell('03').className), 'the map is itself again');
});

test('knightlore: a way out is its room number, which goes there', () => {
  const page = open(bootFor('knightlore', 0));
  const links = nodesIn(page.dom.byId.exits).filter((n) => n.tagName === 'BUTTON');
  // Room $00 leads north to $10 and east to $01, and there is no "go".
  assert.deepStrictEqual(links.map((b) => b.textContent), ['$10', '$01']);
  listenerOn(page.dom, links[0], 'click')();
  assert.ok(/room \$10/.test(page.dom.byId.subtitle.textContent), page.dom.byId.subtitle.textContent);
});

test('selecting an object points the Place picker at its template', () => {
  const page = open(bootFor('knightlore', 0));
  const placer = () => nodesIn(page.dom.byId.panel)
    .find((n) => n.tagName === 'DIV' && /\badder\b/.test(n.className))
    .children.find((n) => n.tagName === 'SELECT');
  const first = Object.keys(bootFor('knightlore').templates.objectTemplates)[0];
  // Room $00's third group is the dropping block; select one of its objects.
  const spots = nodesIn(page.dom.byId.panel).filter((n) => /\bspot\b/.test(n.className));
  const group = bootFor('knightlore').atlas.rooms[0].objects;
  const index = group.findIndex((g) => g.template !== first);
  assert.ok(index >= 0, 'room $00 has a group of something else');
  let at = 0;
  for (let g = 0; g < index; g++) at += group[g].positions.length;
  listenerOn(page.dom, spots[at], 'click')();
  assert.strictEqual(placer().value, group[index].template);
  // ...and it stays on it once the selection has gone.
  listenerOn(page.dom, nodesIn(page.dom.byId.grid).find((n) => n.textContent === '01'), 'click')();
  assert.strictEqual(placer().value, group[index].template);
});

test('a castle that lists no starting rooms shows none', () => {
  const page = open(bootFor('knightlore', 0));
  assert.strictEqual(page.dom.byId.starts.children.length, 0);
});

test('the older castles keep their maps and their exits as they were', () => {
  // Knight Lore: the number grid, and exits that are arithmetic, not inputs.
  const kl = open(bootFor('knightlore', 0)).dom;
  assert.strictEqual(kl.byId.mapnote.textContent, '16 x 16, north up');
  assert.strictEqual(nodesIn(kl.byId.exits).filter((n) => n.tagName === 'INPUT').length, 0);
  // Pentagram: a list, and its destination bytes as inputs.
  const pg = open(bootFor('pentagram')).dom;
  assert.ok(/ rooms$/.test(pg.byId.mapnote.textContent), pg.byId.mapnote.textContent);
  assert.ok(nodesIn(pg.byId.exits).filter((n) => n.tagName === 'INPUT').length > 0);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
