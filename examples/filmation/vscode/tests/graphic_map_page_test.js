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
const sheetModel = require('../sheet_model');
const layout = require('../game_layout');
const sheetFiles = require('../sheet_files');

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
const INLINED = ['sheet_model.js', 'room_render.js', 'graphic_map_model.js'];

function assemble(boot) {
  const nonce = 'deadbeef';
  const bootJs = 'window.graphicMapHost = (function () {\n' +
    '  return { boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    // What the page saves is kept where a test can read it back.
    '    save: function (text) { (window.saved || []).push(text); },\n' +
    '    onReload: function () {} };\n' +
    '})();\n';
  let html = fs.readFileSync(path.join(EXT, 'graphic_map_view.html'), 'utf8')
    .replace('<script>', '<script nonce="' + nonce + '">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(EXT, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

// The files the way the host finds them: graphics.json in the game's
// metadata/, the sheet it names in "sprites" relative to itself, and the
// picture the sheet names in sheet.file relative to the sheet.
function filesFor(game) {
  const here = layout.metadataOf(path.join(FILMATION, game));
  const file = path.join(here, 'graphics.json');
  if (!fs.existsSync(file)) skip(game + '/graphics.json has not been unpacked');
  const graphics = model.parseMap(fs.readFileSync(file, 'utf8'));
  const sheetFile = layout.within(here, graphics.sprites || 'sprites.json');
  if (!sheetFile || !fs.existsSync(sheetFile)) skip(game + '/sprites.json has not been unpacked');
  const sheet = JSON.parse(fs.readFileSync(sheetFile, 'utf8'));
  const png = layout.within(path.dirname(sheetFile), sheetModel.formatOf(sheet).file);
  // The other sheets graphics.json lists, each a description and a picture,
  // found by what the host finds them with -- here as paths, not data: URIs.
  const { others, otherPngs } = sheetFiles.otherSheets(graphics, here, null);
  return { graphics: graphics, sheet: sheet, png: png, others: others, otherPngs: otherPngs,
           graphicCount: sheetFiles.graphicCountOf(layout.gameDirOf(here)) };
}

function bootFor(game) {
  const files = filesFor(game);
  return {
    graphics: files.graphics,
    sheet: files.sheet,
    others: files.others,
    game: game,
    eol: '\n',
    sheetPng: null,
    otherPngs: {},
    graphicCount: files.graphicCount,
    showSave: false
  };
}

// A DOM small enough to run the page against: the page only ever creates
// elements, sets text and appends, so this records rather than renders. A
// listener is kept, so a test can click.
function fakePage(boot) {
  function element(tag) {
    const node = {
      tagName: tag, children: [], style: {}, classList: null,
      _classes: new Set(), _on: {},
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      // Setting a real node's text takes its children away, which the
      // page relies on to empty a list before filling it again.
      _text: '',
      get textContent() { return this._text; },
      set textContent(v) { this._text = String(v); this.children = []; },
      title: '', type: '', placeholder: '', value: '',
      disabled: false, id: '', selected: false,
      appendChild(child) { this.children.push(child); return child; },
      addEventListener(type, fn) { this._on[type] = fn; },
      removeEventListener() {}
    };
    node.classList = {
      add: (c) => node._classes.add(c),
      remove: (c) => node._classes.delete(c),
      contains: (c) => node._classes.has(c)
    };
    return node;
  }

  const byId = {};
  for (const id of ['title', 'summary', 'problems', 'map', 'map-size', 'detail',
                    'dialog', 'state', 'save']) {
    byId[id] = element('div');
    byId[id].id = id;
  }
  const saved = [];
  const sandbox = {
    window: {},
    document: {
      createElement: element,
      getElementById: (id) => byId[id] || null,
      head: element('head')
    },
    console: console
  };
  // assemble() injects the host, the way the editor does; it keeps what the
  // page saves here.
  sandbox.window.saved = saved;
  vm.createContext(sandbox);
  new vm.Script(scriptOf(assemble(boot))).runInContext(sandbox);
  return { byId: byId, saved: saved, head: sandbox.document.head };
}

// The button under a node that says `text`.
function buttonIn(node, text) {
  const found = under(node).find((n) => n.tagName === 'button' && n.textContent === text);
  assert.ok(found, 'no ' + text + ' button');
  return found;
}

// Every node under one, depth first.
function under(node) {
  return [node].concat(...node.children.map(under));
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
  assert.deepStrictEqual(markers, ['/*@sheet_model.js@*/', '/*@room_render.js@*/',
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

test('the picture is where the sheet says, in the game’s art/', () => {
  // The sheet is in metadata/ and names its picture ../art/sprites.png. The
  // host follows that, relative to the sheet and no further than the game.
  for (const game of ['knightlore', 'pentagram']) {
    const png = filesFor(game).png;
    assert.ok(png, game + ': the sheet names no picture the host would follow');
    assert.strictEqual(path.relative(path.join(FILMATION, game), png),
                       path.join('art', 'sprites.png'), game);
    assert.ok(fs.existsSync(png), png + ' is missing');
  }
});

test('the boot carries the table, the sheet and nothing beside it', () => {
  // Two files, and only the first is the document. graphics.json is what this
  // edits; sprites.json travels with it read-only, for the pictures and the
  // names, and sprites.png for the pixels.
  const boot = bootFor('pentagram');
  assert.deepStrictEqual(Object.keys(boot).sort(),
    ['eol', 'game', 'graphicCount', 'graphics', 'others', 'otherPngs', 'sheet',
     'sheetPng', 'showSave'].sort());
});

test('each game’s graphic count is what its sprite_sheet.py builds it with', () => {
  // The table cannot say: Lightkeep is built for 512 and uses none past 255.
  assert.strictEqual(bootFor('knightlore').graphicCount, 256);
  assert.strictEqual(bootFor('pentagram').graphicCount, 172);
  assert.strictEqual(bootFor('lightkeep').graphicCount, 512);
});

test('lightkeep: the other sheets are listed, described and committed', () => {
  // The descriptions -- names and rectangles, no pixels -- are carried; the
  // pictures are converted from your own copy of Melkhior's Mansion and are
  // not, so they are looked for where the descriptions say and not required.
  const files = filesFor('lightkeep');
  assert.deepStrictEqual(Object.keys(files.others),
    ['objects', 'furniture', 'doors', 'characters', 'walls', 'floors']);
  for (const name of Object.keys(files.others)) {
    assert.ok(files.otherPngs[name], name + ': the picture is outside the game');
    assert.strictEqual(path.relative(path.join(FILMATION, 'lightkeep'), files.otherPngs[name]),
                       path.join('art', 'melkhior', name + '.png'), name);
    assert.ok(sheetModel.spriteList(files.others[name], name).length > 0, name + ' is empty');
  }
});

test('lightkeep: a number picked from another sheet is drawn from that sheet', () => {
  const boot = bootFor('lightkeep');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  boot.otherPngs = { objects: 'data:image/png;base64,BBBB' };
  const page = fakePage(boot);

  // The first number Lightkeep leaves free -- 0 and 1 are never free -- picked,
  // then Add, then the Objects
  // sheet, then the bell, then the dialog's Add.
  const tiles = page.byId.map.children;
  const free = model.rows(boot.graphics, boot.sheet, boot.others)
    .find((r) => r.graphic > 1 && r.sprite === null).graphic;
  assert.ok(tiles[free].classList.contains('empty'), 'graphic ' + free + ' should start unused');
  tiles[free]._on.click();
  buttonIn(page.byId.detail, 'Add…')._on.click();
  assert.strictEqual(page.byId.dialog.style.display, 'flex', 'Add opened no dialog');
  const dialog = under(page.byId.dialog);
  const number = dialog.find((n) => n.classList.contains('number-choice'));
  assert.ok(number.children.find((o) => o.selected).value === String(free),
            'Add should offer the picked number when it is free');
  const choose = dialog.find((n) => n.classList.contains('sheet-choice'));
  assert.ok(choose, 'there is no sheet to choose from');
  const options = choose.children.map((o) => o.value);
  assert.deepStrictEqual(options,
    ['', 'objects', 'furniture', 'doors', 'characters', 'walls', 'floors']);
  choose.value = 'objects';
  choose._on.change();
  const picker = dialog.find((n) => n.id === 'picker');
  const bell = picker.children.find((t) => t.title.startsWith('objects:Bell.0 '));
  assert.ok(bell, 'the bell is not in the picker');
  assert.strictEqual(picker.children.length,
                     sheetModel.spriteList(boot.others.objects, 'objects').length,
                     'the picker shows the Objects sheet and only that');
  bell._on.click();
  assert.strictEqual(page.saved.length, 0, 'picking a sprite is not yet adding it');
  buttonIn(page.byId.dialog, 'Add')._on.click();
  assert.strictEqual(page.byId.dialog.style.display, 'none', 'the dialog stayed open');

  // The document that comes back adds the graphic, and the tile draws it from
  // the Objects picture by its class -- not by carrying the picture itself.
  const said = model.parseMap(page.saved[page.saved.length - 1]);
  assert.deepStrictEqual(said.graphics['objects.Bell.0'], { number: free, sprite: 'objects:Bell.0' });
  assert.deepStrictEqual(said.sheets, boot.graphics.sheets, 'the sheets were dropped');
  const tile = page.byId.map.children[free];
  assert.ok(!tile.classList.contains('empty') && !tile.classList.contains('dangling'));
  const art = under(tile).find((n) => n.classList.contains('art'));
  assert.ok(art && art.classList.contains('sheet-objects'), 'not drawn from the Objects sheet');
  assert.strictEqual(art.style.backgroundImage, undefined, 'the picture is in the tile itself');
  const rules = page.head.children.map((n) => n.textContent).join('');
  assert.ok(rules.includes('.sheet-objects { background-image: url(data:image/png;base64,BBBB)'),
            'no rule draws the Objects sheet');
  // One more drawn from the other sheets than the table already drew.
  const before = model.summary(boot.graphics, boot.sheet, boot.others).fromSheets;
  assert.ok(page.byId.summary.textContent.includes(
              (before + 1) + ' of them from the 6 other sheets'),
            page.byId.summary.textContent);
});

test('edit and delete go through the dialog and the side panel', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const used = list.find((r) => r.sprite !== null && !r.sharedWith.length);
  const other = list.find((r) => r.sprite !== null && r.sprite !== used.sprite);

  // Nothing chosen: Edit and Delete have nothing to act on.
  assert.ok(buttonIn(page.byId.detail, 'Change…').disabled);
  assert.ok(buttonIn(page.byId.detail, 'Delete').disabled);

  assert.ok(!buttonIn(page.byId.detail, 'Add…').disabled, 'Add with nothing chosen');
  page.byId.map.children[used.graphic]._on.click();
  // A number that already draws a sprite is changed, not added to.
  assert.ok(buttonIn(page.byId.detail, 'Add…').disabled, 'Add on a used graphic');
  buttonIn(page.byId.detail, 'Change…')._on.click();
  const dialog = under(page.byId.dialog);
  assert.ok(!dialog.some((n) => n.classList.contains('number-choice')),
            'Edit keeps the number it was opened on');
  const ok = buttonIn(page.byId.dialog, 'OK');
  assert.ok(ok.disabled, 'OK before anything is picked would change nothing');
  const picker = dialog.find((n) => n.id === 'picker');
  picker.children.find((t) => t.title.startsWith(other.sprite + ' '))._on.click();
  assert.ok(!ok.disabled);
  ok._on.click();
  let said = model.parseMap(page.saved[page.saved.length - 1]);
  assert.strictEqual(said.graphics[used.name].sprite, other.sprite);

  // Delete takes the sprite off and leaves the name and the nudge.
  buttonIn(page.byId.detail, 'Delete')._on.click();
  said = model.parseMap(page.saved[page.saved.length - 1]);
  assert.ok(said.graphics[used.name], 'Delete threw the entry away');
  assert.strictEqual(said.graphics[used.name].sprite, undefined);
  assert.strictEqual(said.graphics[used.name].x, boot.graphics.graphics[used.name].x);
});

// The nudge dialog's own controls, found by class.
function inDialog(page, className) {
  const found = under(page.byId.dialog).find((n) => n.classList.contains(className));
  assert.ok(found, 'no ' + className + ' in the dialog');
  return found;
}

function type(input, value) {
  input.value = String(value);
  input._on.input();
}

test('the side panel shows the chosen graphic in its box, and Nudge opens on it', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const used = list.find((r) => r.rect && model.boxFor(boot.graphics, r.graphic));
  assert.ok(buttonIn(page.byId.detail, 'Nudge…').disabled, 'Nudge with nothing chosen');
  page.byId.map.children[used.graphic]._on.click();
  const stage = page.byId.detail.children.find((n) => n.tagName === 'canvas');
  assert.ok(stage && stage.classList.contains('stage'), 'no box view in the side panel');
  stage._on.click();
  assert.strictEqual(page.byId.dialog.style.display, 'flex', 'clicking the box view opened nothing');
  assert.strictEqual(inDialog(page, 'nudge-x').value, String(used.nudge ? used.nudge.x : 0));
});

test('a nudge typed, or moved with the keys, is saved on OK as one edit', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const row = list.find((r) => r.rect && r.nudge && !r.nudge.mirrored);
  page.byId.map.children[row.graphic]._on.click();
  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  const ok = buttonIn(page.byId.dialog, 'OK');
  assert.ok(ok.disabled, 'OK before anything has moved would change nothing');

  type(inDialog(page, 'nudge-x'), row.nudge.x + 3);
  // Up the screen is UP the nudge: the game subtracts y from the row.
  page.byId.dialog._on.keydown({ key: 'ArrowUp', target: { tagName: 'CANVAS' } });
  page.byId.dialog._on.keydown({ key: 'ArrowRight', shiftKey: true,
                                 target: { tagName: 'CANVAS' } });
  assert.strictEqual(inDialog(page, 'nudge-y').value, String(row.nudge.y + 1));
  assert.strictEqual(page.saved.length, 0, 'moving it is not yet saving it');
  assert.ok(!ok.disabled);
  ok._on.click();

  assert.strictEqual(page.saved.length, 1, 'OK should be one edit');
  const said = model.parseMap(page.saved[0]);
  assert.strictEqual(said.graphics[row.name].x, row.nudge.x + 3 + 8);
  assert.strictEqual(said.graphics[row.name].y, row.nudge.y + 1);
  assert.strictEqual(said.graphics[row.name].mirrored, undefined, 'the plain nudge grew a mirrored one');
});

test('the mirrored nudge is its own, reflected from the plain one or taken away', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const row = list.find((r) => r.rect && r.nudge && !r.nudge.mirrored && r.nudge.x);
  page.byId.map.children[row.graphic]._on.click();
  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  buttonIn(page.byId.dialog, 'Mirrored')._on.click();
  assert.ok(buttonIn(page.byId.dialog, 'Use the plain one').disabled,
            'it has no mirrored nudge to take away');
  buttonIn(page.byId.dialog, 'Reflect the plain one')._on.click();
  // -(x + W): the column reflected about the point it stands on.
  assert.strictEqual(inDialog(page, 'nudge-x').value, String(-(row.nudge.x + row.rect.w)));
  buttonIn(page.byId.dialog, 'OK')._on.click();
  let said = model.parseMap(page.saved[page.saved.length - 1]);
  assert.deepStrictEqual(said.graphics[row.name].mirrored,
                         { x: -(row.nudge.x + row.rect.w), y: row.nudge.y });
  assert.strictEqual(said.graphics[row.name].x, row.nudge.x, 'the plain nudge moved');

  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  buttonIn(page.byId.dialog, 'Mirrored')._on.click();
  buttonIn(page.byId.dialog, 'Use the plain one')._on.click();
  buttonIn(page.byId.dialog, 'OK')._on.click();
  said = model.parseMap(page.saved[page.saved.length - 1]);
  assert.strictEqual(said.graphics[row.name].mirrored, undefined);
});

test('a graphic is given a box of its own, and Cancel keeps nothing', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  // One drawing a sprite whose box another number has.
  const row = list.find((r) => {
    const boxed = r.rect && model.boxFor(boot.graphics, r.graphic);
    return boxed && boxed.from !== r.graphic;
  });
  const borrowed = model.boxFor(boot.graphics, row.graphic);
  page.byId.map.children[row.graphic]._on.click();

  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  const give = buttonIn(page.byId.dialog, 'Give it a box');
  assert.notStrictEqual(give.style.display, 'none');
  give._on.click();
  type(inDialog(page, 'box-z'), borrowed.box.z + 4);
  buttonIn(page.byId.dialog, 'Cancel')._on.click();
  assert.strictEqual(page.saved.length, 0, 'Cancel saved something');

  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  buttonIn(page.byId.dialog, 'Give it a box')._on.click();
  type(inDialog(page, 'box-z'), borrowed.box.z + 4);
  buttonIn(page.byId.dialog, 'OK')._on.click();
  const said = model.parseMap(page.saved[0]);
  assert.deepStrictEqual(said.graphics[row.name].size,
                         { u: borrowed.box.u, v: borrowed.box.v, z: borrowed.box.z + 4 });
  // The graphic it was borrowed from is not touched.
  const from = list[borrowed.from];
  assert.deepStrictEqual(said.graphics[from.name].size, boot.graphics.graphics[from.name].size);
});

