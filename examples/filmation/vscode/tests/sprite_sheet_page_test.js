// The sprite sheet editor's page as its host assembles it, run against a
// fake DOM and Knight Lore's real sheet.
//
//   node examples/filmation/vscode/tests/sprite_sheet_page_test.js
//
// The page is built by string replacement, so a mistake in it is a syntax
// error in a file that only exists at runtime; and it paints on a canvas, so
// a fake that swallowed every call would pass a page that drew nothing. This
// one hands the page the sheet's real pixels where a canvas would, and checks
// that a click lands on the pixel it was aimed at and sends what it should.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const png = require('../png_codec');
const m = require('../sprite_sheet_model');

const EXT = path.join(__dirname, '..');
const FILMATION = path.join(EXT, '..');
const INLINED = ['sprite_sheet_model.js'];

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

// What sprite_sheet_view.js's bootFor sends, for Knight Lore's own sheet.
function bootFor() {
  const json = path.join(FILMATION, 'knightlore', 'metadata', 'sprites.json');
  if (!fs.existsSync(json)) skip('knightlore/metadata/sprites.json is not here');
  const sheet = JSON.parse(fs.readFileSync(json, 'utf8'));
  const picture = path.resolve(path.dirname(json), sheet.sheet.file);
  if (!fs.existsSync(picture)) skip('knightlore/art/sprites.png is not here');
  return {
    sheet: sheet,
    title: 'knightlore/metadata/sprites.json',
    picture: 'sprites.png',
    png: 'data:image/png;base64,' + fs.readFileSync(picture).toString('base64'),
    graphics: JSON.parse(fs.readFileSync(path.join(path.dirname(json), 'graphics.json'), 'utf8')),
    prefix: ''
  };
}

function assemble() {
  let html = fs.readFileSync(path.join(EXT, 'sprite_sheet_view.html'), 'utf8');
  for (const name of INLINED) {
    html = html.replace('/*@' + name + '@*/', () => fs.readFileSync(path.join(EXT, name), 'utf8'));
  }
  html = html.replace('/*@host@*/', '');
  const open = html.indexOf('>', html.indexOf('<script')) + 1;
  return html.slice(open, html.indexOf('</script>', open));
}

// A DOM that records rather than renders. A canvas's 2d context counts what
// is drawn, and gives back the pixels of whatever image was drawn into it --
// which is how the page reads the sheet.
function fakePage(boot) {
  const painted = {};
  function context(canvas) {
    let image = null;
    return new Proxy({}, {
      get: (target, key) => {
        if (key in target) return target[key];
        if (key === 'drawImage') return (img) => { image = img; painted.drawImage = (painted.drawImage || 0) + 1; };
        if (key === 'getImageData') {
          return () => ({ data: new Uint8ClampedArray(image.decoded.rgba) });
        }
        return function () { painted[key] = (painted[key] || 0) + 1; };
      },
      set: (target, key, value) => { target[key] = value; return true; }
    });
  }
  function element(tag) {
    const node = {
      tagName: String(tag).toUpperCase(), children: [], style: {}, _on: {}, _classes: new Set(),
      title: '', value: '', type: '', placeholder: '', width: 300, height: 150,
      _text: '',
      get textContent() { return this._text; },
      set textContent(v) { this._text = String(v); this.children = []; },
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      appendChild(child) { this.children.push(child); return child; },
      insertBefore(child, before) {
        const at = this.children.indexOf(before);
        this.children.splice(at < 0 ? 0 : at, 0, child);
        return child;
      },
      get firstChild() { return this.children[0] || null; },
      addEventListener(kind, fn) { this._on[kind] = fn; },
      getBoundingClientRect() { return { left: 0, top: 0, width: this.width, height: this.height }; },
      getContext() { return this._ctx || (this._ctx = context(this)); }
    };
    node.classList = {
      add: (c) => node._classes.add(c),
      remove: (c) => node._classes.delete(c),
      contains: (c) => node._classes.has(c)
    };
    return node;
  }
  const byId = {};
  for (const id of ['title', 'summary', 'tree', 'toolbar', 'stage', 'side']) byId[id] = element('div');
  // What the page sent, copied out of its realm so it compares by value.
  const sent = [];
  const asked = [];
  let heard = null;
  const windowListeners = {};
  const sandbox = {
    document: { createElement: element, getElementById: (id) => byId[id] || null },
    window: {
      addEventListener: (kind, fn) => { windowListeners[kind] = fn; },
      spriteSheetHost: {
        boot: boot,
        paint: (changes) => sent.push(JSON.parse(JSON.stringify(changes))),
        resize: (path, edges) => asked.push({ resize: path, edges: JSON.parse(JSON.stringify(edges)) }),
        tidy: () => asked.push({ tidy: true }),
        state: () => ({}),
        keep: () => {},
        onMessage: (fn) => { heard = fn; }
      }
    },
    // An image decodes its data: URI with the codec, as a browser would.
    Image: function () {
      const self = this;
      Object.defineProperty(this, 'src', {
        set(uri) {
          self.decoded = png.decode(Buffer.from(uri.slice(uri.indexOf(',') + 1), 'base64'));
          self.width = self.decoded.width;
          self.height = self.decoded.height;
          if (self.onload) self.onload();
        }
      });
    },
    console: console
  };
  vm.createContext(sandbox);
  new vm.Script(assemble(), { filename: 'sprite_sheet_view.assembled.js' }).runInContext(sandbox);
  return { byId, sent, asked, painted, hear: (message) => heard(message), keys: windowListeners };
}

