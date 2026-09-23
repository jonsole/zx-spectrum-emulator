// Designing a tape.
//
// A `*.tape.json` says what goes on a tape and how it loads: the loading scheme
// (tape_model.js's SCHEMES -- the standard ROM loader, or the fast loader in
// examples/zx-tape-loader), the blocks keyed by name in tape order with the
// address each loads at, where to jump when they have, where the loader runs if
// it is one that can move, and the `*.screen.json` that is its loading screen.
//
// This opens it as a page like a .tap's: the picture, what is on the tape with a
// map of where everything lands, the checks the builder makes for its scheme,
// and Build / Build & Run, which run scripts/build_tape.py as a task and load
// the result into the emulator. The screen's order is designed in its own file's
// own editor (screen_view.js), which Design screen opens in a window of its
// own, the way a castle opens its templates.
//
// Each file is its own document, so each editor's undo, dirty mark and Save are
// VS Code's: every change a page makes goes back as a WorkspaceEdit of the
// whole file, and an edit from anywhere else -- an undo, the text editor, the
// screen being redesigned in its window -- is pushed back to the page.
//
// tape_model.js is the pure half, shared with the pages and tested by
// tests/tape_model_test.js and tests/tape_page_test.js.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const model = require('./tape_model');
const info = require('./program_info');
const programs = require('./program_view');
const shared = require('./tape_files');
const screens = require('./screen_view');

const VIEW_TYPE = 'zxspectrum.tapeDesign';
const TAPES = ['.tap', '.tzx'];

function baseOf(file) {
  return file.replace(/\.tape\.json$/i, '').replace(/\.screen\.json$/i, '').replace(/\.[^.\\/]*$/, '');
}

// A block's bytes: its slice of its file, or why not.
function blockData(tapeUri, block) {
  const file = shared.resolve(tapeUri, block.file);
  let data;
  try {
    data = fs.readFileSync(file);
  } catch (err) {
    return { data: null, problem: path.basename(block.file) + ' can\'t be read' };
  }
  const end = block.length ? block.offset + block.length : data.length;
  if (block.offset > data.length || end > data.length || end <= block.offset) {
    return { data: null, problem: path.basename(block.file) + ' is only ' + data.length + ' bytes' };
  }
  return { data: data.subarray(block.offset, end), problem: null };
}

// A document's text as it is now -- the open editor's, unsaved changes and all,
// if it is open; the file's otherwise.
async function liveText(uri) {
  try {
    return (await vscode.workspace.openTextDocument(uri)).getText();
  } catch (err) {
    return null;
  }
}

async function replaceText(uri, text) {
  const document = await vscode.workspace.openTextDocument(uri);
  if (document.getText() === text) {
    return;
  }
  const edit = new vscode.WorkspaceEdit();
  edit.replace(uri, new vscode.Range(0, 0, document.lineCount, 0), text);
  await vscode.workspace.applyEdit(edit);
}

class TapeEditor {
  constructor(document, panel) {
    this.document = document;
    this.panel = panel;
    this.written = null;
    this.watchers = [];
    panel.webview.options = { enableScripts: true };
    panel.webview.html = shared.pageHtml('tape_view.html');
    this.disposables = [
      panel.webview.onDidReceiveMessage((message) => this.received(message)),
      vscode.workspace.onDidChangeTextDocument((event) => this.documentChanged(event))
    ];
    panel.onDidDispose(() => this.dispose());
  }

  parsed() {
    return model.parseTape(this.document.getText() || '{}');
  }

  screenUri(tape) {
    return tape.loadingScreen ? vscode.Uri.file(shared.resolve(this.document.uri, tape.loadingScreen)) : null;
  }

