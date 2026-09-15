// The execution profile's heat map: hot lines tinted in every open source
// file, their numbers written beside them, a hover with the exact figures, a
// list of the hottest lines and routines to jump to, and the call tree in the
// debug sidebar (profile_tree.js).
//
// The emulator counts (see the DAP `profile` request); this asks for the
// report and paints it. While a profile is counting the report is re-read
// every PROFILE_POLL_MS, so the map warms up as the game runs -- the request
// is serviced at the run loop's yields and never pauses it. Once stopped it is
// re-read whenever the machine stops, and otherwise left as it is.

const vscode = require('vscode');
const {
  HEAT_LEVELS,
  heatLevel,
  indexReport,
  reportKeyFor,
  lineLabel,
  lineHover,
  formatShare,
  formatCount,
  perFrame,
} = require('./profile_model');
const { ProfileTreeProvider } = require('./profile_tree');

const PROFILE_POLL_MS = 1000;
const HOT_LINES_SHOWN = 40;
const HOT_ROUTINES_SHOWN = 15;
// One tint per heat level, coolest first. Translucent over the editor's own
// background, so the same values read on a dark theme and a light one.
const HEAT_ALPHAS = [0.05, 0.09, 0.14, 0.2, 0.28, 0.38];
const HEAT_RGB = '255, 96, 32';

let getSession;       // () => the active zxspectrum session, or undefined
let model;            // the last report, indexed; undefined before the first
let heatDecorations;  // one decoration type per level
let labelDecoration;  // the numbers after a hot line
let statusItem;
let treeProvider;     // the call tree view's data
let treeView;
let pollTimer;
let requestInFlight = false;
let refreshTimer;

