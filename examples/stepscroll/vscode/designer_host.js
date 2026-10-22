// The Stepscroll Designer's editors in VS Code: each a custom text editor on
// one of examples/stepscroll/world's files -- tiles.json (the tiles) or
// blocks.json (the blocks) -- whose page also reads the other two beside it,
// and edits them when an edit reaches them (a tile's rename reaches
// blocks.json, a block's rename map.json) through their own documents, so they
// show as changed and save on their own.
//
// The Filmation designer's shape (examples/filmation/vscode/tile_map_view.js):
// the file is the model, every change comes back from the page as the whole
// document and goes in through a WorkspaceEdit, so undo, the dirty mark and
// Save are the editor's own. An edit from anywhere else -- the text editor,
// or a file beside it changing -- is pushed back to the page.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const pages = require('./pages');

// The world's files, by the name the pages use for them.
const FILES = { tiles: 'tiles.json', blocks: 'blocks.json', map: 'map.json' };

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// An open document's text if it has one (it may be edited and unsaved), else
// the file's.
function textOf(file) {
  const open = vscode.workspace.textDocuments.find((d) => d.uri.fsPath === file);
  return open ? open.getText() : readIfThere(file);
}

// What a page opens with: all three files, and the document's line endings so
// that writing it back changes only what was edited.
function bootFor(document) {
  const here = path.dirname(document.uri.fsPath);
  const boot = { eol: document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n' };
  for (const [key, name] of Object.entries(FILES)) {
    const file = path.join(here, name);
    const text = file === document.uri.fsPath ? document.getText() : textOf(file);
    if (text === null) {
      return { error: name + ' is not beside ' + path.basename(document.uri.fsPath) };
    }
    boot[key] = text;
  }
  return boot;
}

// The page's host: the boot data, and edits and settings passed to VS Code.
function hostJs(boot) {
  // JSON goes into a <script>, so anything that could close it early is escaped.
  return 'window.designerHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let reload = null;\n' +
    '  let select = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && event.data.type === "reload" && reload) reload(event.data.boot);\n' +
    '    if (event.data && event.data.type === "select" && select) select(event.data.name);\n' +
    '  });\n' +
    '  return {\n' +
    '    standalone: false,\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    edit: function (file, text) { vscode.postMessage({ type: "edit", file: file, text: text }); },\n' +
    '    state: function () { return vscode.getState() || {}; },\n' +
    '    keep: function (state) { vscode.setState(state); },\n' +
    '    onReload: function (fn) { reload = fn; },\n' +
    '    onSelect: function (fn) { select = fn; },\n' +
    '    openTile: function (name) { vscode.postMessage({ type: "openTile", name: name }); }\n' +
    '  };\n' +
    '})();\n';
}

function brokenHtml(document, why) {
  const escape = (text) => String(text).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  return '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body ' +
    'style="font: 13px var(--vscode-font-family, sans-serif); color: var(--vscode-foreground); padding: 24px;">' +
    '<h2>' + escape(path.basename(document.uri.fsPath)) + ' cannot be opened here</h2>' +
    '<p>' + escape(why) + '</p></body></html>';
}

// The open sessions by their document's path, so that one editor can ask
// another to show something (the blocks editor, a tile in the tiles editor);
// and what to show in one not open yet, by its path.
const sessions = new Map();
const pendingSelect = new Map();

// One open document. It holds only what the documents cannot: which text this
// side wrote to each, so a change event can tell the page's own edit from
// another.
class Session {
  constructor(document, panel, page) {
    this.document = document;
    this.panel = panel;
    sessions.set(document.uri.fsPath, this);
    this.here = path.dirname(document.uri.fsPath);
    this.written = {};      // file path -> the text this side last wrote
    this.disposables = [];
    panel.webview.options = { enableScripts: true };
    const boot = bootFor(document);
    panel.webview.html = boot.error ? brokenHtml(document, boot.error)
      : pages.assemble(page, hostJs(boot), crypto.randomBytes(16).toString('hex'));
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(this.here, '{' + Object.values(FILES).join(',') + '}'));
    this.disposables.push(
      watcher,
      watcher.onDidChange((uri) => this.changed(uri.fsPath, null)),
      watcher.onDidCreate((uri) => this.changed(uri.fsPath, null)),
      panel.webview.onDidReceiveMessage((message) => this.fromPage(message)),
      vscode.workspace.onDidChangeTextDocument((event) =>
        this.changed(event.document.uri.fsPath, event.document.getText()))
    );
    panel.onDidDispose(() => this.dispose());
    const pending = pendingSelect.get(document.uri.fsPath);
    if (pending !== undefined) {
      pendingSelect.delete(document.uri.fsPath);
      this.select(pending);
    }
  }

  fromPage(message) {
    if (message && message.type === 'openTile') {
      this.openTile(message.name);
      return;
    }
    if (!message || message.type !== 'edit' || !FILES[message.file]) {
      return;
    }
    this.write(path.join(this.here, FILES[message.file]), message.text);
  }

  // Asks the page to show one thing: a tile, in the tiles editor.
  select(name) {
    this.panel.webview.postMessage({ type: 'select', name });
  }

  // The tiles editor opened (or brought forward) on tiles.json beside this
  // file, showing the tile `name`.
  async openTile(name) {
    const file = path.join(this.here, FILES.tiles);
    const open = sessions.get(file);
    if (open) {
      open.panel.reveal();
      open.select(name);
      return;
    }
    pendingSelect.set(file, name);
    await vscode.commands.executeCommand('vscode.openWith', vscode.Uri.file(file), 'stepscroll.tiles');
  }

  // A file's new text, through its document (opened if it is not).
  async write(file, text) {
    const doc = file === this.document.uri.fsPath ? this.document
      : await vscode.workspace.openTextDocument(vscode.Uri.file(file));
    if (doc.getText() === text) {
      return;
    }
    const edit = new vscode.WorkspaceEdit();
    edit.replace(doc.uri, new vscode.Range(0, 0, doc.lineCount, 0), text);
    this.written[file] = text;
    await vscode.workspace.applyEdit(edit);
  }

  // A world file changed: the page follows, unless it is this side's own
  // edit coming back.
  changed(file, text) {
    if (path.dirname(file) !== this.here || Object.values(FILES).indexOf(path.basename(file)) < 0) {
      return;
    }
    if (text !== null && text === this.written[file]) {
      return;
    }
    const boot = bootFor(this.document);
    if (boot.error) {
      return;
    }
    for (const key of Object.keys(FILES)) {
      try {
        JSON.parse(boot[key]);
      } catch (err) {
        return;                             // mid-keystroke in the text editor
      }
    }
    this.panel.webview.postMessage({ type: 'reload', boot });
  }

  dispose() {
    if (sessions.get(this.document.uri.fsPath) === this) {
      sessions.delete(this.document.uri.fsPath);
    }
    for (const item of this.disposables) {
      item.dispose();
    }
    this.disposables = [];
  }
}

// One designer editor: its view type, its page, the file it opens and the
// command that opens it.
function activateEditor(context, viewType, page, file, command) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(viewType, {
      async resolveCustomTextEditor(document, panel) {
        new Session(document, panel, page);
      },
    }, {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false,
    }),
    vscode.commands.registerCommand(command, async (uri) => {
      let target = uri;
      if (!target) {
        const found = await vscode.workspace.findFiles('**/examples/stepscroll/world/' + file, '**/node_modules/**', 1);
        target = found[0];
      }
      if (!target) {
        vscode.window.showErrorMessage('No examples/stepscroll/world/' + file + ' in the workspace.');
        return;
      }
      await vscode.commands.executeCommand('vscode.openWith', target, viewType);
    })
  );
}

module.exports = { activateEditor, bootFor, hostJs, FILES };