  async load() {
    const { tape, problems } = this.parsed();
    const blocks = tape.blocks.map((block) => {
      const read = blockData(this.document.uri, block);
      return {
        name: block.name,
        length: read.data ? read.data.length : null,
        problem: read.problem,
        // Only a standard ROM tape needs the bytes themselves: its time depends
        // on them, where the fast loader spends the same on every bit.
        data: read.data && tape.scheme === 'rom' ? Buffer.from(read.data).toString('base64') : null
      };
    });
    let screen = null;
    let order = [];
    let picture = '';
    const screenUri = this.screenUri(tape);
    if (screenUri) {
      const text = await liveText(screenUri);
      if (text === null) {
        problems.push(tape.loadingScreen + ' can\'t be read');
      } else {
        const parsed = model.parseScreen(text);
        problems.push(...parsed.problems.map((p) => tape.loadingScreen + ': ' + p));
        order = parsed.screen.order;
        picture = parsed.screen.picture;
        if (picture) {
          const read = shared.readScreen(shared.resolve(screenUri, picture));
          screen = read.screen;
          if (read.problem) {
            problems.push(read.problem);
          }
        }
      }
    }
    const builder = shared.findBuilder();
    const loaderTap = builder ? shared.fastLoaderTap(builder) : null;
    this.panel.webview.postMessage({
      type: 'load',
      name: path.basename(this.document.uri.fsPath),
      tape,
      blocks,
      screen: screen ? screen.toString('base64') : null,
      screenFile: tape.loadingScreen,
      picture,
      order,
      fastRomSeconds: loaderTap ? model.romTapeSeconds(loaderTap) : null,
      problems
    });
    this.watch(tape, screenUri, picture);
  }

  // Every file the tape reads is watched -- the blocks, the screen file and its
  // picture -- because they are usually built by scripts, and rebuilding one
  // while the tape is open should show the new bytes and the new lengths.
  watch(tape, screenUri, picture) {
    for (const watcher of this.watchers) {
      watcher.dispose();
    }
    const files = new Set(tape.blocks.map((block) => shared.resolve(this.document.uri, block.file)));
    if (screenUri) {
      files.add(screenUri.fsPath);
      if (picture) {
        files.add(shared.resolve(screenUri, picture));
      }
    }
    this.watchers = Array.from(files).filter(Boolean).map((file) => {
      const watcher = vscode.workspace.createFileSystemWatcher(
        new vscode.RelativePattern(path.dirname(file), path.basename(file)));
      watcher.onDidChange(() => this.load());
      watcher.onDidCreate(() => this.load());
      watcher.onDidDelete(() => this.load());
      return watcher;
    });
  }

  // The whole document, replaced: one undo step per change the page made.
  async write(tape) {
    const text = model.serializeTape(tape);
    if (text === this.document.getText()) {
      return;
    }
    this.written = text;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(this.document.uri, new vscode.Range(0, 0, this.document.lineCount, 0), text);
    await vscode.workspace.applyEdit(edit);
  }

  // A change the extension makes on the page's behalf -- a block added, a tape
  // imported, a screen made -- goes to the document and then back to the page
  // in full, since the page can't know the new file's contents.
  async change(mutate) {
    const { tape } = this.parsed();
    if ((await mutate(tape)) === false) {
      return;
    }
    this.written = null;
    await this.write(tape);
    await this.load();
  }

  documentChanged(event) {
    if (!event.contentChanges.length) {
      return;
    }
    const { tape } = this.parsed();
    const screenUri = this.screenUri(tape);
    if (screenUri && event.document.uri.fsPath.toLowerCase() === screenUri.fsPath.toLowerCase()) {
      this.load();            // the screen redesigned in its own window
      return;
    }
    if (event.document.uri.toString() !== this.document.uri.toString()) {
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
      await this.load();
    } else if (message.type === 'tape') {
      await this.write(message.tape);
    } else if (message.type === 'designScreen') {
      const uri = await this.ensureScreen();
      if (uri) {
        await screens.openScreen(uri);
      }
    } else if (message.type === 'pick') {
      await this.pickPicture();
    } else if (message.type === 'addBlock') {
      await this.addBlock();
    } else if (message.type === 'importTape') {
      await this.importTape();
    } else if (message.type === 'build' || message.type === 'buildRun') {
      await build(this.document, (m) => this.panel.webview.postMessage(m), message.type === 'buildRun');
    }
  }

  // The tape's screen file, made beside it from a picture if it has none yet.
  async ensureScreen() {
    const { tape } = this.parsed();
    if (tape.loadingScreen) {
      return this.screenUri(tape);
    }
    const picture = await shared.pickPicture('The picture this tape loads as its screen');
    if (!picture) {
      return null;
    }
    return this.makeScreen(picture);
  }

