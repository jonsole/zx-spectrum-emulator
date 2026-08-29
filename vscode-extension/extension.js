// ZX Spectrum Debug extension.
//
// Two jobs: (1) purely declarative -- registering the "zxspectrum" debugger
// type (see package.json) so launch.json's debugServer field can connect
// directly to zx-spectrum-emulator's DAP server, no adapter code needed for
// that part; (2) this file -- a live screen viewer and beeper. A webview's own
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

const SCREEN_HOST = '127.0.0.1';
const SCREEN_PORT = 8500; // must match --screen-port; see README if you changed it
const AUDIO_PORT = 8501; // must match --audio-port
const RECONNECT_DELAY_MS = 1000;

// How often the row counter is refreshed while a capture runs. traceStatus
// bypasses the emulator's command queue, so this costs nothing on the server
// side even mid-run -- it is paced for the eye, not for the machine.
const TRACE_POLL_MS = 400;
// Where the Record button writes. One fixed name rather than a prompt per
// capture: recording is something you do repeatedly while chasing one
// question down, and each capture supersedes the last.
const LIVE_TRACE_NAME = 'live.zxtrace';
// How often the tape pane asks where the tape has got to. tapeControl bypasses
// the emulator's command queue, exactly as traceStatus does, so this costs
// nothing on the server side even mid-load -- and like the trace poll it is
// paced for the eye. It only ticks while the pane is actually visible.
const TAPE_POLL_MS = 400;

let panel;
let tracePanel;
let traceFile;      // the .zxtrace currently shown
let traceWatcher;   // reloads the panel when that file is recaptured
let tracePoll;      // ticks while a live capture is running
let socket;
let reconnectTimer;
let recvBuffer = Buffer.alloc(0);

let tapeProvider;   // the block list shown in the debug sidebar
let tapeView;
let tapePoll;       // ticks while that pane is visible
let tapeFastLoadContext; // last values pushed to the when-clause context keys
let tapePlayingContext;

let audioSocket;
let audioReconnectTimer;
let audioBuffer = Buffer.alloc(0);
let audioPreambleSeen = false;

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showScreen', () => showScreenPanel(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showTrace', () => showTracePanel(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.loadTape', () => loadTape(context))
  );

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
        showScreenPanel(context);
        startTapePolling();
      }
      publishLiveState();
    })
  );
  // A capture belongs to the session that is making it, so one ending ends the
  // capture's story too -- the panel goes back to "no debug session" rather
  // than sitting on a row count that has stopped moving.
  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession(() => {
      stopTracePolling();
      stopTapePolling();
      refreshTape(undefined);
      publishLiveState();
    })
  );
  context.subscriptions.push(
    vscode.debug.onDidChangeActiveDebugSession(() => {
      // The session is not necessarily active yet when onDidStartDebugSession
      // fires, so this is the event that reliably has one to poll.
      startTapePolling();
      publishLiveState();
    })
  );
}

function showScreenPanel(context) {
  if (panel) {
    panel.reveal(vscode.ViewColumn.Beside);
    return;
  }
  panel = vscode.window.createWebviewPanel(
    'zxspectrumScreen',
    'ZX Spectrum Screen',
    vscode.ViewColumn.Beside,
    { enableScripts: true, retainContextWhenHidden: true }
  );
  panel.webview.html = getHtml();
  panel.onDidDispose(
    () => {
      panel = undefined;
      disconnectStream();
      disconnectAudioStream();
    },
    null,
    context.subscriptions
  );
  panel.webview.onDidReceiveMessage(handleWebviewMessage, null, context.subscriptions);
  connectStream();
  connectAudioStream();
}

// Forwards a keydown/keyup captured by the webview (see getHtml()'s script)
// to the emulator via a DAP custom request (server-side: dap.rs's
// "keyDown"/"keyUp" handlers). Silently drops the keypress if there's no
// active zxspectrum session -- nothing sensible to do with it otherwise,
// and this fires on every keystroke so a warning popup per keypress would
// be far too noisy.
async function handleWebviewMessage(message) {
  if (message.type !== 'keyDown' && message.type !== 'keyUp') return;
  const session = vscode.debug.activeDebugSession;
  if (!session || session.type !== 'zxspectrum') return;
  try {
    await session.customRequest(message.type, { key: message.key });
  } catch (err) {
    // Most likely cause: the Python server (no keyDown/keyUp custom
    // request) is what's actually running, not the Rust one.
  }
}

function connectStream() {
  recvBuffer = Buffer.alloc(0);
  socket = net.connect(SCREEN_PORT, SCREEN_HOST);

  socket.on('data', (chunk) => {
    recvBuffer = Buffer.concat([recvBuffer, chunk]);
    // A frame is a 4-byte big-endian length prefix + that many PNG bytes
    // (see zxspectrum/server/screen_stream.py) -- loop in case multiple
    // frames arrived in one chunk, and leave a partial frame buffered for
    // the next 'data' event rather than assuming chunk boundaries line up
    // with frame boundaries (they generally won't).
    while (recvBuffer.length >= 4) {
      const length = recvBuffer.readUInt32BE(0);
      if (recvBuffer.length < 4 + length) break;
      const frame = recvBuffer.subarray(4, 4 + length);
      recvBuffer = recvBuffer.subarray(4 + length);
      if (panel) {
        panel.webview.postMessage({ image: frame.toString('base64') });
      }
    }
  });
  socket.on('error', scheduleReconnect);
  socket.on('close', scheduleReconnect);
}

