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

const SCREEN_HOST = '127.0.0.1';
const SCREEN_PORT = 8500; // must match --screen-port; see README if you changed it
const RECONNECT_DELAY_MS = 1000;

let panel;
let socket;
let reconnectTimer;
let recvBuffer = Buffer.alloc(0);

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('zxspectrum.showScreen', () => showScreenPanel(context))
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
  connectStream();
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
    body { margin:0; padding:0; background:#000; display:flex; align-items:center; justify-content:center; height:100vh; }
    img { image-rendering: pixelated; width:512px; height:384px; }
  </style>
</head>
<body>
  <img id="screen" alt="ZX Spectrum screen" />
  <script nonce="${nonce}">
    const img = document.getElementById('screen');
    window.addEventListener('message', (event) => {
      img.src = 'data:image/png;base64,' + event.data.image;
    });
  </script>
</body>
</html>`;
}

function deactivate() {
  disconnectStream();
}

module.exports = { activate, deactivate };
