// ZX Spectrum Debug extension.
//
// Two jobs: (1) registering the "zxspectrum" debugger type (see package.json)
// -- a configuration's debugServer connects straight to zx-spectrum-emulator's
// DAP server, and one without it goes through server_view.js, which starts the
// server when nothing is listening; (2) this file -- a live screen viewer and
// beeper. A webview's own
// JS can't open a raw TCP socket, so this runs in the extension host (Node,
// has raw socket access via `net`), connects to the emulator's screen and
// audio stream ports, and forwards frames and sample blocks into the webview
// via postMessage.
//
// Pushing audio through postMessage rather than letting the webview fetch it
// is what keeps the CSP at `default-src 'none'`: Web Audio needs no network
// directive at all when the samples arrive as a message, the same reason the
// screen gets by with only `img-src data:`.

const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { activateAsmLanguage } = require('./asm_language');
const { activateProfile } = require('./profile_view');
const { activateRewind } = require('./rewind_view');
const { activateWatchpoints } = require('./watchpoint_view');
const http = require('http');
const {
  activateServer,
  deactivateServer,
  ports: serverPorts,
  servers: liveServers,
  portsOfSession,
} = require('./server_view');
const { describeServer, detailServer, sameServer, fromServerInfo } = require('./server_registry');
const { activatePrograms } = require('./program_view');
const { activateTapeDesigner } = require('./tape_view');
const graphicsModel = require('./graphics_model');
const {
  FILTERS,
  SCALES,
  SCANLINE_PRESETS,
  BORDER_PRESETS,
  visibleRect,
  layoutFor,
  prescaleFactor,
  scanlinesPossible,
  scanlineBand,
  normaliseView,
} = require('./screen_scaling');

// Each screen panel's ports are those of the server it shows -- asked of the
// session, or read from the server's advert -- and zxspectrum.server.*Port
// (serverPorts()) only until one of those has answered.
const SCREEN_HOST = '127.0.0.1';
const SCREEN_VIEW_TYPE = 'zxspectrumScreen';
const RECONNECT_DELAY_MS = 1000;

// How often the row counter is refreshed while a capture runs. traceStatus
// bypasses the emulator's command queue, so this costs nothing on the server
// side even mid-run -- it is paced for the eye, not for the machine.
const TRACE_POLL_MS = 400;
// Where the Record button writes. One fixed name rather than a prompt per
// capture: recording is something you do repeatedly while chasing one
// question down, and each capture supersedes the last.
const LIVE_TRACE_NAME = 'live.zxtrace';
// How often the graphics panel re-reads memory while its Live box is ticked.
// readMemory is a during_run job on the server (see Engine::submit), serviced
// at the run's own yields about twice a frame, so this can watch a sprite
// buffer being built without stopping the machine to do it.
const GRAPHICS_POLL_MS = 250;
// How often the tape pane asks where the tape has got to. tapeControl bypasses
// the emulator's command queue, exactly as traceStatus does, so this costs
// nothing on the server side even mid-load -- and like the trace poll it is
// paced for the eye. It only ticks while the pane is actually visible.
const TAPE_POLL_MS = 400;

let tracePanel;
let graphicsPanel;
let graphicsFile;   // the file "Choose file..." last picked
let graphicsPoll;   // ticks while the Live box is ticked
// A message for a panel that has only just been created. A webview drops
// anything posted before its script has run, and "open the panel and show this
// selection" is exactly one post at exactly that moment -- so it waits here
// for the page to say it is ready.
let graphicsPending = [];
// The last non-empty selection seen in a text editor. Remembered rather than
// read on demand because activeTextEditor is undefined while a webview has
// focus -- which is exactly when the panel's "Grab selection" button is
// clicked, so asking then would always come back empty.
let lastSelection;
// The extension context, so an event arriving from the server can open the
// graphics panel -- everything that creates a panel needs one for its
// disposables, and an event handler has no other way to reach it.
let graphicsContext;
// The highest graphics-view version applied from the server. Compared rather
// than simply applied, so catching up on open, on a session appearing and on
// an event can all call the same code without the last two undoing a change
// the first already made. A fresh server starts at 0 and never goes back,
// which is why this is reset when a session starts.
let graphicsAppliedVersion = 0;
let traceFile;      // the .zxtrace currently shown
let traceWatcher;   // reloads the panel when that file is recaptured
let tracePoll;      // ticks while a live capture is running
let tapeProvider;   // the block list shown in the debug sidebar
let tapeView;
let tapePoll;       // ticks while that pane is visible
const uiContextKeys = new Map(); // last value pushed for each when-clause key

// The screen panel's volume, which reaches both the panel's own playback and
// the server's native sound device; 0 is mute, and the level before a mute is
// kept so the speaker button can go back to it. Both are kept across reloads,
// so a reload never turns the sound back up by itself, and are handed to
// every server the extension meets.
const VOLUME_KEY = 'zxspectrum.audioVolume';
const VOLUME_BEFORE_MUTE_KEY = 'zxspectrum.audioVolumeBeforeMute';
let audioVolume = 100;
let audioVolumeBeforeMute = 100;
let volumeState; // the extension's globalState, where both are kept
// Whether the emulator is painting the display-write overlay. Off at every
// launch, which is what a freshly started server has it as.
let writeOverlayOn = false;
// ...and how it draws a stopped screen, which a freshly started server has as
// the beam marked and the in-progress frame composed, but pending writes not
// tracked. See RasterView in engine.h.
let rasterView = { marker: true, inProgress: true, pending: false };

function activate(context) {
  graphicsContext = context;
  volumeState = context.globalState;
  audioVolume = clampPercent(volumeState.get(VOLUME_KEY, 100), 100);
  audioVolumeBeforeMute = clampPercent(volumeState.get(VOLUME_BEFORE_MUTE_KEY, 100), 100) || 100;
  activateServer(context);
  activatePrograms(context);
  activateTapeDesigner(context);
  activateAsmLanguage(context);
  activateProfile(context, zxDebugSession);
  activateRewind(context, zxDebugSession);
  activateWatchpoints(context, zxDebugSession);
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showScreen', () => showScreenPanel(context)),
    vscode.commands.registerCommand('zxspectrum.showServerScreen', () => pickServerScreen(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showTrace', () => showTracePanel(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showGraphics', () => showGraphicsPanel(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showSelectionAsGraphics', () =>
      showSelectionAsGraphics(context)
    )
  );
  context.subscriptions.push(
    vscode.window.onDidChangeTextEditorSelection((event) => {
      if (event.selections.length > 0 && !event.selections[0].isEmpty) {
        lastSelection = { document: event.textEditor.document, range: event.selections[0] };
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.screenScaling', pickScreenScaling)
  );
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      // Whoever changed it -- the title-bar button, the Settings editor, a
      // settings.json edit -- every open panel follows.
      if (event.affectsConfiguration('zxspectrum.screen')) {
        for (const screen of screenPanels()) {
          screen.post({ view: screenView() });
        }
      }
    })
  );
  context.subscriptions.push(vscode.commands.registerCommand('zxspectrum.setSpeed', pickSpeed));
  speedStatus = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  speedStatus.command = 'zxspectrum.setSpeed';
  context.subscriptions.push(speedStatus);
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.loadTape', () => loadTape(context))
  );
  for (const [name, enabled] of [
    ['zxspectrum.writeOverlayOn', true],
    ['zxspectrum.writeOverlayOff', false],
  ]) {
    context.subscriptions.push(
      vscode.commands.registerCommand(name, () => setWriteOverlay(enabled))
    );
  }
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.writeOverlayFade', pickWriteOverlayFade)
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.writeOverlayOpacity', pickWriteOverlayOpacity)
  );
  for (const [name, field, value] of [
    ['zxspectrum.rasterMarkerOn', 'marker', true],
    ['zxspectrum.rasterMarkerOff', 'marker', false],
    ['zxspectrum.rasterInProgressOn', 'inProgress', true],
    ['zxspectrum.rasterInProgressOff', 'inProgress', false],
    ['zxspectrum.rasterPendingOn', 'pending', true],
    ['zxspectrum.rasterPendingOff', 'pending', false],
  ]) {
    context.subscriptions.push(
      vscode.commands.registerCommand(name, () => setRasterView({ [field]: value }))
    );
  }

  // The tape pane, in the debug view container -- so it docks with Call Stack
  // and Breakpoints rather than floating as another editor tab. The tree is
  // the shape the data already has: a tape IS a list of blocks.
  tapeProvider = new TapeTreeProvider();
  tapeView = vscode.window.createTreeView('zxspectrumTape', {
    treeDataProvider: tapeProvider,
  });
  context.subscriptions.push(tapeView);
  // Settles the title bar on the defaults before any status has arrived --
  // otherwise the fast-load button spends the first poll interval showing the
  // opposite of what the emulator is actually doing.
  refreshTape(undefined);
  // Polling only while someone is looking. The request is free server-side,
  // but a pane in a collapsed section is not worth a request every 400ms.
  context.subscriptions.push(
    tapeView.onDidChangeVisibility((e) => {
      if (e.visible) {
        startTapePolling();
      } else {
        stopTapePolling();
      }
    })
  );
  for (const [name, action] of [
    ['zxspectrum.tapePlay', 'play'],
    ['zxspectrum.tapeStop', 'stop'],
    ['zxspectrum.tapeRewind', 'rewind'],
    ['zxspectrum.tapeEject', 'eject'],
  ]) {
    context.subscriptions.push(
      vscode.commands.registerCommand(name, () => tapeControl({ action }))
    );
  }
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.tapeFastLoadOn', () =>
      tapeControl({ fastLoad: true })
    )
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.tapeFastLoadOff', () =>
      tapeControl({ fastLoad: false })
    )
  );
  // Seek leaves the motor stopped, so clicking a block and pressing Play is
  // two steps -- deliberately. Seeking mid-load would otherwise yank the tape
  // out from under a loader that is part-way through reading it.
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.tapeSeek', (item) => {
      // The tree hands over the item it was invoked on; the block index is
      // what the request wants.
      const block = item && typeof item === 'object' ? item.zxBlock : item;
      if (typeof block === 'number') {
        tapeControl({ action: 'seek', block });
      }
    })
  );

  // Auto-open on launching a zxspectrum debug session -- no matching
  // auto-close on terminate, since staying open across a relaunch (e.g.
  // restarting the server task during development) is more useful than
  // having it disappear and need reopening every time.
  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession((session) => {
      if (session.type === 'zxspectrum') {
        // A new server starts with the overlay off and the raster view at its
        // own defaults, whatever the last one was left showing.
        writeOverlayOn = false;
        rasterView = { marker: true, inProgress: true, pending: false };
        currentSpeed = { uncapped: false, multiplier: 1 };
        // A new server's graphics-view version restarts at 0, so what this
        // session has already applied must not be held against it.
        graphicsAppliedVersion = 0;
        zxSessions.set(session.id, { session, server: null });
        showScreenPanel(context);
        followActiveSession();
        startTapePolling();
      }
      refreshSpeedStatus();
      publishUiContext();
      publishLiveState();
    })
  );
  // A capture belongs to the session that is making it, so one ending ends the
  // capture's story too -- the panel goes back to "no debug session" rather
  // than sitting on a row count that has stopped moving.
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession((session) => {
      // The following panel stays on the server it was showing: a restart
      // comes straight back to it, and the picture should not blink away
      // in between.
      zxSessions.delete(session.id);
      stopTracePolling();
      stopTapePolling();
      refreshTape(undefined);
      refreshSpeedStatus();
      publishLiveState();
    })
  );
  // The only way out here to hear that the machine has stopped. VS Code
  // surfaces a session's stack frame, not its DAP events, so a panel that
  // wants to re-read memory the moment a breakpoint hits has to watch the
  // traffic itself.
  // How an MCP client reaches the editor: the server broadcasts this when
  // something sets a graphics view, and VS Code hands unknown DAP events to
  // extensions for exactly this purpose. See "driving the panel from MCP".
  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
      if (event.session.type === 'zxspectrum' && event.event === 'zxGraphicsView') {
        applyGraphicsView(context, event.body);
      }
    })
  );
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory('zxspectrum', {
      createDebugAdapterTracker() {
        return {
          onDidSendMessage(message) {
            if (message && message.type === 'event' && message.event === 'stopped') {
              postGraphics({ type: 'refresh' });
            }
          },
        };
      },
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidChangeActiveDebugSession(() => {
      // The session is not necessarily active yet when onDidStartDebugSession
      // fires, so this is the event that reliably has one to poll.
      startTapePolling();
      refreshSpeedStatus();
      publishUiContext();
      publishLiveState();
      // A server that has just started is at full volume, whatever the
      // panel says.
      sendVolume();
      // A second session can be on a second machine; the screen goes with
      // whichever is being debugged.
      followActiveSession();
      // A view can be set over MCP before VS Code is there to hear it. This is
      // the event that reliably has a session to ask, so it is where the
      // catching up happens.
      catchUpGraphicsView(true);
    })
  );
}

// ---- emulation speed -------------------------------------------------------