function scheduleReconnect() {
  // The server gets restarted often during development (a code change
  // needs a fresh process) -- reconnecting automatically instead of giving
  // up on the first drop means the panel recovers on its own instead of
  // needing to be closed and reopened every time.
  if (!panel || reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    if (panel) connectStream();
  }, RECONNECT_DELAY_MS);
}

function disconnectStream() {
  if (socket) {
    socket.removeAllListeners();
    socket.destroy();
    socket = undefined;
  }
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = undefined;
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
  const fastLoad = status ? status.fastLoad === true : true;
  if (tapeFastLoadContext !== fastLoad) {
    // Drives which of the two fast-load buttons the title bar shows.
    tapeFastLoadContext = fastLoad;
    vscode.commands.executeCommand('setContext', 'zxspectrum.tapeFastLoad', fastLoad);
  }
  const playing = status ? status.playing === true : false;
  if (tapePlayingContext !== playing) {
    // Play and Stop share one slot in the title bar and swap according to
    // this, the way the debug toolbar's Continue and Pause do -- a transport
    // has one button there, not two, and which one it is IS the state.
    tapePlayingContext = playing;
    vscode.commands.executeCommand('setContext', 'zxspectrum.tapePlaying', playing);
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
    tracePanel.webview.html = getTraceHtml(viewer);
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

async function startLiveTrace(options) {
  const session = zxDebugSession();
  if (!session) {
    publishLiveState(); // the session went away between the click and here
    return;
  }
  const file = liveTracePath();
  const request = { path: file, extra: options.extra === true };
  // Left out rather than sent as null: the server has its own defaults for
  // both, and "not specified" is not the same as a value.
  if (typeof options.limit === 'number') request.limit = options.limit;
  if (typeof options.watch === 'number') request.watch = options.watch;

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
      message: 'could not start: ' + (err && err.message ? err.message : String(err))
    });
    return;
  }
  postTrace({ type: 'traceStatus', state: 'recording', status });
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
      message: 'could not stop: ' + (err && err.message ? err.message : String(err))
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

// Wraps the standalone viewer in the CSP a webview needs. The file has exactly
// one <style> and one <script>, both inline, so the nonce goes on the script
// and styles are allowed inline -- the same shape the screen panel uses.
function getTraceHtml(viewer) {
  const nonce = getNonce();
  const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; ` +
              `script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; ` +
              `font-src data:; img-src data:;">`;
  return fs.readFileSync(viewer, 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + csp)
    .replace('<script>', '<script nonce="' + nonce + '">');
}

function connectAudioStream() {
  audioBuffer = Buffer.alloc(0);
  audioPreambleSeen = false;
  audioSocket = net.connect(AUDIO_PORT, SCREEN_HOST);

  audioSocket.on('data', (chunk) => {
    audioBuffer = Buffer.concat([audioBuffer, chunk]);

    // A one-off preamble: "ZXA2", a big-endian u32 sample rate, then the
    // server's target latency in ms. Both travel with the stream so neither
    // is hardcoded here, and so the server's --audio-latency-ms is the single
    // knob for how deep the panel buffers too.
    if (!audioPreambleSeen) {
      if (audioBuffer.length < 12) return;
      const magic = audioBuffer.subarray(0, 4).toString('latin1');
      const rate = audioBuffer.readUInt32BE(4);
      const latencyMs = audioBuffer.readUInt32BE(8);
      audioBuffer = audioBuffer.subarray(12);
      audioPreambleSeen = true;
      if (magic !== 'ZXA2') {
        // An older server, or something else altogether listening on that
        // port. Stop rather than feed the speakers whatever it is sending.
        disconnectAudioStream();
        return;
      }
      if (panel) panel.webview.postMessage({ audioRate: rate, audioLatencyMs: latencyMs });
    }

    // Then [4-byte big-endian byte length][mono int16 LE samples] blocks,
    // reassembled exactly the way the screen's PNG frames are.
    while (audioBuffer.length >= 4) {
      const length = audioBuffer.readUInt32BE(0);
      if (audioBuffer.length < 4 + length) break;
      const block = audioBuffer.subarray(4, 4 + length);
      audioBuffer = audioBuffer.subarray(4 + length);
      if (panel) {
        panel.webview.postMessage({ audio: block.toString('base64') });
      }
    }
  });
  audioSocket.on('error', scheduleAudioReconnect);
  audioSocket.on('close', scheduleAudioReconnect);
}

function scheduleAudioReconnect() {
  if (!panel || audioReconnectTimer) return;
  audioReconnectTimer = setTimeout(() => {
    audioReconnectTimer = undefined;
    if (panel) connectAudioStream();
  }, RECONNECT_DELAY_MS);
}