  async makeScreen(picture) {
    const read = shared.readScreen(picture);
    if (!read.screen) {
      vscode.window.showErrorMessage(read.problem);
      return null;
    }
    const file = baseOf(this.document.uri.fsPath) + '.screen.json';
    if (!shared.fileExists(file)) {
      fs.writeFileSync(file, model.serializeScreen({
        meta: { version: 1 },
        picture: shared.relativeTo(file, picture),
        order: model.autoRegions(new Uint8Array(read.screen))
      }));
    }
    await this.change((tape) => {
      tape.loadingScreen = shared.relativeTo(this.document.uri.fsPath, file);
    });
    return vscode.Uri.file(file);
  }

  // A new picture goes into the screen file -- its document, with its own undo
  // -- or makes one.
  async pickPicture() {
    const picture = await shared.pickPicture('The picture this tape loads as its screen');
    if (!picture) {
      return;
    }
    const { tape } = this.parsed();
    const screenUri = this.screenUri(tape);
    if (!screenUri || !shared.fileExists(screenUri.fsPath)) {
      await this.makeScreen(picture);
      return;
    }
    const read = shared.readScreen(picture);
    if (!read.screen) {
      vscode.window.showErrorMessage(read.problem);
      return;
    }
    const parsed = model.parseScreen((await liveText(screenUri)) || '{}');
    parsed.screen.picture = shared.relativeTo(screenUri.fsPath, picture);
    if (!parsed.screen.order.length) {
      parsed.screen.order = model.autoRegions(new Uint8Array(read.screen));
    }
    await replaceText(screenUri, model.serializeScreen(parsed.screen));
  }

  async addBlock() {
    const picked = await vscode.window.showOpenDialog({
      title: 'A file to load into memory', openLabel: 'Add to the tape', canSelectMany: false
    });
    if (!picked || !picked.length) {
      return;
    }
    const file = picked[0].fsPath;
    const { tape } = this.parsed();
    const name = await vscode.window.showInputBox({
      title: 'A name for the block',
      value: model.uniqueName(path.basename(file).replace(/\.[^.]*$/, ''), tape.blocks.map((b) => b.name)),
      validateInput: (input) => (!input.trim() ? 'A block needs a name'
        : tape.blocks.some((b) => b.name === input.trim()) ? 'There is a block of that name already' : null)
    });
    if (!name) {
      return;
    }
    const address = await askAddress('Where ' + name.trim() + ' loads');
    if (address === null) {
      return;
    }
    await this.change((draft) => {
      draft.blocks.push({ name: name.trim(), file: shared.relativeTo(this.document.uri.fsPath, file),
                          address, offset: 0, length: null });
      if (draft.entry === null) {
        draft.entry = address;
      }
    });
  }

  // A standard tape's CODE files as named blocks pointing into it, its loading
  // screen if the tape has none, and its USR address if it has no entry yet.
  async importTape() {
    const picked = await vscode.window.showOpenDialog({
      title: 'A standard tape to take the blocks from', openLabel: 'Import', canSelectMany: false,
      filters: { 'Spectrum tapes': TAPES.map((ext) => ext.slice(1)) }
    });
    if (!picked || !picked.length) {
      return;
    }
    const said = await importInto(this, picked[0].fsPath);
    if (said) {
      vscode.window.showInformationMessage('Imported ' + said + ' from ' + path.basename(picked[0].fsPath) + '.');
    }
  }

  dispose() {
    for (const item of this.disposables.concat(this.watchers)) {
      item.dispose();
    }
  }
}

// A standard tape's data blocks, each with where its data starts in the file:
// what a design's block needs to point straight into the tape.
function tapeBlocksWithOffsets(fileName, bytes) {
  const blocks = /\.tzx$/i.test(fileName) ? info.tzxBlocks(bytes) : info.tapBlocks(bytes);
  return blocks.map((block) => ({ flag: block.flag, data: block.data, offset: block.data.byteOffset - bytes.byteOffset }));
}

