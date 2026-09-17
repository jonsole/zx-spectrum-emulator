// Starting the emulator from VS Code.
//
// A launch configuration with no `debugServer` goes through the debug adapter
// descriptor factory registered here: it makes sure zx_server is listening on
// the DAP port -- starting it if nothing is -- and hands VS Code that port. A
// configuration that does name a `debugServer` never reaches this (VS Code
// connects to that port itself), which is how the repository's own
// configurations, whose preLaunchTask builds and starts the server, carry on
// exactly as before.
//
// A server the extension starts outlives the debug session, as a task-started
// one does, so an MCP client keeps its machine between sessions; it is stopped
// when VS Code closes (zxspectrum.server.stopOnExit). A server something else
// started is only ever joined, and only stopped when asked, after a question.
//
// The pure half -- where the executable is, how it is started -- is
// server_launch.js.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const launch = require('./server_launch');

const HOST = '127.0.0.1';
const START_TIMEOUT_MS = 20000;

let output;
let statusItem;
let child = null;          // the server this extension started, while it runs
let childExit = null;      // resolves when it exits
let state = 'stopped';     // stopped | starting | running | external
let starting = null;       // the start in progress, so two sessions share it

function settings() {
  return vscode.workspace.getConfiguration('zxspectrum.server');
}