function activateProfile(context, sessionGetter) {
  getSession = sessionGetter;

  heatDecorations = [];
  for (let i = 0; i < HEAT_LEVELS; i++) {
    const type = vscode.window.createTextEditorDecorationType({
      isWholeLine: true,
      backgroundColor: `rgba(${HEAT_RGB}, ${HEAT_ALPHAS[i]})`,
      overviewRulerColor: `rgba(${HEAT_RGB}, ${Math.min(1, HEAT_ALPHAS[i] * 2.5)})`,
      overviewRulerLane: vscode.OverviewRulerLane.Right,
    });
    heatDecorations.push(type);
    context.subscriptions.push(type);
  }
  labelDecoration = vscode.window.createTextEditorDecorationType({
    after: {
      color: new vscode.ThemeColor('editorCodeLens.foreground'),
      fontStyle: 'italic',
      margin: '0 0 0 3em',
    },
  });
  context.subscriptions.push(labelDecoration);

  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 99);
  context.subscriptions.push(statusItem);

  treeProvider = new ProfileTreeProvider();
  treeView = vscode.window.createTreeView('zxspectrumProfile', {
    treeDataProvider: treeProvider,
    showCollapseAll: true,
  });
  context.subscriptions.push(treeView);
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.profileSortBySelf', () => setTreeSort('self'))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.profileSortByTotal', () => setTreeSort('total'))
  );
  setTreeSort('total');

  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.profileStart', startProfile));
  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.profileStop', stopProfile));
  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.profileRefresh', () => refresh(true)));
  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.profileClear', clearProfile));
  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.profileHotSpots', showHotSpots));

  context.subscriptions.push(
    vscode.languages.registerHoverProvider({ scheme: 'file' }, { provideHover })
  );
  context.subscriptions.push(
    vscode.window.onDidChangeVisibleTextEditors(() => paintAll())
  );

  // A stop is when the numbers are worth re-reading: a breakpoint or a pause
  // lands somewhere the person is about to look.
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory('zxspectrum', {
      createDebugAdapterTracker() {
        return {
          onDidSendMessage(message) {
            if (model !== undefined && message && message.type === 'event' && message.event === 'stopped') {
              scheduleRefresh();
            }
          },
        };
      },
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession((session) => {
      if (session.type === 'zxspectrum' && model !== undefined) {
        // A fresh server is not counting, whatever the last one was doing.
        // The old map stays up until something replaces it.
        model.active = false;
        stopPolling();
        updateStatus();
      }
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => {
      stopPolling();
      if (model !== undefined) {
        model.active = false;
      }
      updateStatus();
    })
  );
  context.subscriptions.push({ dispose: stopPolling });
  setProfilingContext(false);
}

// ---- commands ---------------------------------------------------------------

async function startProfile() {
  const body = await request('start');
  if (body === undefined) {
    return;
  }
  adopt(body);
  startPolling();
}

async function stopProfile() {
  const body = await request('stop');
  if (body === undefined) {
    return;
  }
  stopPolling();
  adopt(body);
}

function clearProfile() {
  stopPolling();
  model = undefined;
  paintAll();
  treeProvider.setModel(undefined);
  updateStatus();
}

/// Orders the call tree by a routine's total (itself and everything it
/// called) or by its own code alone -- the first finds what to drill into,
/// the second where the instructions themselves are slow.
function setTreeSort(sortBy) {
  treeProvider.setSort(sortBy);
  vscode.commands.executeCommand('setContext', 'zxspectrum.profileSort', sortBy);
  updateStatus();
}

async function refresh(announceErrors) {
  if (requestInFlight) {
    return;
  }
  const body = await request('get', !announceErrors);
  if (body !== undefined) {
    adopt(body);
  }
}

function scheduleRefresh() {
  if (refreshTimer !== undefined) {
    clearTimeout(refreshTimer);
  }
  refreshTimer = setTimeout(() => {
    refreshTimer = undefined;
    refresh(false);
  }, 100);
}

async function showHotSpots() {
  if (model === undefined) {
    await refresh(true);
  }
  if (model === undefined || model.total === 0) {
    vscode.window.showInformationMessage('Nothing profiled yet -- start profiling and let the program run.');
    return;
  }
  const unit = model.frames > 0 ? '/frame' : '';
  const items = [];
  items.push({ label: 'Routines', kind: vscode.QuickPickItemKind.Separator });
  for (let i = 0; i < model.routines.length && i < HOT_ROUTINES_SHOWN; i++) {
    const r = model.routines[i];
    items.push({
      label: `$(symbol-function) ${formatShare(r.tstates / model.total)}  ${r.name}`,
      description: r.path ? `${vscode.workspace.asRelativePath(r.path)}:${r.line}` : 'no source',
      detail: `${formatCount(perFrame(model, r.tstates))} T${unit} · ${formatCount(perFrame(model, r.hits))} instructions${unit}`,
      target: r.path ? { path: r.path, line: r.line } : undefined,
    });
  }
  items.push({ label: 'Lines', kind: vscode.QuickPickItemKind.Separator });
  for (let i = 0; i < model.lines.length && i < HOT_LINES_SHOWN; i++) {
    const l = model.lines[i];
    items.push({
      label: `$(flame) ${formatShare(l.tstates / model.total)}  ${l.symbol || '(no label)'}`,
      description: `${vscode.workspace.asRelativePath(l.path)}:${l.line}`,
      detail: `${formatCount(perFrame(model, l.tstates))} T${unit} · ${formatCount(perFrame(model, l.hits))}×${unit} · ${(l.hits > 0 ? l.tstates / l.hits : 0).toFixed(1)} T a run`,
      target: { path: l.path, line: l.line },
    });
  }
  const picked = await vscode.window.showQuickPick(items, {
    title: `Profile: ${formatCount(perFrame(model, model.total))} T${unit}` +
      (model.frames > 0 ? ` over ${model.frames.toLocaleString('en-GB')} frames` : ''),
    matchOnDescription: true,
    matchOnDetail: true,
  });
  if (picked === undefined || picked.target === undefined) {
    return;
  }
  try {
    const document = await vscode.workspace.openTextDocument(picked.target.path);
    const line = Math.max(0, picked.target.line - 1);
    const range = new vscode.Range(line, 0, line, 0);
    await vscode.window.showTextDocument(document, { selection: range });
  } catch (err) {
    vscode.window.showErrorMessage(`Couldn't open ${picked.target.path}: ${err && err.message ? err.message : err}`);
  }
}

// ---- talking to the emulator --------------------------------------------------

async function request(action, quiet) {
  const session = getSession();
  if (session === undefined) {
    if (!quiet) {
      vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    }
    return undefined;
  }
  requestInFlight = true;
  try {
    return await session.customRequest('profile', { action });
  } catch (err) {
    if (!quiet) {
      vscode.window.showErrorMessage(`Profile: ${err && err.message ? err.message : err}`);
    }
    return undefined;
  } finally {
    requestInFlight = false;
  }
}

function adopt(body) {
  model = indexReport(body);
  if (!model.active) {
    stopPolling();
  }
  paintAll();
  treeProvider.setModel(model);
  updateStatus();
}

function startPolling() {
  stopPolling();
  pollTimer = setInterval(() => {
    if (getSession() === undefined) {
      stopPolling();
      return;
    }
    refresh(false);
  }, PROFILE_POLL_MS);
}

function stopPolling() {
  if (pollTimer !== undefined) {
    clearInterval(pollTimer);
    pollTimer = undefined;
  }
}

// ---- painting -------------------------------------------------------------------

function paintAll() {
  for (const editor of vscode.window.visibleTextEditors) {
    paint(editor);
  }
}

function paint(editor) {
  const levels = [];
  for (let i = 0; i < HEAT_LEVELS; i++) {
    levels.push([]);
  }
  const labels = [];
  const key = model !== undefined ? reportKeyFor(model, editor.document.uri.fsPath) : undefined;

  if (key !== undefined) {
    const document = editor.document;
    const lines = model.byFile.get(key) || new Map();
    const routines = model.routinesByFile.get(key) || new Map();
    const seen = new Set();
    for (const [line, stats] of lines) {
      seen.add(line);
      if (line < 1 || line > document.lineCount) {
        continue;
      }
      const level = heatLevel(stats.share);
      if (level > 0) {
        levels[level - 1].push(document.lineAt(line - 1).range);
      }
      pushLabel(labels, document, line, lineLabel(model, stats, routines.get(line)));
    }
    // A routine whose label line has no code of its own still gets its total.
    for (const [line, routine] of routines) {
      if (!seen.has(line) && line >= 1 && line <= document.lineCount) {
        pushLabel(labels, document, line, lineLabel(model, undefined, routine));
      }
    }
  }

  for (let i = 0; i < HEAT_LEVELS; i++) {
    editor.setDecorations(heatDecorations[i], levels[i]);
  }
  editor.setDecorations(labelDecoration, labels);
}

function pushLabel(labels, document, line, text) {
  if (text === undefined) {
    return;
  }
  const end = document.lineAt(line - 1).range.end;
  labels.push({
    range: new vscode.Range(end, end),
    renderOptions: { after: { contentText: text } },
  });
}

function provideHover(document, position) {
  if (model === undefined) {
    return undefined;
  }
  const key = reportKeyFor(model, document.uri.fsPath);
  if (key === undefined) {
    return undefined;
  }
  const line = position.line + 1;
  const stats = (model.byFile.get(key) || new Map()).get(line);
  const routine = (model.routinesByFile.get(key) || new Map()).get(line);
  if (stats === undefined && routine === undefined) {
    return undefined;
  }
  return new vscode.Hover(new vscode.MarkdownString(lineHover(model, stats, routine)));
}

function updateStatus() {
  const profiling = model !== undefined && model.active;
  setProfilingContext(profiling);
  vscode.commands.executeCommand('setContext', 'zxspectrum.hasProfile', model !== undefined);
  if (model === undefined) {
    statusItem.hide();
    treeView.message = undefined;
    return;
  }
  const frames = model.frames > 0 ? `${model.frames.toLocaleString('en-GB')} frames` : 'stepped';
  treeView.message = `${profiling ? 'Counting' : 'Stopped'} · ${frames} · by ${treeProvider.sortBy === 'self' ? 'own code' : 'total'}`;
  const unit = model.frames > 0 ? '/frame' : '';
  const top = model.routines.length > 0 && model.total > 0 ? model.routines[0] : undefined;
  if (profiling) {
    statusItem.text = `$(flame) Profiling · ${model.frames.toLocaleString('en-GB')} frames`;
    statusItem.command = 'zxspectrum.profileStop';
  } else {
    statusItem.text = '$(flame) Profile';
    statusItem.command = 'zxspectrum.profileHotSpots';
  }
  let tooltip = profiling ? 'Counting -- click to stop.' : 'Click for the hottest lines and routines.';
  if (top !== undefined) {
    tooltip += `\nHottest routine: ${top.name}, ${formatShare(top.tstates / model.total)} ` +
      `(${formatCount(perFrame(model, top.tstates))} T${unit})`;
  }
  if (model.total > 0 && model.interruptTstates > 0) {
    tooltip += `\nInterrupt acknowledges: ${formatShare(model.interruptTstates / model.total)}`;
  }
  if (model.total > 0 && model.unmappedTstates > 0) {
    tooltip += `\nWith no source line: ${formatShare(model.unmappedTstates / model.total)}`;
  }
  statusItem.tooltip = tooltip;
  statusItem.show();
}

function setProfilingContext(on) {
  vscode.commands.executeCommand('setContext', 'zxspectrum.profiling', on);
}

module.exports = { activateProfile };