async function importInto(editor, tapePath) {
  const bytes = fs.readFileSync(tapePath);
  const { tape } = editor.parsed();
  const contents = model.tapeContents(tapeBlocksWithOffsets(tapePath, bytes), tape.blocks.map((b) => b.name));
  const read = shared.readScreen(tapePath);
  if (!contents.code.length && !read.screen) {
    vscode.window.showWarningMessage(path.basename(tapePath) + ' has no standard CODE files to take: ' +
      'a tape with its own turbo loader can\'t be taken apart this way.');
    return null;
  }
  const said = [contents.code.length + (contents.code.length === 1 ? ' block' : ' blocks')];
  if (read.screen && !tape.loadingScreen) {
    await editor.makeScreen(tapePath);
    said.push('its loading screen');
  }
  await editor.change((draft) => {
    const file = shared.relativeTo(editor.document.uri.fsPath, tapePath);
    for (const code of contents.code) {
      draft.blocks.push({ name: code.name, file, address: code.address, offset: code.offset, length: code.length });
    }
    if (contents.entry !== null && draft.entry === null) {
      draft.entry = contents.entry;
      said.push('USR ' + model.formatAddress(contents.entry) + ' as the entry');
    }
  });
  return said.join(', ');
}

async function askAddress(title) {
  const text = await vscode.window.showInputBox({
    title,
    prompt: 'An address: $8000, 0x8000 or 32768',
    validateInput: (input) => {
      const parsed = model.parseAddress(input);
      return parsed === null || Number.isNaN(parsed) ? 'Not an address' : null;
    }
  });
  return text === undefined ? null : model.parseAddress(text);
}

// --- building ----------------------------------------------------------------

// What build_tape.py writes when the design names no output: a .tap for a
// standard ROM tape, which the emulator loads at once, and a .tzx for the fast
// loader, whose own encoding is a generalized data block rather than a .tap's.
// build_tape.py's default_output, including its way out of a design whose
// blocks come from a tape of that very name -- as one imported from a game's
// own tape does.
function outputOf(document, tape) {
  if (tape.output) {
    return shared.resolve(document.uri, tape.output);
  }
  const kind = tape.scheme === 'rom' ? '.tap' : '.tzx';
  const base = baseOf(document.uri.fsPath);
  const sources = tape.blocks.filter((block) => block.file)
    .map((block) => shared.resolve(document.uri, block.file).toLowerCase());
  if (tape.loadingScreen) {
    sources.push(shared.resolve(document.uri, tape.loadingScreen).toLowerCase());
  }
  if (sources.includes((base + kind).toLowerCase())) {
    return base + (tape.scheme === 'rom' ? '-rom' : '-fast') + kind;
  }
  return base + kind;
}

// Save the tape and its screen, then run build_tape.py as a task so its output
// is in the terminal panel where it can be read, and wait for it. Build & Run
// then loads the tape into the emulator the way Run does a .tap.
async function build(document, post, andRun) {
  const builder = shared.findBuilder();
  if (!builder) {
    vscode.window.showErrorMessage('No scripts/build_tape.py to build with: set zxspectrum.tapeDesigner.builder.');
    return;
  }
  const { tape } = model.parseTape(document.getText() || '{}');
  if (document.isDirty) {
    await document.save();
  }
  if (tape.loadingScreen) {
    const screen = vscode.workspace.textDocuments.find((d) =>
      d.uri.fsPath.toLowerCase() === shared.resolve(document.uri, tape.loadingScreen).toLowerCase());
    if (screen && screen.isDirty) {
      await screen.save();
    }
  }
  const output = outputOf(document, tape);
  const args = [builder, document.uri.fsPath, output];
  // A loader that is moved, or CLEARs somewhere else, is assembled afresh.
  if (tape.scheme === 'zx-tape-loader' &&
      ((tape.loaderAddress !== null && tape.loaderAddress !== model.LOADER_DEFAULT) ||
       (tape.stack !== null && tape.stack !== model.STACK_DEFAULT))) {
    args.push('--sjasmplus', shared.findSjasmplus(builder));
  }
  const task = new vscode.Task(
    { type: 'zxspectrum-tape', tape: document.uri.fsPath },
    vscode.workspace.getWorkspaceFolder(document.uri) || vscode.TaskScope.Workspace,
    'Build ' + path.basename(output),
    'ZX Spectrum',
    new vscode.ProcessExecution(shared.findPython(builder), args, { cwd: path.dirname(builder) })
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Silent, clear: true };

  post({ type: 'building', text: 'Building ' + path.basename(output) + '...' });
  let code;
  try {
    const execution = await vscode.tasks.executeTask(task);
    code = await new Promise((done) => {
      const listener = vscode.tasks.onDidEndTaskProcess((event) => {
        if (event.execution === execution) {
          listener.dispose();
          done(event.exitCode);
        }
      });
    });
  } finally {
    post({ type: 'building', text: '' });
  }
  if (code !== 0) {
    vscode.window.showErrorMessage('The tape did not build: see the terminal for why.', 'Show').then((choice) => {
      if (choice) {
        vscode.commands.executeCommand('workbench.action.terminal.focus');
      }
    });
    return;
  }
  if (!andRun) {
    vscode.window.showInformationMessage('Built ' + path.basename(output) + '.');
    return;
  }
  const size = (file) => {
    try {
      return fs.statSync(file).size;
    } catch (err) {
      return null;
    }
  };
  const rom = info.pickRom(programs.romCandidates(), false, size);
  if (!rom) {
    vscode.window.showErrorMessage('The tape needs a 48K (16K) ROM to load into, and none was found. ' +
      'Put it in roms/ or list it in zxspectrum.server.roms.');
    return;
  }
  const config = info.launchConfigFor(output, path.basename(output), { kind: 'tape', needs128: false }, rom, null, false);
  const current = vscode.debug.activeDebugSession;
  if (current && current.type === 'zxspectrum') {
    await vscode.debug.stopDebugging(current);
  }
  await vscode.debug.startDebugging(vscode.workspace.getWorkspaceFolder(document.uri), config);
}

