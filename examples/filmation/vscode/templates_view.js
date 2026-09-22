// A Filmation castle's templates, as the editor for templates.json.
//
// The room designer's tabs each edit the room on screen. A template is not
// part of a room: it is a castle-wide piece that every room naming it draws,
// so a change to one moves all of them. That is a different job, and it has a
// file of its own -- templates.json -- and so an editor of its own.
//
// Being a custom editor on that file is the point. The document is the model:
// every change the page makes comes back as the whole file and goes in through
// a WorkspaceEdit, so undo, redo, the dirty mark and Save are the editor's own.
//
// It reads rooms.json beside it, for what the rooms make of each template --
// how many place it, which, and the floor to stand it on -- and follows that
// file as it changes. It writes rooms.json only to rename a template: rooms
// refer to templates by name, so a rename is one edit across both files, and
// VS Code offers to undo it across both.
//
// room_model.js and room_render.js are the pure halves, shared with the room
// designer and with the tests.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const model = require('./room_model');
const { codeReferences } = require('./template_refs');

const VIEW_TYPE = 'filmation.roomTemplates';

// The pure files the page inlines, in the order its markers name them.
const INLINED = ['sheet_model.js', 'room_model.js', 'room_render.js'];

// A castle is always the two files together, and each names the other in its
// meta. Nothing here assumes either name.

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

function readJsonIfThere(file) {
  const text = readIfThere(file);
  try {
    return text ? JSON.parse(text) : null;
  } catch (err) {
    return null;
  }
}

function imageUri(file) {
  try {
    return 'data:image/png;base64,' + fs.readFileSync(file).toString('base64');
  } catch (err) {
    return null;
  }
}

// Paths a rooms.json names are relative to it, and may not climb out.
function beside(here, name) {
  const full = path.resolve(here, name);
  const inside = path.relative(here, full);
  if (!inside || inside.startsWith('..') || path.isAbsolute(inside)) return null;
  return full;
}

// A file's text as the editor has it: an open document's, unsaved edits and
// all, or else what is on the disk. The room designer beside this may be
// holding changes to rooms.json that are not saved yet, and a count of the
// rooms placing a template has to be of those.
function liveText(file) {
  const open = vscode.workspace.textDocuments.find(
    (doc) => doc.uri.fsPath.toLowerCase() === file.toLowerCase());
  return open ? open.getText() : readIfThere(file);
}

// The rooms these templates belong to, as the file says -- or null.
function roomsFileFor(document) {
  let templates = null;
  try {
    templates = JSON.parse(document.getText());
  } catch (err) {
    return null;
  }
  const named = model.roomsFileOf(templates);
  return named ? beside(path.dirname(document.uri.fsPath), named) : null;
}

function bootFor(document) {
  const here = path.dirname(document.uri.fsPath);
  let templates;
  let rooms;
  try {
    templates = model.parseTemplates(document.getText());
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) };
  }
  const roomsFile = roomsFileFor(document);
  if (!roomsFile) {
    return { error: 'it does not say which rooms it belongs to, in meta.rooms -- ' +
                    'and a template means nothing without the rooms that place it' };
  }
  const roomsName = path.basename(roomsFile);
  const roomsText = liveText(roomsFile);
  if (roomsText === null) return { error: roomsName + ', which it names, is not there' };
  try {
    rooms = model.parseAtlas(roomsText);
  } catch (err) {
    return { error: roomsName + ' is not readable: ' + (err && err.message) };
  }
  const mismatch = model.pairProblem(roomsName, rooms,
                                     path.basename(document.uri.fsPath), templates);
  if (mismatch) return { error: mismatch };
  const named = model.spriteFilesOf(rooms);
  const sheetFile = beside(here, named.sheet);
  const atlasFile = beside(here, named.atlas);
  const graphicsFile = beside(here, named.graphics);
  return {
    templates: templates,
    rooms: rooms,
    eol: document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n',
    roomsEol: model.eolOf(roomsText),
    sheet: atlasFile && readJsonIfThere(atlasFile),
    graphics: graphicsFile && readJsonIfThere(graphicsFile),
    sheetPng: sheetFile && imageUri(sheetFile),
    codeRefs: codeReferences(here)
  };
}