test('lightkeep: y is kept to seven bits, as a game of 512 graphic numbers needs', () => {
  const boot = bootFor('lightkeep');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const row = list.find((r) => r.rect && r.nudge);
  page.byId.map.children[row.graphic]._on.click();
  buttonIn(page.byId.detail, 'Nudge…')._on.click();
  type(inDialog(page, 'nudge-y'), 100);
  buttonIn(page.byId.dialog, 'OK')._on.click();
  assert.strictEqual(model.parseMap(page.saved[0]).graphics[row.name].y, 63);
});

test('lightkeep: a graphic is dragged onto another number, and a fixed one stays', () => {
  const boot = bootFor('lightkeep');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const loose = list.find((r) => r.name === 'castle.chair.1');
  const fixed = list.find((r) => r.fixed && r.sprite !== null);
  const free = list.find((r) => r.graphic > 1 && r.sprite === null && r.name === null);
  const tiles = page.byId.map.children;
  const event = () => ({ prevented: false, preventDefault() { this.prevented = true; } });

  assert.ok(tiles[fixed.graphic].classList.contains('locked'), 'a fixed tile shows no lock');
  assert.strictEqual(tiles[fixed.graphic]._on.dragstart, undefined, 'a fixed tile can be picked up');
  assert.ok(!tiles[loose.graphic].classList.contains('locked'));

  tiles[loose.graphic]._on.click();
  tiles[loose.graphic]._on.dragstart(event());
  // Nothing goes onto a fixed number; an unused one takes it.
  const onFixed = event();
  tiles[fixed.graphic]._on.dragover(onFixed);
  assert.ok(!onFixed.prevented, 'a fixed number offered to take the drop');
  const onFree = event();
  tiles[free.graphic]._on.dragover(onFree);
  assert.ok(onFree.prevented, 'an unused number refused the drop');
  tiles[free.graphic]._on.drop(event());

  assert.strictEqual(page.saved.length, 1, 'the drop should be one edit');
  const said = model.parseMap(page.saved[0]);
  assert.strictEqual(said.graphics['castle.chair.1'].number, free.graphic);
  assert.strictEqual(said.graphics['castle.chair.1'].sprite, loose.sprite);
  // The map and the side panel follow it to its new number.
  assert.ok(page.byId.map.children[free.graphic].classList.contains('here'));
  assert.ok(page.byId.map.children[loose.graphic].classList.contains('empty'));
  const heading = page.byId.detail.children.find((n) => n.tagName === 'h3');
  assert.strictEqual(heading.textContent, 'Graphic ' + free.graphic);
});

test('the map draws at a fixed size when one is picked', () => {
  const boot = bootFor('knightlore');
  boot.sheetPng = 'data:image/png;base64,AAAA';
  const page = fakePage(boot);
  const list = model.rows(boot.graphics, boot.sheet, boot.others);
  const used = list.find((r) => r.rect);
  assert.ok(!page.byId.map.classList.contains('fixed'), 'the map starts at Fit');
  buttonIn(page.byId['map-size'], '×2')._on.click();
  assert.ok(page.byId.map.classList.contains('fixed'));
  const box = under(page.byId.map.children[used.graphic])
    .find((n) => n.classList.contains('artbox'));
  assert.strictEqual(box.style.width, used.rect.w * 2 + 'px');
  assert.strictEqual(box.style.height, used.rect.h * 2 + 'px');
  assert.ok(buttonIn(page.byId['map-size'], '×2').classList.contains('on'));
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
