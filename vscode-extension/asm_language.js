// Z80 assembly language support: Go to Definition, Find All References,
// hover, rename, the call hierarchy, the outline and Go to Symbol in
// Workspace, for the "z80-asm"
// language this extension contributes. Colouring is declarative -- see
// syntaxes/z80-asm.tmLanguage.json -- and everything that needs to know what
// a name means sits on the index in asm_index.js.
//
// The index covers every assembly file in the workspace, not just the open
// ones, because a definition is usually in a file nobody has opened yet. It is
// built the first time something asks, then kept current from the editor
// (unsaved text wins) and from a file watcher (a build that regenerates a
// source, a git checkout).

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { commentAbove, parseContract, hasContract, contractMarkdown, proseMarkdown, escapeMarkdown } = require('./asm_doc');
const { AsmIndex, fileKey, KIND_LABEL, KIND_LOCAL, KIND_CONSTANT, KIND_MACRO, KIND_PARAM, KIND_STRUCT, KIND_FIELD, KIND_DEFINE } = require('./asm_index');

const LANGUAGE_ID = 'z80-asm';
const SELECTOR = [{ language: LANGUAGE_ID }];
// Which files on disk are indexed -- by extension rather than by language, so
// a .s associated with some other language in someone's settings is still
// found when a z80-asm file includes it. No .inc: here that is C++.
const SOURCE_GLOB = '**/*.{asm,s,a80}';
const SOURCE_EXTENSIONS = new Set(['.asm', '.s', '.a80']);
// Replaces files.exclude rather than adding to it, so it carries the folders
// that would otherwise be crawled for nothing.
const EXCLUDE_GLOB = '**/{node_modules,.git,.venv,.venv-win}/**';
// How long the editor has to go quiet before a changed file that is not the
// one being asked about is re-read.
const REPARSE_DELAY_MS = 300;
// How much of the comment block above a definition a hover shows, counted up
// from the label, so the register lines nearest it are always among them.
const HOVER_COMMENT_LINES = 24;
const WORKSPACE_SYMBOL_LIMIT = 1000;

const index = new AsmIndex();
let indexReady;               // the promise of the first full scan
const indexedVersions = new Map(); // file key -> the editor version last parsed
const reparseTimers = new Map();   // file key -> pending timer

function activateAsmLanguage(context) {
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider(SELECTOR, { provideDefinition })
  );
  context.subscriptions.push(
    vscode.languages.registerReferenceProvider(SELECTOR, { provideReferences })
  );
  context.subscriptions.push(vscode.languages.registerHoverProvider(SELECTOR, { provideHover }));
  context.subscriptions.push(
    vscode.languages.registerDocumentSymbolProvider(
      SELECTOR,
      { provideDocumentSymbols },
      { label: 'Z80 Assembly' }
    )
  );
  context.subscriptions.push(
    vscode.languages.registerWorkspaceSymbolProvider({ provideWorkspaceSymbols })
  );
  context.subscriptions.push(
    vscode.languages.registerRenameProvider(SELECTOR, { prepareRename, provideRenameEdits })
  );
  context.subscriptions.push(
    vscode.languages.registerCallHierarchyProvider(SELECTOR, {
      prepareCallHierarchy,
      provideCallHierarchyIncomingCalls,
      provideCallHierarchyOutgoingCalls,
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => {
      if (isAssembly(event.document)) {
        scheduleReparse(event.document);
      }
    })
  );
  context.subscriptions.push(
    vscode.workspace.onDidCloseTextDocument((document) => {
      // Unsaved edits go with the editor; what is on disk is the truth again.
      if (isAssembly(document) && document.uri.scheme === 'file') {
        indexedVersions.delete(fileKey(document.uri.fsPath));
        index.updateFromDisk(document.uri.fsPath);
      }
    })
  );

  const watcher = vscode.workspace.createFileSystemWatcher(SOURCE_GLOB);
  context.subscriptions.push(watcher);
  context.subscriptions.push(watcher.onDidCreate((uri) => reloadFromDisk(uri)));
  context.subscriptions.push(watcher.onDidChange((uri) => reloadFromDisk(uri)));
  context.subscriptions.push(
    watcher.onDidDelete((uri) => {
      indexedVersions.delete(fileKey(uri.fsPath));
      index.remove(uri.fsPath);
    })
  );
}

function isAssembly(document) {
  if (document.languageId === LANGUAGE_ID) {
    return true;
  }
  return SOURCE_EXTENSIONS.has(path.extname(document.fileName).toLowerCase());
}