/// The speeds the picker offers.
///
/// VS Code's debug toolbar takes buttons, not dropdowns, so "a dropdown" here
/// is a button that opens a quick pick -- the same shape VS Code uses for
/// every other list-of-choices in the debug UI. The status bar item beside it
/// is what actually shows the current speed, since a toolbar button's title
/// is fixed at contribution time and cannot.
const SPEED_CHOICES = [
  {
    label: '1/1000x',
    description: 'a frame every twenty seconds -- watch a single write land ahead of the beam',
    multiplier: 0.001,
  },
  { label: '1/500x', description: 'a frame every ten seconds', multiplier: 0.002 },
  { label: '1/200x', description: 'a frame every four seconds', multiplier: 0.005 },
  {
    label: '1/100x',
    description: 'a frame every two seconds -- the beam crawls down a couple of lines at a time',
    multiplier: 0.01,
  },
  { label: '1/50x', description: 'a frame a second -- raster effects line by line', multiplier: 0.02 },
  { label: '1/25x', description: 'two frames a second', multiplier: 0.04 },
  {
    label: '1/10x',
    description: 'slow motion -- slow enough to watch the beam sweep down the screen',
    multiplier: 0.1,
  },
  { label: '1/4x', description: 'quarter speed', multiplier: 0.25 },
  { label: '1/2x', description: 'half speed', multiplier: 0.5 },
  { label: '1x', description: 'a real 48K -- the only speed with sound', multiplier: 1 },
  { label: '2x', description: 'double speed', multiplier: 2 },
  { label: '3x', description: 'triple speed', multiplier: 3 },
  { label: '5x', description: 'five times -- for sitting through a loading screen', multiplier: 5 },
  {
    label: 'Uncapped',
    description: 'as fast as this machine manages, with no pacing at all',
    uncapped: true,
  },
];

let speedStatus;
let currentSpeed = { uncapped: false, multiplier: 1 };

/// How the current speed reads in the status bar: the picker's own label when
/// it is one of the offered speeds, and the bare number when the emulator was
/// set to something else (by an MCP client, say).
function speedLabel(speed) {
  if (speed.uncapped) {
    return 'Uncapped';
  }
  const known = SPEED_CHOICES.find((choice) => choice.multiplier === speed.multiplier);
  return known ? known.label : `${speed.multiplier}x`;
}

function refreshSpeedStatus() {
  if (!speedStatus) {
    return;
  }
  if (!zxDebugSession()) {
    speedStatus.hide();
    return;
  }
  speedStatus.text = `$(dashboard) ${speedLabel(currentSpeed)}`;
  speedStatus.tooltip = 'ZX Spectrum emulation speed -- click to change';
  speedStatus.show();
}

/// Sends one speed change and adopts whatever the emulator reports back --
/// which is not always what was asked for, since the multiplier is clamped.
async function applySpeed(request) {
  const session = zxDebugSession();
  if (!session) {
    vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    return;
  }
  try {
    const body = await session.customRequest('setSpeed', request);
    if (body) {
      currentSpeed = { uncapped: body.uncapped === true, multiplier: body.multiplier };
    }
    refreshSpeedStatus();
  } catch (err) {
    vscode.window.showErrorMessage(`Could not set the speed: ${err.message}`);
  }
}

async function pickSpeed() {
  const choice = await vscode.window.showQuickPick(
    SPEED_CHOICES.map((entry) =>
      Object.assign({}, entry, {
        label: speedLabel(currentSpeed) === entry.label ? `$(check) ${entry.label}` : entry.label,
      })
    ),
    { title: 'ZX Spectrum: emulation speed' }
  );
  if (!choice) {
    return;
  }
  await applySpeed(choice.uncapped ? { uncapped: true } : { multiplier: choice.multiplier });
}

// ---- screen panels -----------------------------------------------------------
//
// One panel per emulator being watched. The first -- "the" screen panel, which
// a launch opens and Show Screen brings back -- follows the debugger: it shows
// whichever server the active zxspectrum session is on, and with no session,
// the last one it showed. Show Screen of... opens more, each on a server
// picked from the ones advertised on this machine (server_registry.js), and
// each stays on that server until it is closed.
//
// Which server a session is on is asked of the session itself (serverInfo),
// since a launch can name ports of its own or ask for free ones; the ports it
// was pointed at stand in for a server too old to answer.

let followPanel;               // the ScreenPanel that follows the debugger
const pinnedPanels = new Set(); // the ones opened on a server of their own
// Every zxspectrum session there is, by id, with the server it is on once
// known -- VS Code keeps no list of sessions to ask.
const zxSessions = new Map();

// The server in the settings, known by its ports alone: what the panel shows
// before any session has said otherwise.
function settingsServer() {
  return { pid: null, host: SCREEN_HOST, ports: Object.assign({}, serverPorts()), program: null };
}

// The server a session is on. Asked once and remembered; until the session
// can answer (it may not have initialised yet), the ports it was started
// against, which are the right ones for everything but a server too old to
// say.
async function serverOfSession(session) {
  const entry = zxSessions.get(session.id);
  if (entry && entry.server) {
    return entry.server;
  }
  let server = null;
  try {
    server = fromServerInfo(await session.customRequest('serverInfo'));
  } catch (err) {
    // not initialised yet, or an older server
  }
  if (!server) {
    const p = portsOfSession(session);
    return p ? { pid: null, host: SCREEN_HOST, ports: Object.assign({}, p), program: null }
      : settingsServer();
  }
  if (entry) {
    entry.server = server;
  }
  return server;
}

// A zxspectrum session on `server`, preferring the active one: where a
// panel's keys and volume go.
function sessionOnServer(server) {
  const active = zxDebugSession();
  const activeEntry = active && zxSessions.get(active.id);
  const matches = (entry) => {
    if (entry.server) {
      return sameServer(entry.server, server);
    }
    const p = portsOfSession(entry.session);
    return !!p && p.dap === server.ports.dap;
  };
  if (activeEntry && matches(activeEntry)) {
    return active;
  }
  for (const entry of zxSessions.values()) {
    if (matches(entry)) {
      return entry.session;
    }
  }
  return undefined;
}

// Moves the following panel to the active session's server.
async function followActiveSession() {
  const session = zxDebugSession();
  if (!followPanel || !session) {
    return;
  }
  const server = await serverOfSession(session);
  if (followPanel && zxDebugSession() === session) {
    followPanel.retarget(server);
  }
}

class ScreenPanel {
  constructor(context, server, follows) {
    this.server = server;
    this.follows = follows;
    this.screenSocket = undefined;
    this.screenTimer = undefined;
    this.screenBuffer = Buffer.alloc(0);
    this.audioSocket = undefined;
    this.audioTimer = undefined;
    this.audioBuffer = Buffer.alloc(0);
    this.audioPreambleSeen = false;
    // One connection at a time for keys sent over MCP, so a key's release
    // can never overtake its press.
    this.mcpAgent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    this.panel = vscode.window.createWebviewPanel(
      SCREEN_VIEW_TYPE,
      this.title(),
      vscode.ViewColumn.Beside,
      { enableScripts: true, retainContextWhenHidden: true }
    );
    // In the page itself rather than posted after it: a message sent before
    // the webview's script has run is not guaranteed to arrive.
    this.panel.webview.html = getHtml(screenView(), audioVolume, audioVolumeBeforeMute);
    this.panel.onDidDispose(() => this.dispose(), null, context.subscriptions);
    this.panel.webview.onDidReceiveMessage((message) => this.onMessage(message), null,
      context.subscriptions);
    this.connect();
  }

  title() {
    const s = this.server;
    // The usual case, one emulator on the usual ports, keeps the plain name.
    if (this.follows && s.ports.dap === serverPorts().dap) {
      return 'ZX Spectrum Screen';
    }
    return `ZX Spectrum Screen — ${s.pid ? describeServer(s) : ':' + s.ports.dap}`;
  }

  // Brought forward where it already is, never moved. Beside means beside
  // the active editor, and on a restart that is wherever the last session
  // stopped -- so revealing Beside carried the panel into another group,
  // resizing it or burying it behind a source tab. Already on show, it is
  // left alone, and focus stays in the editor either way.
  show() {
    if (!this.panel.visible) {
      this.panel.reveal(this.panel.viewColumn, true);
    }
  }

  // Points the panel at `server`, reconnecting only if its streams moved:
  // the same server described better (its pid, its program) just retitles.
  retarget(server) {
    const moved = server.ports.screen !== this.server.ports.screen
      || server.ports.audio !== this.server.ports.audio
      || (server.host || SCREEN_HOST) !== (this.server.host || SCREEN_HOST);
    this.server = server;
    this.panel.title = this.title();
    if (moved) {
      this.disconnect();
      this.connect();
    }
  }

  post(message) {
    this.panel.webview.postMessage(message);
  }

  connect() {
    this.connectScreen();
    if (this.server.ports.audio) {
      this.connectAudio();
    }
  }

  disconnect() {
    for (const kind of ['screen', 'audio']) {
      const socket = this[kind + 'Socket'];
      if (socket) {
        socket.removeAllListeners();
        socket.destroy();
        this[kind + 'Socket'] = undefined;
      }
      if (this[kind + 'Timer']) {
        clearTimeout(this[kind + 'Timer']);
        this[kind + 'Timer'] = undefined;
      }
    }
  }

  // The server gets restarted often during development (a code change needs
  // a fresh process) -- reconnecting automatically instead of giving up on
  // the first drop means the panel recovers on its own instead of needing to
  // be closed and reopened every time.
  reconnectLater(kind) {
    if (this.disposed || this[kind + 'Timer']) {
      return;
    }
    this[kind + 'Timer'] = setTimeout(() => {
      this[kind + 'Timer'] = undefined;
      if (!this.disposed) {
        if (kind === 'screen') {
          this.connectScreen();
        } else {
          this.connectAudio();
        }
      }
    }, RECONNECT_DELAY_MS);
  }

  connectScreen() {
    this.screenBuffer = Buffer.alloc(0);
    const socket = net.connect(this.server.ports.screen, this.server.host || SCREEN_HOST);
    this.screenSocket = socket;
    socket.on('data', (chunk) => {
      this.screenBuffer = Buffer.concat([this.screenBuffer, chunk]);
      // A frame is a 4-byte big-endian length prefix + that many PNG bytes
      // (see cpp-core/src/screen_stream.cpp) -- loop in case several frames
      // arrived in one chunk, and leave a partial frame buffered for the
      // next 'data' event rather than assuming chunk boundaries line up with
      // frame boundaries (they generally won't).
      while (this.screenBuffer.length >= 4) {
        const length = this.screenBuffer.readUInt32BE(0);
        if (this.screenBuffer.length < 4 + length) break;
        const frame = this.screenBuffer.subarray(4, 4 + length);
        this.screenBuffer = this.screenBuffer.subarray(4 + length);
        this.post({ image: frame.toString('base64') });
      }
    });
    socket.on('error', () => this.reconnectLater('screen'));
    socket.on('close', () => this.reconnectLater('screen'));
  }

  connectAudio() {
    this.audioBuffer = Buffer.alloc(0);
    this.audioPreambleSeen = false;
    const socket = net.connect(this.server.ports.audio, this.server.host || SCREEN_HOST);
    this.audioSocket = socket;
    socket.on('data', (chunk) => {
      this.audioBuffer = Buffer.concat([this.audioBuffer, chunk]);

      // A one-off preamble: "ZXA2", a big-endian u32 sample rate, then the
      // server's target latency in ms. Both travel with the stream so
      // neither is hardcoded here, and so the server's --audio-latency-ms is
      // the single knob for how deep the panel buffers too.
      if (!this.audioPreambleSeen) {
        if (this.audioBuffer.length < 12) return;
        const magic = this.audioBuffer.subarray(0, 4).toString('latin1');
        const rate = this.audioBuffer.readUInt32BE(4);
        const latencyMs = this.audioBuffer.readUInt32BE(8);
        this.audioBuffer = this.audioBuffer.subarray(12);
        this.audioPreambleSeen = true;
        if (magic !== 'ZXA2') {
          // An older server, or something else altogether listening on that
          // port. Stop rather than feed the speakers whatever it is sending.
          socket.removeAllListeners();
          socket.destroy();
          this.audioSocket = undefined;
          return;
        }
        this.post({ audioRate: rate, audioLatencyMs: latencyMs });
      }

      // Then [4-byte big-endian byte length][mono int16 LE samples] blocks,
      // reassembled exactly the way the screen's PNG frames are.
      while (this.audioBuffer.length >= 4) {
        const length = this.audioBuffer.readUInt32BE(0);
        if (this.audioBuffer.length < 4 + length) break;
        const block = this.audioBuffer.subarray(4, 4 + length);
        this.audioBuffer = this.audioBuffer.subarray(4 + length);
        this.post({ audio: block.toString('base64') });
      }
    });
    socket.on('error', () => this.reconnectLater('audio'));
    socket.on('close', () => this.reconnectLater('audio'));
  }

