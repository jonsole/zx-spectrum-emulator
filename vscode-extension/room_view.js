// Designing a Filmation room, in the editor.
//
// A game's rooms live in examples/filmation/<game>/rooms.json: rooms.py
// decodes the game's own packed tables into it, and rooms_source.py turns it
// back into room_data.s, which is what the build assembles. So the JSON is the
// editable form, and this opens it as a picture of the castle rather than
// twelve thousand lines of numbers.
//
// The file is the model. Every change the page makes comes back as the whole
// document and goes in through a WorkspaceEdit, so undo, the dirty mark and
// Save are the editor's own and nothing here keeps a change list. An edit from
// anywhere else -- an undo, the text editor, rooms.py having rewritten the
// file -- is pushed back to the page, which reopens on the room it was on.
//
// The page itself, room_view.html, is the same page the browser gets from
// scripts/room_designer.py. Everything that differs between the two arrives
// through a `roomHost` object injected into it, and the two hosts inject the
// same shape, so the page has no idea which it is in.
//
// room_model.js and room_render.js are the pure halves, shared with the page
// and with tests/room_model_test.js and tests/room_render_test.js.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const model = require('./room_model');

const VIEW_TYPE = 'zxspectrum.roomDesign';

// The two pure files the page inlines, in the order its markers name them.
const INLINED = ['room_model.js', 'room_render.js'];

// What a game keeps beside its rooms.json, which the file itself names in
// meta.sprites -- room_model.js's spriteFilesOf, with the names it always used
// as the fallback. All three are gitignored except the adjustments: the
// artwork is Ultimate's, and build.py unpacks it from the packed file the
// first time it runs. Without it the page still opens and still edits, and
// says it has no sheet rather than drawing an empty room.
//
// A named path is relative to the rooms.json, and may not climb out of its
// directory: the file is data, and data does not get to point the editor at
// something elsewhere on the disk.
function beside(here, name) {
  const full = path.resolve(here, name);
  const inside = path.relative(here, full);
  if (!inside || inside.startsWith('..') || path.isAbsolute(inside)) return null;
  return full;
}

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// The sprite sheet as a data: URI. A webview cannot read a file of its own, and
// the browser host hands it over the same way, so the page takes one path for
// both rather than a URL it would have to resolve differently in each.
function imageUri(file) {
  try {
    return 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
  } catch (err) {
    return null;
  }
}

// What the page needs to open the document: the castle, the artwork, and the
// file's own line endings so that writing it back changes only what was edited.
function bootFor(document, room) {
  const here = path.dirname(document.uri.fsPath);
  const text = document.getText();
  let atlas;
  try {
    atlas = JSON.parse(text);
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) };
  }
  const named = model.spriteFilesOf(atlas);
  const atlasFile = beside(here, named.atlas);
  const sheetFile = beside(here, named.sheet);
  const adjustFile = beside(here, named.adjust);
  const sheet = atlasFile && readIfThere(atlasFile);
  return {
    atlas: atlas,
    eol: document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n',
    sheet: sheet ? JSON.parse(sheet) : null,
    sheetPng: sheetFile && imageUri(sheetFile),
    adjText: adjustFile && readIfThere(adjustFile),
    room: room === undefined ? null : room,
    // The editor saves the document, so the page needs no Save of its own.
    showSave: false,
    buildLabel: 'Build ' + path.basename(here)
  };
}

// The page with its content-security policy, the two pure files, and the
// editor's half of the host seam. The same shape extension.js gives its viewer
// pages: one inline <style>, one inline <script>, and a nonce on the script.
function pageHtml(document, room) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
              'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; ' +
              'font-src data:; img-src data:;">';
  const boot = bootFor(document, room);
  // A document that is not JSON at all -- someone part way through typing in
  // the text editor, or a file that was never a castle. Say so rather than
  // opening a page that has nothing to draw.
  if (boot.error) return brokenHtml(document, boot.error);
  // JSON goes into a <script>, so anything that could close it early is
  // escaped -- a template's name is text out of a file.
  const bootJs = 'window.roomHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let reload = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && event.data.type === "reload" && reload) reload(event.data.boot);\n' +
    '  });\n' +
    '  return {\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    save: function (text, what) { vscode.postMessage({ type: "save", text: text, what: what }); },\n' +
    '    onReload: function (fn) { reload = fn; },\n' +
    '    roomChanged: function (n) { vscode.postMessage({ type: "room", room: n }); },\n' +
    '    build: function () { vscode.postMessage({ type: "build" }); }\n' +
    '  };\n' +
    '})();\n';

  let html = fs.readFileSync(path.join(__dirname, 'room_view.html'), 'utf8')
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
    '<h2>' + escape(path.basename(document.uri.fsPath)) + ' is not a rooms.json</h2>' +
    '<p>' + escape(why) + '</p>' +
    '<p style="opacity:.7">Reopen it with the text editor to fix it, or run the ' +
    'game’s rooms.py against its room_data.bin to make a fresh one.</p>' +
    '</body></html>';
}


