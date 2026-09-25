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
// A configuration's `ports` points it at another server instead: named ports,
// joined or started like the settings' server, or "auto" -- a server of the
// session's own on free ports, stopped with it (see "other servers" below).
//
// The pure half -- where the executable is, how it is started -- is
// server_launch.js.

'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const launch = require('./server_launch');
const registry = require('./server_registry');

const HOST = '127.0.0.1';
const START_TIMEOUT_MS = 20000;

let output;
let statusItem;
// Where the extension is installed: a release carries zx_server in bin/ and
// the ROMs in roms/ beneath it.
let extensionPath;
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
    home: os.homedir(),
    bundled: extensionPath && path.join(extensionPath, 'bin')
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

// Starts zx_server on `p` -- a port of 0 meaning any free one -- with the
// settings' sound, ROMs and extra arguments. Resolves once it is serving,
// with the process, a promise of its exit, and the ports it really got: read
// back from its advert when any were 0, since only the server knows which
// it was given. `onExit` hears about the exit whenever it comes.
async function spawnServer(p, onExit) {
  const { exe, configured, exists } = locateServer();
  if (!exe) {
    const where = configured
      ? `zxspectrum.server.path names ${configured}, which does not exist.`
      : 'Set zxspectrum.server.path to where zx_server is, or open the emulator\'s repository ' +
        'with a build in cpp-core/build/RelWithDebInfo.';
    throw new StartError('Could not find the ZX Spectrum emulator (' +
      launch.exeName(process.platform) + '). ' + where);
  }
  const root = launch.serverRoot(exe, folders());
  const config = settings();
  const args = launch.serverArgs({
    ports: p,
    sound: config.get('sound', 'device'),
    roms: launch.serverRoms(config.get('roms'), root, os.homedir(), exists,
      extensionPath && path.join(extensionPath, 'roms')),
    extra: config.get('args', [])
  });

  output.appendLine(`> ${exe} ${args.join(' ')}`);
  output.appendLine(`  in ${root}`);
  let proc;
  try {
    proc = cp.spawn(exe, args, { cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    throw new StartError(`Could not start ${exe}: ${err.message}`);
  }
  proc.stdout.on('data', (chunk) => log(chunk.toString()));
  proc.stderr.on('data', (chunk) => log(chunk.toString()));
  let exitInfo = null;
  const exited = new Promise((resolve) => {
    const finish = (code, signal) => {
      if (exitInfo) {
        return;
      }
      exitInfo = { code, signal };
      output.appendLine(`[zx_server ${proc.pid || ''} exited${code !== null ? ' with code ' + code : ''}` +
                        `${signal ? ' (' + signal + ')' : ''}]`);
      onExit(proc);
      resolve();
    };
    proc.once('exit', finish);
    proc.once('error', (err) => {
      output.appendLine(`[could not run zx_server: ${err.message}]`);
      finish(null, null);
    });
  });

  // Fixed ports are ready when the DAP port answers. Free ones are only
  // known once the server says, which it does by advertising -- and it
  // advertises once everything is bound, so the advert is the readiness
  // signal too.
  const anyPort = !p.dap || !p.mcp || !p.screen || !p.audio;
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (exitInfo) {
      output.show(true);
      throw new StartError('The ZX Spectrum emulator stopped as it started -- see the ' +
        '"ZX Spectrum Emulator" output for why (a port in use, or a ROM it could not read).');
    }
    if (anyPort) {
      const server = advertOf(proc.pid);
      if (server) {
        return { proc, exited, server };
      }
    } else if (await probe(p.dap, 300)) {
      return { proc, exited, server: advertOf(proc.pid) || { pid: proc.pid, ports: p } };
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  proc.kill();
  output.show(true);
  throw new StartError(anyPort
    ? `The ZX Spectrum emulator did not say which ports it was given within ${START_TIMEOUT_MS / 1000} ` +
      `seconds -- it writes them to ${advertDir()}, which a build older than the extension does not.`
    : `The ZX Spectrum emulator did not start listening on port ${p.dap} ` +
      `within ${START_TIMEOUT_MS / 1000} seconds.`);
}

async function startServer() {
  setState('starting');
  try {
    const started = await spawnServer(ports(), (proc) => {
      if (child === proc) {
        child = null;
        refreshState();
      }
    });
    child = started.proc;
    childExit = started.exited;
    setState('running');
  } catch (err) {
    setState('stopped');
    throw err;
  }
}

// ---- other servers -----------------------------------------------------------
//
// A launch configuration can name a server of its own with `ports`: a set of
// ports (joined if something is there, started if not), or "auto" -- a new
// server on free ports, for that session alone, stopped when it ends. What
// makes a second debug session a second machine rather than a second view of
// the first. The status bar item stays about the server in the settings.

// Servers this window started other than the one in the settings, by pid:
// { proc, sessionId } -- sessionId set for an "auto" server, which lives and
// dies with its session.
const extraServers = new Map();
// The ports each session was pointed at, by session id: what the screen
// panel falls back on for a server too old to answer serverInfo.
const sessionPorts = new Map();

function advertDir() {
  return registry.advertDirectory({
    env: process.env, platform: process.platform, home: os.homedir(), tmp: os.tmpdir()
  });
}

function advertOf(pid) {
  const dir = advertDir();
  try {
    const server = registry.parseAdvert(fs.readFileSync(path.join(dir, `${pid}.json`), 'utf8'));
    return server && server.pid === pid ? server : null;
  } catch (err) {
    return null;
  }
}

// Every server advertised on this machine that is still running.
function servers() {
  return registry.liveServers(advertDir(), {
    readdir: (dir) => fs.readdirSync(dir),
    readFile: (file) => fs.readFileSync(file, 'utf8'),
    unlink: (file) => fs.unlinkSync(file),
    alive: registry.processAlive
  });
}

async function spawnExtra(p, sessionId) {
  const started = await spawnServer(p, (proc) => extraServers.delete(proc.pid));
  extraServers.set(started.proc.pid, { proc: started.proc, sessionId });
  return started.server;
}

// A server on these ports: whatever is listening there, or a new one.
async function ensureServerOn(p) {
  const defaults = ports();
  if (['dap', 'mcp', 'screen', 'audio'].every((key) => p[key] === defaults[key])) {
    await ensureServer();
    return;
  }
  if (await probe(p.dap)) {
    return;
  }
  if (!settings().get('autoStart', true)) {
    throw new StartError(`Nothing is listening on port ${p.dap}, and ` +
      'zxspectrum.server.autoStart is off. Start the emulator, or turn the setting on.');
  }
  await spawnExtra(p, null);
}

// A new server for one session. A restart comes back here with the same
// session, and gets a fresh machine rather than the old one's leftovers.
async function startSessionServer(session) {
  stopSessionServers(session.id);
  return spawnExtra({ dap: 0, mcp: 0, screen: 0, audio: 0 }, session.id);
}

function stopSessionServers(sessionId) {
  for (const [pid, entry] of extraServers) {
    if (entry.sessionId === sessionId) {
      extraServers.delete(pid);
      entry.proc.kill();
    }
  }
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
        { label: '$(device-desktop) Show Screen of...', command: 'zxspectrum.showServerScreen' },
        { label: '$(output) Show Emulator Log', command: 'zxspectrum.serverLog' }
      ]
    : [
        { label: '$(play) Start Emulator', command: 'zxspectrum.serverStart' },
        { label: '$(device-desktop) Show Screen of...', command: 'zxspectrum.showServerScreen' },
        { label: '$(output) Show Emulator Log', command: 'zxspectrum.serverLog' }
      ];
  const pick = await vscode.window.showQuickPick(items, { placeHolder: statusItem.tooltip });
  if (pick) {
    vscode.commands.executeCommand(pick.command);
  }
}

function activateServer(context) {
  extensionPath = context.extensionPath;
  output = vscode.window.createOutputChannel('ZX Spectrum Emulator');
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusItem.command = 'zxspectrum.serverMenu';
  context.subscriptions.push(output, statusItem);

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory('zxspectrum', {
      async createDebugAdapterDescriptor(session) {
        // A failure is thrown rather than shown: VS Code reports a launch
        // that could not start itself, and a second notice would repeat it.
        try {
          const asked = registry.launchPorts(session.configuration.ports, ports());
          if (asked.error) {
            throw new StartError(asked.error);
          }
          let p;
          if (!asked.request) {
            await ensureServer();
            p = ports();
          } else if (asked.request.auto) {
            const server = await startSessionServer(session);
            p = Object.assign({}, server.ports);
          } else {
            await ensureServerOn(asked.request.ports);
            p = asked.request.ports;
          }
          sessionPorts.set(session.id, p);
          return new vscode.DebugAdapterServer(p.dap, HOST);
        } catch (err) {
          output.appendLine(`[${err.message}]`);
          throw err;
        }
      }
    }),
    // F5 in a folder with no launch.json: VS Code asks which debugger, then
    // hands over an empty configuration, and without this nothing happens at
    // all -- the first thing someone does after installing a release. What
    // it gets is the Spectrum booting into BASIC, on the ROMs the server was
    // started with, which is also what the generated launch.json does.
    vscode.debug.registerDebugConfigurationProvider('zxspectrum', {
      resolveDebugConfiguration(folder, config) {
        if (!config.type && !config.request && !config.name) {
          return { type: 'zxspectrum', request: 'launch', name: 'ZX Spectrum' };
        }
        return config;
      }
    }),
    vscode.debug.onDidTerminateDebugSession((session) => {
      sessionPorts.delete(session.id);
      stopSessionServers(session.id);
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

// Called from the extension's deactivate: the window is closing. A session's
// own server goes whatever the setting says -- nothing else knows it is
// there to stop it.
function deactivateServer() {
  const stopAll = settings().get('stopOnExit', true);
  if (child && stopAll) {
    child.kill();
  }
  for (const entry of extraServers.values()) {
    if (stopAll || entry.sessionId) {
      entry.proc.kill();
    }
  }
}

// The ports a session was pointed at when it started, or undefined.
function portsOfSession(session) {
  return session ? sessionPorts.get(session.id) : undefined;
}

module.exports = { activateServer, deactivateServer, ports, servers, portsOfSession };