  // Keys typed into the panel (see getHtml()'s script) and its volume
  // slider. Keys go to the machine this panel shows: through a debug session
  // on it when there is one (dap.cpp's keyDown/keyUp), and otherwise
  // straight to its MCP port -- a server nobody is debugging can still be
  // played. Failures are dropped quietly: this fires on every keystroke, and
  // a popup per keypress would be far too noisy.
  async onMessage(message) {
    if (message.type === 'setVolume') {
      audioVolume = clampPercent(message.volume, audioVolume);
      audioVolumeBeforeMute = clampPercent(message.before, audioVolumeBeforeMute) || 100;
      // Stored when a drag ends rather than at every step of it.
      if (message.persist) {
        volumeState.update(VOLUME_KEY, audioVolume);
        volumeState.update(VOLUME_BEFORE_MUTE_KEY, audioVolumeBeforeMute);
      }
      sendVolume(sessionOnServer(this.server));
      return;
    }
    if (message.type !== 'keyDown' && message.type !== 'keyUp') return;
    const session = sessionOnServer(this.server);
    if (session) {
      try {
        await session.customRequest(message.type, { key: message.key });
      } catch (err) {
        // Most likely cause: a server too old to have keyDown/keyUp.
      }
      return;
    }
    if (this.server.ports.mcp) {
      callMcpTool(this.server, this.mcpAgent, message.type === 'keyDown' ? 'key_down' : 'key_up',
        { key: message.key });
    }
  }

  dispose() {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.disconnect();
    this.mcpAgent.destroy();
    if (followPanel === this) {
      followPanel = undefined;
    }
    pinnedPanels.delete(this);
  }
}

// Every open screen panel.
function screenPanels() {
  const all = Array.from(pinnedPanels);
  if (followPanel) {
    all.unshift(followPanel);
  }
  return all;
}

// One MCP tool call, fire and forget. MCP here is plain JSON-RPC over HTTP
// POST with nothing kept per session (mcp_server.cpp), so a call needs no
// handshake first.
function callMcpTool(server, agent, name, args) {
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name, arguments: args } });
  const request = http.request({
    host: server.host || SCREEN_HOST,
    port: server.ports.mcp,
    path: '/mcp',
    method: 'POST',
    agent,
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      'Content-Length': Buffer.byteLength(body)
    }
  }, (response) => response.resume());
  request.on('error', () => {});
  request.end(body);
}

function showScreenPanel(context) {
  if (followPanel) {
    followPanel.show();
    return;
  }
  followPanel = new ScreenPanel(context, settingsServer(), true);
  followActiveSession();
}

// Show Screen of...: every emulator advertised on this machine, and a panel
// on the one picked -- brought forward if one is already showing it.
async function pickServerScreen(context) {
  const list = liveServers();
  if (list.length === 0) {
    vscode.window.showInformationMessage('No ZX Spectrum emulator is running -- or none new ' +
      'enough to advertise itself (a zx_server built before server adverts, 2026-09-23).');
    return;
  }
  const items = list.map((server) => {
    const marks = [];
    if (sessionOnServer(server)) {
      marks.push('$(debug) debugging');
    }
    if (screenPanels().some((p) => sameServer(p.server, server))) {
      marks.push('$(eye) on screen');
    }
    return { label: describeServer(server), description: marks.join('  '),
      detail: detailServer(server), server };
  });
  const pick = await vscode.window.showQuickPick(items, {
    title: 'ZX Spectrum: Show Screen of...',
    placeHolder: 'Every emulator running on this machine, newest first'
  });
  if (!pick) {
    return;
  }
  const showing = screenPanels().find((p) => sameServer(p.server, pick.server));
  if (showing) {
    showing.retarget(pick.server);
    showing.show();
    return;
  }
  pinnedPanels.add(new ScreenPanel(context, pick.server, false));
}

// How the screen panel draws the picture, from the settings -- see
// screen_scaling.js for what each choice means.
function screenView() {
  const config = vscode.workspace.getConfiguration('zxspectrum.screen');
  return normaliseView({
    filter: config.get('filter'),
    scale: config.get('scale'),
    scanlines: config.get('scanlines'),
    border: config.get('border'),
  });
}

/// One list, three sections: picking a filter changes the filter, a size the
/// size, a scanline darkness the darkness, and the current one of each is
/// ticked. Stored as a
/// user setting, so it holds in every workspace and survives a reload.
async function pickScreenScaling() {
  const current = screenView();
  const items = [{ label: 'Filter', kind: vscode.QuickPickItemKind.Separator }];
  for (const f of FILTERS) {
    items.push({
      label: `${f.id === current.filter ? '$(check)' : '$(blank)'} ${f.label}`,
      detail: f.detail,
      setting: 'filter',
      value: f.id,
    });
  }
  items.push({ label: 'Size', kind: vscode.QuickPickItemKind.Separator });
  for (const s of SCALES) {
    items.push({
      label: `${s.id === current.scale ? '$(check)' : '$(blank)'} ${s.label}`,
      detail: s.detail,
      setting: 'scale',
      value: s.id,
    });
  }
  items.push({ label: 'Border', kind: vscode.QuickPickItemKind.Separator });
  percentItems(items, 'border', current.border, BORDER_PRESETS, (percent) =>
    percent === 100 ? 'All of it' : percent === 0 ? 'None -- the paper alone' : `${percent}%`
  );
  items.push({ label: 'Scanlines', kind: vscode.QuickPickItemKind.Separator });
  percentItems(items, 'scanlines', current.scanlines, SCANLINE_PRESETS, (percent) =>
    percent === 0 ? 'Off' : `${percent}% dark`
  );
  const pick = await vscode.window.showQuickPick(items, {
    title: 'ZX Spectrum Screen Scaling',
    placeHolder: 'Pick a filter, a size, a border or a scanline darkness -- each is set on its own',
  });
  if (!pick) {
    return;
  }
  let value = pick.value;
  if (value === undefined) {
    const prompts = {
      border: {
        title: 'Border size',
        prompt: 'How much of the border to show, 0 (the paper alone) to 100 (all of it)',
      },
      scanlines: {
        title: 'Scanline darkness',
        prompt: 'How dark the gaps between the lines are, 0 (off) to 100 (black)',
      },
    };
    const typed = await vscode.window.showInputBox({
      title: prompts[pick.setting].title,
      prompt: prompts[pick.setting].prompt,
      value: String(current[pick.setting]),
      validateInput: (text) =>
        /^\s*\d{1,3}\s*%?\s*$/.test(text) && Number(text.replace('%', '')) <= 100
          ? undefined
          : 'A whole number from 0 to 100',
    });
    if (typed === undefined) {
      return;
    }
    value = Number(typed.replace('%', '').trim());
  }
  await vscode.workspace
    .getConfiguration('zxspectrum.screen')
    .update(pick.setting, value, vscode.ConfigurationTarget.Global);
}

/// A percentage setting's presets, then a Custom entry that shows the current
/// value when it is not one of them. A Custom pick has no value: the picker
/// asks for one.
function percentItems(items, setting, current, presets, name) {
  for (const percent of presets) {
    items.push({
      label: `${percent === current ? '$(check)' : '$(blank)'} ${name(percent)}`,
      setting,
      value: percent,
    });
  }
  const custom = !presets.includes(current);
  items.push({
    label: `${custom ? '$(check)' : '$(blank)'} ${custom ? `Custom: ${current}%` : 'Custom...'}`,
    detail: 'Any whole percentage from 0 to 100.',
    setting,
    value: undefined,
  });
}

// A whole percentage from 0 to 100, or `fallback` when it is not a number.
function clampPercent(value, fallback) {
  const n = Math.round(Number(value));
  if (!Number.isFinite(n)) return fallback;
  return n < 0 ? 0 : n > 100 ? 100 : n;
}

// Tells a server how loud its native sound device should be, through a
// session on it -- the active one when none is named. Quietly does nothing
// without one, and against a server too old to know the request: the panel's
// own playback follows the slider either way.
async function sendVolume(session = zxDebugSession()) {
  if (!session) return;
  try {
    await session.customRequest('setAudioVolume', { volume: audioVolume });
  } catch (err) {
    // an older server
  }
}


// ---- tape -------------------------------------------------------------------
//
// Insertion goes over a loadTape custom request on the active debug session
// (server-side: dap.cpp), the same channel the trace panel's Record button
// uses. There is no way to do it from the extension host directly: the
// extension registers no debug adapter of its own -- launch.json points at
// debugServer -- so the session IS the only handle on the running emulator.
//
// A tape can also be named in launch.json ("tape"), which is the better route
// when it is always the same image; this command is for reaching for a
// different one mid-session.

async function loadTape(context) {
  const session = vscode.debug.activeDebugSession;
  if (!session || session.type !== 'zxspectrum') {
    vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    return;
  }
  // Opens in tapes/ when the workspace has one -- that is where
  // scripts/make_test_tape.py writes, and where tape images tend to live.
  const folders = vscode.workspace.workspaceFolders;
  let start;
  if (folders && folders.length > 0) {
    start = vscode.Uri.joinPath(folders[0].uri, 'tapes');
    if (!fs.existsSync(start.fsPath)) {
      start = folders[0].uri;
    }
  }
  const chosen = await vscode.window.showOpenDialog({
    canSelectMany: false,
    openLabel: 'Load tape',
    filters: {
      'ZX Spectrum tape': ['tap', 'tzx', 'wav', 'csw'],
      'Tape image': ['tap', 'tzx'],
      'Tape recording': ['wav', 'csw'],
      'All files': ['*'],
    },
    defaultUri: start,
  });
  if (!chosen || chosen.length === 0) {
    return;
  }
  // Only the request itself is guarded, and deliberately so: anything that
  // goes wrong afterwards is a problem with showing the result, not with
  // loading the tape, and reporting it as "could not load tape" would send
  // you looking in the wrong place for a tape that is already in the machine.
  let status;
  try {
    status = await session.customRequest('loadTape', {
      path: chosen[0].fsPath,
      autoStart: true,
    });
  } catch (err) {
    // err.message is the adapter's reason (dap.cpp puts it in the response's
    // top-level `message`); the rest is for the case where it is not.
    const detail = (err && (err.message || err.toString())) || String(err);
    console.error('zxspectrum.loadTape failed', err);
    vscode.window.showErrorMessage(
      `Could not load tape ${chosen[0].fsPath}: ${detail}`
    );
    return;
  }

  // The screen is where the load is actually visible, so bring it up.
  showScreenPanel(context);
  // The response already carries the new block list, so the pane is right
  // immediately rather than at the next poll.
  refreshTape(status);
  startTapePolling();
  const blocks = `${status.blocks} block${status.blocks === 1 ? '' : 's'}`;
  vscode.window.showInformationMessage(
    `Tape inserted: ${status.description || status.name} (${blocks}), loading...`
  );
  for (const warning of status.warnings || []) {
    vscode.window.showWarningMessage(`Tape: ${warning}`);
  }
}

// ---- the tape pane ----------------------------------------------------------
//
// A tree in the debug view container, so it sits with Call Stack and
// Breakpoints. A TreeDataProvider rather than a webview on purpose: the data
// is a list, VS Code already draws lists that look like the rest of the
// sidebar, and a webview here would mean hand-rolling theming and a CSP to
// arrive somewhere worse.
//
// Every tape response carries the block list (server-side: dap.cpp's
// tape_body), so the pane never has to ask for the contents separately -- one
// poll answers both "what is on this tape" and "where has it got to".

/// The last tape status seen, block list included, or undefined when there is
/// no session. The tree renders this and nothing else.
let tapeStatus;

class TapeTreeProvider {
  constructor() {
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;
  }

  refresh() {
    this._onDidChangeTreeData.fire();
  }

  getTreeItem(item) {
    return item;
  }

  getChildren(item) {
    if (item) {
      return item.zxChildren || [];
    }
    if (!tapeStatus || !tapeStatus.inserted) {
      // Empty: the view's viewsWelcome content (package.json) takes over and
      // offers the Load Tape button, which is more use than a "no tape" row.
      return [];
    }
    const blocks = tapeStatus.blockList || [];
    return blocks.map((block) => makeBlockItem(block, tapeStatus));
  }
}

/// One row per block, with its detail as children rather than in the label --
/// a tape's rows are read down the list, and "Bytes: MMCODE" scans where
/// "Bytes: MMCODE, tzx 0x11, pilot 3223, pause 1000ms" does not.
function makeBlockItem(block, status) {
  const name = block.name ? `${block.kind}: ${block.name}` : block.kind;
  const item = new vscode.TreeItem(
    `${block.index}  ${name}`,
    vscode.TreeItemCollapsibleState.Collapsed
  );
  // A stable id per block, so a row the user has expanded stays expanded when
  // the poll redraws the tree underneath it.
  item.id = `zx-tape-block-${block.index}`;
  const size = block.dataBytes > 0 ? `${block.dataBytes} B · ` : '';
  item.description = `${size}${formatDuration(block.durationMs)}`;
  item.iconPath = blockIcon(block, status);
  item.tooltip = blockTooltip(block);
  // Seek hangs off the row's own hover button (package.json's
  // view/item/context, group "inline") rather than off item.command. These
  // rows expand, and a plain click both expands a row and runs its command --
  // which would make reading a block's detail move the tape.
  item.contextValue = 'zxspectrumTapeBlock';
  item.zxBlock = block.index;

  const detail = [`Block ${describeBlockId(block.id)}`];
  if (!block.standardSpeed) {
    detail.push('Non-standard timings, so fast load will decline this block');
  }
  if (block.stopTape) {
    detail.push('Stops the motor when it has played');
  }
  if (block.pauseMs > 0) {
    detail.push(`${block.pauseMs}ms pause after it`);
  }
  item.zxChildren = detail.map((text, i) => {
    const child = new vscode.TreeItem(text);
    child.id = `zx-tape-block-${block.index}-${i}`;
    return child;
  });
  return item;
}

