// Designing a tape's loading screen: the order its rectangles are sent in.
//
// A `*.screen.json` is a picture and that order. zx-tape-loader's fast loader
// sends a screen as a sequence of character-cell rectangles, so the order is
// the reveal -- the picture building up in front of whoever is waiting -- and it
// wants to be seen, not computed. This opens the file as the picture with its
// rectangles, draws and reorders them, and plays the result back at the speed
// the tape really runs.
//
// It is an editor of its own document, so it can have a window of its own (a
// tape's page opens it with openScreenOf, the way a castle opens its
// templates), and its undo, dirty mark and Save are VS Code's: every change the
// page makes goes back as a WorkspaceEdit of the whole file, and an edit from
// anywhere else -- an undo, the text editor -- is pushed back to the page.
//
// The page is screen_designer.html; tape_model.js is the pure half, inlined
// into it and tested by tests/tape_model_test.js and tests/screen_page_test.js.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const model = require('./tape_model');
const shared = require('./tape_files');

const VIEW_TYPE = 'zxspectrum.screenDesign';
const MOVE_TO_NEW_WINDOW = 'workbench.action.moveEditorToNewWindow';

class ScreenEditor {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.written = null;
    this.watcher = null;
    panel.webview.options = { enableScripts: true };
    panel.webview.html = shared.pageHtml('screen_designer.html');
    this.disposables = [
      panel.webview.onDidReceiveMessage((message) => this.received(message)),
      vscode.workspace.onDidChangeTextDocument((event) => this.documentChanged(event))
    ];
    panel.onDidDispose(() => this.dispose());
  }

  parsed() {
    return model.parseScreen(this.document.getText() || '{}');
  }

  load() {
    const { screen, problems } = this.parsed();
    let bytes = null;
    if (screen.picture) {
      const read = shared.readScreen(shared.resolve(this.document.uri, screen.picture));
      bytes = read.screen;
      if (read.problem) {
        problems.push(read.problem);
      }
    }
    this.panel.webview.postMessage({
      type: 'load',
      picture: screen.picture,
      screen: bytes ? bytes.toString('base64') : null,
      regions: screen.order,
      problems
    });
    this.watchPicture(screen.picture);
  }

  // The picture is watched rather than read once: a loading screen is usually
  // built by a script, and rebuilding it while the order is open should show
  // the new artwork under it.
  watchPicture(picture) {
    if (this.watcher) {
      this.watcher.dispose();
      this.watcher = null;
    }
    if (!picture) {
      return;
    }
    const file = shared.resolve(this.document.uri, picture);
    this.watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(path.dirname(file), path.basename(file)));
    this.watcher.onDidChange(() => this.load());
    this.watcher.onDidCreate(() => this.load());
  }

  // The whole document, replaced: one undo step per change the designer made.
  async write(screen) {
    const text = model.serializeScreen(screen);
    if (text === this.document.getText()) {
      return;
    }
    this.written = text;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(this.document.uri, new vscode.Range(0, 0, this.document.lineCount, 0), text);
    await vscode.workspace.applyEdit(edit);
  }

  documentChanged(event) {
    if (event.document.uri.toString() !== this.document.uri.toString() || !event.contentChanges.length) {
      return;
    }
    if (this.document.getText() === this.written) {
      return;                 // our own edit coming back
    }
    this.written = null;
    this.load();              // an undo, the text editor, the file on disk
  }

  async received(message) {
    if (message.type === 'ready') {
      this.load();
    } else if (message.type === 'order') {
      const { screen } = this.parsed();
      screen.order = message.regions.map(model.clampRegion);
      await this.write(screen);
    } else if (message.type === 'pick') {
      const picked = await shared.pickPicture('The picture this screen is');
      if (!picked) {
        return;
      }
      const read = shared.readScreen(picked);
      if (!read.screen) {
        vscode.window.showErrorMessage(read.problem);
        return;
      }
      const { screen } = this.parsed();
      screen.picture = shared.relativeTo(this.document.uri.fsPath, picked);
      // A new picture keeps the order already drawn, if there is one: the usual
      // reason to change it is that the artwork was redone.
      if (!screen.order.length) {
        screen.order = model.autoRegions(new Uint8Array(read.screen));
      }
      this.written = null;
      await this.write(screen);
      this.load();
    } else if (message.type === 'python' && message.text) {
      await vscode.env.clipboard.writeText(message.text + '\n');
      vscode.window.showInformationMessage('The loading order is on the clipboard as gen_block() calls.');
    }
  }

  dispose() {
    for (const item of this.disposables) {
      item.dispose();
    }
    if (this.watcher) {
      this.watcher.dispose();
    }
  }
}

class ScreenEditorProvider {
  resolveCustomTextEditor(document, panel) {
    new ScreenEditor(document, panel);
  }
}

// Open a screen file in its designer, in a window of its own -- or, if it is
// already open somewhere, bring that forward rather than open a second copy.
async function openScreen(uri) {
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      const input = tab.input;
      if (input && input.viewType === VIEW_TYPE && input.uri &&
          input.uri.fsPath.toLowerCase() === uri.fsPath.toLowerCase()) {
        await vscode.commands.executeCommand('vscode.openWith', uri, VIEW_TYPE, { viewColumn: group.viewColumn });
        return;
      }
    }
  }
  await vscode.commands.executeCommand('vscode.openWith', uri, VIEW_TYPE, { viewColumn: vscode.ViewColumn.Beside });
  try {
    await vscode.commands.executeCommand(MOVE_TO_NEW_WINDOW);
  } catch (err) {
    // Beside the tape is a perfectly good place for it too.
  }
}

function activateScreenDesigner(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new ScreenEditorProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    })
  );
}

module.exports = { activateScreenDesigner, openScreen, VIEW_TYPE };