function walk(node, out) {
  out = out || [];
  for (const child of node.children || []) {
    out.push(child);
    walk(child, out);
  }
  return out;
}

function rows(page) {
  return walk(page.byId.tree).filter((n) => n.classList.contains('sprite'));
}

// The view: a canvas under a scroller, whose content is a box the size of
// the whole sheet at the zoom.
function scrollerOf(page) {
  return page.byId.stage.children[1];
}

// Screen pixels a sheet pixel, read off the scroller's content: it is the
// sheet's width times the zoom.
function zoomOf(page) {
  return parseInt(scrollerOf(page).children[0].style.width, 10) / SHEET_WIDTH;
}

const SHEET_WIDTH = 640;

// Press the mouse on the view over a sheet pixel -- given as a column and a
// row within the sprite being aimed at -- the way a pointer would: where the
// pixel is on the zoomed sheet, less how far the view is scrolled.
function press(page, column, row, button) {
  const scroller = scrollerOf(page);
  const z = zoomOf(page);
  const r = spriteShown(page).rect;
  const at = { clientX: (r.x + column + 0.5) * z - (scroller.scrollLeft || 0),
               clientY: (r.y + row + 0.5) * z - (scroller.scrollTop || 0),
               button: button || 0, pointerId: 1, preventDefault() {} };
  scroller._on.pointerdown(at);
  scroller._on.pointerup(at);
}

// Where a sprite's middle is on the view, in screen pixels.
function middleOf(page, sprite) {
  const scroller = scrollerOf(page);
  const z = zoomOf(page);
  const r = sprite.rect;
  return [(r.x + r.w / 2) * z - scroller.scrollLeft, (r.y + r.h / 2) * z - scroller.scrollTop];
}

let SHOWN = null;
function spriteShown() {
  return SHOWN;
}

function decodedSheet(boot) {
  return png.decode(Buffer.from(boot.png.slice(boot.png.indexOf(',') + 1), 'base64'));
}

test('the page opens on the sheet, one row a sprite, and draws', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  assert.strictEqual(rows(page).length, all.length);
  assert.ok(new RegExp('^' + all.length + ' sprites').test(page.byId.summary.textContent),
            page.byId.summary.textContent);
  // The view is the whole sheet: its scroller holds a box the sheet's size
  // at the zoom, and the view draws whatever part of it shows.
  const z = zoomOf(page);
  assert.ok(z >= 1, 'no view of the sheet');
  assert.strictEqual(scrollerOf(page).children[0].style.height,
                     decodedSheet(boot).height * z + 'px');
  assert.ok(page.painted.drawImage > 0, 'the sheet was not drawn');
  assert.ok(page.painted.fillRect > 1000, 'the thumbnails were not drawn');
});

