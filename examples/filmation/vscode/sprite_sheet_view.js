// The sprite sheet editor's host: a custom editor on a sheet's description
// -- metadata/sprites.json, or one of Lightkeep's metadata/melkhior/*.json --
// that edits the picture it names, pixel by pixel.
//
// Not a text editor, unlike the room designer and the graphic map: the thing
// edited is a PNG, which VS Code cannot hold as a text document. So the
// document is a SheetFile (sprite_sheet_document.js), every stroke is an
// edit VS Code is told about -- which gives it the dirty mark, Ctrl+Z and
// Ctrl+Y -- and Save writes the picture. A change to the layout -- a sprite
// resized, which can move it, or the whole sheet tidied -- changes the
// description as well, and is one edit across the two; Save writes both.
//
// The page is sprite_sheet_view.html, with sprite_sheet_model.js inlined, and it holds a copy of the pixels to draw
// from. What it paints comes back here as a list of pixels; what is undone
// goes back to it the same way.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { SheetFile, graphicsFor } = require('./sprite_sheet_document');
const layout = require('./game_layout');

const model = require('./sprite_sheet_model');

const VIEW_TYPE = 'filmation.spriteSheet';
const INLINED = ['sprite_sheet_model.js'];
// Past this many changed pixels a layout change sends the whole picture
// rather than the list: a tidy moves most of a sheet.
const LAYOUT_PIXELS = 200000;

// What the page is given: the description, the picture as a data: URI, and
// which graphics draw each sprite.
function bootFor(document) {
  const file = document.file;
  const drawn = graphicsFor(document.uri.fsPath);
  // The game and where in it: lightkeep/metadata/melkhior/doors.json.
  const game = layout.gameDirAbove(path.dirname(document.uri.fsPath));
  const name = path.relative(path.dirname(game), document.uri.fsPath).split(path.sep).join('/');
  return {
    sheet: file.sheet,
    title: name,
    picture: path.basename(file.pngPath),
    png: 'data:image/png;base64,' + file.pngBytes().toString('base64'),
    graphics: drawn ? drawn.graphics : null,
    prefix: drawn ? drawn.prefix : null
  };
}