/// Where the tape has got to, said in icons: the one playing, the ones behind
/// it, the ones still to come. `status.block` is the cursor -- the block that
/// would play next, which is the one playing when the motor is running.
function blockIcon(block, status) {
  if (block.index === status.block && !status.atEnd) {
    // Playing and paused share one colour deliberately: both mean "this is
    // where the tape is", and only the glyph says which of the two it is.
    return new vscode.ThemeIcon(
      status.playing ? 'play' : 'debug-pause',
      new vscode.ThemeColor('charts.blue')
    );
  }
  if (block.index < status.block) {
    return new vscode.ThemeIcon('pass-filled', new vscode.ThemeColor('descriptionForeground'));
  }
  if (block.stopTape) {
    return new vscode.ThemeIcon('debug-stop');
  }
  if (!block.standardSpeed) {
    // Not an error -- it loads, just at real tape speed. The icon is there to
    // answer "why is this one taking 90 seconds" before it is asked.
    return new vscode.ThemeIcon('watch');
  }
  return new vscode.ThemeIcon('circle-outline');
}

function blockTooltip(block) {
  const title = block.name ? `${block.kind}: ${block.name}` : block.kind;
  const lines = [`**${title}**`];
  lines.push(`Block ${block.index} · ${describeBlockId(block.id)}`);
  if (block.dataBytes > 0) {
    lines.push(`${block.dataBytes} bytes`);
  }
  lines.push(`${formatDuration(block.durationMs)} to play`);
  lines.push(block.standardSpeed ? 'Standard speed' : 'Non-standard speed, so no fast load');
  if (block.pauseMs > 0) {
    lines.push(`${block.pauseMs}ms pause`);
  }
  if (block.stopTape) {
    lines.push('Stops the tape');
  }
  lines.push("_Use the row's seek button to start the tape from here_");
  return new vscode.MarkdownString(lines.join('\n\n'));
}

function describeBlockId(id) {
  return `0x${id.toString(16).toUpperCase().padStart(2, '0')}`;
}

function formatDuration(ms) {
  const total = Math.round(ms / 1000);
  if (total < 60) {
    // Sub-minute blocks are where the interesting variety is (a header is
    // ~2s, a screen ~30s), so they keep their tenths.
    return `${(ms / 1000).toFixed(1)}s`;
  }
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

/// Puts a fresh status into the pane. Takes the status rather than fetching
/// one, because every route to here already has a response in hand -- a poll,
/// a transport command, or a load.
function refreshTape(status) {
  const before = tapeSignature(tapeStatus);
  tapeStatus = status;
  const after = tapeSignature(status);
  if (tapeView) {
    // The message carries the position, which moves on every tick -- so it is
    // always rewritten, while the rows below it are not.
    tapeView.message = tapeMessage(status);
  }
  // Only when a row would actually come out different. This runs four times a
  // second, and redrawing the tree that often would fight the user for the
  // selection and the scroll position to say nothing new.
  if (tapeProvider && before !== after) {
    tapeProvider.refresh();
  }
  publishUiContext();
}

/// The keys the title bars' buttons are drawn from: whether there is a session
/// to talk to at all, which greys the lot (package.json's `enablement`), and
/// which way round the play/pause, fast-load and write-overlay pairs go.
///
/// Called on every debug session event as well as from refreshTape, because
/// the session can go away without a status arriving to say so.
function publishUiContext() {
  setUiContext('zxspectrum.tapeSession', zxDebugSession() !== undefined);
  setUiContext('zxspectrum.writeOverlay', writeOverlayOn);
  setUiContext('zxspectrum.rasterMarker', rasterView.marker);
  setUiContext('zxspectrum.rasterInProgress', rasterView.inProgress);
  setUiContext('zxspectrum.rasterPending', rasterView.pending);
  setUiContext(
    'zxspectrum.tapeFastLoad',
    tapeStatus ? tapeStatus.fastLoad === true : true
  );
  // Play and Stop share one slot in the title bar and swap according to this,
  // the way the debug toolbar's Continue and Pause do -- a transport has one
  // button there, not two, and which one it is IS the state.
  setUiContext('zxspectrum.tapePlaying', tapeStatus ? tapeStatus.playing === true : false);
}

/// Pushes a when-clause context key, but only when it has actually changed.
/// The tape poll runs four times a second and every one of these is a round
/// trip into the workbench.
function setUiContext(key, value) {
  if (uiContextKeys.get(key) !== value) {
    uiContextKeys.set(key, value);
    vscode.commands.executeCommand('setContext', key, value);
  }
}

/// Everything the ROWS are drawn from, and nothing else -- the position is
/// deliberately left out, since it changes constantly and shows in the message
/// rather than in the list.
function tapeSignature(status) {
  if (!status || !status.inserted) {
    return 'empty';
  }
  const blocks = (status.blockList || [])
    .map((b) => `${b.index}:${b.kind}:${b.name}:${b.standardSpeed}:${b.stopTape}`)
    .join('|');
  return `${status.name}/${status.block}/${status.playing}/${status.atEnd}/${blocks}`;
}

/// The line above the list: which tape, where it is, and anything the parser
/// had to say about the image.
function tapeMessage(status) {
  if (!status || !status.inserted) {
    // No session, or an empty deck -- the view's welcome content says the
    // rest, and a message on top of it would only repeat it.
    return undefined;
  }
  const title = status.description || path.basename(status.name) || 'tape';
  // Numbered as the rows are, from 0 -- which is also the index `seek` takes
  // and the one MCP's block_list reports. One numbering, everywhere.
  const at = status.atEnd ? 'at the end' : `block ${status.block} of ${status.blocks}`;
  const position = `${formatDuration(status.positionMs)} / ${formatDuration(status.totalMs)}`;
  const state = status.playing ? 'playing' : 'stopped';
  let message = `${title} · ${at} · ${position} · ${state}`;
  if (!status.fastLoad) {
    message += ' · real speed';
  }
  if (status.warnings && status.warnings.length > 0) {
    message += `\n${status.warnings.join('\n')}`;
  }
  return message;
}

/// Turns the display-write overlay on or off. The emulator dims the picture
/// and shows every byte written to the screen bitmap at full brightness -- all
/// eight of its pixels -- on the frame it was written, so the panel shows what
/// the program is DRAWING rather than only what it ended up with.
///
/// The state lives in the emulator, not here -- the overlay is per machine and
/// survives the panel being closed -- so the button reflects what the last
/// reply said rather than what this extension last asked for. The two percents
/// are left alone when undefined, so the button does not undo a setting made
/// from the palette (or by an MCP client sharing the machine).
async function setWriteOverlay(enabled, options) {
  const session = zxDebugSession();
  if (!session) {
    vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    return;
  }
  const request = Object.assign({ enabled }, options);
  try {
    const body = await session.customRequest('setWriteOverlay', request);
    writeOverlayOn = body ? body.enabled === true : enabled;
  } catch (err) {
    const detail = (err && (err.message || err.toString())) || String(err);
    console.error('zxspectrum setWriteOverlay failed', request, err);
    vscode.window.showErrorMessage(`Write overlay: ${detail}`);
  }
  setUiContext('zxspectrum.writeOverlay', writeOverlayOn);
}

/// How long a drawn byte lingers. A quick pick rather than a setting: it is
/// something to try both ways while watching a game, not something to decide
/// once -- how much of a redraw is a moving sprite and how much is scenery
/// being laid down again reads completely differently at 100% and at 10%.
///
/// Picking one also turns the overlay on, since choosing how it looks and then
/// having to switch it on separately is a step nobody wants.
async function pickWriteOverlayFade() {
  const choice = await vscode.window.showQuickPick(
    [
      { label: 'This frame only', description: 'fade 100% -- clears every frame', fade: 100 },
      { label: 'Short trail', description: 'fade 25% -- about a fifth of a second', fade: 25 },
      { label: 'Long trail', description: 'fade 10% -- about a second', fade: 10 },
      { label: 'Never fade', description: 'fade 0% -- everything drawn since', fade: 0 },
    ],
    { title: 'ZX Spectrum: how long display writes stay lit' }
  );
  if (choice) {
    await setWriteOverlay(true, { fadePercent: choice.fade });
  }
}

/// How a stopped machine's screen is drawn: the beam marked, the picture
/// composed as far as the beam has drawn it, and the writes it has not reached
/// yet tinted. `fields` carries only what is changing; the emulator leaves the
/// rest alone and answers with all three, which is what the palette's
/// on/off pairs are drawn from.
async function setRasterView(fields) {
  const session = zxDebugSession();
  if (!session) {
    vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    return;
  }
  try {
    const body = await session.customRequest('setRasterView', fields);
    if (body) {
      rasterView = {
        marker: body.marker === true,
        inProgress: body.inProgress === true,
        pending: body.pending === true,
      };
    } else {
      rasterView = Object.assign({}, rasterView, fields);
    }
  } catch (err) {
    const detail = (err && (err.message || err.toString())) || String(err);
    console.error('zxspectrum setRasterView failed', fields, err);
    vscode.window.showErrorMessage(`Raster view: ${detail}`);
  }
  publishUiContext();
}

/// How far a written byte is lifted out of the dimmed picture. Full
/// brightness is the clearest answer to "what did this frame draw"; a
/// smaller lift keeps busy areas from dominating the picture.
async function pickWriteOverlayOpacity() {
  const choice = await vscode.window.showQuickPick(
    [
      { label: 'Full', description: '100% -- written bytes at full brightness', opacity: 100 },
      { label: 'Strong', description: '75% of the way from dimmed to full', opacity: 75 },
      { label: 'Half', description: '50% of the way from dimmed to full', opacity: 50 },
      { label: 'Faint', description: '25% of the way from dimmed to full', opacity: 25 },
    ],
    { title: 'ZX Spectrum: how brightly display writes are lit' }
  );
  if (choice) {
    await setWriteOverlay(true, { opacityPercent: choice.opacity });
  }
}

/// One transport command, and the pane redrawn from the reply it comes back
/// with. Shares loadTape's error handling: the adapter's own `message` is the
/// useful part, and anything else is a bug worth seeing in full.
async function tapeControl(options) {
  const session = zxDebugSession();
  if (!session) {
    vscode.window.showErrorMessage('Start a ZX Spectrum debug session first.');
    return;
  }
  try {
    refreshTape(await session.customRequest('tapeControl', options));
  } catch (err) {
    const detail = (err && (err.message || err.toString())) || String(err);
    console.error('zxspectrum tapeControl failed', options, err);
    vscode.window.showErrorMessage(`Tape: ${detail}`);
  }
}

function startTapePolling() {
  stopTapePolling();
  if (!tapeView || !tapeView.visible || !zxDebugSession()) {
    return;
  }
  tapePoll = setInterval(async () => {
    const session = zxDebugSession();
    if (!session || !tapeView || !tapeView.visible) {
      stopTapePolling();
      return;
    }
    try {
      refreshTape(await session.customRequest('tapeControl', { action: 'status' }));
    } catch (err) {
      // The session went away mid-request, or it is a server too old to know
      // the request. Either way there is nothing left to show, and nothing
      // worth saying about it once per tick.
      stopTapePolling();
      refreshTape(undefined);
    }
  }, TAPE_POLL_MS);
}

function stopTapePolling() {
  if (tapePoll) {
    clearInterval(tapePoll);
    tapePoll = undefined;
  }
}

// ---- trace viewer ----------------------------------------------------------
//
// A trace is a file the server writes, so the extension host reads it and
// posts the text into the webview. The page itself is tools/trace_viewer.html,
// the same file that opens standalone in a browser -- it is not duplicated
// here, only wrapped in a CSP the webview will accept.
//
// The panel's Record button goes the other way: startTrace/stopTrace/
// traceStatus custom requests on the active debug session (server-side:
// dap.cpp), so a capture is taken of the machine that session is running
// rather than having to be arranged beforehand on the command line. Those
// three bypass the emulator's command queue, which is what makes recording a
// running game -- rather than only a stopped one -- possible at all.

function traceViewerPath(context) {
  // Three places, in order of how deliberate they are:
  //   1. bundled beside extension.js, which is what a packaged .vsix or the
  //      "copy into ~/.vscode/extensions" install should carry;
  //   2. ../tools/, which is where it lives when the extension is symlinked
  //      or loaded straight out of the repo;
  //   3. any open workspace folder, which covers a copy-installed extension
  //      being used on the repo it came from.
  const candidates = [
    path.join(context.extensionPath, 'trace_viewer.html'),
    path.join(context.extensionPath, '..', 'tools', 'trace_viewer.html')
  ];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    candidates.push(path.join(folder.uri.fsPath, 'tools', 'trace_viewer.html'));
  }
  return candidates.find((candidate) => fs.existsSync(candidate)) || candidates[0];
}

