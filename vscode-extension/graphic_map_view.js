// The Filmation graphic map, in the editor.
//
// examples/filmation/<game>/graphics.json is the table a game indexes by:
// for each of its graphic numbers, which sprite draws it, the pixel nudge that
// lines that bitmap up, and the box it occupies in the world. As text it is
// numbers pointing at names; this opens it as the bitmaps those name.
//
// sprites.json is read alongside, for the pictures and the rectangles they come
// out of, and sprites.png for the pixels. Neither is edited here.
//
// The same shape as room_view.js, and for the same reasons: the file is the
// model, every change comes back as the whole document and goes in through a
// WorkspaceEdit, so undo, the dirty mark and Save are the editor's own. An
// edit from anywhere else is pushed back to the page.
//
// graphic_map_model.js is the pure half, shared with the page and with
// tests/graphic_map_model_test.js.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const model = require('./graphic_map_model');

const VIEW_TYPE = 'zxspectrum.graphicMap';

// The one pure file the page inlines, in the order its markers name it.
const INLINED = ['sheet_model.js', 'graphic_map_model.js'];

// The sheet this table's names point into, and the picture it describes.
// Both are written by sprite_sheet.py, ONCE, and nothing regenerates them.
// They sit beside the document, which is how graphics.json names the first of
// them -- so a game whose files are called something else still opens.
const SHEET_JSON = 'sprites.json';
const SHEET_PNG = 'sprites.png';

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// The sheet as a data: URI. A webview cannot read a file of its own, so the
// picture travels with the page the way room_view.js sends the same one.
function imageUri(file) {
  try {
    return 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
  } catch (err) {
    return null;
  }
}

// What the page needs to open the document: the map, the artwork, and the
// file's own line endings so writing it back changes only what was edited.
function bootFor(document) {
  const here = path.dirname(document.uri.fsPath);
  let graphics;
  try {
    graphics = model.parseMap(document.getText());
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) };
  }

  // The sheet is an input, not part of the document. A missing one is not an
  // error: the table is still readable and still editable, it just has no
  // pictures to show, and saying so beats refusing to open the file.
  let sheet = {};
  const sheetText = readIfThere(
    path.join(here, (graphics && graphics.sprites) || SHEET_JSON));
  if (sheetText !== null) {
    try {
      sheet = JSON.parse(sheetText);
    } catch (err) {
      sheet = {};
    }
  }

  return {
    // The document is graphics.json; the sheet travels with it, read-only.
    graphics: graphics,
    sheet: sheet,
    game: path.basename(here),
    eol: document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n',
    sheetPng: imageUri(path.join(here, SHEET_PNG)),
    // The editor saves the document, so the page needs no Save of its own.
    showSave: false
  };
}

function pageHtml(document) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
              'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; ' +
              'font-src data:; img-src data:;">';
  const boot = bootFor(document);
  if (boot.error) return brokenHtml(document, boot.error);
  // JSON goes into a <script>, so anything that could close it early is
  // escaped -- a sprite's name is text out of a file.
  const bootJs = 'window.graphicMapHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let reload = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && event.data.type === "reload" && reload) reload(event.data.boot);\n' +
    '  });\n' +
    '  return {\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    save: function (text) { vscode.postMessage({ type: "save", text: text }); },\n' +
    '    onReload: function (fn) { reload = fn; }\n' +
    '  };\n' +
    '})();\n';

  let html = fs.readFileSync(path.join(__dirname, 'graphic_map_view.html'), 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(__dirname, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

function brokenHtml(document, why) {
  const escape = (text) => String(text).replace(/[&<>]/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  return '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body ' +
    'style="font: 13px var(--vscode-font-family, sans-serif); ' +
    'color: var(--vscode-foreground); padding: 24px;">' +
    '<h2>' + escape(path.basename(document.uri.fsPath)) + ' is not a sprite sheet</h2>' +
    '<p>' + escape(why) + '</p>' +
    '<p style="opacity:.7">Reopen it with the text editor to fix it, or run the ' +
    'game’s extractor once against your own copy to make a fresh one.</p>' +
    '</body></html>';
}

// One open map. The document is the model, so this holds only what the
// document cannot: which text this side wrote, so the document's own change
// event can tell an edit the page made from one that came from anywhere else.
class MapSession {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.written = null;
    this.disposables = [];

    panel.webview.options = { enableScripts: true };
    panel.webview.html = pageHtml(document);
    this.disposables.push(
      panel.webview.onDidReceiveMessage((message) => this.fromPage(message)),
      vscode.workspace.onDidChangeTextDocument((event) => this.documentChanged(event))
    );
    panel.onDidDispose(() => this.dispose());
  }

  fromPage(message) {
    if (message && message.type === 'save') this.write(message.text);
  }

  write(text) {
    if (text === this.document.getText()) return;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(
      this.document.uri,
      new vscode.Range(0, 0, this.document.lineCount, 0),
      text
    );
    this.written = text;
    vscode.workspace.applyEdit(edit);
  }

  documentChanged(event) {
    if (event.document.uri.toString() !== this.document.uri.toString()) return;
    const text = this.document.getText();
    if (text === this.written) return;      // our own edit coming back
    this.written = null;
    const boot = bootFor(this.document);
    if (boot.error) return;                 // mid-keystroke in the text editor
    this.panel.webview.postMessage({ type: 'reload', boot: boot });
  }

  dispose() {
    for (const item of this.disposables) item.dispose();
    this.disposables = [];
  }
}

class GraphicMapProvider {
  async resolveCustomTextEditor(document, panel) {
    new MapSession(document, panel);
  }
}

function activateGraphicMap(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new GraphicMapProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    }),
    vscode.commands.registerCommand('zxspectrum.openGraphicMap', async (uri) => {
      const file = uri || await pickMap();
      if (!file) return;
      await vscode.commands.executeCommand('vscode.openWith', file, VIEW_TYPE);
    })
  );
}

// The Filmation sprite sheets in the workspace, for the command-palette route.
// There is one a game and the games live side by side.
async function pickMap() {
  const found = await vscode.workspace.findFiles(
    '**/examples/filmation/*/sprites.json', '**/node_modules/**', 20);
  if (!found.length) {
    vscode.window.showErrorMessage(
      'No Filmation sprites.json in the workspace. Run a game’s extractor ' +
      'and then its sprite_sheet.py once, against your own copy of the game.');
    return null;
  }
  if (found.length === 1) return found[0];
  const pick = await vscode.window.showQuickPick(
    found.map((uri) => ({
      label: path.basename(path.dirname(uri.fsPath)),
      description: vscode.workspace.asRelativePath(uri),
      uri: uri
    })),
    { placeHolder: 'Which game’s graphic map?' }
  );
  return pick ? pick.uri : null;
}

module.exports = { activateGraphicMap, VIEW_TYPE, pageHtml, bootFor };
