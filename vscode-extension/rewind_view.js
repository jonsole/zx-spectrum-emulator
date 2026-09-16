// Rewind in the editor: the buttons, menu items and status bar that go with
// the emulator's history (see docs/rewind-design.md).
//
// VS Code draws Step Back and Reverse Continue itself once the adapter
// declares supportsStepBack, and sends the standard stepBack and
// reverseContinue requests for them. What it has no buttons for -- Step Back
// Into, Step Back Out, Run Back to Cursor, Run Back to Last Write, Return to
// Live -- are this adapter's own requests, sent from here.
//
// A request only starts the search: the server answers at once and the
// landing arrives as the usual `stopped` event, followed by a `zxRewind`
// event saying whether it found anything. That second event is where a
// search that found nothing is reported, since the stop alone looks the same
// as a step that did nothing.

const vscode = require('vscode');
const { statusFor } = require('./rewind_model');

let getSession;   // () => the active zxspectrum session, or undefined
let statusItem;
let refreshTimer;

function activateRewind(context, sessionGetter) {
  getSession = sessionGetter;

  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 99);
  statusItem.command = 'zxspectrum.returnToLive';
  context.subscriptions.push(statusItem);

  const simple = [
    ['zxspectrum.stepBackInto', 'stepBackInto'],
    ['zxspectrum.stepBackOut', 'stepBackOut'],
    ['zxspectrum.returnToLive', 'returnToLive'],
  ];
  for (const [name, request] of simple) {
    context.subscriptions.push(vscode.commands.registerCommand(name, () => send(request, {})));
  }
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.runBackToCursor', runBackToCursor)
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.runBackToWrite', runBackToWrite)
  );

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory('zxspectrum', {
      createDebugAdapterTracker() {
        return {
          onDidSendMessage(message) {
            if (!message || message.type !== 'event') {
              return;
            }
            if (message.event === 'stopped') {
              scheduleRefresh();
            } else if (message.event === 'continued') {
              // A run from the past catches up to live as it goes; what it
              // says is only worth reading again once it stops.
              show(undefined);
            }
          },
        };
      },
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
      if (event.session.type !== 'zxspectrum' || event.event !== 'zxRewind') {
        return;
      }
      const body = event.body || {};
      if (body.message) {
        vscode.window.setStatusBarMessage(`$(history) ${body.message}`, 5000);
      }
      scheduleRefresh();
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => show(undefined))
  );
}

async function send(request, args) {
  const session = getSession();
  if (!session) {
    vscode.window.showWarningMessage('No ZX Spectrum debug session is running.');
    return;
  }
  try {
    await session.customRequest(request, args);
  } catch (err) {
    vscode.window.showWarningMessage(`ZX Spectrum: ${err.message || err}`);
  }
}

function runBackToCursor() {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    return;
  }
  // DAP lines count from 1, as setBreakpoints' do.
  return send('runBackToAddress', {
    source: { path: editor.document.uri.fsPath },
    line: editor.selection.active.line + 1,
  });
}

async function runBackToWrite() {
  // Offer the word under the cursor, which is usually the label of the
  // variable whose value is in question.
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
  const address = await vscode.window.showInputBox({
    title: 'Run Back to Last Write',
    prompt: 'The address to find the last write to: a number ($5C3A, 0x5C3A, 23610) or a symbol, optionally +offset',
    value: suggestion,
  });
  if (address === undefined || address.trim() === '') {
    return;
  }
  return send('runBackToWrite', { address: address.trim() });
}

function scheduleRefresh() {
  if (refreshTimer) {
    return;
  }
  // Several stops can arrive together (a landing, then the `zxRewind`
  // behind it); one question covers them all.
  refreshTimer = setTimeout(async () => {
    refreshTimer = undefined;
    const session = getSession();
    if (!session) {
      show(undefined);
      return;
    }
    try {
      show(await session.customRequest('history', {}));
    } catch (err) {
      show(undefined); // an older server without the request
    }
  }, 100);
}

function show(history) {
  const status = statusFor(history);
  vscode.commands.executeCommand('setContext', 'zxspectrum.inPast', status !== undefined);
  if (status === undefined) {
    statusItem.hide();
    return;
  }
  statusItem.text = `$(history) ${status.text}`;
  statusItem.tooltip = new vscode.MarkdownString(
    `**In the past**, ${Math.round(status.share * 100)}% of the way back through the recorded history.\n\n` +
      'Stepping or running forward replays what happened. A key, a poke or a register edit ' +
      'here starts a new timeline and discards the old future.\n\n' +
      'Click to return to live.'
  );
  statusItem.show();
}

module.exports = { activateRewind };
