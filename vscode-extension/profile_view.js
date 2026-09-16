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
//
// Two settings shape what is counted, both kept per workspace and sent with
// every start: the routines that are idle (a pacing loop), and what a period
// is (a video frame, or a turn of a chosen routine). The map can show the
// whole profile or any one of the worst periods.

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
  periodName,
} = require('./profile_model');
const { ProfileTreeProvider } = require('./profile_tree');

const PROFILE_POLL_MS = 1000;
const HOT_LINES_SHOWN = 40;
const HOT_ROUTINES_SHOWN = 15;
const PERIOD_ROUTINES_OFFERED = 60;
// One tint per heat level, coolest first. Translucent over the editor's own
// background, so the same values read on a dark theme and a light one.
const HEAT_ALPHAS = [0.05, 0.09, 0.14, 0.2, 0.28, 0.38];
const HEAT_RGB = '255, 96, 32';
const IDLE_TINT = 'rgba(128, 128, 128, 0.12)';
const IDLE_KEY = 'zxspectrum.profile.idle';
const PERIOD_KEY = 'zxspectrum.profile.period';
const CUMULATIVE_KEY = 'zxspectrum.profile.cumulative';

let getSession;       // () => the active zxspectrum session, or undefined
let workspaceState;   // where the idle list and the period are kept
let model;            // the last report, indexed; undefined before the first
let shownPeriod;      // the worst period painted on the source, or undefined
let heatDecorations;  // one decoration type per level
let idleDecoration;   // idle lines, which have time but no heat
let labelDecoration;  // the numbers after a hot line
let statusItem;
let treeProvider;     // the call tree view's data
let treeView;
let pollTimer;
let requestInFlight = false;
let refreshTimer;