test('a click on the pixel aimed at: the picked colour on a clear one, then ink and paper in turn', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[5];
  SHOWN = sprite;
  rows(page)[5]._on.click();
  const x = sprite.rect.x + 3;
  const y = sprite.rect.y + 2;
  // Made clear first, so the first click has a known pixel to land on.
  page.hear({ type: 'pixels', changes: [{ x: x, y: y, to: 'transparent' }] });
  press(page, 3, 2);
  press(page, 3, 2);
  press(page, 3, 2);
  // The right button rubs out, whatever is picked.
  press(page, 3, 2, 2);
  assert.deepStrictEqual(page.sent, [
    [{ x: x, y: y, to: 'ink' }],
    [{ x: x, y: y, to: 'paper' }],
    [{ x: x, y: y, to: 'ink' }],
    [{ x: x, y: y, to: 'transparent' }]
  ]);
});

test('with Transparent picked, a click rubs out instead of toggling', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[5];
  SHOWN = sprite;
  rows(page)[5]._on.click();
  page.keys.keydown({ key: '3', target: { tagName: 'BODY' }, preventDefault() {} });   // transparent
  const x = sprite.rect.x;
  const y = sprite.rect.y;
  page.hear({ type: 'pixels', changes: [{ x: x, y: y, to: 'ink' }] });
  press(page, 0, 0);
  press(page, 0, 0);
  assert.deepStrictEqual(page.sent, [[{ x: x, y: y, to: 'transparent' }]],
                         'a second click on a clear pixel changes nothing');
});

test('a click on another sprite picks it, and paints nothing', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  rows(page)[5]._on.click();
  SHOWN = all[6];
  press(page, 0, 0);
  assert.strictEqual(page.sent.length, 0, 'it painted the sprite it picked');
  assert.ok(rows(page)[6].classList.contains('on'), 'the tree did not follow');
  assert.ok(!rows(page)[5].classList.contains('on'));
});

test('zooming keeps the pixel under the pointer where it was', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const scroller = scrollerOf(page);
  // A sprite halfway down the sheet, clear of its edges, picked -- which
  // brings it into the middle of the view -- and the pointer on its middle.
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  const half = Math.floor(all.length / 2);
  rows(page)[half]._on.click();
  const was = zoomOf(page);
  const [px, py] = middleOf(page, all[half]).map(Math.round);
  // The sheet pixel under the pointer, before and after.
  const under = () => [(scroller.scrollLeft + px) / zoomOf(page), (scroller.scrollTop + py) / zoomOf(page)];
  const before = under();
  scroller._on.wheel({ ctrlKey: true, deltaY: -1, clientX: px, clientY: py, preventDefault() {} });
  assert.ok(zoomOf(page) > was, 'Ctrl and the wheel did not zoom in');
  const after = under();
  assert.ok(Math.abs(after[0] - before[0]) < 1 && Math.abs(after[1] - before[1]) < 1,
            before + ' moved to ' + after);
  // The wheel alone is left to the scroller.
  const z = zoomOf(page);
  scroller._on.wheel({ ctrlKey: false, deltaY: -1, clientX: px, clientY: py, preventDefault() {} });
  assert.strictEqual(zoomOf(page), z);
});

test('the zoom buttons zoom about the picked sprite, which stays where it is', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  // Halfway down the sheet, so the view is never stopped by its edge.
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  const half = Math.floor(all.length / 2);
  const sprite = all[half];
  rows(page)[half]._on.click();
  const was = zoomOf(page);
  const before = middleOf(page, sprite);
  walk(page.byId.toolbar).find((n) => n.tagName === 'BUTTON' && n.textContent === '−')._on.click();
  assert.ok(zoomOf(page) < was, 'it did not zoom out');
  const after = middleOf(page, sprite);
  assert.ok(Math.abs(after[0] - before[0]) <= 1 && Math.abs(after[1] - before[1]) <= 1,
            before + ' moved to ' + after);
});

test('zooming with the wheel far from the picked sprite still leaves it in sight', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[5];
  rows(page)[5]._on.click();
  // The pointer at the view's far corner, and two steps in: to ×16, where
  // the sprite still fits the view. (Bigger than the view, it is centred.)
  for (let i = 0; i < 2; i++) {
    scrollerOf(page)._on.wheel({ ctrlKey: true, deltaY: -1, clientX: 590, clientY: 390,
                                 preventDefault() {} });
  }
  // The fake view is 600 by 400: the sprite, frame and all, is inside it.
  const z = zoomOf(page);
  const scroller = scrollerOf(page);
  const r = sprite.rect;
  const left = (r.x - 1) * z - scroller.scrollLeft;
  const top = (r.y - 1) * z - scroller.scrollTop;
  assert.ok(left >= 0 && top >= 0 && left + (r.w + 2) * z <= 600 && top + (r.h + 2) * z <= 400,
            'the sprite is at ' + left + ', ' + top + ' at ×' + z);
});