// --- making a design -----------------------------------------------------------

// "Design Tape" on a picture or a tape: opens the design beside it, making the
// pair if there is none -- the screen in the order convert_tape.py would pick,
// and, from a standard tape, its CODE files and USR address too, so the design
// opens already able to build.
async function designTape(uri) {
  let source = uri instanceof vscode.Uri ? uri.fsPath : null;
  if (!source) {
    const picked = await vscode.window.showOpenDialog({
      title: 'A picture or a tape to design a tape from', openLabel: 'Design tape', canSelectMany: false,
      filters: { 'Spectrum screens and tapes': shared.PICTURES.map((ext) => ext.slice(1)) }
    });
    if (!picked || !picked.length) {
      return;
    }
    source = picked[0].fsPath;
  }
  const ext = path.extname(source).toLowerCase();
  if (!shared.PICTURES.includes(ext)) {
    vscode.window.showErrorMessage('A tape is designed from a .scr, .tap, .tzx, .sna or .z80.');
    return;
  }
  const base = source.slice(0, source.length - ext.length);
  const tapeFile = base + '.tape.json';
  const screenFile = base + '.screen.json';
  if (!shared.fileExists(tapeFile)) {
    const tape = model.emptyTape();
    const read = shared.readScreen(source);
    if (read.screen && !shared.fileExists(screenFile)) {
      fs.writeFileSync(screenFile, model.serializeScreen({
        meta: { version: 1 }, picture: shared.relativeTo(screenFile, source),
        order: model.autoRegions(new Uint8Array(read.screen))
      }));
    }
    if (shared.fileExists(screenFile)) {
      tape.loadingScreen = shared.relativeTo(tapeFile, screenFile);
    }
    if (TAPES.includes(ext)) {
      const bytes = fs.readFileSync(source);
      const contents = model.tapeContents(tapeBlocksWithOffsets(source, bytes), []);
      for (const code of contents.code) {
        tape.blocks.push({ name: code.name, file: shared.relativeTo(tapeFile, source), address: code.address,
                           offset: code.offset, length: code.length });
      }
      tape.entry = contents.entry;
    }
    fs.writeFileSync(tapeFile, model.serializeTape(tape));
  }
  await vscode.commands.executeCommand('vscode.openWith', vscode.Uri.file(tapeFile), VIEW_TYPE);
}

class TapeEditorProvider {
  resolveCustomTextEditor(document, panel) {
    new TapeEditor(document, panel);
  }
}

function activateTapeDesigner(context) {
  screens.activateScreenDesigner(context);
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new TapeEditorProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false
    }),
    vscode.commands.registerCommand('zxspectrum.designTape', designTape)
  );
}

module.exports = { activateTapeDesigner, VIEW_TYPE };