/// Builds the index the first time it is wanted. Yields to the event loop
/// every few files so a workspace with megabytes of disassembly does not
/// freeze the extension host while it is read.
function ensureIndexed() {
  if (indexReady === undefined) {
    indexReady = (async () => {
      const uris = await vscode.workspace.findFiles(SOURCE_GLOB, EXCLUDE_GLOB);
      let count = 0;
      for (const uri of uris) {
        if (!indexedVersions.has(fileKey(uri.fsPath))) {
          index.updateFromDisk(uri.fsPath);
        }
        count++;
        if (count % 8 === 0) {
          await new Promise((resolve) => setImmediate(resolve));
        }
      }
      for (const document of vscode.workspace.textDocuments) {
        if (isAssembly(document)) {
          refreshDocument(document);
        }
      }
    })();
  }
  return indexReady;
}

/// Makes sure the index holds this editor's current text, not what was there
/// the last time it was parsed.
function refreshDocument(document) {
  const key = fileKey(document.uri.fsPath);
  if (indexedVersions.get(key) === document.version && index.has(document.uri.fsPath)) {
    return;
  }
  const timer = reparseTimers.get(key);
  if (timer !== undefined) {
    clearTimeout(timer);
    reparseTimers.delete(key);
  }
  index.update(document.uri.fsPath, document.getText());
  indexedVersions.set(key, document.version);
}

function scheduleReparse(document) {
  const key = fileKey(document.uri.fsPath);
  const pending = reparseTimers.get(key);
  if (pending !== undefined) {
    clearTimeout(pending);
  }
  reparseTimers.set(
    key,
    setTimeout(() => {
      reparseTimers.delete(key);
      if (!document.isClosed) {
        refreshDocument(document);
      }
    }, REPARSE_DELAY_MS)
  );
}

function reloadFromDisk(uri) {
  // An open editor's text is newer than the file, dirty or not -- the editor
  // reloads a clean document itself and the change event re-parses it then.
  for (const document of vscode.workspace.textDocuments) {
    if (document.uri.fsPath === uri.fsPath) {
      return;
    }
  }
  index.updateFromDisk(uri.fsPath);
}

async function prepare(document) {
  await ensureIndexed();
  refreshDocument(document);
}

// ---- providers ------------------------------------------------------------

async function provideDefinition(document, position) {
  await prepare(document);
  const file = document.uri.fsPath;

  const inc = index.includeAt(file, position.line, position.character);
  if (inc !== undefined) {
    const target = index.resolveInclude(file, inc.target);
    if (target === undefined) {
      return undefined;
    }
    return [
      {
        originSelectionRange: new vscode.Range(position.line, inc.col, position.line, inc.col + inc.len),
        targetUri: vscode.Uri.file(target),
        targetRange: new vscode.Range(0, 0, 0, 0),
      },
    ];
  }

  const token = index.tokenAt(file, position.line, position.character);
  const found = index.definitionsAt(file, position.line, position.character);
  if (token === undefined || found.results.length === 0) {
    return undefined;
  }
  // Underline only as much of a dotted name as the target is: OBJ, when the
  // click on OBJ.FLAGS went to the struct.
  const hidden = token.name.length - token.len;
  let visible = token.len;
  if (token.name.startsWith(found.name) && found.name.length < token.name.length) {
    visible = found.name.length - hidden;
  }
  const origin = new vscode.Range(position.line, token.col, position.line, token.col + visible);

  const links = [];
  for (const result of found.results) {
    const def = result.def;
    links.push({
      originSelectionRange: origin,
      targetUri: vscode.Uri.file(result.path),
      targetRange: new vscode.Range(def.line, 0, def.line, def.col + def.len),
      targetSelectionRange: new vscode.Range(def.line, def.col, def.line, def.col + def.len),
    });
  }
  return links;
}

async function provideReferences(document, position, context) {
  await prepare(document);
  const references = index.referencesAt(
    document.uri.fsPath,
    position.line,
    position.character,
    context.includeDeclaration
  );
  const locations = [];
  for (const ref of references) {
    locations.push(
      new vscode.Location(
        vscode.Uri.file(ref.path),
        new vscode.Range(ref.line, ref.col, ref.line, ref.col + ref.len)
      )
    );
  }
  return locations;
}