function brokenHtml(document, why) {
  const escape = (text) => String(text).replace(/[&<>]/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  return '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body ' +
    'style="font: 13px var(--vscode-font-family, sans-serif); ' +
    'color: var(--vscode-foreground); padding: 24px;">' +
    '<h2>' + escape(path.basename(document.uri.fsPath)) + ' cannot be opened as templates</h2>' +
    '<p>' + escape(why) + '</p>' +
    '<p style="opacity:.7">Reopen it with the text editor to fix it, or run the ' +
    'game’s rooms.py against its room_data.bin to make a fresh pair.</p>' +
    '</body></html>';
}

function pageHtml(document) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
              'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; ' +
              'img-src data:;">';
  const boot = bootFor(document);
  if (boot.error) return brokenHtml(document, boot.error);
  // JSON goes into a <script>, so anything that could close it early is
  // escaped -- a template's name is text out of a file.
  const bootJs = 'window.templatesHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let reload = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && event.data.type === "reload" && reload) reload(event.data.boot);\n' +
    '  });\n' +
    '  return {\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    save: function (text) { vscode.postMessage({ type: "save", text: text }); },\n' +
    '    rename: function (templates, rooms) {\n' +
    '      vscode.postMessage({ type: "rename", templates: templates, rooms: rooms });\n' +
    '    },\n' +
    '    showRoom: function (n) { vscode.postMessage({ type: "room", room: n }); },\n' +
    '    picked: function () {},\n' +
    '    onReload: function (fn) { reload = fn; }\n' +
    '  };\n' +
    '})();\n';

  let html = fs.readFileSync(path.join(__dirname, 'templates_view.html'), 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">');
  for (const name of INLINED) {
    const source = fs.readFileSync(path.join(__dirname, name), 'utf8');
    html = html.replace('/*@' + name + '@*/', () => source);
  }
  return html.replace('/*@host@*/', () => bootJs);
}

// One open templates editor. The document is the model, so this holds only
// what it cannot: which text this side wrote, so that the change event can
// tell an edit the page made from one that came from anywhere else.
class TemplatesSession {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.roomsFile = roomsFileFor(document) || '';
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
    if (!message) return;
    if (message.type === 'save') this.write(message.text);
    else if (message.type === 'rename') this.rename(message.templates, message.rooms);
    else if (message.type === 'room') {
      vscode.commands.executeCommand('filmation.showRoomOf',
                                     vscode.Uri.file(this.roomsFile), message.room);
    }
  }

  // The whole document, replaced: one step of the editor's undo a change.
  write(text) {
    if (text === this.document.getText()) return;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(this.document.uri,
                 new vscode.Range(0, 0, this.document.lineCount, 0), text);
    this.written = text;
    vscode.workspace.applyEdit(edit);
  }

  // A rename is both files at once. Rooms name their templates, so a rename
  // that changed only this one would leave every room that places it naming
  // something that no longer exists -- and one WorkspaceEdit across both is
  // one change to VS Code, which offers to undo it in both.
  async rename(templatesText, roomsText) {
    const roomsUri = vscode.Uri.file(this.roomsFile);
    let rooms;
    try {
      rooms = await vscode.workspace.openTextDocument(roomsUri);
    } catch (err) {
      vscode.window.showErrorMessage('Could not open ' + path.basename(this.roomsFile) +
                                     ' to rename in it: ' + err.message);
      return;
    }
    const edit = new vscode.WorkspaceEdit();
    edit.replace(this.document.uri,
                 new vscode.Range(0, 0, this.document.lineCount, 0), templatesText);
    if (roomsText !== rooms.getText()) {
      edit.replace(roomsUri, new vscode.Range(0, 0, rooms.lineCount, 0), roomsText);
    }
    this.written = templatesText;
    await vscode.workspace.applyEdit(edit);
  }

  // Either file moved under us: an undo, the text editor, the room designer
  // beside this, or rooms.py having rewritten them. Reload from both.
  documentChanged(event) {
    const changed = event.document.uri.fsPath.toLowerCase();
    const ours = this.document.uri.fsPath.toLowerCase();
    // Which rooms it belongs to can itself be edited.
    this.roomsFile = roomsFileFor(this.document) || this.roomsFile;
    if (changed !== ours && changed !== this.roomsFile.toLowerCase()) return;
    if (changed === ours && this.document.getText() === this.written) return;
    if (changed === ours) this.written = null;
    const boot = bootFor(this.document);
    if (boot.error) return;                 // mid-keystroke in the text editor
    this.panel.webview.postMessage({ type: 'reload', boot: boot });
  }

  dispose() {
    for (const item of this.disposables) item.dispose();
    this.disposables = [];
  }
}

class TemplatesEditorProvider {
  async resolveCustomTextEditor(document, panel) {
    new TemplatesSession(document, panel);
  }
}

// Moves the active editor into a window of its own. There is no API for
// opening an editor straight into one, so it is opened, made active, and
// moved. Where the command is missing -- an older VS Code, or one with
// auxiliary windows turned off -- the editor just stays where it opened.
const MOVE_TO_NEW_WINDOW = 'workbench.action.moveEditorToNewWindow';

// Open a castle's templates, in a window of their own, from its rooms.json.
async function openTemplatesOf(roomsUri) {
  let atlas = null;
  try {
    atlas = model.parseAtlas(liveText(roomsUri.fsPath) || '');
  } catch (err) {
    atlas = null;
  }
  const roomsName = path.basename(roomsUri.fsPath);
  const leaf = atlas ? model.templatesFileOf(atlas) : null;
  if (!leaf) {
    vscode.window.showErrorMessage(roomsName + ' does not say where its templates are, ' +
                                   'in meta.templates.');
    return;
  }
  const file = beside(path.dirname(roomsUri.fsPath), leaf);
  if (!file || !fs.existsSync(file)) {
    vscode.window.showErrorMessage(roomsName + ' names ' + leaf + ' as its templates, and ' +
                                   'it is not beside it. Run the game’s rooms.py against ' +
                                   'its room_data.bin to make the pair.');
    return;
  }
  const uri = vscode.Uri.file(file);
  // Already open somewhere -- a window of its own, most likely: bring it
  // forward there rather than opening a second copy in this window.
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      const input = tab.input;
      if (input && input.viewType === VIEW_TYPE && input.uri &&
          input.uri.fsPath.toLowerCase() === file.toLowerCase()) {
        await vscode.commands.executeCommand('vscode.openWith', uri, VIEW_TYPE,
                                             { viewColumn: group.viewColumn });
        return;
      }
    }
  }
  await vscode.commands.executeCommand('vscode.openWith', uri, VIEW_TYPE,
                                       { viewColumn: vscode.ViewColumn.Beside });
  try {
    await vscode.commands.executeCommand(MOVE_TO_NEW_WINDOW);
  } catch (err) {
    // Beside the designer is a perfectly good place for it too.
  }
}

function activateTemplatesEditor(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new TemplatesEditorProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    })
  );
}

module.exports = { activateTemplatesEditor, openTemplatesOf, VIEW_TYPE, pageHtml, bootFor };