test('picking a sprite in the tree brings it into view', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  const last = all[all.length - 1];
  rows(page)[all.length - 1]._on.click();
  const scroller = scrollerOf(page);
  const z = zoomOf(page);
  // The fake view is 600 by 400; the sprite's middle is in the middle of it.
  const mid = (last.rect.y + last.rect.h / 2) * z - scroller.scrollTop;
  assert.ok(Math.abs(mid - 200) <= 1, 'the sprite is at ' + mid + ' down the view');
});

test('a fill sends the joined pixels the model says, and nothing outside the sprite', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[5];
  SHOWN = sprite;
  rows(page)[5]._on.click();
  page.keys.keydown({ key: 'f', target: { tagName: 'BODY' }, preventDefault() {} });
  page.keys.keydown({ key: '2', target: { tagName: 'BODY' }, preventDefault() {} });   // paper
  const picture = decodedSheet(boot);
  const colours = m.coloursOf(boot.sheet);
  // A fill follows the click's rule: from ink it paints paper, from paper
  // ink, from a clear pixel the colour picked.
  const under = m.colourAt(picture, colours, sprite.rect.x, sprite.rect.y);
  const colour = m.strokeColour(under, 'paper');
  const want = m.fill(picture, colours, sprite.rect, sprite.rect.x, sprite.rect.y, colour);
  if (!want.length) skip('its corner is already what a fill would paint');
  press(page, 0, 0);
  assert.strictEqual(page.sent.length, 1);
  assert.deepStrictEqual(page.sent[0], want.map((c) => ({ x: c.x, y: c.y, to: colour })));
  assert.ok(page.sent[0].every((c) => m.inside(sprite.rect, c.x, c.y)));
});

test('an undo from the host puts the page\'s pixel back', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[0];
  SHOWN = sprite;
  // What the host says a pixel is, is what the next click toggles from.
  page.hear({ type: 'pixels', changes: [{ x: sprite.rect.x, y: sprite.rect.y, to: 'ink' }] });
  press(page, 0, 0);
  page.hear({ type: 'pixels', changes: [{ x: sprite.rect.x, y: sprite.rect.y, to: 'ink' }] });   // the undo
  press(page, 0, 0);
  assert.deepStrictEqual(page.sent.map((c) => c[0].to), ['paper', 'paper']);
});

test('the filter hides the sprites whose names do not match', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const search = walk(page.byId.tree).find((n) => n.placeholder === 'Filter by name…');
  search.value = 'sabreman.legs';
  search._on.input();
  const shown = rows(page).filter((r) => r.style.display !== 'none');
  const want = m.allSpritesOf(m.sheetTree(boot.sheet)).filter((s) => s.path.indexOf('sabreman.legs') >= 0);
  assert.strictEqual(shown.length, want.length);
  assert.ok(shown.length > 0);
});

test('the side panel says which graphics draw the sprite, and that the build takes it', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const all = m.allSpritesOf(m.sheetTree(boot.sheet));
  const at = all.findIndex((s) => s.path === 'guard.1');
  if (at < 0) skip('no guard.1 on the sheet');
  rows(page)[at]._on.click();
  const text = walk(page.byId.side).map((n) => n.textContent).join(' | ');
  // Graphics 30 and 150 both draw it -- the pair README.md documents.
  assert.ok(/graphics 30, 150/.test(text), text);
  assert.ok(/The build will take it/.test(text), text);
});

// A button anywhere under a node, by its label.
function buttonIn(node, text) {
  const found = walk(node).find((n) => n.tagName === 'BUTTON' && n.textContent === text);
  assert.ok(found, 'no ' + text + ' button');
  return found;
}

