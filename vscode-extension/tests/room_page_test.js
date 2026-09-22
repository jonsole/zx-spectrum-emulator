// The room designer's page as its two hosts assemble it.
//
//   node vscode-extension/tests/room_page_test.js
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
const GAMES = ['knightlore', 'pentagram'];
const FILMATION = path.join(EXT, '..', 'examples', 'filmation');

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
    '    save: function () {}, saveSpecials: function (t) { window.__specials = t; },\n' +
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
    path.join(EXT, '..', 'scripts', 'room_designer.py'), 'utf8');
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
      type: '', min: '', max: '', checked: true, disabled: false, innerHTML: '',
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

const PAGE_IDS = ['title', 'subtitle', 'state', 'save', 'build', 'grid', 'exits',
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
    save() {},
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
  assert.ok(/the wizard asks for 14/.test(text), text);

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

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