function activateProfile(context, sessionGetter) {
  getSession = sessionGetter;
  workspaceState = context.workspaceState;

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
  idleDecoration = vscode.window.createTextEditorDecorationType({
    isWholeLine: true,
    backgroundColor: IDLE_TINT,
  });
  context.subscriptions.push(idleDecoration);
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

  const commands = [
    ['zxspectrum.profileSortBySelf', () => setTreeSort('self')],
    ['zxspectrum.profileSortByTotal', () => setTreeSort('total')],
    ['zxspectrum.profileStart', startProfile],
    ['zxspectrum.profileStop', stopProfile],
    ['zxspectrum.profileRefresh', () => refresh(true)],
    ['zxspectrum.profileClear', clearProfile],
    ['zxspectrum.profileHotSpots', showHotSpots],
    ['zxspectrum.profileMarkIdle', (element) => changeIdle(element, true)],
    ['zxspectrum.profileUnmarkIdle', (element) => changeIdle(element, false)],
    ['zxspectrum.profileSetIdle', pickIdle],
    ['zxspectrum.profileSetPeriod', pickPeriod],
    ['zxspectrum.profileShowPeriod', showPeriod],
    ['zxspectrum.profileShowAll', () => showPeriod(undefined)],
    ['zxspectrum.profileTintWithCalls', () => setCumulative(true)],
    ['zxspectrum.profileTintOwnCode', () => setCumulative(false)],
  ];
  for (const [name, fn] of commands) {
    context.subscriptions.push(vscode.commands.registerCommand(name, fn));
  }
  setTreeSort('total');
  setCumulative(workspaceState.get(CUMULATIVE_KEY, true));

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

// ---- settings -----------------------------------------------------------------

function settings() {
  return {
    idle: workspaceState.get(IDLE_KEY, []),
    period: workspaceState.get(PERIOD_KEY, 'frame'),
  };
}

/// Stores new settings and, with a session, sends them -- they take effect
/// from now on, so a profile already counting carries on under them.
async function applySettings(idle, period) {
  await workspaceState.update(IDLE_KEY, idle);
  await workspaceState.update(PERIOD_KEY, period);
  if (getSession() === undefined) {
    updateStatus();
    return;
  }
  const body = await request('get', false, { idle, period });
  if (body !== undefined) {
    adopt(body);
    warnUnresolved(body);
  }
}

function warnUnresolved(body) {
  if (body.unresolved && body.unresolved.length > 0) {
    vscode.window.showWarningMessage(
      `Profile: no routine called ${body.unresolved.join(', ')} in the loaded debug info.`
    );
  }
}

async function changeIdle(element, idle) {
  const name = element && element.group ? element.group.name : undefined;
  if (name === undefined) {
    return;
  }
  const current = settings();
  const names = current.idle.filter((n) => n !== name);
  if (idle) {
    names.push(name);
  }
  await applySettings(names, current.period);
}

async function pickIdle() {
  const current = settings();
  const names = new Set(current.idle);
  if (model !== undefined) {
    for (const routine of model.routines) {
      names.add(routine.name);
    }
  }
  const items = [];
  for (const name of names) {
    items.push({ label: name, picked: current.idle.includes(name) });
  }
  const picked = await vscode.window.showQuickPick(items, {
    canPickMany: true,
    title: 'Idle routines: time spent waiting, not working',
    placeHolder: 'A pacing loop, say. A HALT is always idle.',
  });
  if (picked === undefined) {
    return;
  }
  await applySettings(picked.map((item) => item.label), current.period);
}

async function pickPeriod() {
  const current = settings();
  const items = [
    {
      label: '$(clock) Video frame',
      description: current.period === 'frame' ? 'current' : '',
      detail: 'Each 50th of a second -- for a game that keeps to the frame rate.',
      value: 'frame',
    },
  ];
  if (model !== undefined) {
    const routines = model.routines
      .filter((r) => r.path)
      .sort((a, b) => (b.hits || 0) - (a.hits || 0))
      .slice(0, PERIOD_ROUTINES_OFFERED);
    for (const routine of routines) {
      items.push({
        label: `$(symbol-function) ${routine.name}`,
        description: current.period === routine.name ? 'current' : '',
        value: routine.name,
      });
    }
  }
  items.push({ label: '$(edit) Another routine or address...', value: undefined });
  const picked = await vscode.window.showQuickPick(items, {
    title: 'Profile periods: what the program\'s work repeats in',
    placeHolder: 'A routine starts a period each time it is reached -- one turn of the game loop.',
    matchOnDetail: true,
  });
  if (picked === undefined) {
    return;
  }
  let period = picked.value;
  if (period === undefined) {
    period = await vscode.window.showInputBox({
      title: 'Profile periods',
      prompt: 'A routine name or address that starts each period',
      value: current.period === 'frame' ? '' : current.period,
    });
    if (!period) {
      return;
    }
  }
  shownPeriod = undefined;
  await applySettings(current.idle, period);
}

// ---- commands ---------------------------------------------------------------

async function startProfile() {
  const body = await request('start', false, settings());
  if (body === undefined) {
    return;
  }
  shownPeriod = undefined;
  adopt(body);
  warnUnresolved(body);
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
  shownPeriod = undefined;
  paintAll();
  treeProvider.setModel(undefined);
  updateStatus();
}

/// Paints one worst period on the source, or with none the whole profile.
function showPeriod(element) {
  shownPeriod = element && element.period ? element.period : undefined;
  vscode.commands.executeCommand('setContext', 'zxspectrum.profileShowingPeriod', shownPeriod !== undefined);
  paintAll();
  updateStatus();
}

/// Whether a CALL line is tinted with the time its calls took as well as its
/// own. Kept per workspace; re-reads nothing, since the report carries both.
function setCumulative(cumulative) {
  workspaceState.update(CUMULATIVE_KEY, cumulative);
  treeProvider.setCumulative(cumulative);
  vscode.commands.executeCommand('setContext', 'zxspectrum.profileCumulative', cumulative);
  if (model !== undefined) {
    model = indexReport(model.report, { cumulative });
    treeProvider.setModel(model);
  }
  paintAll();
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
  const shown = shownModel();
  const unit = shown.frames > 0 ? '/frame' : '';
  const share = (entry) => (isIdleEntry(entry) ? 'idle' : formatShare(shown.busy > 0 ? (entry.tstates - (entry.idle_tstates || 0)) / shown.busy : 0));
  const items = [];
  items.push({ label: 'Routines', kind: vscode.QuickPickItemKind.Separator });
  for (let i = 0; i < shown.routines.length && i < HOT_ROUTINES_SHOWN; i++) {
    const r = shown.routines[i];
    let detail = `${formatCount(perFrame(shown, r.tstates))} T${unit}`;
    if (r.hits !== undefined) {
      detail += ` · ${formatCount(perFrame(shown, r.hits))} instructions${unit}`;
    }
    items.push({
      label: `$(symbol-function) ${share(r)}  ${r.name}`,
      description: r.path ? `${vscode.workspace.asRelativePath(r.path)}:${r.line}` : 'no source',
      detail,
      target: r.path ? { path: r.path, line: r.line } : undefined,
    });
  }
  items.push({ label: 'Lines', kind: vscode.QuickPickItemKind.Separator });
  for (let i = 0; i < shown.lines.length && i < HOT_LINES_SHOWN; i++) {
    const l = shown.lines[i];
    let detail = `${formatCount(perFrame(shown, l.tstates))} T${unit}`;
    if (l.hits !== undefined) {
      detail += ` · ${formatCount(perFrame(shown, l.hits))}×${unit} · ${(l.hits > 0 ? l.tstates / l.hits : 0).toFixed(1)} T a run`;
    }
    items.push({
      label: `$(flame) ${share(l)}  ${l.symbol || '(no label)'}`,
      description: `${vscode.workspace.asRelativePath(l.path)}:${l.line}`,
      detail,
      target: { path: l.path, line: l.line },
    });
  }
  const title = shownPeriod !== undefined
    ? `${periodName(model, shownPeriod)}: ${formatCount(shown.busy)} T busy`
    : `Profile: ${formatCount(perFrame(model, model.busy))} T${unit} busy` +
      (model.frames > 0 ? ` over ${model.frames.toLocaleString('en-GB')} frames` : '');
  const picked = await vscode.window.showQuickPick(items, { title, matchOnDescription: true, matchOnDetail: true });
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

function isIdleEntry(entry) {
  return entry.tstates > 0 && (entry.idle_tstates || 0) >= entry.tstates * 0.9;
}

// ---- talking to the emulator --------------------------------------------------

async function request(action, quiet, extra) {
  const session = getSession();
  if (session === undefined) {
    if (!quiet) {
      vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    }
    return undefined;
  }
  requestInFlight = true;
  try {
    return await session.customRequest('profile', Object.assign({ action }, extra || {}));
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
  model = indexReport(body, { cumulative: treeProvider.cumulative });
  if (!model.active) {
    stopPolling();
  }
  // The period being shown stays shown while the profile still ranks it;
  // once a busier set has pushed it out, the map goes back to the whole.
  if (shownPeriod !== undefined) {
    const worst = (model.periods && model.periods.worst) || [];
    const still = worst.find((p) => p.index === shownPeriod.index);
    shownPeriod = still;
    vscode.commands.executeCommand('setContext', 'zxspectrum.profileShowingPeriod', still !== undefined);
  }
  treeProvider.setModel(model);
  paintAll();
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

/// The model the source is painted from: the whole profile, or one period.
function shownModel() {
  if (model === undefined) {
    return undefined;
  }
  if (shownPeriod !== undefined) {
    return treeProvider.periodModel(shownPeriod);
  }
  return model;
}

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
  const idle = [];
  const labels = [];
  const shown = shownModel();
  const key = shown !== undefined ? reportKeyFor(shown, editor.document.uri.fsPath) : undefined;

  if (key !== undefined) {
    const document = editor.document;
    const lines = shown.byFile.get(key) || new Map();
    const routines = shown.routinesByFile.get(key) || new Map();
    const seen = new Set();
    for (const [line, stats] of lines) {
      seen.add(line);
      if (line < 1 || line > document.lineCount) {
        continue;
      }
      if (stats.idle) {
        idle.push(document.lineAt(line - 1).range);
      } else {
        const level = heatLevel(stats.share);
        if (level > 0) {
          levels[level - 1].push(document.lineAt(line - 1).range);
        }
      }
      pushLabel(labels, document, line, lineLabel(shown, stats, routines.get(line)));
    }
    // A routine whose label line has no code of its own still gets its total.
    for (const [line, routine] of routines) {
      if (!seen.has(line) && line >= 1 && line <= document.lineCount) {
        pushLabel(labels, document, line, lineLabel(shown, undefined, routine));
      }
    }
  }

  for (let i = 0; i < HEAT_LEVELS; i++) {
    editor.setDecorations(heatDecorations[i], levels[i]);
  }
  editor.setDecorations(idleDecoration, idle);
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
  const shown = shownModel();
  if (shown === undefined) {
    return undefined;
  }
  const key = reportKeyFor(shown, document.uri.fsPath);
  if (key === undefined) {
    return undefined;
  }
  const line = position.line + 1;
  const stats = (shown.byFile.get(key) || new Map()).get(line);
  const routine = (shown.routinesByFile.get(key) || new Map()).get(line);
  if (stats === undefined && routine === undefined) {
    return undefined;
  }
  return new vscode.Hover(new vscode.MarkdownString(lineHover(shown, stats, routine)));
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
  const current = settings();
  const frames = model.frames > 0 ? `${model.frames.toLocaleString('en-GB')} frames` : 'stepped';
  const parts = [`${profiling ? 'Counting' : 'Stopped'} · ${frames}`];
  if (current.idle.length > 0) {
    parts.push(`idle: ${current.idle.join(', ')}`);
  }
  if (current.period && current.period !== 'frame') {
    parts.push(`turns of ${current.period}`);
  }
  parts.push(`by ${treeProvider.sortBy === 'self' ? 'own code' : 'total'}`);
  parts.push(treeProvider.cumulative ? 'lines with calls' : 'lines own code');
  if (shownPeriod !== undefined) {
    parts.push(`source shows ${periodName(model, shownPeriod)}`);
  }
  treeView.message = parts.join(' · ');

  const unit = model.frames > 0 ? '/frame' : '';
  if (profiling) {
    statusItem.text = `$(flame) Profiling · ${model.frames.toLocaleString('en-GB')} frames`;
    statusItem.command = 'zxspectrum.profileStop';
  } else if (shownPeriod !== undefined) {
    statusItem.text = `$(flame) ${periodName(model, shownPeriod)}`;
    statusItem.command = 'zxspectrum.profileShowAll';
  } else {
    statusItem.text = '$(flame) Profile';
    statusItem.command = 'zxspectrum.profileHotSpots';
  }
  let tooltip = profiling
    ? 'Counting -- click to stop.'
    : shownPeriod !== undefined
      ? 'The source shows one period -- click to show the whole profile.'
      : 'Click for the hottest lines and routines.';
  if (model.total > 0) {
    tooltip += `\nBusy: ${formatCount(perFrame(model, model.busy))} T${unit}`;
    if (model.idle > 0) {
      tooltip += `, idle ${formatShare(model.idle / model.total)} of the time`;
    }
  }
  const top = model.routines.find((r) => !isIdleEntry(r));
  if (top !== undefined && model.busy > 0) {
    tooltip += `\nHottest routine: ${top.name}, ${formatShare((top.tstates - (top.idle_tstates || 0)) / model.busy)} ` +
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