async function pickTraceFile() {
  const chosen = await vscode.window.showOpenDialog({
    canSelectMany: false,
    openLabel: 'Open trace',
    filters: { 'ZX Spectrum trace': ['zxtrace', 'txt', 'log'], 'All files': ['*'] },
    defaultUri: vscode.workspace.workspaceFolders
      ? vscode.workspace.workspaceFolders[0].uri
      : undefined
  });
  return chosen && chosen.length > 0 ? chosen[0].fsPath : undefined;
}

async function showTracePanel(context) {
  const viewer = traceViewerPath(context);
  if (!fs.existsSync(viewer)) {
    vscode.window.showErrorMessage(
      'Trace viewer not found at ' + viewer + '. It lives at tools/trace_viewer.html in the ' +
      'zx-spectrum-emulator repo; the extension expects to be loaded from alongside it.'
    );
    return;
  }

  if (!tracePanel) {
    tracePanel = vscode.window.createWebviewPanel(
      'zxspectrumTrace',
      'ZX Spectrum Trace',
      vscode.ViewColumn.Active,
      { enableScripts: true, retainContextWhenHidden: true }
    );
    tracePanel.webview.html = webviewHtml(viewer);
    tracePanel.onDidDispose(
      () => {
        tracePanel = undefined;
        stopWatchingTrace();
        // A capture left running is deliberate: the panel is not the only way
        // to read one, and a trace stopped by closing a window would be a
        // surprising way to lose the thing being chased. Only the polling,
        // which has nowhere to report to now, goes.
        stopTracePolling();
      },
      null,
      context.subscriptions
    );
    tracePanel.webview.onDidReceiveMessage(
      (message) => handleTraceMessage(message),
      null,
      context.subscriptions
    );
  } else {
    tracePanel.reveal(vscode.ViewColumn.Active);
  }
  // No file prompt on open. The panel is now somewhere you go to MAKE a
  // capture as well as to read one, and a modal dialog in the way of the
  // Record button would be exactly wrong for that.
  publishLiveState();
}

async function handleTraceMessage(message) {
  if (!message) return;
  if (message.type === 'ready') {
    publishLiveState();
  } else if (message.type === 'pick') {
    // The page asks for a file when its "Open trace..." button is used, since
    // a webview has no way to reach the workspace itself.
    const file = await pickTraceFile();
    if (file) loadTrace(file);
  } else if (message.type === 'startTrace') {
    await startLiveTrace(message);
  } else if (message.type === 'stopTrace') {
    await stopLiveTrace();
  } else if (message.type === 'symbols') {
    await sendSymbolMatches(message);
  }
}

function loadTrace(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    vscode.window.showErrorMessage('Could not read ' + file + ': ' + err.message);
    return;
  }
  traceFile = file;
  if (tracePanel) {
    tracePanel.title = 'Trace: ' + path.basename(file);
    tracePanel.webview.postMessage({ type: 'trace', name: path.basename(file), text });
  }
  watchTrace(file);
}

// A trace is usually captured more than once while chasing something down, and
// each capture rewrites the same file -- so reload rather than making the panel
// be reopened every time.
function watchTrace(file) {
  stopWatchingTrace();
  traceWatcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(path.dirname(file), path.basename(file))
  );
  const reload = () => {
    if (tracePanel && traceFile === file) loadTrace(file);
  };
  traceWatcher.onDidChange(reload);
  traceWatcher.onDidCreate(reload);
}

function stopWatchingTrace() {
  if (traceWatcher) {
    traceWatcher.dispose();
    traceWatcher = undefined;
  }
}

// ---- live capture ----------------------------------------------------------

// The session a capture can be taken from, or undefined if there isn't one.
function zxDebugSession() {
  const session = vscode.debug.activeDebugSession;
  return session && session.type === 'zxspectrum' ? session : undefined;
}

// Where the Record button writes: the first workspace folder, so the capture
// lands somewhere the user can find, keep and reopen -- and where the server's
// own relative --trace-log paths go too. A temp directory only if there is no
// folder open at all.
function liveTracePath() {
  const folders = vscode.workspace.workspaceFolders;
  const dir = folders && folders.length > 0 ? folders[0].uri.fsPath : os.tmpdir();
  return path.join(dir, LIVE_TRACE_NAME);
}

function postTrace(message) {
  if (tracePanel) tracePanel.webview.postMessage(message);
}

// Tells the panel whether there is anything to record from. Sent on open and
// on every session change, so the button follows the session rather than
// waiting to be clicked to find out.
function publishLiveState() {
  postTrace({ type: 'live', available: zxDebugSession() !== undefined });
}

// Whatever the far end refused with. A failed custom request is not always an
// Error -- a DAP failure response arrives as a bare message -- so this is
// wanted at all three call sites below.
function errorText(err) {
  return err && err.message ? err.message : String(err);
}

// What the panel's address fields offer as they are typed into. The symbol
// table lives in the server (the ROM disassembly's thousand-odd labels, plus
// whatever the loaded program's own debug info adds), so this is a round trip
// per keystroke -- a cheap one: matchSymbols reads a parsed file and never
// touches the machine, so it answers mid-game as readily as at a breakpoint.
async function sendSymbolMatches(message) {
  const session = zxDebugSession();
  let body;
  if (session) {
    try {
      body = await session.customRequest('matchSymbols', { prefix: message.prefix || '' });
    } catch (err) {
      // An older server with no such request. Completion is a convenience:
      // a field that quietly offers nothing is a better answer than an error
      // nobody asked for, and typing the name out still works.
      body = undefined;
    }
  }
  postTrace({
    type: 'symbolMatches',
    // Echoed back so the page can drop an answer to a prefix it has already
    // typed past -- these are issued per keystroke and can land out of order.
    token: message.token,
    symbols: body && body.symbols ? body.symbols : [],
    more: body ? body.more === true : false
  });
}

// Closes a capture that has just been started and should not have been. Used
// where the capture itself is fine but is not the one that was asked for.
async function cancelLiveTrace(session) {
  try {
    await session.customRequest('stopTrace');
  } catch (ignored) {
    // The session is going away; there is nothing left to close it with.
  }
}

// DAP ignores request arguments it does not recognise, so a gate this panel
// asks for and the far end has never heard of is dropped in silence -- and a
// capture that quietly begins in the wrong place looks like a broken gate
// rather than a stale link. The status echoes the gates actually installed
// (from the capture's own options, not from whether they have fired yet), so
// asking for one and not seeing it come back is exactly that mismatch.
function droppedGates(request, status) {
  const dropped = [];
  if (request.pc && typeof status.startPc !== 'number') {
    dropped.push('start address');
  }
  if (typeof request.tstate === 'number' && typeof status.startTstate !== 'number') {
    dropped.push('start T-state');
  }
  return dropped;
}

async function startLiveTrace(options) {
  const session = zxDebugSession();
  if (!session) {
    publishLiveState(); // the session went away between the click and here
    return;
  }
  const file = liveTracePath();
  const request = {
    path: file,
    extra: options.extra === true,
    ula: options.ula === true
  };
  // Left out rather than sent as null: the server has its own defaults for
  // all of them, and "not specified" is not the same as a value.
  if (typeof options.limit === 'number') request.limit = options.limit;
  // Addresses travel as the strings they were typed as, blanks dropped. The
  // server resolves a symbol expression as readily as a number and says which
  // it could not, so nothing here needs to know what a symbol looks like.
  if (options.watch) request.watch = options.watch;
  if (options.pc) request.pc = options.pc;
  // The other start gate, and a plain number rather than an address: a point
  // in the video frame, which no symbol names.
  if (typeof options.tstate === 'number') request.tstate = options.tstate;

  // The file is about to be rewritten from underneath any watcher on it, a
  // block at a time -- reloading the panel from a half-written capture would
  // show nothing but parse errors until it finished.
  stopWatchingTrace();
  let status;
  try {
    status = await session.customRequest('startTrace', request);
  } catch (err) {
    // Most likely an older server, or the Python one, neither of which has a
    // startTrace request. Worth saying out loud: unlike a dropped keypress,
    // the user pressed a button and is waiting for something to happen.
    postTrace({
      type: 'traceStatus',
      state: 'error',
      message: 'could not start: ' + errorText(err)
    });
    return;
  }
  const dropped = droppedGates(request, status);
  if (dropped.length > 0) {
    await cancelLiveTrace(session);
    postTrace({
      type: 'traceStatus',
      state: 'error',
      message: dropped.join(' and ') + ' was ignored by the debug session -- '
               + 'reload the window (and restart the session) to pick up the current build'
    });
    return;
  }
  postTrace({ type: 'traceStatus', state: 'recording', status });

  // Where to stop is armed as a second request, which is what stopTrace's own
  // `pc` is for -- with an address it aims the capture rather than closing it.
  // startTrace has already answered by now, and that answer means the capture
  // is installed, so this lands on it rather than on nothing.
  if (options.stopPc) {
    try {
      status = await session.customRequest('stopTrace', { pc: options.stopPc });
    } catch (err) {
      // A capture that would never stop where it was asked to is worse than no
      // capture: it has recorded microseconds so far, and the address wants
      // retyping anyway, so close it and say why rather than leave a
      // half-armed one running.
      await cancelLiveTrace(session);
      postTrace({
        type: 'traceStatus',
        state: 'error',
        message: 'could not stop at ' + options.stopPc + ': ' + errorText(err)
      });
      return;
    }
    // Same silence, one request later: a stop address the far end dropped
    // would leave a capture running to its limit instead of to the address.
    if (typeof status.stopPc !== 'number') {
      await cancelLiveTrace(session);
      postTrace({
        type: 'traceStatus',
        state: 'error',
        message: 'stop address was ignored by the debug session -- reload the window '
                 + '(and restart the session) to pick up the current build'
      });
      return;
    }
    postTrace({ type: 'traceStatus', state: 'recording', status });
  }
  startTracePolling();
}

async function stopLiveTrace() {
  stopTracePolling();
  const session = zxDebugSession();
  if (!session) {
    publishLiveState();
    return;
  }
  let status;
  try {
    status = await session.customRequest('stopTrace');
  } catch (err) {
    postTrace({
      type: 'traceStatus',
      state: 'error',
      message: 'could not stop: ' + errorText(err)
    });
    return;
  }
  finishLiveTrace(status);
}

// Shared ending for a capture, however it stopped: the Stop button, or the
// capture reaching its own row limit and closing itself.
function finishLiveTrace(status) {
  postTrace({ type: 'traceStatus', state: 'stopped', status });
  if (status && status.rows > 0 && status.path) {
    // The file is complete by the time the server reports the capture closed,
    // so this is the natural moment to show it -- the point of recording from
    // the panel is not to have to go and open the result by hand.
    loadTrace(status.path);
  }
}

// Keeps the panel's row counter moving, and notices a capture that reached its
// limit and closed itself -- which is how most of them end.
function startTracePolling() {
  stopTracePolling();
  tracePoll = setInterval(async () => {
    const session = zxDebugSession();
    if (!session || !tracePanel) {
      stopTracePolling();
      publishLiveState();
      return;
    }
    let status;
    try {
      status = await session.customRequest('traceStatus');
    } catch (err) {
      // The session is going away mid-capture; there is nothing left to ask.
      stopTracePolling();
      publishLiveState();
      return;
    }
    if (status.active) {
      postTrace({ type: 'traceStatus', state: 'recording', status });
      return;
    }
    stopTracePolling();
    finishLiveTrace(status);
  }, TRACE_POLL_MS);
}

function stopTracePolling() {
  if (tracePoll) {
    clearInterval(tracePoll);
    tracePoll = undefined;
  }
}

// ---- driving the panel from MCP --------------------------------------------
//
// MCP and DAP are separate front-ends onto one Engine with no channel between
// them, so "point the graphics panel at sprite_017" travels the long way
// round: the MCP tool sets a GraphicsView on the Engine (engine.h), the DAP
// server turns that into an unsolicited `zxGraphicsView` event (dap.cpp), and
// this picks it up. VS Code surfaces unknown DAP events to extensions exactly
// so this is possible.
//
// One-way by design. The panel's own controls are not written back, so the
// server holds what was last ASKED for rather than what is on screen.

// The server's field names are its own; two of them the webview spells
// differently. Mapping here rather than at either end keeps each side's
// vocabulary its own business.
const GRAPHICS_FIELD_NAMES = { invert_mask: 'invertMask', flip: 'bottomUp' };

function graphicsViewMessage(view, quiet) {
  const mapped = {};
  for (const key of Object.keys(view)) {
    mapped[GRAPHICS_FIELD_NAMES[key] || key] = view[key];
  }
  return {
    type: 'view',
    view: mapped,
    // An action rather than a setting: "add this to the sheet" instead of
    // "replace what is being dialled in".
    pin: view.pin === true,
    // A view caught up on rather than just asked for (see catchUpGraphicsView).
    quiet: quiet === true,
    // The page shows a name, not a path; the host is the side that has one.
    fileName: view.file ? path.basename(view.file) : undefined,
  };
}