function disconnectAudioStream() {
  if (audioSocket) {
    audioSocket.removeAllListeners();
    audioSocket.destroy();
    audioSocket = undefined;
  }
  if (audioReconnectTimer) {
    clearTimeout(audioReconnectTimer);
    audioReconnectTimer = undefined;
  }
}

function getNonce() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let text = '';
  for (let i = 0; i < 32; i++) {
    text += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return text;
}

function getHtml() {
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
    body { margin:0; padding:0; background:#000; display:flex; align-items:center; justify-content:center; height:100vh; outline:none; }
    /* 352x312 (border included) at 2x scale */
    img { image-rendering: pixelated; width:704px; height:624px; }
    #mute { position:fixed; top:8px; right:12px; font:16px system-ui,sans-serif;
            background:rgba(0,0,0,.5); color:#fff; border:1px solid #666;
            border-radius:4px; padding:2px 8px; cursor:pointer; opacity:.35; }
    #mute:hover { opacity:1; }
  </style>
</head>
<body tabindex="0">
  <img id="screen" alt="ZX Spectrum screen" />
  <button id="mute" title="Mute the beeper">&#128266;</button>
  <script nonce="${nonce}">
    const vscodeApi = acquireVsCodeApi();
    const img = document.getElementById('screen');

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
    let muted = false;

    // How far ahead of 'now' to aim, and the point past which we are
    // drifting and should drop a block to claw the latency back. The server
    // sends its own --audio-latency-ms in the preamble and this follows it,
    // so there is one setting rather than two that can disagree.
    let jitterS = 0.06;
    let maxAheadS = 0.21;

    function ensureAudio() {
      if (!audioCtx) {
        audioCtx = new AudioContext({ sampleRate: sampleRate });
      }
      // Autoplay policy: the context starts suspended until the user has
      // interacted with the panel, so this is retried on every gesture.
      if (audioCtx.state === 'suspended') audioCtx.resume();
      return audioCtx;
    }

    function playBlock(base64) {
      if (muted) return;
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
      source.connect(ctx.destination);
      source.start(nextStart);
      nextStart += buffer.duration;
    }

    window.addEventListener('message', (event) => {
      const data = event.data;
      if (data.image !== undefined) {
        img.src = 'data:image/png;base64,' + data.image;
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
          if (audioCtx) { audioCtx.close(); audioCtx = null; }
          nextStart = 0;
        }
      }
    });

    const muteButton = document.getElementById('mute');
    muteButton.addEventListener('click', () => {
      muted = !muted;
      muteButton.innerHTML = muted ? '&#128263;' : '&#128266;';
      muteButton.title = muted ? 'Unmute the beeper' : 'Mute the beeper';
      if (!muted) ensureAudio();
      document.body.focus(); // keep keystrokes going to the Spectrum
    });

    // Maps a browser KeyboardEvent to a 48K Spectrum key name (see
    // zx-core/src/keyboard.rs's ROWS table) -- null for anything with no
    // Spectrum equivalent. Left/right Shift both map to CAPS SHIFT since
    // physical Spectrum keyboards only have the one; Ctrl (either side)
    // maps to SYM SHIFT, matching a common software-emulator convention
    // (real hardware has no direct PC-keyboard equivalent for it).
    function toSpectrumKey(event) {
      const key = event.key;
      if (key.length === 1 && /[a-zA-Z]/.test(key)) return key.toUpperCase();
      if (key.length === 1 && /[0-9]/.test(key)) return key;
      switch (key) {
        case ' ': return 'SPACE';
        case 'Enter': return 'ENTER';
        case 'Shift': return 'CAPS SHIFT';
        case 'Control': return 'SYM SHIFT';
        default: return null;
      }
    }

    // Tracks which mapped keys are currently down so a lost blur/focus
    // event (switching windows mid-keypress) can't leave a key stuck
    // pressed forever from the emulator's point of view.
    const held = new Set();

    document.body.addEventListener('keydown', (event) => {
      ensureAudio(); // the gesture the autoplay policy has been waiting for
      const key = toSpectrumKey(event);
      if (!key) return;
      event.preventDefault();
      if (event.repeat || held.has(key)) return;
      held.add(key);
      vscodeApi.postMessage({ type: 'keyDown', key });
    });

    document.body.addEventListener('keyup', (event) => {
      const key = toSpectrumKey(event);
      if (!key) return;
      event.preventDefault();
      held.delete(key);
      vscodeApi.postMessage({ type: 'keyUp', key });
    });

    window.addEventListener('blur', () => {
      for (const key of held) {
        vscodeApi.postMessage({ type: 'keyUp', key });
      }
      held.clear();
    });

    document.body.focus();
  </script>
</body>
</html>`;
}

function deactivate() {
  disconnectStream();
  disconnectAudioStream();
  stopWatchingTrace();
  stopTracePolling();
  stopTapePolling();
}

module.exports = { activate, deactivate };