// One open design. The document is the model, so this holds only what the
// document cannot: which room the page is looking at, and which text this
// side wrote -- so that the document's own change event can tell an edit the
// page made from one that came from anywhere else.
class RoomSession {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.room = null;
    this.written = null;
    this.disposables = [];

    panel.webview.options = { enableScripts: true };
    panel.webview.html = pageHtml(document, null);
    this.disposables.push(
      panel.webview.onDidReceiveMessage((message) => this.fromPage(message)),
      vscode.workspace.onDidChangeTextDocument((event) => this.documentChanged(event))
    );
    panel.onDidDispose(() => this.dispose());
  }

  fromPage(message) {
    if (!message) return;
    if (message.type === 'save') this.write(message.text);
    else if (message.type === 'build') this.build();
    else if (message.type === 'room') this.room = message.room;
  }

  // The whole document, replaced. It is a big file and this is a big edit, but
  // it is one undo step per change the designer made, which is what someone
  // dragging a block about expects -- and the alternative, patching the one
  // room's lines, would have to reproduce the generator's formatting exactly.
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
    // Somebody else moved it: an undo, the text editor, or rooms.py having
    // rewritten the file. Reopen on the room the page was on if it survives.
    const boot = bootFor(this.document, this.room);
    if (boot.error) return;                 // mid-keystroke in the text editor
    this.panel.webview.postMessage({ type: 'reload', boot: boot });
  }

  // The game's own build.py, as a task, so its output lands in the terminal
  // panel where the rest of the build output does.
  build() {
    const here = path.dirname(this.document.uri.fsPath);
    const build = path.join(here, 'build.py');
    if (!fs.existsSync(build)) {
      vscode.window.showErrorMessage('No build.py beside ' + path.basename(here) +
                                     '/rooms.json.');
      return;
    }
    const python = pythonFor(here);
    vscode.tasks.executeTask(new vscode.Task(
      { type: 'zxspectrum-rooms', design: this.document.uri.fsPath },
      vscode.TaskScope.Workspace,
      'Build ' + path.basename(here),
      'zxspectrum',
      new vscode.ShellExecution(python, ['build.py'], { cwd: here })
    ));
  }

  dispose() {
    for (const item of this.disposables) item.dispose();
    this.disposables = [];
  }
}

// The repo's own interpreter, which is what its scripts are written against,
// falling back on whatever `python` is on PATH.
function pythonFor(here) {
  const repo = path.resolve(here, '..', '..', '..');
  const venv = path.join(repo, '.venv-win', 'Scripts', 'python.exe');
  return fs.existsSync(venv) ? venv : 'python';
}

class RoomDesignerProvider {
  async resolveCustomTextEditor(document, panel) {
    new RoomSession(document, panel);
  }
}

function activateRoomDesigner(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new RoomDesignerProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    }),
    vscode.commands.registerCommand('zxspectrum.openRoomDesigner', async (uri) => {
      const file = uri || await pickRooms();
      if (!file) return;
      await vscode.commands.executeCommand('vscode.openWith', file, VIEW_TYPE);
    })
  );
}

// The rooms.json files in the workspace, for the command-palette route. There
// is one a game and the games live side by side, so a quick pick beats making
// someone find the file.
async function pickRooms() {
  const found = await vscode.workspace.findFiles('**/rooms.json', '**/node_modules/**', 20);
  if (!found.length) {
    vscode.window.showErrorMessage(
      'No rooms.json in the workspace. Run a Filmation game’s rooms.py once ' +
      'against its room_data.bin to make one.');
    return null;
  }
  if (found.length === 1) return found[0];
  const pick = await vscode.window.showQuickPick(
    found.map((uri) => ({
      label: path.basename(path.dirname(uri.fsPath)),
      description: vscode.workspace.asRelativePath(uri),
      uri: uri
    })),
    { placeHolder: 'Which game’s rooms?' }
  );
  return pick ? pick.uri : null;
}

module.exports = { activateRoomDesigner, VIEW_TYPE, pageHtml, bootFor };
