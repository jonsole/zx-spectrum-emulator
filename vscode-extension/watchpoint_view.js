// Watchpoints in the editor: the Watch Address command, and the list of what
// is being watched in the debug sidebar.
//
// VS Code has watchpoints of its own -- data breakpoints, set from the memory
// inspector's "Break on Value Change" and shown in the BREAKPOINTS pane -- and
// the adapter answers those (dataBreakpointInfo/setDataBreakpoints). They only
// reach as far as VS Code's own UI goes, though: a watchpoint on a symbol, on
// a range, or one set over MCP has nowhere to appear there. Hence this view,
// which shows what the EMULATOR is watching, whoever asked for it.

const vscode = require('vscode');
const { watchpointName, watchpointDetail, parseWatchRequest } = require('./watchpoint_model');

let getSession;
let provider;
let view;
let refreshTimer;

class WatchpointTreeProvider {
  constructor() {
    this.watchpoints = [];
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
  }

  set(watchpoints) {
    this.watchpoints = watchpoints || [];
    this.emitter.fire();
  }

  getChildren() {
    return this.watchpoints;
  }

  /// Flat: every watchpoint is a root. Needed for reveal() to be allowed.
  getParent() {
    return undefined;
  }

  getTreeItem(w) {
    const item = new vscode.TreeItem(watchpointName(w), vscode.TreeItemCollapsibleState.None);
    item.description = watchpointDetail(w);
    item.id = String(w.id);
    item.contextValue = 'zxWatchpoint';
    item.iconPath = new vscode.ThemeIcon(w.enabled ? 'eye' : 'eye-closed');
    item.tooltip = new vscode.MarkdownString(
      `**${watchpointName(w)}** — ${watchpointDetail(w)}\n\n` +
        'The machine stops at the instruction after the access, and says what changed and ' +
        'what changed it. Step back once to be just before it.'
    );
    return item;
  }
}

function activateWatchpoints(context, sessionGetter) {
  getSession = sessionGetter;
  provider = new WatchpointTreeProvider();
  view = vscode.window.createTreeView('zxspectrumWatchpoints', { treeDataProvider: provider });
  context.subscriptions.push(view);

  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.watchAddress', watchAddress)
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.clearWatchpoint', (item) =>
      send('clearWatchpoint', { id: item && item.id ? item.id : 0 })
    )
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.clearWatchpoints', () =>
      send('clearWatchpoint', {})
    )
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.toggleWatchpoint', (item) =>
      send('setWatchpoint', {
        id: item.id,
        address: item.address,
        length: item.length,
        access: item.onWrite ? (item.onRead ? 'readWrite' : 'write') : 'read',
        onChange: item.onChange,
        enabled: !item.enabled,
      })
    )
  );

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory('zxspectrum', {
      createDebugAdapterTracker() {
        return {
          onDidSendMessage(message) {
            // A hit changes a count, and a session that has just started has
            // whatever the last one left the emulator watching.
            if (message && message.type === 'event' && message.event === 'stopped') {
              scheduleRefresh();
            }
          },
        };
      },
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidChangeActiveDebugSession(() => scheduleRefresh())
  );
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => provider.set([]))
  );
}

async function send(request, args) {
  const session = getSession();
  if (!session) {
    vscode.window.showWarningMessage('No ZX Spectrum debug session is running.');
    return;
  }
  try {
    const body = await session.customRequest(request, args);
    show(body);
  } catch (err) {
    vscode.window.showWarningMessage(`ZX Spectrum: ${err.message || err}`);
  }
}

async function watchAddress() {
  // The word under the cursor is usually the label of the thing in question.
  let suggestion = '';
  const editor = vscode.window.activeTextEditor;
  if (editor) {
    const range = editor.selection.isEmpty
      ? editor.document.getWordRangeAtPosition(editor.selection.active, /[A-Za-z_.$][\w.$]*/)
      : editor.selection;
    if (range) {
      suggestion = editor.document.getText(range);
    }
  }
  const typed = await vscode.window.showInputBox({
    title: 'Watch Address',
    prompt: 'Address or symbol to watch, and how many bytes: "player", "player 8", "$5C3A,2"',
    value: suggestion,
  });
  const request = parseWatchRequest(typed);
  if (!request) {
    return;
  }
  const access = await vscode.window.showQuickPick(
    [
      {
        label: 'Writes that change it',
        description: 'stop when the program writes a different value',
        access: 'write',
        onChange: true,
      },
      {
        label: 'Every write',
        description: 'including a write of the value already there',
        access: 'write',
        onChange: false,
      },
      { label: 'Reads', description: 'stop when the program reads it as data', access: 'read' },
      {
        label: 'Reads and writes',
        description: 'either',
        access: 'readWrite',
        onChange: false,
      },
    ],
    { title: `Watch ${request.address}`, placeHolder: 'What to stop on' }
  );
  if (!access) {
    return;
  }
  await send('setWatchpoint', {
    address: request.address,
    length: request.length,
    access: access.access,
    onChange: access.onChange !== false,
  });
  // The list is in the debug sidebar; show it rather than leaving someone to
  // wonder whether the watchpoint took.
  if (view && provider.watchpoints.length > 0) {
    view.reveal(provider.watchpoints[provider.watchpoints.length - 1], { focus: false });
  }
}

function scheduleRefresh() {
  if (refreshTimer) {
    return;
  }
  refreshTimer = setTimeout(async () => {
    refreshTimer = undefined;
    const session = getSession();
    if (!session) {
      provider.set([]);
      return;
    }
    try {
      show(await session.customRequest('watchpoints', {}));
    } catch (err) {
      provider.set([]); // an older server without watchpoints
    }
  }, 100);
}

function show(body) {
  const watchpoints = (body && body.watchpoints) || [];
  provider.set(watchpoints);
  vscode.commands.executeCommand('setContext', 'zxspectrum.hasWatchpoints', watchpoints.length > 0);
}

module.exports = { activateWatchpoints };