function applyGraphicsView(context, view, quiet) {
  if (!view || typeof view.version !== 'number' || view.version <= graphicsAppliedVersion) {
    return;
  }
  graphicsAppliedVersion = view.version;
  if (view.source === 'file' && view.file) {
    graphicsFile = view.file;
  }
  const fresh = !graphicsPanel;
  showGraphicsPanel(context);
  postOrQueueGraphics(graphicsViewMessage(view, quiet), fresh);
}

// Asks the server where the panel is meant to be pointed. Used when the panel
// opens, and when a session appears -- a view can be set over MCP before there
// is any VS Code to hear about it, and the tool says so, which is only true if
// somebody eventually asks.
//
// `mayOpen` is false when the panel is the one asking: it exists already.
async function catchUpGraphicsView(mayOpen) {
  const session = zxDebugSession();
  if (!session || (!mayOpen && !graphicsPanel)) {
    return;
  }
  let body;
  try {
    body = await session.customRequest('graphicsView', {});
  } catch (err) {
    // An older server with no such request. Nothing to catch up on.
    return;
  }
  // Version 0 means nothing has ever been asked for, and the panel keeps its
  // own last state rather than being dragged to the server's defaults.
  // Applied quietly: the page takes it as where Add... starts, and neither
  // adds it nor opens the dialog on it. A catch-up happens on every session
  // start and panel open, long after the call it replays -- acting on a `pin`
  // again then would put the same sprite on a remembered sheet each time.
  if (body && body.version > 0 && (mayOpen || graphicsPanel)) {
    applyGraphicsView(graphicsContext, body, true);
  }
}

// ---- graphics viewer -------------------------------------------------------
//
// Points at bytes and draws them as the Spectrum would: a sprite sheet, a
// character set, or a screen dump. The bytes come from one of three places --
// the running machine's memory (DAP readMemory), a file, or whatever is
// selected in an editor -- because a sprite is usually all three things over
// its life: a table in an .s file, a blob the build emits, and finally
// something at an address that a blitter is getting wrong.
//
// The page is graphics_view.html, beside this file rather than in tools/ like
// the trace viewer. That one is standalone-useful in a browser; this one is
// not, since every byte it draws arrives from the extension host -- so it goes
// where the extension's own install already carries it, and needs no separate
// copy step.

function showGraphicsPanel(context) {
  if (graphicsPanel) {
    graphicsPanel.reveal(vscode.ViewColumn.Active);
    return graphicsPanel;
  }
  graphicsPanel = vscode.window.createWebviewPanel(
    'zxspectrumGraphics',
    'ZX Spectrum Graphics',
    vscode.ViewColumn.Active,
    { enableScripts: true, retainContextWhenHidden: true }
  );
  graphicsPanel.webview.html = graphicsPageHtml();
  graphicsPanel.onDidDispose(
    () => {
      graphicsPanel = undefined;
      stopGraphicsPolling();
    },
    null,
    context.subscriptions
  );
  graphicsPanel.webview.onDidReceiveMessage(
    (message) => handleGraphicsMessage(message),
    null,
    context.subscriptions
  );
  return graphicsPanel;
}

// The page with graphics_model.js inlined where it has its marker -- the same
// source the tests run, so the decoding and the export are tested in Node and
// used unchanged in the webview. A function replacement, because the model's
// source is full of '$' and a replacement string would read "$'" as a pattern.
//
// The sheet the page last saved goes in the same way, as `window.__zxSheet`:
// a webview's own state is dropped when its panel closes, so the extension
// keeps a copy in the workspace (GRAPHICS_SHEET_KEY) and a reopened panel
// starts from it. `<` is escaped so no sprite name can close the script.
const GRAPHICS_SHEET_KEY = 'zxspectrum.graphicsSheet';

function graphicsPageHtml() {
  const model = fs.readFileSync(path.join(__dirname, 'graphics_model.js'), 'utf8');
  const sheet = graphicsContext ? graphicsContext.workspaceState.get(GRAPHICS_SHEET_KEY) : undefined;
  const sheetJs = 'window.__zxSheet = ' +
    JSON.stringify(sheet && typeof sheet === 'object' ? sheet : null).replace(/</g, '\\u003c') + ';';
  return webviewHtml(path.join(__dirname, 'graphics_view.html'))
    .replace('/*@graphics_model.js@*/', () => model)
    .replace('/*@graphics_sheet@*/', () => sheetJs);
}

// The editor context-menu entry. Takes the selection here rather than letting
// the panel ask for it, because opening the panel is itself what takes focus
// away from the editor the selection is in.
function showSelectionAsGraphics(context) {
  const editor = vscode.window.activeTextEditor;
  if (editor && !editor.selection.isEmpty) {
    lastSelection = { document: editor.document, range: editor.selection };
  }
  if (!lastSelection) {
    vscode.window.showErrorMessage('Select some DEFB data first.');
    return;
  }
  const fresh = !graphicsPanel;
  showGraphicsPanel(context);
  postOrQueueGraphics({ type: 'useSelection' }, fresh);
}

function postGraphics(message) {
  if (graphicsPanel) {
    graphicsPanel.webview.postMessage(message);
  }
}

// A webview drops anything posted before its script has run, and every way of
// driving the panel from outside -- the context-menu command, an MCP-set view
// -- opens it and then immediately has something to say to it.
function postOrQueueGraphics(message, queue) {
  if (queue) {
    graphicsPending.push(message);
  } else {
    postGraphics(message);
  }
}

function postGraphicsError(text) {
  postGraphics({ type: 'error', text });
}

function stopGraphicsPolling() {
  if (graphicsPoll) {
    clearInterval(graphicsPoll);
    graphicsPoll = undefined;
  }
}

function setGraphicsLive(on) {
  stopGraphicsPolling();
  if (on) {
    graphicsPoll = setInterval(() => postGraphics({ type: 'refresh' }), GRAPHICS_POLL_MS);
  }
}

async function handleGraphicsMessage(message) {
  if (!message) return;
  if (message.type === 'ready') {
    for (const queued of graphicsPending) {
      postGraphics(queued);
    }
    graphicsPending = [];
    // A panel opening for the first time catches up on whatever was asked for
    // before it existed -- including the MCP call that opened it.
    await catchUpGraphicsView(false);
  } else if (message.type === 'read') {
    await sendGraphicsData(message);
  } else if (message.type === 'pickFile') {
    await pickGraphicsFile();
  } else if (message.type === 'symbols') {
    await sendGraphicsSymbols(message);
  } else if (message.type === 'live') {
    setGraphicsLive(message.on === true);
  } else if (message.type === 'export') {
    await exportGraphics(message);
  } else if (message.type === 'import') {
    await importGraphics();
  } else if (message.type === 'clear') {
    await clearGraphicsSheet(message);
  } else if (message.type === 'saveSheet') {
    if (graphicsContext && message.state && typeof message.state === 'object') {
      await graphicsContext.workspaceState.update(GRAPHICS_SHEET_KEY, message.state);
    }
  }
}

// Clearing the sheet is asked about rather than undone: a sprite read from
// memory or a file can be added again from where it came from, but one that
// carries its own bytes -- grabbed from a selection, or imported from an
// atlas -- has nowhere to be read back from once it is gone.
async function clearGraphicsSheet(message) {
  const count = Math.max(0, Number(message && message.count) || 0);
  const choice = await vscode.window.showWarningMessage(
    'Clear the graphics sheet?',
    {
      modal: true,
      detail: 'Takes ' + count + ' sprite' + (count === 1 ? '' : 's')
            + ' and every group off it. Sprites that carry their own bytes, from a '
            + 'selection or an imported atlas, cannot be read back afterwards.',
    },
    'Clear',
  );
  if (choice === 'Clear') {
    postGraphics({ type: 'cleared' });
  }
}

// ---- export and import ------------------------------------------------------
//
// The page makes the files (see graphics_model.js); this asks where they go,
// writes them, and does the parts that need the machine or the disk. The save
// dialog names the atlas, and the picture and the source go beside it under
// the same name -- a set of files that only works together is easier to keep
// together if it cannot be named apart.

let graphicsExportDir;  // where the last export went, so the next starts there

function workspaceDir() {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length ? folders[0].uri.fsPath : os.homedir();
}

// A path in the atlas is kept relative to the atlas when that works, so a
// sheet exported inside a repo still finds its files from another clone.
function pathForAtlas(file, atlasDir) {
  const relative = path.relative(atlasDir, file);
  if (!relative || path.isAbsolute(relative)) {
    return file;
  }
  return relative.split(path.sep).join('/');
}

function fileSizeOrNull(file) {
  try {
    return fs.statSync(file).size;
  } catch (err) {
    return null;
  }
}

async function exportGraphics(message) {
  const dir = graphicsExportDir || workspaceDir();
  const suggested = message.name || 'sprites';
  const chosen = await vscode.window.showSaveDialog({
    defaultUri: vscode.Uri.file(path.join(dir, suggested + '.json')),
    saveLabel: 'Export',
    filters: { 'Sprite atlas': ['json'] },
  });
  if (!chosen) {
    return;
  }
  const atlasPath = /\.json$/i.test(chosen.fsPath) ? chosen.fsPath : chosen.fsPath + '.json';
  const stem = atlasPath.replace(/\.json$/i, '');
  const pngPath = stem + '.png';
  const snaPath = stem + '.sna';
  const asmPath = stem + '.s';
  const atlasDir = path.dirname(atlasPath);
  graphicsExportDir = atlasDir;

  const atlas = message.atlas || {};
  const meta = atlas.meta || {};
  const sprites = (meta.zx && meta.zx.sprites) || [];
  if (message.png) {
    meta.image = path.basename(pngPath);
  }
  const written = [atlasPath];
  try {
    if (message.png) {
      fs.writeFileSync(pngPath, Buffer.from(message.png, 'base64'));
      written.unshift(pngPath);
    }
    if (message.reference) {
      // Sprites read from memory point into the machine as it is now, saved
      // beside the atlas -- only when there are any, and only then does the
      // export need a session.
      let machine = null;
      if (sprites.some((sprite) => sprite.source === 'memory' && typeof sprite.bytes !== 'string')) {
        const session = zxDebugSession();
        if (!session) {
          postGraphicsError('Pointing sprites from memory into a snapshot needs the debug ' +
                            'session they were read from -- start one, or export their bytes instead.');
          return;
        }
        const saved = await session.customRequest('saveSnapshot', { path: snaPath });
        machine = { file: path.basename(snaPath), size: (saved && saved.bytes) || fileSizeOrNull(snaPath) };
        written.push(snaPath);
      }
      const lost = graphicsModel.addSnapshotPointers(sprites, machine, fileSizeOrNull);
      if (lost.length) {
        postGraphicsError('Could not point these into a snapshot: ' + lost.join(', '));
        return;
      }
    }
    for (const sprite of sprites) {
      if (typeof sprite.file === 'string' && sprite.file) {
        sprite.file = pathForAtlas(sprite.file, atlasDir);
      }
      if (sprite.snapshot && typeof sprite.snapshot.file === 'string') {
        sprite.snapshot.file = pathForAtlas(path.resolve(atlasDir, sprite.snapshot.file), atlasDir);
      }
    }
    fs.writeFileSync(atlasPath, JSON.stringify(atlas, null, 2) + '\n');
    if (typeof message.asm === 'string') {
      // The source was written naming the suggested files; name the real ones.
      const asm = message.asm
        .replace(suggested + '.png', path.basename(pngPath))
        .replace(suggested + '.json', path.basename(atlasPath));
      fs.writeFileSync(asmPath, asm);
      written.push(asmPath);
    }
  } catch (err) {
    postGraphicsError('Could not export: ' + errorText(err));
    return;
  }
  postGraphics({
    type: 'exported',
    files: written,
    frames: message.frames,
    skipped: message.skipped || [],
  });
}

// Paths in an atlas are relative to it, and a sprite that only points at its
// bytes gets them read here, where the disk is -- the panel is shown them as
// if the atlas had carried them. One whose file has gone arrives without, and
// the panel reads it the usual way (or says why it cannot).
async function importGraphics() {
  const chosen = await vscode.window.showOpenDialog({
    canSelectMany: false,
    openLabel: 'Import',
    filters: { 'Sprite atlas': ['json'], 'All files': ['*'] },
    defaultUri: vscode.Uri.file(graphicsExportDir || workspaceDir()),
  });
  if (!chosen || chosen.length === 0) {
    return;
  }
  const atlasPath = chosen[0].fsPath;
  const atlasDir = path.dirname(atlasPath);
  let atlas;
  try {
    atlas = JSON.parse(fs.readFileSync(atlasPath, 'utf8'));
  } catch (err) {
    postGraphicsError('Could not read ' + path.basename(atlasPath) + ': ' + errorText(err));
    return;
  }
  const sprites = (atlas && atlas.meta && atlas.meta.zx && atlas.meta.zx.sprites) || [];
  const unreadable = [];
  for (const sprite of Array.isArray(sprites) ? sprites : []) {
    if (!sprite || typeof sprite !== 'object') {
      continue;
    }
    if (typeof sprite.file === 'string' && sprite.file) {
      sprite.file = path.resolve(atlasDir, sprite.file);
    }
    if (sprite.snapshot && typeof sprite.snapshot.file === 'string') {
      sprite.snapshot.file = path.resolve(atlasDir, sprite.snapshot.file);
    }
    if (typeof sprite.bytes !== 'string') {
      try {
        const bytes = graphicsModel.pointedBytes(sprite, (file) => fs.readFileSync(file));
        if (bytes) {
          sprite.bytes = Buffer.from(bytes).toString('base64');
        }
      } catch (err) {
        unreadable.push((sprite.name || '?') + ' (' + errorText(err) + ')');
      }
    }
  }
  postGraphics({ type: 'imported', atlas, path: atlasPath });
  if (unreadable.length) {
    postGraphicsError('Could not read the bytes for ' + unreadable.join(', '));
  }
}