async function provideHover(document, position) {
  await prepare(document);
  const file = document.uri.fsPath;
  const token = index.tokenAt(file, position.line, position.character);
  if (token === undefined) {
    return undefined;
  }
  const found = index.definitionsAt(file, position.line, position.character);
  if (found.results.length === 0) {
    return undefined;
  }
  const result = found.results[0];
  const def = result.def;
  // Hovering the definition itself would only repeat what is on screen.
  if (fileKey(result.path) === fileKey(file) && def.line === position.line && def.col === token.col) {
    return undefined;
  }
  if (def.kind === KIND_PARAM) {
    return undefined;
  }

  const lines = sourceLines(result.path);
  if (lines === undefined || def.line >= lines.length) {
    return undefined;
  }
  const markdown = new vscode.MarkdownString();
  // Tab-aligned columns are twice the width of a hover; one space apart reads
  // the same and fits.
  markdown.appendCodeblock(lines[def.line].trim().replace(/\s+/g, ' '), LANGUAGE_ID);

  // What a caller has to know -- the registers in, out and corrupted -- goes
  // first, as a table; the prose it was written among follows.
  const contract = parseContract(commentAbove(lines, def.line, HOVER_COMMENT_LINES));
  if (hasContract(contract)) {
    markdown.appendMarkdown(contractMarkdown(contract) + '\n');
  }
  if (contract.prose.length > 0) {
    markdown.appendMarkdown(proseMarkdown(contract.prose) + '\n\n');
  }

  let where = vscode.workspace.asRelativePath(result.path) + ':' + (def.line + 1);
  if (found.results.length > 1) {
    where += ' -- one of ' + found.results.length + ' definitions';
  }
  markdown.appendMarkdown('*' + escapeMarkdown(where) + '*');
  return new vscode.Hover(markdown, new vscode.Range(position.line, token.col, position.line, token.col + token.len));
}

async function provideDocumentSymbols(document) {
  // The outline needs only this file, so it does not wait for the workspace.
  refreshDocument(document);
  const parsed = index.parsed(document.uri.fsPath);
  if (parsed === undefined) {
    return [];
  }

  // A label's range runs to the line before the next label, macro or struct,
  // so the outline and breadcrumbs follow the cursor through a routine.
  const starts = [];
  for (const def of parsed.defs) {
    if (def.kind === KIND_LABEL || def.kind === KIND_MACRO || def.kind === KIND_STRUCT) {
      starts.push(def.line);
    }
  }

  const symbols = [];
  const byName = new Map();
  let nextStart = 0;
  for (const def of parsed.defs) {
    if (def.kind === KIND_PARAM) {
      continue;
    }
    const selection = new vscode.Range(def.line, def.col, def.line, def.col + def.len);
    let endLine = def.line;
    if (def.kind === KIND_LABEL || def.kind === KIND_MACRO || def.kind === KIND_STRUCT) {
      while (nextStart < starts.length && starts[nextStart] <= def.line) {
        nextStart++;
      }
      endLine = nextStart < starts.length ? starts[nextStart] - 1 : parsed.lineCount - 1;
    }
    const range = new vscode.Range(def.line, 0, endLine, 0);
    const display = def.kind === KIND_LOCAL || def.kind === KIND_FIELD ? def.name.slice(def.container.length) : def.name;
    const symbol = new vscode.DocumentSymbol(display, '', symbolKind(def.kind), range.union(selection), selection);

    const container = def.container !== '' ? byName.get(def.container) : undefined;
    if (container !== undefined && (def.kind === KIND_LOCAL || def.kind === KIND_FIELD)) {
      container.children.push(symbol);
      if (!container.range.contains(symbol.range)) {
        container.range = container.range.union(symbol.range);
      }
    } else {
      symbols.push(symbol);
      byName.set(def.name, symbol);
    }
  }
  return symbols;
}

async function provideWorkspaceSymbols(query) {
  await ensureIndexed();
  const needle = query.toLowerCase();
  const symbols = [];
  for (const [name, list] of index.byName) {
    if (!isSubsequence(needle, name.toLowerCase())) {
      continue;
    }
    for (const item of list) {
      const def = item.def;
      if (def.kind === KIND_PARAM) {
        continue;
      }
      const entry = index.files.get(item.key);
      symbols.push(
        new vscode.SymbolInformation(
          name,
          symbolKind(def.kind),
          def.container,
          new vscode.Location(
            vscode.Uri.file(entry.path),
            new vscode.Range(def.line, def.col, def.line, def.col + def.len)
          )
        )
      );
      if (symbols.length >= WORKSPACE_SYMBOL_LIMIT) {
        return symbols;
      }
    }
  }
  return symbols;
}

