// ZX Spectrum Debug extension.
//
// Two jobs: (1) purely declarative -- registering the "zxspectrum" debugger
// type (see package.json) so launch.json's debugServer field can connect
// directly to zx-spectrum-emulator's DAP server, no adapter code needed for
// that part; (2) this file -- a live screen viewer. A webview's own JS can't
// open a raw TCP socket, so this runs in the extension host (Node, has raw
// socket access via `net`), connects to the emulator's screen-stream port,
// and forwards each frame into the webview via postMessage.

const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const path = require('path');

const SCREEN_HOST = '127.0.0.1';
const SCREEN_PORT = 8500; // must match --screen-port; see README if you changed it
const RECONNECT_DELAY_MS = 1000;

let panel;
let tracePanel;
let traceFile;      // the .zxtrace currently shown
let traceWatcher;   // reloads the panel when that file is recaptured
let socket;
let reconnectTimer;
let recvBuffer = Buffer.alloc(0);

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showScreen', () => showScreenPanel(context))
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showTrace', () => showTracePanel(context))
  );

  // Auto-open on launching a zxspectrum debug session -- no matching
  // auto-close on terminate, since staying open across a relaunch (e.g.
  // restarting the server task during development) is more useful than
  // having it disappear and need reopening every time.
  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession((session) => {
      if (session.type === 'zxspectrum') {
        showScreenPanel(context);
      }
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
    },
    null,
    context.subscriptions
  );
  panel.webview.onDidReceiveMessage(handleWebviewMessage, null, context.subscriptions);
  connectStream();
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


// ---- trace viewer ----------------------------------------------------------
//
// Unlike the screen panel, this one has no live connection to the emulator: a
// trace is a file the server wrote, so the extension host reads it and posts
// the text into the webview. The page itself is tools/trace_viewer.html, the
// same file that opens standalone in a browser -- it is not duplicated here,
// only wrapped in a CSP the webview will accept.

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
      },
      null,
      context.subscriptions
    );
    // The page asks for a file when its "Open trace..." button is used, since
    // a webview has no way to reach the workspace itself.
    tracePanel.webview.onDidReceiveMessage(
      async (message) => {
        if (message && message.type === 'pick') {
          const file = await pickTraceFile();
          if (file) loadTrace(file);
        }
      },
      null,
      context.subscriptions
    );
  } else {
    tracePanel.reveal(vscode.ViewColumn.Active);
  }

  const file = await pickTraceFile();
  if (file) loadTrace(file);
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

// Wraps the standalone viewer in the CSP a webview needs. The file has exactly
// one <style> and one <script>, both inline, so the nonce goes on the script
// and styles are allowed inline -- the same shape the screen panel uses.
function getTraceHtml(viewer) {
  const nonce = getNonce();
  const csp = '<meta http-equiv="Content-Security-Policy" content="default-src 'none'; ' +
              'script-src 'nonce-' + nonce + ''; style-src 'unsafe-inline'; ' +
              'font-src data:; img-src data:;">';
  return fs.readFileSync(viewer, 'utf8')
    .replace('<meta charset="utf-8">', '<meta charset="utf-8">
' + csp)
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
  </style>
</head>
<body tabindex="0">
  <img id="screen" alt="ZX Spectrum screen" />
  <script nonce="${nonce}">
    const vscodeApi = acquireVsCodeApi();
    const img = document.getElementById('screen');
    window.addEventListener('message', (event) => {
      img.src = 'data:image/png;base64,' + event.data.image;
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
  stopWatchingTrace();
}

module.exports = { activate, deactivate };