async function pickGraphicsFile() {
  const chosen = await vscode.window.showOpenDialog({
    canSelectMany: false,
    openLabel: 'Show graphics',
    filters: {
      'Spectrum graphics': ['scr', 'bin', 'sna', 'z80', 'dat', 'raw'],
      'All files': ['*'],
    },
    defaultUri: vscode.workspace.workspaceFolders
      ? vscode.workspace.workspaceFolders[0].uri
      : undefined,
  });
  if (chosen && chosen.length > 0) {
    graphicsFile = chosen[0].fsPath;
    postGraphics({
      type: 'file',
      name: path.basename(graphicsFile),
      path: graphicsFile,
    });
  }
}

// "16384", "$4000", "0x4000", "4000h" -- and, since the whole point of having
// symbols on the server is not having to look addresses up by hand,
// "sprite_000" or "sprite_000+4" as well.
function parseNumber(text) {
  const trimmed = String(text).trim();
  let match;
  if ((match = /^\$([0-9a-f]+)$/i.exec(trimmed))) return parseInt(match[1], 16);
  if ((match = /^0x([0-9a-f]+)$/i.exec(trimmed))) return parseInt(match[1], 16);
  if ((match = /^#([0-9a-f]+)$/i.exec(trimmed))) return parseInt(match[1], 16);
  if ((match = /^(\d[0-9a-f]*)h$/i.exec(trimmed))) return parseInt(match[1], 16);
  if ((match = /^(\d+)$/.exec(trimmed))) return parseInt(match[1], 10);
  return undefined;
}

async function lookupSymbol(session, name) {
  let body;
  try {
    body = await session.customRequest('matchSymbols', { prefix: name });
  } catch (err) {
    return undefined;
  }
  const symbols = (body && body.symbols) || [];
  const exact = symbols.find((symbol) => symbol.name === name);
  const insensitive = symbols.find(
    (symbol) => symbol.name.toLowerCase() === name.toLowerCase()
  );
  const chosen = exact || insensitive;
  return chosen ? chosen.address : undefined;
}

async function resolveGraphicsAddress(session, text) {
  const trimmed = String(text || '').trim();
  if (!trimmed) return undefined;
  // One term, optionally displaced: the lazy first group splits at the first
  // sign, so "$8000-2" and "sprite_000+4" both come apart the obvious way.
  const split = /^(.+?)\s*([+-])\s*(\S+)$/.exec(trimmed);
  const baseText = split ? split[1] : trimmed;
  let delta = 0;
  if (split) {
    const parsed = parseNumber(split[3]);
    if (parsed === undefined) return undefined;
    delta = split[2] === '-' ? -parsed : parsed;
  }
  let base = parseNumber(baseText);
  if (base === undefined) {
    base = await lookupSymbol(session, baseText);
  }
  if (base === undefined) return undefined;
  return (((base + delta) % 0x10000) + 0x10000) % 0x10000;
}

async function sendGraphicsSymbols(message) {
  const session = zxDebugSession();
  if (!session) return;
  let body;
  try {
    body = await session.customRequest('matchSymbols', { prefix: message.prefix || '' });
  } catch (err) {
    // An older server with no such request. Completion is a convenience; the
    // address still types out by hand.
    return;
  }
  postGraphics({ type: 'symbols', symbols: (body && body.symbols) || [] });
}

// Every read carries the id of the sprite it is for -- the one being dialled
// in, or one pinned to the sheet -- and every reply carries it back. Without
// that, a sheet of sprites reading from different places could not tell whose
// bytes had just arrived.
async function sendGraphicsData(request) {
  const length = Math.max(1, Math.min(Number(request.length) || 0, 0x10000));
  const offset = Math.max(0, Number(request.offset) || 0);
  const id = request.id === undefined ? 'current' : request.id;
  try {
    if (request.source === 'memory') {
      await sendMemoryGraphics(id, request, length);
    } else if (request.source === 'file') {
      sendFileGraphics(id, request.file, offset, length);
    } else {
      sendSelectionGraphics(id, offset, length);
    }
  } catch (err) {
    postGraphicsError('Could not read the data: ' + errorText(err));
  }
}

async function sendMemoryGraphics(id, request, length) {
  const session = zxDebugSession();
  if (!session) {
    postGraphicsError('No ZX Spectrum debug session -- start one to read memory.');
    return;
  }
  const address = await resolveGraphicsAddress(session, request.address);
  if (address === undefined) {
    postGraphicsError('Not an address or a known symbol: ' + request.address);
    return;
  }
  // Clamped rather than wrapped at the top of memory. A sprite table that runs
  // off $FFFF is a mistake worth seeing as a short read, not one worth hiding
  // by folding the rest of it back onto the ROM.
  const count = Math.min(length, 0x10000 - address);
  const body = await session.customRequest('readMemory', {
    memoryReference: address,
    offset: 0,
    count,
  });
  postGraphics({
    type: 'data',
    id,
    bytes: (body && body.data) || '',
    origin: {
      kind: 'memory',
      address,
      label: 'memory ' + hex4(address) + '..' + hex4((address + count - 1) & 0xFFFF),
    },
  });
}

// The path comes from the request when there is one, so a sprite pinned from
// one file keeps reading that file after "Choose file..." has moved on to
// another. Only a sprite that never had a path of its own falls back to
// whichever file is currently open.
function sendFileGraphics(id, file, offset, length) {
  const target = file || graphicsFile;
  if (!target) {
    postGraphicsError('No file chosen yet.');
    return;
  }
  const buffer = fs.readFileSync(target);
  const start = Math.min(offset, buffer.length);
  const slice = buffer.subarray(start, start + length);
  postGraphics({
    type: 'data',
    id,
    bytes: slice.toString('base64'),
    origin: {
      kind: 'file',
      path: target,
      label: path.basename(target) + ' +' + start + ' of ' + buffer.length,
    },
  });
}

function sendSelectionGraphics(id, offset, length) {
  if (!lastSelection) {
    postGraphicsError('Select some DEFB data in an editor, then press Grab selection.');
    return;
  }
  const text = lastSelection.document.getText(lastSelection.range);
  const bytes = parseByteLiterals(text);
  const start = Math.min(offset, bytes.length);
  const slice = bytes.subarray(start, start + length);
  postGraphics({
    type: 'data',
    id,
    bytes: slice.toString('base64'),
    origin: {
      kind: 'selection',
      label:
        path.basename(lastSelection.document.fileName) +
        ':' +
        (lastSelection.range.start.line + 1) +
        ' -- ' +
        bytes.length +
        ' bytes parsed',
    },
  });
}

// Pulls the numbers out of assembler source. Anything sjasmplus writes for a
// byte is understood: 0x3C, $3C, #3C, 3Ch, 0b00111100, %00111100, 60.
//
// When the selection contains DEFB lines, only those contribute -- a selection
// that caught the label above the table, or an EQU beside it, should not have
// those numbers land in the middle of the sprite. With no such line anywhere
// (a plain column of numbers, say) every number counts, since there is nothing
// to tell them apart by.
function parseByteLiterals(text) {
  const stripped = text.split(/\r?\n/).map((line) => line.replace(/;.*$/, ''));
  const directive = /\b(?:DEFB|DB|DEFM|DM|BYTE)\b(.*)$/i;
  const emitted = stripped.map((line) => {
    const match = directive.exec(line);
    return match ? match[1] : null;
  });
  const lines = emitted.some((line) => line !== null)
    ? emitted.filter((line) => line !== null)
    : stripped;

  const token = /0x([0-9a-f]+)|\$([0-9a-f]+)|#([0-9a-f]+)|0b([01]+)|%([01]+)|\b(\d[0-9a-f]*)h\b|\b(\d+)\b/gi;
  const bytes = [];
  for (const line of lines) {
    // Quoted text is skipped rather than turned into character codes: a DEFM
    // is nearly always a message, and messages in the middle of a sprite sheet
    // would be noise.
    const numbers = line.replace(/"[^"]*"|'[^']*'/g, ' ');
    token.lastIndex = 0;
    let match;
    while ((match = token.exec(numbers)) !== null) {
      let value;
      if (match[1] !== undefined) value = parseInt(match[1], 16);
      else if (match[2] !== undefined) value = parseInt(match[2], 16);
      else if (match[3] !== undefined) value = parseInt(match[3], 16);
      else if (match[4] !== undefined) value = parseInt(match[4], 2);
      else if (match[5] !== undefined) value = parseInt(match[5], 2);
      else if (match[6] !== undefined) value = parseInt(match[6], 16);
      else value = parseInt(match[7], 10);
      bytes.push(value & 0xFF);
    }
  }
  return Buffer.from(bytes);
}

function hex4(value) {
  return '$' + value.toString(16).toUpperCase().padStart(4, '0');
}

// Wraps a viewer page in the CSP a webview needs. Both pages that go through
// here have exactly one <style> and one <script>, both inline, so the nonce
// goes on the script and styles are allowed inline -- the same shape the
// screen panel's inline HTML uses.
function webviewHtml(file) {
  const nonce = getNonce();
  const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; ` +
              `script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; ` +
              `font-src data:; img-src data:;">`;
  return fs.readFileSync(file, 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">');
}

function getNonce() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let text = '';
  for (let i = 0; i < 32; i++) {
    text += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return text;
}

function getHtml(view, startVolume, startVolumeBeforeMute) {
  const nonce = getNonce();
  // Frames arrive via postMessage as base64, rendered as a data: URI --
  // no network-facing CSP directive is needed at all (no img-src/connect-src
  // for the screen-stream host), which is the main advantage of pushing
  // frames through the extension host over having the webview poll an HTTP
  // endpoint itself.
  return `<!DOCTYPE html>
<html>
<head>
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; img-src data:; script-src 'nonce-${nonce}'; style-src 'unsafe-inline';">
  <style>
    /* The canvas centres itself with auto margins rather than the body
       centring it: centring by flex alignment pushes a canvas larger than
       the panel (a fixed 4x in a small panel) off the top and left, where no
       scrollbar can reach it. */
    body { margin:0; padding:0; background:#000; display:flex; min-height:100vh; overflow:auto; outline:none; }
    canvas { display:block; margin:auto; }
    /* The speaker button, with the volume slider sliding out beside it on
       hover. Faint until pointed at, so it keeps out of the picture. */
    #audio { position:fixed; top:8px; right:12px; display:flex; align-items:center;
             gap:6px; opacity:.35; }
    #audio:hover { opacity:1; }
    #mute { font:16px system-ui,sans-serif; background:rgba(0,0,0,.5); color:#fff;
            border:1px solid #666; border-radius:4px; padding:2px 8px; cursor:pointer; }
    #volume { width:0; opacity:0; margin:0; transition:width .15s, opacity .15s; }
    #audio:hover #volume, #volume:focus { width:96px; opacity:1; }
  </style>
</head>
<body tabindex="0">
  <canvas id="screen" aria-label="ZX Spectrum screen"></canvas>
  <div id="audio">
    <input id="volume" type="range" min="0" max="100" step="1" aria-label="Volume" />
    <button id="mute"></button>
  </div>
  <script nonce="${nonce}">
    const vscodeApi = acquireVsCodeApi();

    // ---- the picture ----------------------------------------------------
    //
    // Drawn into a canvas sized in DEVICE pixels, and laid out at exactly
    // that size in CSS pixels, so the only filtering is the one chosen here
    // -- never the browser quietly rescaling the element behind it. The two
    // functions below are screen_scaling.js's own, inlined as source; its
    // tests hold them to the answers this page gets.
    ${layoutFor.toString()}

    ${prescaleFactor.toString()}

    ${scanlinesPossible.toString()}

    ${scanlineBand.toString()}

    ${visibleRect.toString()}

    const canvas = document.getElementById('screen');
    const ctx = canvas.getContext('2d');
    // Sharp bilinear's first pass, nearest neighbour up to a whole multiple.
    const prescaled = document.createElement('canvas');
    const prescaledCtx = prescaled.getContext('2d');
    // The scanline gaps, built once per size and darkness and laid over every
    // frame -- one drawImage a frame rather than 312 rectangles.
    const scanlines = document.createElement('canvas');
    const scanlinesCtx = scanlines.getContext('2d');
    let scanlinesShown = false;
    let view = ${JSON.stringify(view)};
    // The part of the frame shown, for the border setting: the picture is
    // this rectangle of it, everywhere below.
    let crop = visibleRect(view.border);
    let frame = null;   // the newest decoded frame, an ImageBitmap
    let decoding = 0;   // the newest frame handed to the decoder

    function resize() {
      crop = visibleRect(view.border);
      const l = layoutFor(view.scale, window.innerWidth, window.innerHeight,
                          window.devicePixelRatio || 1, crop.w, crop.h);
      if (canvas.width !== l.canvasW || canvas.height !== l.canvasH) {
        canvas.width = l.canvasW;
        canvas.height = l.canvasH;
      }
      canvas.style.width = l.cssW + 'px';
      canvas.style.height = l.cssH + 'px';
      buildScanlines();
    }

    // The gaps are measured from the canvas the picture is drawn into, not
    // from the scale it was asked for, so they fall exactly between its lines
    // however the size was rounded.
    function buildScanlines() {
      // The crop starts on a whole line, so the first line of the canvas is
      // the first line of a Spectrum line and the gaps stay in step.
      const rowHeight = canvas.height / crop.h;
      scanlinesShown = view.scanlines > 0 && scanlinesPossible(rowHeight);
      if (!scanlinesShown) return;
      if (scanlines.width !== canvas.width || scanlines.height !== canvas.height) {
        scanlines.width = canvas.width;
        scanlines.height = canvas.height;
      }
      scanlinesCtx.clearRect(0, 0, scanlines.width, scanlines.height);
      scanlinesCtx.fillStyle = 'rgba(0, 0, 0, ' + view.scanlines / 100 + ')';
      const band = scanlineBand(rowHeight);
      for (let line = 0; line < crop.h; line++) {
        scanlinesCtx.fillRect(0, line * rowHeight + band.offset, scanlines.width, band.height);
      }
    }

    function draw() {
      if (!frame) return;
      const w = canvas.width;
      const h = canvas.height;
      // Set on every draw: resizing a canvas resets its context, smoothing
      // included. 'low' is Chromium's bilinear -- 'medium' adds mipmaps,
      // which only matter going down, and 'high' is bicubic.
      if (view.filter === 'bilinear') {
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'low';
        ctx.drawImage(frame, crop.x, crop.y, crop.w, crop.h, 0, 0, w, h);
      } else if (view.filter === 'sharp-bilinear') {
        // Nearest neighbour to the largest whole multiple that fits, then
        // bilinear for what is left: every pixel stays square and the same
        // size, and only its edges are blended. At a whole-multiple size
        // there is nothing left over, and this is nearest neighbour exactly.
        const k = prescaleFactor(w, h, crop.w, crop.h);
        if (prescaled.width !== crop.w * k || prescaled.height !== crop.h * k) {
          prescaled.width = crop.w * k;
          prescaled.height = crop.h * k;
        }
        prescaledCtx.imageSmoothingEnabled = false;
        prescaledCtx.drawImage(frame, crop.x, crop.y, crop.w, crop.h,
                               0, 0, prescaled.width, prescaled.height);
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = 'low';
        ctx.drawImage(prescaled, 0, 0, w, h);
      } else {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(frame, crop.x, crop.y, crop.w, crop.h, 0, 0, w, h);
      }
      // After the filter, as a CRT's gaps would be: the dark band is in the
      // glass, not in the picture being scaled.
      if (scanlinesShown) {
        ctx.drawImage(scanlines, 0, 0);
      }
    }

    // Decoded off the main thread. Frames arrive fifty times a second and a
    // decode can take longer than the gap, so a frame that finishes after a
    // newer one has been sent for decoding is thrown away rather than drawn
    // over it.
    async function showFrame(base64) {
      const seq = ++decoding;
      const bin = atob(base64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      let bitmap;
      try {
        bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
      } catch (err) {
        return; // a damaged frame: the next one will do
      }
      if (seq !== decoding) {
        bitmap.close();
        return;
      }
      if (frame) frame.close();
      frame = bitmap;
      draw();
    }

    // Moving the panel between monitors changes the device pixel ratio, and
    // Chromium reports that as a resize too.
    window.addEventListener('resize', () => { resize(); draw(); });
    resize();

    // ---- beeper playback ------------------------------------------------
    //
    // Blocks arrive about every 10ms and have to be played gapless, so each
    // one is scheduled against a running cursor rather than played on
    // arrival -- 'when the last block ends' is the only start time that
    // doesn't leave a seam. Two things can knock the cursor out:
    //
    //   * an underrun, when the emulator stops (a breakpoint, a step) and
    //     then resumes. The cursor is behind now, so reset it forward.
    //   * slow drift, because the emulator paces itself against
    //     steady_clock while playback runs off the sound card's clock.
    //     Those disagree by a few parts per million, which over minutes
    //     accumulates into latency. Dropping a block claws it back.
    let audioCtx = null;
    let sampleRate = 44100;
    let nextStart = 0;
    // One volume for all the sound, wherever it comes out: this panel's own
    // playback, and -- through the extension -- the server's sound device.
    // 0 is mute; the level before a mute is what the speaker button restores.
    let volume = ${Number(startVolume)};
    let volumeBeforeMute = ${Number(startVolumeBeforeMute)};
    let gainNode = null;
    // Shaped so that the middle of the slider sounds about half as loud:
    // loudness follows the square of the amplitude far more closely than the
    // amplitude itself. The server applies the same curve.
    function gainFor(percent) {
      return (percent / 100) * (percent / 100);
    }

    // How far ahead of 'now' to aim, and the point past which we are
    // drifting and should drop a block to claw the latency back. The server
    // sends its own --audio-latency-ms in the preamble and this follows it,
    // so there is one setting rather than two that can disagree.
    let jitterS = 0.06;
    let maxAheadS = 0.21;

    function ensureAudio() {
      if (!audioCtx) {
        audioCtx = new AudioContext({ sampleRate: sampleRate });
        gainNode = audioCtx.createGain();
        gainNode.gain.value = gainFor(volume);
        gainNode.connect(audioCtx.destination);
      }
      // Autoplay policy: the context starts suspended until the user has
      // interacted with the panel, so this is retried on every gesture.
      if (audioCtx.state === 'suspended') audioCtx.resume();
      return audioCtx;
    }

    function playBlock(base64) {
      // Scheduled even at volume 0, so turning it back up picks up where the
      // stream is rather than re-seeding the cursor.
      const ctx = ensureAudio();
      if (ctx.state !== 'running') return; // still waiting on a gesture

      const bin = atob(base64);
      const count = bin.length >> 1;
      if (count === 0) return;

      const buffer = ctx.createBuffer(1, count, sampleRate);
      const channel = buffer.getChannelData(0);
      for (let i = 0; i < count; i++) {
        // mono int16, little-endian
        let v = bin.charCodeAt(i * 2) | (bin.charCodeAt(i * 2 + 1) << 8);
        if (v >= 0x8000) v -= 0x10000;
        channel[i] = v / 32768;
      }

      const now = ctx.currentTime;
      if (nextStart < now + 0.005) {
        nextStart = now + jitterS;       // underrun: re-seed the cursor
      } else if (nextStart > now + maxAheadS) {
        return;                          // drifted ahead: drop this block
      }
      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(gainNode);
      source.start(nextStart);
      nextStart += buffer.duration;
    }

    window.addEventListener('message', (event) => {
      const data = event.data;
      if (data.image !== undefined) {
        showFrame(data.image);
      } else if (data.view !== undefined) {
        view = data.view;
        resize();
        draw();
      } else if (data.audio !== undefined) {
        playBlock(data.audio);
      } else if (data.audioRate !== undefined) {
        if (data.audioLatencyMs !== undefined) {
          jitterS = data.audioLatencyMs / 1000;
          // Enough slack above the target to ride out normal jitter without
          // dropping, but close enough that drift is caught before it is
          // audible as lag.
          maxAheadS = jitterS + 0.15;
        }
        // A rate change means a different server; start a fresh context
        // rather than resampling everything by hand.
        if (data.audioRate !== sampleRate) {
          sampleRate = data.audioRate;
          if (audioCtx) { audioCtx.close(); audioCtx = null; gainNode = null; }
          nextStart = 0;
        }
      }
    });

    const muteButton = document.getElementById('mute');
    const volumeSlider = document.getElementById('volume');
    function showVolume() {
      // Muted, one-wave and three-wave speakers, as a volume icon has them.
      muteButton.innerHTML = volume === 0 ? '&#128263;' : volume < 50 ? '&#128265;' : '&#128266;';
      muteButton.title = volume === 0
        ? 'Unmute (back to ' + volumeBeforeMute + '%)'
        : 'Mute -- volume ' + volume + '%, this panel and the sound device';
      volumeSlider.value = String(volume);
      volumeSlider.title = 'Volume ' + volume + '%';
      if (gainNode) gainNode.gain.value = gainFor(volume);
    }
    // 'persist' is false while a slider is being dragged: every step is heard
    // at once, but only where it ends up is remembered.
    function setVolume(percent, persist) {
      volume = percent;
      if (percent > 0) volumeBeforeMute = percent;
      showVolume();
      vscodeApi.postMessage({ type: 'setVolume', volume: volume, before: volumeBeforeMute, persist: persist });
    }
    showVolume();
    muteButton.addEventListener('click', () => {
      setVolume(volume === 0 ? (volumeBeforeMute || 100) : 0, true);
      if (volume > 0) ensureAudio();
      document.body.focus(); // keep keystrokes going to the Spectrum
    });
    volumeSlider.addEventListener('input', () => {
      setVolume(Number(volumeSlider.value), false);
    });
    volumeSlider.addEventListener('change', () => {
      setVolume(Number(volumeSlider.value), true);
      if (volume > 0) ensureAudio();
      document.body.focus();
    });

    // Maps a browser KeyboardEvent to the Spectrum keys it means (see
    // cpp-core/src/keyboard.cpp's ROWS table) -- an empty list for anything
    // with no Spectrum equivalent. Left/right Shift both map to CAPS SHIFT
    // since physical Spectrum keyboards only have the one; Ctrl (either side)
    // maps to SYM SHIFT, matching a common software-emulator convention
    // (real hardware has no direct PC-keyboard equivalent for it).
    //
    // Decoded from event.code -- the PHYSICAL key -- and not event.key. With
    // Shift held, event.key for the 5 key is '%', which is no Spectrum key at
    // all, so CAPS SHIFT + 5 (cursor left) could never be typed; the same
    // went for every shifted digit and symbol. The code names the key cap
    // whatever modifiers are down.
    //
    // The PC's own cursor keys and Backspace are the Spectrum's CAPS SHIFT
    // combinations, which is why one event can mean two keys.
    function toSpectrumKeys(event) {
      const code = event.code;
      if (/^Key[A-Z]$/.test(code)) return [code.slice(3)];
      if (/^Digit[0-9]$/.test(code)) return [code.slice(5)];
      switch (code) {
        case 'Space': return ['SPACE'];
        case 'Enter':
        case 'NumpadEnter': return ['ENTER'];
        case 'ShiftLeft':
        case 'ShiftRight': return ['CAPS SHIFT'];
        case 'ControlLeft':
        case 'ControlRight': return ['SYM SHIFT'];
        case 'ArrowLeft': return ['CAPS SHIFT', '5'];
        case 'ArrowDown': return ['CAPS SHIFT', '6'];
        case 'ArrowUp': return ['CAPS SHIFT', '7'];
        case 'ArrowRight': return ['CAPS SHIFT', '8'];
        case 'Backspace': return ['CAPS SHIFT', '0'];
        default: return [];
      }
    }

    // Tracks which mapped keys are currently down so a lost blur/focus
    // event (switching windows mid-keypress) can't leave a key stuck
    // pressed forever from the emulator's point of view. Counted rather
    // than a set: CAPS SHIFT can be held by the Shift key and by an arrow
    // key at once, and releasing one of them must not release it for the
    // other.
    const held = new Map();

    function press(key) {
      const n = held.get(key) || 0;
      held.set(key, n + 1);
      if (n === 0) vscodeApi.postMessage({ type: 'keyDown', key });
    }

    function release(key) {
      const n = held.get(key) || 0;
      if (n <= 1) {
        held.delete(key);
        if (n === 1) vscodeApi.postMessage({ type: 'keyUp', key });
      } else {
        held.set(key, n - 1);
      }
    }

    // Which physical keys are down, so a keyup releases exactly what its
    // keydown pressed -- and an auto-repeat keydown presses nothing twice.
    const down = new Set();

    document.body.addEventListener('keydown', (event) => {
      ensureAudio(); // the gesture the autoplay policy has been waiting for
      const keys = toSpectrumKeys(event);
      if (keys.length === 0) return;
      event.preventDefault();
      if (event.repeat || down.has(event.code)) return;
      down.add(event.code);
      for (const key of keys) press(key);
    });

    document.body.addEventListener('keyup', (event) => {
      const keys = toSpectrumKeys(event);
      if (keys.length === 0) return;
      event.preventDefault();
      if (!down.delete(event.code)) return;
      for (const key of keys) release(key);
    });

    window.addEventListener('blur', () => {
      for (const key of held.keys()) {
        vscodeApi.postMessage({ type: 'keyUp', key });
      }
      held.clear();
      down.clear();
    });

    document.body.focus();
  </script>
</body>
</html>`;
}

function deactivate() {
  deactivateServer();
  for (const screen of screenPanels()) {
    screen.dispose();
  }
  stopWatchingTrace();
  stopTracePolling();
  stopTapePolling();
}

module.exports = { activate, deactivate };