async function prepareRename(document, position) {
  await prepareAll();
  const target = index.renameTargetAt(document.uri.fsPath, position.line, position.character);
  if (target.error !== undefined) {
    throw new Error(target.error);
  }
  const r = target.range;
  return new vscode.Range(r.line, r.col, r.line, r.col + r.len);
}

async function provideRenameEdits(document, position, newName) {
  await prepareAll();
  const result = index.renameEdits(document.uri.fsPath, position.line, position.character, newName);
  if (result.error !== undefined) {
    throw new Error(result.error);
  }
  const edit = new vscode.WorkspaceEdit();
  for (const e of result.edits) {
    edit.replace(vscode.Uri.file(e.path), new vscode.Range(e.line, e.col, e.line, e.col + e.len), e.text);
  }
  return edit;
}

/// A rename writes to every file that uses the name, so every open editor's
/// unsaved text has to be in the index first -- not only the one F2 was
/// pressed in. An edit computed from stale text lands in the wrong columns.
async function prepareAll() {
  await ensureIndexed();
  for (const document of vscode.workspace.textDocuments) {
    if (isAssembly(document) && document.uri.scheme === 'file') {
      refreshDocument(document);
    }
  }
}

// Which index entry each call hierarchy item stands for. VS Code hands the
// same item object back when it asks for that item's calls, so this is how an
// item is found again -- including the stand-in for code above a file's first
// label, which has no name to look up.
const callItems = new WeakMap();

async function prepareCallHierarchy(document, position) {
  await prepare(document);
  const item = index.callItemAt(document.uri.fsPath, position.line, position.character);
  if (item === undefined) {
    return undefined;
  }
  return makeCallItem(item);
}

async function provideCallHierarchyIncomingCalls(item) {
  const entry = callItems.get(item);
  if (entry === undefined) {
    return [];
  }
  await prepareAll();
  const calls = [];
  for (const group of index.incomingCalls(entry)) {
    calls.push(new vscode.CallHierarchyIncomingCall(makeCallItem(group.caller), toRanges(group.ranges)));
  }
  return calls;
}

async function provideCallHierarchyOutgoingCalls(item) {
  const entry = callItems.get(item);
  if (entry === undefined) {
    return [];
  }
  await prepareAll();
  const calls = [];
  for (const group of index.outgoingCalls(entry)) {
    calls.push(new vscode.CallHierarchyOutgoingCall(makeCallItem(group.target), toRanges(group.ranges)));
  }
  return calls;
}

function makeCallItem(entry) {
  const def = entry.def;
  const end = def.len === 0 ? def.line : index.routineEnd(entry.path, def);
  const selection = new vscode.Range(def.line, def.col, def.line, def.col + def.len);
  const item = new vscode.CallHierarchyItem(
    def.kind === KIND_MACRO ? vscode.SymbolKind.Operator : vscode.SymbolKind.Function,
    def.name,
    vscode.workspace.asRelativePath(entry.path) + ':' + (def.line + 1),
    vscode.Uri.file(entry.path),
    new vscode.Range(def.line, 0, end, 0).union(selection),
    selection
  );
  callItems.set(item, entry);
  return item;
}

function toRanges(ranges) {
  const out = [];
  for (const r of ranges) {
    out.push(new vscode.Range(r.line, r.col, r.line, r.col + r.len));
  }
  return out;
}

// ---- helpers --------------------------------------------------------------

function symbolKind(kind) {
  switch (kind) {
    case KIND_LABEL:
      return vscode.SymbolKind.Function;
    case KIND_LOCAL:
      return vscode.SymbolKind.Method;
    case KIND_CONSTANT:
      return vscode.SymbolKind.Constant;
    case KIND_MACRO:
      return vscode.SymbolKind.Operator;
    case KIND_STRUCT:
      return vscode.SymbolKind.Struct;
    case KIND_FIELD:
      return vscode.SymbolKind.Field;
    case KIND_DEFINE:
      return vscode.SymbolKind.Constant;
    default:
      return vscode.SymbolKind.Variable;
  }
}

/// A file's lines: the open editor's if there is one, otherwise from disk.
function sourceLines(filePath) {
  for (const document of vscode.workspace.textDocuments) {
    if (fileKey(document.uri.fsPath) === fileKey(filePath)) {
      return document.getText().split(/\r?\n/);
    }
  }
  try {
    return fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  } catch (err) {
    return undefined;
  }
}

function isSubsequence(needle, haystack) {
  let i = 0;
  for (let j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack[j] === needle[i]) {
      i++;
    }
  }
  return i === needle.length;
}

module.exports = { activateAsmLanguage };