test('the Size card asks the host to grow or shrink the sprite at one edge', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprite = m.allSpritesOf(m.sheetTree(boot.sheet))[5];
  rows(page)[5]._on.click();
  // The rows go: top, bottom, left, right, each a minus and a plus. The
  // third pair is the left edge, a byte at a time.
  const size = walk(page.byId.side).find((n) => n.classList.contains('edges'));
  const buttons = size.children.filter((n) => n.tagName === 'BUTTON');
  assert.deepStrictEqual(buttons.map((b) => b.textContent), ['−1', '+1', '−1', '+1', '−8', '+8', '−8', '+8']);
  buttons[5]._on.click();
  buttons[0]._on.click();
  assert.deepStrictEqual(page.asked, [{ resize: sprite.path, edges: { left: 8 } },
                                      { resize: sprite.path, edges: { top: -1 } }]);
});

test('a layout change from the host reshapes the page\'s copy: the tree, the pixels, the height', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  const sprites = m.allSpritesOf(m.sheetTree(boot.sheet));
  const sprite = sprites[5];
  rows(page)[5]._on.click();
  // What the host would send for one more row at the top of it.
  const picture = decodedSheet(boot);
  const colours = m.coloursOf(boot.sheet);
  const out = m.resizeSprite(picture, colours, JSON.parse(JSON.stringify(boot.sheet)), sprite.path, { top: 1 });
  const diff = m.diffPictures(picture, out.picture);
  page.hear({ type: 'layout', sheet: out.sheet, width: out.picture.width, height: out.picture.height,
              at: Array.from(diff.at), values: Array.from(diff.after),
              note: out.moved ? 'moved' : '' });
  const text = walk(page.byId.side).map((n) => n.textContent).join(' | ');
  assert.ok(text.indexOf(out.rect.w + ' × ' + out.rect.h) >= 0, 'the side panel has the new size: ' + text);
  assert.ok(/The build will take it/.test(text), 'and the page\'s pixels have the new frame: ' + text);
  assert.ok(page.byId.summary.textContent.indexOf('× ' + out.picture.height + ')') >= 0,
            page.byId.summary.textContent);
});

test('tidy asks first, in the page, and only then asks the host', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  buttonIn(page.byId.tree, 'Tidy sheet…')._on.click();
  assert.strictEqual(page.asked.length, 0, 'tidied without asking');
  buttonIn(page.byId.tree, 'Cancel')._on.click();
  assert.strictEqual(page.asked.length, 0);
  buttonIn(page.byId.tree, 'Tidy sheet…')._on.click();
  buttonIn(page.byId.tree, 'Tidy')._on.click();
  assert.deepStrictEqual(page.asked, [{ tidy: true }]);
});

test('a refusal from the host is said in the Size card', () => {
  const boot = bootFor();
  const page = fakePage(boot);
  page.hear({ type: 'refused', why: 'a sprite is at least a row high' });
  const text = walk(page.byId.side).map((n) => n.textContent).join(' | ');
  assert.ok(/at least a row high/.test(text), text);
});

test('the host itself assembles the page: every marker filled, and the script parses', () => {
  // sprite_sheet_view.js requires vscode, which only exists in the editor;
  // a stand-in with nothing in it is enough to load it and call pageHtml.
  const Module = require('module');
  const resolve = Module._resolveFilename;
  Module._resolveFilename = function (request, ...rest) {
    return request === 'vscode' ? 'vscode' : resolve.call(this, request, ...rest);
  };
  require.cache.vscode = { id: 'vscode', filename: 'vscode', loaded: true, exports: {} };
  try {
    const view = require('../sprite_sheet_view');
    const { SheetFile } = require('../sprite_sheet_document');
    const json = path.join(FILMATION, 'knightlore', 'metadata', 'sprites.json');
    let file;
    try {
      file = SheetFile.load(json);
    } catch (err) {
      skip(err.message);
    }
    const html = view.pageHtml({ uri: { fsPath: json }, file: file });
    assert.ok(!/\/\*@[a-z_.]+@\*\//.test(html), 'a marker survived');
    assert.ok(html.includes('window.spriteSheetHost'), 'the host was not injected');
    assert.ok(html.includes('function sheetTree('), 'the model was not inlined');
    const open = html.indexOf('>', html.indexOf('<script nonce=')) + 1;
    new vm.Script(html.slice(open, html.indexOf('</script>', open)), { filename: 'assembled.js' });
  } finally {
    Module._resolveFilename = resolve;
    delete require.cache.vscode;
  }
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
