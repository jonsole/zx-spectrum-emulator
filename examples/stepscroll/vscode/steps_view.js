// The stepscroll graphics editor, in VS Code: a custom editor on
// examples/stepscroll/world/steps.json, the step graphics, drawn as bitmaps
// and in the world. tiles.json and map.json beside it are read for the world;
// tiles.json is also edited when a graphic or a group it names is renamed,
// through its own document, so it shows as changed and saves on its own.
//
// The Filmation designer's shape (examples/filmation/vscode/graphic_map_view.js):
// the file is the model, every change comes back from the page as the whole
// document and goes in through a WorkspaceEdit, so undo, the dirty mark and
// Save are the editor's own. An edit from anywhere else -- the text editor,
// or tiles.json or map.json changing -- is pushed back to the page.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const pages = require('./pages');

const VIEW_TYPE = 'stepscroll.stepGraphics';
const READ_ALONGSIDE = ['tiles.json', 'map.json'];

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// What the page opens with: the graphics, the world they are drawn in, and
// the document's line endings so that writing it back changes only what was
// edited.
function bootFor(document) {
  const here = path.dirname(document.uri.fsPath);
  const boot = {
    steps: document.getText(),
    eol: document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n',
  };
  for (const name of READ_ALONGSIDE) {
    // An open, edited document is what the page should see, not the file.
    const open = vscode.workspace.textDocuments.find((d) => d.uri.fsPath === path.join(here, name));
    const text = open ? open.getText() : readIfThere(path.join(here, name));
    if (text === null) {
      return { error: name + ' is not beside ' + path.basename(document.uri.fsPath) };
    }
    boot[name.replace('.json', '')] = text;
  }
  return boot;
}

// The page's host: the boot data, and edits and settings passed to VS Code.
function hostJs(boot) {
  // JSON goes into a <script>, so anything that could close it early is escaped.
  return 'window.designerHost = (function () {\n' +
    '  const vscode = acquireVsCodeApi();\n' +
    '  let reload = null;\n' +
    '  window.addEventListener("message", function (event) {\n' +
    '    if (event.data && event.data.type === "reload" && reload) reload(event.data.boot);\n' +
    '  });\n' +
    '  return {\n' +
    '    standalone: false,\n' +
    '    boot: ' + JSON.stringify(boot).replace(/</g, '\\u003c') + ',\n' +
    '    edit: function (file, text) { vscode.postMessage({ type: "edit", file: file, text: text }); },\n' +
    '    state: function () { return vscode.getState() || {}; },\n' +
    '    keep: function (state) { vscode.setState(state); },\n' +
    '    onReload: function (fn) { reload = fn; }\n' +
    '  };\n' +
    '})();\n';
}

function pageHtml(document) {
  const boot = bootFor(document);
  if (boot.error) {
    return brokenHtml(document, boot.error);
  }
  return pages.assemble('steps_view.html', hostJs(boot), crypto.randomBytes(16).toString('hex'));
}

function brokenHtml(document, why) {
  const escape = (text) => String(text).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  return '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body ' +
    'style="font: 13px var(--vscode-font-family, sans-serif); color: var(--vscode-foreground); padding: 24px;">' +
    '<h2>' + escape(path.basename(document.uri.fsPath)) + ' cannot be opened here</h2>' +
    '<p>' + escape(why) + '</p></body></html>';
}

// One open document. It holds only what the document cannot: which text this
// side wrote, so the change event can tell the page's own edit from another.
class Session {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.written = null;
    this.disposables = [];
    panel.webview.options = { enableScripts: true };
    panel.webview.html = pageHtml(document);
    const here = path.dirname(document.uri.fsPath);
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(here, '{' + READ_ALONGSIDE.join(',') + '}'));
    this.disposables.push(
      watcher,
      watcher.onDidChange(() => this.reload()),
      watcher.onDidCreate(() => this.reload()),
      panel.webview.onDidReceiveMessage((message) => this.fromPage(message)),
      vscode.workspace.onDidChangeTextDocument((event) => this.documentChanged(event)),
      vscode.workspace.onDidChangeTextDocument((event) => this.alongsideChanged(event))
    );
    panel.onDidDispose(() => this.dispose());
  }

  fromPage(message) {
    if (message && message.type === 'edit') {
      if (message.file === 'tiles') {
        this.writeTiles(message.text);
      } else {
        this.write(message.text);
      }
    }
  }

  // tiles.json changed by a rename: an edit to its own document, left
  // unsaved like any other. The page already has it, so the reload that
  // change would send is skipped while the text is what was written.
  async writeTiles(text) {
    const uri = vscode.Uri.file(path.join(path.dirname(this.document.uri.fsPath), 'tiles.json'));
    const tiles = await vscode.workspace.openTextDocument(uri);
    if (tiles.getText() === text) {
      return;
    }
    const edit = new vscode.WorkspaceEdit();
    edit.replace(uri, new vscode.Range(0, 0, tiles.lineCount, 0), text);
    this.tilesWritten = text;
    await vscode.workspace.applyEdit(edit);
  }

  // tiles.json or map.json edited in a text editor: the page follows. Not
  // tiles.json's change from this page's own rename.
  alongsideChanged(event) {
    const here = path.dirname(this.document.uri.fsPath);
    const name = path.basename(event.document.uri.fsPath);
    if (path.dirname(event.document.uri.fsPath) !== here || READ_ALONGSIDE.indexOf(name) < 0) {
      return;
    }
    if (name === 'tiles.json' && event.document.getText() === this.tilesWritten) {
      return;
    }
    this.reload();
  }

  write(text) {
    if (text === this.document.getText()) {
      return;
    }
    const edit = new vscode.WorkspaceEdit();
    edit.replace(this.document.uri, new vscode.Range(0, 0, this.document.lineCount, 0), text);
    this.written = text;
    vscode.workspace.applyEdit(edit);
  }

  documentChanged(event) {
    if (event.document.uri.toString() !== this.document.uri.toString()) {
      return;
    }
    if (this.document.getText() === this.written) {
      return;                               // our own edit coming back
    }
    this.written = null;
    this.reload();
  }

  reload() {
    const boot = bootFor(this.document);
    if (boot.error) {
      return;
    }
    try {
      JSON.parse(boot.steps);
    } catch (err) {
      return;                               // mid-keystroke in the text editor
    }
    this.panel.webview.postMessage({ type: 'reload', boot });
  }

  dispose() {
    for (const item of this.disposables) {
      item.dispose();
    }
    this.disposables = [];
  }
}

class Provider {
  async resolveCustomTextEditor(document, panel) {
    new Session(document, panel);
  }
}

function activateStepGraphics(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new Provider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false,
    }),
    vscode.commands.registerCommand('stepscroll.openStepGraphics', async (uri) => {
      let file = uri;
      if (!file) {
        const found = await vscode.workspace.findFiles('**/examples/stepscroll/world/steps.json',
                                                       '**/node_modules/**', 1);
        file = found[0];
      }
      if (!file) {
        vscode.window.showErrorMessage('No examples/stepscroll/world/steps.json in the workspace.');
        return;
      }
      await vscode.commands.executeCommand('vscode.openWith', file, VIEW_TYPE);
    })
  );
}

module.exports = { activateStepGraphics, VIEW_TYPE, bootFor, hostJs };
