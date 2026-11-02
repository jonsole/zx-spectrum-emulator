// The SpecNext board as a target beside the emulator: its bridge started, joined
// and stopped, and the status bar switch between the two.
//
// The bridge is retro-spectrum's tools/zx_bridge.py. It owns the board's
// FT232H link and serves zx_server's DAP, MCP and screen stream on ports of
// its own (zxspectrum.board.ports, 4712, 8001 and 8502 unless changed), so a
// debug session on the board is a session like any other once it is
// connected. What this adds is the starting: a launch for the board -- its
// own "target": "specnext", or none while the switch says SpecNext -- joins the bridge
// that is advertised or answering, and starts one if there is none. One this
// window started is stopped when VS Code closes, as the emulator is.
//
// The switch is zxspectrum.target. The viewers' Run and Debug and every
// launch with no target of its own follow it. The pure half -- the settings,
// the command line, what a launch for the board becomes -- is board_target.js.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const net = require('net');
const os = require('os');
const path = require('path');
const target = require('./board_target');
const servers = require('./server_view');

const HOST = '127.0.0.1';
const START_TIMEOUT_MS = 20000;

let output;
let switchItem;
let child = null;       // the bridge this window started, while it runs
let starting = null;    // the start in progress, so two launches share it

function boardConfig() {
  const config = vscode.workspace.getConfiguration('zxspectrum.board');
  return target.boardSettings((key) => config.get(key));
}

// Which machine the switch points at: "emulator" or "specnext".
function chosenTarget() {
  const value = vscode.workspace.getConfiguration('zxspectrum').get('target', 'emulator');
  return target.TARGETS.indexOf(value) >= 0 ? value : 'emulator';
}