function pageHtml(document) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
              'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; ' +
              'img-src data:;">';
  const boot = bootFor(document);
  const bootJs = 'window.spriteSheetHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let heard = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && heard) heard(event.data);\n' +
    '  });\n' +
    '  return {\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    paint: function (changes) { vscode.postMessage({ type: "paint", changes: changes }); },\n' +
    '    resize: function (path, edges) { vscode.postMessage({ type: "resize", path: path, edges: edges }); },\n' +
    '    tidy: function () { vscode.postMessage({ type: "tidy" }); },\n' +
    // The page's own settings -- zoom, tool, which sprite -- kept by the
    // webview while it is hidden and brought back.
    '    state: function () { return vscode.getState() || {}; },\n' +
    '    keep: function (state) { vscode.setState(state); },\n' +
    '    onMessage: function (fn) { heard = fn; }\n' +
    '  };\n' +
    '})();\n';
  let html = fs.readFileSync(path.join(__dirname, 'sprite_sheet_view.html'), 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(__dirname, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

function brokenHtml(uri, why) {
  const escape = (text) => String(text).replace(/[&<>]/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  return '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body ' +
    'style="font: 13px var(--vscode-font-family, sans-serif); ' +
    'color: var(--vscode-foreground); padding: 24px;">' +
    '<h2>' + escape(path.basename(uri.fsPath)) + ' cannot be opened as a sprite sheet</h2>' +
    '<p>' + escape(why) + '</p>' +
    '<p style="opacity:.7">Reopen it with the text editor to look at it.</p>' +
    '</body></html>';
}

// The document VS Code holds: the file, or why it could not be opened -- a
// description whose picture is missing still opens, to say so.
class SheetDocument {
  constructor(uri, file, error) {
    this.uri = uri;
    this.file = file;
    this.error = error;
    this.panels = new Set();
    this.watchers = [];
  }

  // Tell every page showing it.
  post(message) {
    for (const panel of this.panels) panel.webview.postMessage(message);
  }

  dispose() {
    for (const w of this.watchers) w.dispose();
    this.watchers = [];
  }
}

function load(uri) {
  try {
    return new SheetDocument(uri, SheetFile.load(uri.fsPath), null);
  } catch (err) {
    return new SheetDocument(uri, null, err.message || String(err));
  }
}

class SpriteSheetProvider {
  constructor() {
    this.changed = new vscode.EventEmitter();
    this.onDidChangeCustomDocument = this.changed.event;
  }

  async openCustomDocument(uri, context) {
    const document = load(uri);
    // A backup VS Code kept when the window closed with the sheet unsaved:
    // the picture as it was, painted pixels and all.
    if (context.backupId && document.file) {
      try {
        const bytes = await vscode.workspace.fs.readFile(vscode.Uri.parse(context.backupId));
        const saved = JSON.parse(Buffer.from(bytes).toString('utf8'));
        const kept = require('./png_codec').decode(Buffer.from(saved.png, 'base64'));
        document.file.picture = kept;
        document.file.edited = true;
      } catch (err) {
        // A backup that cannot be read leaves the file as the disk has it.
      }
    }
    if (document.file) this.watch(document);
    return document;
  }

  // A paint program saving the picture, or the description changing: reload,
  // unless there is painting here not yet saved, which would be lost.
  watch(document) {
    const file = document.file;
    for (const target of [file.pngPath, file.jsonPath]) {
      const watcher = vscode.workspace.createFileSystemWatcher(
        new vscode.RelativePattern(path.dirname(target), path.basename(target)));
      watcher.onDidChange(() => {
        if (file.edited) return;
        if (target === file.pngPath && !file.changedOnDisk()) return;   // our own Save
        if (target === file.jsonPath) {
          let text = null;
          try { text = fs.readFileSync(file.jsonPath, 'utf8'); } catch (err) { return; }
          if (text === file.text) return;                                 // ...of both
        }
        try {
          file.revert();
        } catch (err) {
          return;
        }
        document.post({ type: 'reload', boot: bootFor(document) });
      });
      document.watchers.push(watcher);
    }
  }

  async resolveCustomEditor(document, panel) {
    panel.webview.options = { enableScripts: true };
    if (!document.file) {
      panel.webview.html = brokenHtml(document.uri, document.error);
      return;
    }
    document.panels.add(panel);
    panel.onDidDispose(() => document.panels.delete(panel));
    panel.webview.html = pageHtml(document);
    panel.webview.onDidReceiveMessage((message) => this.fromPage(document, message));
  }

  fromPage(document, message) {
    if (!message) return;
    if (message.type === 'resize') {
      this.layout(document, 'Resize ' + message.path, () => model.resizeSprite(
        document.file.picture, document.file.colours, document.file.sheet, message.path,
        message.edges || {}));
      return;
    }
    if (message.type === 'tidy') {
      this.layout(document, 'Tidy the sheet', () => model.tidySheet(
        document.file.picture, document.file.colours, document.file.sheet));
      return;
    }
    if (message.type !== 'paint' || !Array.isArray(message.changes)) return;
    const done = document.file.paint(message.changes);
    if (!done.length) return;
    // The page painted these already; any it was refused go back to what
    // this side has, so the two copies agree.
    if (done.length !== message.changes.length) {
      document.post({ type: 'pixels', changes: this.colours(document, message.changes) });
    }
    this.changed.fire({
      document: document,
      label: 'Paint ' + done.length + ' pixel' + (done.length === 1 ? '' : 's'),
      undo: () => {
        document.file.apply(done, true);
        document.post({ type: 'pixels', changes: done.map((c) => ({ x: c.x, y: c.y, to: c.from })) });
      },
      redo: () => {
        document.file.apply(done, false);
        document.post({ type: 'pixels', changes: done.map((c) => ({ x: c.x, y: c.y, to: c.to })) });
      }
    });
  }

  // A change to the layout: worked out by the model on this side's pixels,
  // made one edit of VS Code's, and sent to the page. A change the model
  // refuses -- a sprite shrunk to nothing, say -- goes back with the reason.
  layout(document, label, work) {
    let result;
    try {
      result = work();
    } catch (err) {
      document.post({ type: 'refused', why: err.message || String(err) });
      return;
    }
    const record = document.file.layout(result.picture, result.sheet);
    const note = result.moved
      ? 'There was no room for it where it was, so it moved to ' + result.rect.x + ', ' +
        result.rect.y + (record.diff.toHeight > record.diff.fromHeight
          ? ', and the picture grew to ' + record.diff.toHeight + ' rows' : '') + '.'
      : '';
    this.sendLayout(document, record, false, note);
    this.changed.fire({
      document: document,
      label: label,
      undo: () => {
        document.file.relayout(record, true);
        this.sendLayout(document, record, true, '');
      },
      redo: () => {
        document.file.relayout(record, false);
        this.sendLayout(document, record, false, '');
      }
    });
  }

  // The page's copy brought to match: the description and the pixels that
  // changed, or -- for a change touching most of a tall sheet, a tidy -- the
  // whole picture again.
  sendLayout(document, record, backwards, note) {
    const file = document.file;
    const diff = record.diff;
    if (diff.at.length > LAYOUT_PIXELS) {
      document.post({ type: 'reload', boot: bootFor(document), note: note });
      return;
    }
    document.post({
      type: 'layout', sheet: file.sheet, width: file.picture.width, height: file.picture.height,
      at: Array.from(diff.at), values: Array.from(backwards ? diff.before : diff.after), note: note
    });
  }

  // What this side has at the given pixels, for putting the page right.
  colours(document, points) {
    return points.map((p) => ({
      x: p.x, y: p.y, to: model.colourAt(document.file.picture, document.file.colours, p.x, p.y)
    })).filter((p) => p.to);
  }

  async saveCustomDocument(document) {
    document.file.save();
  }

  async saveCustomDocumentAs() {
    throw new Error('a sprite sheet is two files, a description and the picture it names, ' +
                    'so it is saved where it is; copy both to make another');
  }

  async revertCustomDocument(document) {
    document.file.revert();
    document.post({ type: 'reload', boot: bootFor(document) });
  }

  async backupCustomDocument(document, context) {
    const body = JSON.stringify({ png: document.file.pngBytes().toString('base64') });
    await vscode.workspace.fs.writeFile(context.destination, Buffer.from(body, 'utf8'));
    return {
      id: context.destination.toString(),
      delete: async () => {
        try {
          await vscode.workspace.fs.delete(context.destination);
        } catch (err) {
          // Already gone.
        }
      }
    };
  }
}

function activateSpriteSheet(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new SpriteSheetProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    }),
    vscode.commands.registerCommand('filmation.openSpriteSheet', async (uri) => {
      const file = uri || await pickSheet();
      if (!file) return;
      await vscode.commands.executeCommand('vscode.openWith', file, VIEW_TYPE);
    })
  );
}

// The sheets in the workspace, for the command-palette route: every game's
// sprites.json, and the other sheets it keeps beside it.
async function pickSheet() {
  const found = await vscode.workspace.findFiles(
    '{**/examples/filmation/*/metadata/sprites.json,**/examples/filmation/*/metadata/melkhior/*.json}',
    '**/node_modules/**', 50);
  if (!found.length) {
    vscode.window.showErrorMessage('No Filmation sprite sheet in this workspace.');
    return null;
  }
  const pick = await vscode.window.showQuickPick(
    found.map((uri) => ({ label: vscode.workspace.asRelativePath(uri), uri: uri })),
    { placeHolder: 'Which sprite sheet?' });
  return pick ? pick.uri : null;
}

module.exports = { activateSpriteSheet, VIEW_TYPE, pageHtml, bootFor };