function folders() {
  return (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
}

// The ports the server is (or would be) on. The screen and sound panels read
// these too, so a changed port reaches both sides.
function ports() {
  const config = settings();
  return launch.serverPorts((key) => config.get(key));
}

function log(text) {
  if (output) {
    output.append(text);
  }
}

// Whether anything answers on a port. A bare connect: the DAP server accepts
// and waits, and closing straight away costs it nothing.
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

function setState(next) {
  state = next;
  vscode.commands.executeCommand('setContext', 'zxspectrum.serverRunning',
    next === 'running' || next === 'external');
  if (!statusItem) {
    return;
  }
  const port = ports().dap;
  if (next === 'stopped') {
    statusItem.hide();
    return;
  }
  statusItem.text = next === 'starting' ? '$(loading~spin) Spectrum' : '$(vm-running) Spectrum';
  statusItem.tooltip = next === 'starting' ? `Starting the ZX Spectrum emulator on port ${port}...`
    : next === 'running' ? `ZX Spectrum emulator on port ${port}, started by VS Code`
    : `ZX Spectrum emulator on port ${port}, started outside this window`;
  statusItem.show();
}

async function refreshState() {
  if (state === 'starting') {
    return;
  }
  const up = await probe(ports().dap);
  if (!up) {
    setState('stopped');
  } else {
    setState(child ? 'running' : 'external');
  }
}

function locateServer() {
  const found = launch.serverCandidates({
    setting: settings().get('path'),
    folders: folders(),
    pathEnv: process.env.PATH,
    platform: process.platform,
    home: os.homedir()
  });
  const exists = (file) => {
    try {
      return fs.statSync(file).isFile();
    } catch (err) {
      return false;
    }
  };
  return { exe: launch.findServer(found.candidates, exists), configured: found.configured, exists };
}

class StartError extends Error {}

// Makes sure a server is listening on the DAP port, starting one if nothing
// is and the settings allow it. Resolves once it answers.
async function ensureServer() {
  if (starting) {
    return starting;
  }
  if (await probe(ports().dap)) {
    await refreshState();
    return;
  }
  if (!settings().get('autoStart', true)) {
    throw new StartError(`Nothing is listening on port ${ports().dap}, and ` +
      'zxspectrum.server.autoStart is off. Start the emulator, or turn the setting on.');
  }
  starting = startServer().finally(() => {
    starting = null;
  });
  return starting;
}

async function startServer() {
  const { exe, configured, exists } = locateServer();
  if (!exe) {
    const where = configured
      ? `zxspectrum.server.path names ${configured}, which does not exist.`
      : 'Set zxspectrum.server.path to where zx_server is, or open the emulator\'s repository ' +
        'with a build in cpp-core/build/RelWithDebInfo.';
    throw new StartError('Could not find the ZX Spectrum emulator (' +
      launch.exeName(process.platform) + '). ' + where);
  }
  const p = ports();
  const root = launch.serverRoot(exe, folders());
  const config = settings();
  const args = launch.serverArgs({
    ports: p,
    sound: config.get('sound', 'device'),
    roms: launch.serverRoms(config.get('roms'), root, os.homedir(), exists),
    extra: config.get('args', [])
  });

  setState('starting');
  output.appendLine(`> ${exe} ${args.join(' ')}`);
  output.appendLine(`  in ${root}`);
  let proc;
  try {
    proc = cp.spawn(exe, args, { cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    setState('stopped');
    throw new StartError(`Could not start ${exe}: ${err.message}`);
  }
  child = proc;
  proc.stdout.on('data', (chunk) => log(chunk.toString()));
  proc.stderr.on('data', (chunk) => log(chunk.toString()));
  let exitInfo = null;
  childExit = new Promise((resolve) => {
    const finish = (code, signal) => {
      if (exitInfo) {
        return;
      }
      exitInfo = { code, signal };
      output.appendLine(`[zx_server exited${code !== null ? ' with code ' + code : ''}` +
                        `${signal ? ' (' + signal + ')' : ''}]`);
      if (child === proc) {
        child = null;
        refreshState();
      }
      resolve();
    };
    proc.once('exit', finish);
    proc.once('error', (err) => {
      output.appendLine(`[could not run zx_server: ${err.message}]`);
      finish(null, null);
    });
  });

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (exitInfo) {
      setState('stopped');
      output.show(true);
      throw new StartError('The ZX Spectrum emulator stopped as it started -- see the ' +
        '"ZX Spectrum Emulator" output for why (a port in use, or a ROM it could not read).');
    }
    if (await probe(p.dap, 300)) {
      setState('running');
      return;
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  proc.kill();
  setState('stopped');
  output.show(true);
  throw new StartError(`The ZX Spectrum emulator did not start listening on port ${p.dap} ` +
    `within ${START_TIMEOUT_MS / 1000} seconds.`);
}

// Ends the zxspectrum debug session first: stopping its server under it
// would leave it reporting a lost connection instead.
async function endSessions() {
  const session = vscode.debug.activeDebugSession;
  if (session && session.type === 'zxspectrum') {
    await vscode.debug.stopDebugging(session);
  }
}

async function stopOwnServer() {
  if (!child) {
    return;
  }
  const exited = childExit;
  child.kill();
  await Promise.race([exited, new Promise((r) => setTimeout(r, 3000))]);
}

// A server this window did not start -- from a task, a terminal or another
// window. Only on Windows, where the PID behind the port can be found without
// extra tools, and only after asking: it may be someone else's live session.
async function stopExternalServer(port) {
  if (process.platform !== 'win32') {
    vscode.window.showWarningMessage(`The emulator on port ${port} was not started by this window; ` +
      'stop it from wherever it was started.');
    return false;
  }
  const answer = await vscode.window.showWarningMessage(
    `The ZX Spectrum emulator on port ${port} was started outside this window -- by a task, ` +
    'a terminal, or another window. Stop it anyway?', { modal: true }, 'Stop it');
  if (answer !== 'Stop it') {
    return false;
  }
  const netstat = cp.spawnSync('netstat', ['-ano', '-p', 'TCP'], { encoding: 'utf8', windowsHide: true });
  const pid = launch.pidListeningOn(netstat.stdout, port);
  if (!pid) {
    vscode.window.showErrorMessage(`Could not find the process listening on port ${port}.`);
    return false;
  }
  const list = cp.spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'],
    { encoding: 'utf8', windowsHide: true });
  if (!/zx_server/i.test(list.stdout || '')) {
    vscode.window.showErrorMessage(`Port ${port} belongs to process ${pid}, which is not zx_server; ` +
      'leaving it alone.');
    return false;
  }
  cp.spawnSync('taskkill', ['/PID', String(pid), '/F'], { windowsHide: true });
  output.appendLine(`[stopped zx_server, process ${pid}, which this window had not started]`);
  return true;
}

async function stopServer() {
  const port = ports().dap;
  await endSessions();
  if (child) {
    await stopOwnServer();
  } else if (await probe(port)) {
    if (!(await stopExternalServer(port))) {
      return false;
    }
    for (let i = 0; i < 20 && (await probe(port)); i++) {
      await new Promise((r) => setTimeout(r, 150));
    }
  }
  await refreshState();
  return true;
}

async function reportStartError(err) {
  const choice = await vscode.window.showErrorMessage(err.message, 'Open Settings', 'Show Log');
  if (choice === 'Open Settings') {
    vscode.commands.executeCommand('workbench.action.openSettings', 'zxspectrum.server');
  } else if (choice === 'Show Log') {
    output.show(true);
  }
}

async function commandStart() {
  try {
    if (await probe(ports().dap)) {
      await refreshState();
      vscode.window.showInformationMessage(`The ZX Spectrum emulator is already running on port ${ports().dap}.`);
      return;
    }
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: 'Starting the ZX Spectrum emulator' },
      () => ensureServer());
  } catch (err) {
    reportStartError(err);
  }
}

async function commandRestart() {
  if (!(await stopServer())) {
    return;
  }
  await commandStart();
}

async function commandMenu() {
  const running = state === 'running' || state === 'external';
  const items = running
    ? [
        { label: '$(debug-restart) Restart Emulator', command: 'zxspectrum.serverRestart' },
        { label: '$(debug-stop) Stop Emulator', command: 'zxspectrum.serverStop' },
        { label: '$(output) Show Emulator Log', command: 'zxspectrum.serverLog' }
      ]
    : [
        { label: '$(play) Start Emulator', command: 'zxspectrum.serverStart' },
        { label: '$(output) Show Emulator Log', command: 'zxspectrum.serverLog' }
      ];
  const pick = await vscode.window.showQuickPick(items, { placeHolder: statusItem.tooltip });
  if (pick) {
    vscode.commands.executeCommand(pick.command);
  }
}

function activateServer(context) {
  output = vscode.window.createOutputChannel('ZX Spectrum Emulator');
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusItem.command = 'zxspectrum.serverMenu';
  context.subscriptions.push(output, statusItem);

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory('zxspectrum', {
      async createDebugAdapterDescriptor() {
        // A failure is thrown rather than shown: VS Code reports a launch
        // that could not start itself, and a second notice would repeat it.
        try {
          await ensureServer();
        } catch (err) {
          output.appendLine(`[${err.message}]`);
          throw err;
        }
        return new vscode.DebugAdapterServer(ports().dap, HOST);
      }
    }),
    vscode.commands.registerCommand('zxspectrum.serverStart', commandStart),
    vscode.commands.registerCommand('zxspectrum.serverStop', () => stopServer()),
    vscode.commands.registerCommand('zxspectrum.serverRestart', commandRestart),
    vscode.commands.registerCommand('zxspectrum.serverLog', () => output.show(true)),
    vscode.commands.registerCommand('zxspectrum.serverMenu', commandMenu),
    vscode.debug.onDidStartDebugSession(() => refreshState()),
    vscode.debug.onDidTerminateDebugSession(() => refreshState()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('zxspectrum.server')) {
        refreshState();
      }
    })
  );
  // Not polled: every probe is a connection the server logs. A server this
  // window started reports its own exit; one started elsewhere is noticed
  // when a session starts or ends and when the window comes back into focus.
  context.subscriptions.push(vscode.window.onDidChangeWindowState((e) => {
    if (e.focused) {
      refreshState();
    }
  }));
  refreshState();
  return { ports, ensureServer };
}

// Called from the extension's deactivate: the window is closing.
function deactivateServer() {
  if (child && settings().get('stopOnExit', true)) {
    child.kill();
  }
}

module.exports = { activateServer, deactivateServer, ports };
