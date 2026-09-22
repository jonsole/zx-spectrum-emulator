// The graphic-map page as the host assembles it.
//
//   node examples/filmation/vscode/tests/graphic_map_page_test.js
//
// graphic_map_view.js cannot be required here -- it opens with
// require('vscode'), which only exists inside the editor -- so this does what
// it does to the page and checks the result: the markers are replaced, the
// model really is inlined, the boot data is there and is valid JSON, and the
// script the page runs parses. That last one is the point. The page is
// assembled by string replacement, so a mistake in it is not a syntax error in
// any file, it is a syntax error in a file that only exists at runtime, and
// nothing else would catch it before the panel opened blank.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const model = require('../graphic_map_model');

const EXT = path.join(__dirname, '..');
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

// What graphic_map_view.js's pageHtml does, without the vscode API: the same
// markers, the same order, the same escaping.
const INLINED = ['sheet_model.js', 'graphic_map_model.js'];

function assemble(boot) {
  const nonce = 'deadbeef';
  const bootJs = 'window.graphicMapHost = (function () {\n' +
    '  return { boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    save: function () {}, onReload: function () {} };\n' +
    '})();\n';
  let html = fs.readFileSync(path.join(EXT, 'graphic_map_view.html'), 'utf8')
    .replace('<script>', '<script nonce="' + nonce + '">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(EXT, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

function bootFor(game) {
  const here = path.join(FILMATION, game);
  const file = path.join(here, 'graphics.json');
  const sheetFile = path.join(here, 'sprites.json');
  if (!fs.existsSync(file)) skip(game + '/graphics.json has not been unpacked');
  if (!fs.existsSync(sheetFile)) skip(game + '/sprites.json has not been unpacked');
  return {
    graphics: model.parseMap(fs.readFileSync(file, 'utf8')),
    sheet: JSON.parse(fs.readFileSync(sheetFile, 'utf8')),
    game: game,
    eol: '\n',
    sheetPng: null,
    showSave: false
  };
}

// The <script> the assembled page would run.
function scriptOf(html) {
  const open = html.indexOf('>', html.indexOf('<script')) + 1;
  const close = html.indexOf('</script>', open);
  assert.ok(open > 0 && close > open, 'no script in the page');
  return html.slice(open, close);
}

test('the page has both markers and nothing else that looks like one', () => {
  const raw = fs.readFileSync(path.join(EXT, 'graphic_map_view.html'), 'utf8');
  const markers = raw.match(/\/\*@[a-z_.]+@\*\//g) || [];
  assert.deepStrictEqual(markers, ['/*@sheet_model.js@*/',
    '/*@graphic_map_model.js@*/', '/*@host@*/']);
});

test('assembling replaces every marker', () => {
  const html = assemble(bootFor('knightlore'));
  assert.ok(!html.includes('/*@'), 'a marker survived assembly');
  assert.ok(html.includes('function sharedBy('), 'the model was not inlined');
  assert.ok(html.includes('window.graphicMapHost'), 'the host was not injected');
});

test('the assembled script parses', () => {
  const source = scriptOf(assemble(bootFor('knightlore')));
  // Throws a SyntaxError with a line number if it does not.
  new vm.Script(source, { filename: 'graphic_map_view.assembled.js' });
});

test('the page runs against the real map and draws every graphic', () => {
  const boot = bootFor('knightlore');
  const html = assemble(boot);

  // A DOM small enough to run the page against: the page only ever creates
  // elements, sets text and appends, so this records rather than renders.
  const made = [];
  function element(tag) {
    const node = {
      tagName: tag, children: [], style: {}, classList: null,
      _classes: new Set(),
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      textContent: '', title: '', type: '', placeholder: '', value: '',
      disabled: false, id: '',
      appendChild(child) { this.children.push(child); return child; },
      addEventListener() {},
      removeEventListener() {}
    };
    node.classList = {
      add: (c) => node._classes.add(c),
      remove: (c) => node._classes.delete(c),
      contains: (c) => node._classes.has(c)
    };
    made.push(node);
    return node;
  }

  const byId = {};
  for (const id of ['title', 'summary', 'problems', 'map', 'detail', 'state', 'save']) {
    byId[id] = element('div');
    byId[id].id = id;
  }

  const sandbox = {
    window: {},
    document: {
      createElement: element,
      getElementById: (id) => byId[id] || element('div')
    },
    console: console
  };
  sandbox.window.graphicMapHost = {
    boot: boot,
    save: function () {},
    onReload: function () {}
  };
  vm.createContext(sandbox);
  new vm.Script(scriptOf(html)).runInContext(sandbox);

  // One tile a graphic number, and the summary says what the file holds. The
  // table is as wide as the highest number it names -- 188 for Knight Lore,
  // which uses 186 of them -- rather than the game's own 256: nothing reads
  // past the last graphic that draws something.
  const tiles = byId.map.children;
  assert.strictEqual(tiles.length, model.countOf(boot.graphics),
                     'one tile a graphic number');
  assert.ok(/186 of 188 graphic numbers used/.test(byId.summary.textContent),
            byId.summary.textContent);
  assert.ok(/103 of the sheet/.test(byId.summary.textContent),
            byId.summary.textContent);

  // The unused numbers are drawn as unused, and the shared ones as shared.
  const empty = tiles.filter((t) => t.classList.contains('empty'));
  assert.strictEqual(empty.length, model.countOf(boot.graphics) - 186);
  const shared = tiles.filter((t) => t.classList.contains('shared'));
  const sharing = model.sharedBy(boot.graphics);
  let expected = 0;
  for (const list of sharing.values()) if (list.length > 1) expected += list.length;
  assert.strictEqual(shared.length, expected,
                     'every graphic that shares a bitmap should say so');
  // ...and nothing dangles, or the file points at artwork that is not there.
  assert.strictEqual(tiles.filter((t) => t.classList.contains('dangling')).length, 0);

  // Graphic 150's tile names it and its sprite, which is the thing the text
  // file cannot tell you. A real DOM's textContent gathers a node's children;
  // this one keeps them apart, so the walk is here rather than in the fake.
  const textIn = (node) => node.textContent +
    node.children.map(textIn).join(' ');
  assert.ok(/guard\.1/.test(textIn(tiles[150])),
            'tile 150 should be captioned with its sprite name, got: ' +
            textIn(tiles[150]));
  assert.ok(/^150/.test(textIn(tiles[150]).trim()) ||
            textIn(tiles[150]).includes('150'),
            'and with its number');
});

test('the boot carries the table, the sheet and nothing beside it', () => {
  // Two files, and only the first is the document. graphics.json is what this
  // edits; sprites.json travels with it read-only, for the pictures and the
  // names, and sprites.png for the pixels.
  const boot = bootFor('pentagram');
  assert.deepStrictEqual(Object.keys(boot).sort(),
    ['eol', 'game', 'graphics', 'sheet', 'sheetPng', 'showSave'].sort());
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