function probe(port, timeoutMs = 400) {
  return new Promise((resolve) => {
    const socket = net.connect(port, HOST);
    const done = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

class BoardError extends Error {}

// The bridge advertised on this machine, newest first, or null: what it says
// it is (its cpu and machine) as well as where.
function currentBoard() {
  return target.advertisedBoard(servers.servers());
}

// The bridge to use: one advertised on this machine (it says where it is),
// else whatever answers on the settings' DAP port, else a new one. Resolves
// once it is serving to { ports, server } -- `server` its advert, or null
// for one that has not advertised.
async function ensureBridge() {
  if (starting) {
    return starting;
  }
  const advertised = currentBoard();
  if (advertised) {
    return { ports: { dap: advertised.ports.dap, mcp: advertised.ports.mcp, screen: advertised.ports.screen,
                      audio: null }, server: advertised };
  }
  const settings = boardConfig();
  if (await probe(settings.ports.dap)) {
    return { ports: Object.assign({ audio: null }, settings.ports), server: null };
  }
  starting = startBridge(settings).finally(() => {
    starting = null;
  });
  return starting;
}

async function startBridge(settings) {
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  const command = target.bridgeCommand(settings, folders[0], os.homedir());
  if (command.error) {
    throw new BoardError(command.error);
  }
  // The bridge's own directory, so it finds what sits beside it.
  const cwd = command.script ? path.dirname(command.script) : (folders[0] || os.homedir());
  output.appendLine(`> ${command.command} ${command.args.join(' ')}`);
  let proc;
  try {
    proc = cp.spawn(command.command, command.args, { cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    throw new BoardError(`Could not start the SpecNext bridge: ${err.message}`);
  }
  let said = '';
  let ready = null;
  proc.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    output.append(text);
    said += text;
    ready = ready || target.readyIn(said);
  });
  proc.stderr.on('data', (chunk) => {
    const text = chunk.toString();
    output.append(text);
    said += text;
  });
  let exited = null;
  proc.once('exit', (code) => {
    exited = { code };
    output.appendLine(`[SpecNext bridge ${proc.pid || ''} exited${code !== null ? ' with code ' + code : ''}]`);
    if (child === proc) {
      child = null;
      refreshSwitch();
    }
  });
  proc.once('error', (err) => {
    exited = { code: null, error: err };
    output.appendLine(`[could not run the SpecNext bridge: ${err.message}]`);
  });

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (exited) {
      // Its own words: "COM3 ... Access is denied" when retro-z80's bridge
      // holds the port, "no FT232H found" when the board is not plugged in.
      const why = exited.error ? exited.error.message : target.bridgeComplaint(said);
      throw new BoardError('The SpecNext bridge stopped as it started' + (why ? ': ' + why : '.') +
        (exited.error && exited.error.code === 'ENOENT'
          ? ` (is ${command.command} on the PATH? zxspectrum.board.python says which Python)` : ''));
    }
    if (ready || await probe(settings.ports.dap, 300)) {
      child = proc;
      refreshSwitch();
      // Its advert, written once its ports were bound, says what is on the
      // port.
      return { ports: Object.assign({ audio: null }, settings.ports), server: currentBoard() };
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  proc.kill();
  throw new BoardError(`The SpecNext bridge did not start listening on port ${settings.ports.dap} within ` +
    `${START_TIMEOUT_MS / 1000} seconds -- see the "ZX Spectrum Board" output.`);
}

async function stopBridge() {
  const session = vscode.debug.activeDebugSession;
  if (session && session.type === 'zxspectrum' && session.configuration.target === target.BOARD_TARGET) {
    await vscode.debug.stopDebugging(session);
  }
  if (child) {
    child.kill();
    child = null;
    refreshSwitch();
    return;
  }
  const advertised = target.advertisedBoard(servers.servers());
  if (!advertised) {
    vscode.window.showInformationMessage('No SpecNext bridge is running.');
    return;
  }
  const answer = await vscode.window.showWarningMessage(
    `The SpecNext bridge (process ${advertised.pid}) was started outside this window. Stop it anyway?`,
    { modal: true }, 'Stop it');
  if (answer === 'Stop it') {
    try {
      process.kill(advertised.pid);
    } catch (err) {
      vscode.window.showErrorMessage(`Could not stop process ${advertised.pid}: ${err.message}`);
    }
  }
  refreshSwitch();
}

// ---- the switch ----------------------------------------------------------------

function refreshSwitch() {
  if (!switchItem) {
    return;
  }
  const onBoard = chosenTarget() === target.BOARD_TARGET;
  switchItem.text = onBoard ? '$(circuit-board) SpecNext' : '$(vm) Emulator';
  const running = currentBoard();
  switchItem.tooltip = (onBoard
    ? 'Programs run on the SpecNext board: ' + target.describeBoard(running) +
      (running ? '' : ', its bridge not running') + (child ? ' (its bridge started by this window)' : '')
    : 'Programs run on the emulator') + ' -- click to switch';
  switchItem.show();
  vscode.commands.executeCommand('setContext', 'zxspectrum.targetIsBoard', onBoard);
}

async function selectTarget() {
  const now = chosenTarget();
  const items = [
    { label: '$(vm) Emulator', description: now === 'emulator' ? 'current' : '', value: 'emulator',
      detail: 'zx_server: 48K and 128K, with rewind, the profiler and the rest' },
    { label: '$(circuit-board) SpecNext', description: now === 'specnext' ? 'current' : '', value: 'specnext',
      detail: 'retro-spectrum\'s FPGA 48K, through its bridge: 8 breakpoints, 4 watchpoints, standard tapes' },
    { label: '$(debug-stop) Stop the SpecNext bridge', value: 'stop' },
    { label: '$(output) Show the SpecNext bridge\'s output', value: 'log' }
  ];
  const pick = await vscode.window.showQuickPick(items, { placeHolder: 'Where programs run' });
  if (!pick) {
    return;
  }
  if (pick.value === 'stop') {
    stopBridge();
  } else if (pick.value === 'log') {
    output.show(true);
  } else if (pick.value !== now) {
    // Per workspace when there is one, since which board is on the bench
    // goes with the project; otherwise for every window.
    const where = vscode.workspace.workspaceFolders ? vscode.ConfigurationTarget.Workspace
      : vscode.ConfigurationTarget.Global;
    await vscode.workspace.getConfiguration('zxspectrum').update('target', pick.value, where);
  }
}

function activateBoard(context) {
  output = vscode.window.createOutputChannel('ZX Spectrum Board');
  switchItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 49);
  switchItem.command = 'zxspectrum.selectTarget';
  context.subscriptions.push(
    output, switchItem,
    vscode.commands.registerCommand('zxspectrum.selectTarget', selectTarget),
    vscode.commands.registerCommand('zxspectrum.boardStart', async () => {
      try {
        const found = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Window, title: 'Starting the SpecNext bridge' }, () => ensureBridge());
        vscode.window.showInformationMessage(`The SpecNext bridge is serving on port ${found.ports.dap}: ` +
          `${target.describeBoard(found.server)}.`);
      } catch (err) {
        reportBoardError(err);
      }
    }),
    vscode.commands.registerCommand('zxspectrum.boardStop', stopBridge),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('zxspectrum.target')) {
        refreshSwitch();
      }
    }),
    // What is on the board's port comes into the bridge's advert once the
    // board has answered, which can be after it started: looked at again
    // whenever a session comes or goes and when the window is back in focus.
    vscode.debug.onDidStartDebugSession(() => refreshSwitch()),
    vscode.debug.onDidTerminateDebugSession(() => refreshSwitch()),
    vscode.window.onDidChangeWindowState((e) => {
      if (e.focused) {
        refreshSwitch();
      }
    }),
    { dispose: () => deactivateBoard() }
  );
  refreshSwitch();
}

async function reportBoardError(err) {
  const choice = await vscode.window.showErrorMessage(err.message, 'Open Settings', 'Show Output');
  if (choice === 'Open Settings') {
    vscode.commands.executeCommand('workbench.action.openSettings', 'zxspectrum.board');
  } else if (choice === 'Show Output') {
    output.show(true);
  }
}

// The window is closing: a bridge this window started goes with it, as the
// emulator does unless zxspectrum.server.stopOnExit says otherwise.
function deactivateBoard() {
  const stop = vscode.workspace.getConfiguration('zxspectrum.server').get('stopOnExit', true);
  if (child && stop) {
    child.kill();
    child = null;
  }
}

function log(text) {
  if (output) {
    output.appendLine(text);
  }
}

module.exports = { activateBoard, deactivateBoard, ensureBridge, chosenTarget, currentBoard, BoardError, log,
  isBoard: target.isBoard };
