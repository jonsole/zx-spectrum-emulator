// Opening a snapshot or a tape from VS Code.
//
// .sna, .z80, .tap and .tzx files open in a small read-only editor that says
// what the program is -- which Spectrum it needs, what a tape holds -- with a
// Run button and a Debug button. Run starts a debug session on it that goes
// straight on running; Debug stops at the first instruction. Either way the
// emulator is started if nothing is running (server_view.js). A .z80 that is
// really assembly source is handed back to the text editor.
//
// Also here: the `stopOnEntry` launch attribute. The server always stops a
// session on entry; a session launched with stopOnEntry false is continued
// from that first stop by the tracker below.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const info = require('./program_info');
const launch = require('./server_launch');

const VIEW_TYPE = 'zxspectrum.program';

function fileExists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch (err) {
    return false;
  }
}

function fileSize(file) {
  try {
    return fs.statSync(file).size;
  } catch (err) {
    return null;
  }
}

// The ROMs a program can be given: the server settings' list, or the roms/
// folder of each workspace folder and of the emulator's own checkout.
function romCandidates() {
  const config = vscode.workspace.getConfiguration('zxspectrum.server');
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  const roots = folders.slice();
  const found = launch.serverCandidates({
    setting: config.get('path'), folders, pathEnv: process.env.PATH,
    platform: process.platform, home: os.homedir()
  });
  const exe = launch.findServer(found.candidates, fileExists);
  if (exe) {
    roots.unshift(launch.serverRoot(exe, folders));
  }
  const listed = [];
  for (const root of roots) {
    for (const rom of launch.serverRoms(config.get('roms'), root, os.homedir(), fileExists)) {
      if (!listed.includes(rom)) {
        listed.push(rom);
      }
    }
  }
  return listed;
}

function debugInfoFor(filePath) {
  const candidates = info.debugInfoCandidates(filePath);
  if (!fileExists(candidates.sld)) {
    return null;
  }
  const asm = candidates.asm.find(fileExists);
  return asm ? { sld: candidates.sld, asm } : null;
}

async function runProgram(uri, stopOnEntry) {
  const filePath = uri.fsPath;
  const fileName = path.basename(filePath);
  let bytes;
  try {
    bytes = fs.readFileSync(filePath);
  } catch (err) {
    vscode.window.showErrorMessage(`Could not read ${fileName}: ${err.message}`);
    return;
  }
  const described = info.describeProgram(fileName, bytes);
  if (described.kind === 'unknown') {
    vscode.window.showErrorMessage(`${fileName}: ${described.problem}`);
    return;
  }
  const rom = info.pickRom(romCandidates(), described.needs128, fileSize);
  if (!rom) {
    vscode.window.showErrorMessage(`${fileName} needs a ${described.needs128 ? '128K (32K)' : '48K (16K)'} ROM, ` +
      'and none was found. Put it in roms/ or list it in zxspectrum.server.roms.');
    return;
  }
  const config = info.launchConfigFor(filePath, fileName, described, rom, debugInfoFor(filePath), stopOnEntry);
  // One machine, so one session: a program opened while another runs takes
  // its place rather than sharing the emulator with it.
  const current = vscode.debug.activeDebugSession;
  if (current && current.type === 'zxspectrum') {
    await vscode.debug.stopDebugging(current);
  }
  const folder = vscode.workspace.getWorkspaceFolder(uri);
  await vscode.debug.startDebugging(folder, config);
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

// `picture` is programScreen()'s result or null: drawn on a canvas by the
// page, with the ULA's palette and its display file layout, inside a border of
// the snapshot's colour. The page lays itself out to the editor (fit(),
// below): the picture beside the details or above them, whichever lets it be
// larger with everything still in view, and sized to that -- so nothing needs
// scrolling to reach unless the editor is too small for the details alone.
function pageHtml(fileName, described, runOnOpen, picture) {
  const nonce = crypto.randomBytes(16).toString('hex');
  const unknown = described.kind === 'unknown';
  const title = unknown ? 'Not something the emulator can load'
    : (described.kind === 'tape' ? 'Tape' : 'Snapshot') + ' for the ' +
      (described.needs128 ? 'ZX Spectrum 128' : 'ZX Spectrum 48K');
  const rows = unknown ? [escapeHtml(described.problem)]
    : [escapeHtml(described.format + (described.kind === 'snapshot' ? ', ' + described.model : ''))]
      .concat(described.details.map(escapeHtml));
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline';">
<style>
  html, body { margin: 0; height: 100%; }
  body { font: 13px var(--vscode-font-family, system-ui, sans-serif); color: var(--vscode-foreground);
         background: var(--vscode-editor-background); padding: 20px 24px; box-sizing: border-box;
         overflow: auto; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; }
  h2 { font-size: 13px; font-weight: normal; opacity: .75; margin: 0 0 18px; }
  ul { margin: 0 0 22px; padding-left: 18px; line-height: 1.7; }
  .buttons { display: flex; gap: 10px; margin-bottom: 18px; }
  button { font: inherit; padding: 5px 16px; border: 0; border-radius: 2px; cursor: pointer;
           color: var(--vscode-button-secondaryForeground); background: var(--vscode-button-secondaryBackground); }
  button:hover { background: var(--vscode-button-secondaryHoverBackground); }
  button.primary { color: var(--vscode-button-foreground); background: var(--vscode-button-background); }
  button.primary:hover { background: var(--vscode-button-hoverBackground); }
  label { opacity: .85; }
  p.note { opacity: .7; max-width: 60em; line-height: 1.5; }
  .layout { display: flex; gap: 24px; align-items: flex-start; }
  .layout.stacked { flex-direction: column; }
  .info { flex: 1 1 auto; min-width: 0; }
  .info > :last-child { margin-bottom: 0; }
  figure { margin: 0; flex: none; }
  canvas { display: block; width: 304px; height: 240px; image-rendering: pixelated;
           box-shadow: 0 2px 10px rgba(0, 0, 0, .35); }
  figcaption { opacity: .6; font-size: 12px; margin-top: 6px; }
</style>
</head>
<body>
<div class="layout">
  ${picture ? `<figure><canvas id="screen" width="304" height="240"></canvas>
    <figcaption>${escapeHtml('The screen, from ' + picture.source)}</figcaption></figure>` : ''}
  <div class="info">
  <h1>${escapeHtml(fileName)}</h1>
  <h2>${escapeHtml(title)}</h2>
  <ul>${rows.map((row) => `<li>${row}</li>`).join('')}</ul>
  ${unknown ? '' : `
  <div class="buttons">
    <button class="primary" id="run" title="Reset the emulator, load this and run it">Run</button>
    <button id="debug" title="Reset the emulator, load this and stop at its first instruction">Debug</button>
  </div>
  <label><input type="checkbox" id="auto" ${runOnOpen ? 'checked' : ''}> Run programs as soon as they are opened</label>
  <p class="note">Running a program resets the emulator, and takes the place of any debug session already
  running. The emulator is started if it is not running. A <code>.sld</code> and a source file of the same
  name beside this one (the source may be a folder up) are loaded with it, for stepping through its source.</p>`}
  </div>
</div>
<script nonce="${nonce}">
  const picture = ${picture ? JSON.stringify({ screen: Buffer.from(picture.screen).toString('base64'), border: picture.border }) : 'null'};
  if (picture) {
    // Bright black is black; the rest at two-thirds, bright at full.
    const palette = [[0,0,0],[0,0,192],[192,0,0],[192,0,192],[0,192,0],[0,192,192],[192,192,0],[192,192,192],
                     [0,0,0],[0,0,255],[255,0,0],[255,0,255],[0,255,0],[0,255,255],[255,255,0],[255,255,255]];
    const bytes = Uint8Array.from(atob(picture.screen), (c) => c.charCodeAt(0));
    const canvas = document.getElementById('screen');
    const ctx = canvas.getContext('2d');
    const image = ctx.createImageData(304, 240);
    const border = palette[picture.border & 7];
    for (let i = 0; i < 304 * 240; i++) {
      image.data.set(border, i * 4);
      image.data[i * 4 + 3] = 255;
    }
    for (let y = 0; y < 192; y++) {
      for (let x = 0; x < 256; x++) {
        // The display file's own order: y = 0bYYyyyxxx is byte 0b010YY xxx yyy.
        const at = ((y >> 6) << 11) | ((y & 7) << 8) | (((y >> 3) & 7) << 5) | (x >> 3);
        const attr = bytes[6144 + (y >> 3) * 32 + (x >> 3)];
        const bright = attr & 0x40 ? 8 : 0;
        const set = (bytes[at] >> (7 - (x & 7))) & 1;
        const rgb = palette[set ? (attr & 7) | bright : ((attr >> 3) & 7) | bright];
        image.data.set(rgb, ((y + 24) * 304 + x + 24) * 4);
      }
    }
    ctx.putImageData(image, 0, 0);
  }
  // Side by side or stacked, and how big: whichever layout lets the picture
  // be larger with the details still wholly in view. The details' height is
  // measured in each layout rather than guessed, since it depends on the
  // width the text wraps to.
  const layout = document.querySelector('.layout');
  const figure = document.querySelector('figure');
  const details = document.querySelector('.info');
  const GAP = 24;
  function fit() {
    if (!figure) {
      return;
    }
    const canvas = document.getElementById('screen');
    const body = getComputedStyle(document.body);
    const width = document.body.clientWidth - parseFloat(body.paddingLeft) - parseFloat(body.paddingRight);
    const height = document.body.clientHeight - parseFloat(body.paddingTop) - parseFloat(body.paddingBottom);
    const caption = figure.offsetHeight - canvas.offsetHeight;

    // Beside the picture, the details column is tried at a few widths: a
    // wider column is shorter, which is what lets a short editor still have
    // them side by side.
    layout.classList.remove('stacked');
    let side = 0;
    let sideWidth = 0;
    for (let w = 260; w <= Math.min(620, width - 100); w += 60) {
      details.style.width = w + 'px';
      if (details.offsetHeight > height) {
        continue;
      }
      const scale = Math.min((width - w - GAP) / 304, (height - caption) / 240);
      if (scale > side) {
        side = scale;
        sideWidth = w;
      }
    }
    const sideFits = sideWidth > 0;

    layout.classList.add('stacked');
    details.style.width = '';
    const stacked = Math.min(width / 304, (height - caption - GAP - details.offsetHeight) / 240);

    let scale;
    if (sideFits && side >= stacked && side > 0.3) {
      layout.classList.remove('stacked');
      details.style.width = sideWidth + 'px';
      scale = side;
    } else if (stacked > 0.3) {
      scale = stacked;
    } else {
      // Too small for both: the details stay whole, and the page scrolls to
      // a picture kept just big enough to make out.
      scale = Math.min(width / 304, 0.5);
    }
    canvas.style.width = Math.floor(304 * scale) + 'px';
    canvas.style.height = Math.floor(240 * scale) + 'px';
  }
  fit();
  new ResizeObserver(fit).observe(document.body);

  const vscode = acquireVsCodeApi();
  for (const id of ['run', 'debug']) {
    const button = document.getElementById(id);
    if (button) button.addEventListener('click', () => vscode.postMessage({ type: id }));
  }
  const auto = document.getElementById('auto');
  if (auto) auto.addEventListener('change', () => vscode.postMessage({ type: 'auto', on: auto.checked }));
</script>
</body>
</html>`;
}

class ProgramEditorProvider {
  openCustomDocument(uri) {
    return { uri, dispose() {} };
  }

  async resolveCustomEditor(document, panel) {
    const uri = document.uri;
    const fileName = path.basename(uri.fsPath);
    let bytes;
    try {
      bytes = fs.readFileSync(uri.fsPath);
    } catch (err) {
      bytes = Buffer.alloc(0);
    }
    // Assembly source that happens to be called .z80: the text editor's.
    if (/\.z80$/i.test(fileName) && info.looksLikeText(bytes)) {
      await vscode.commands.executeCommand('vscode.openWith', uri, 'default', panel.viewColumn);
      panel.dispose();
      return;
    }
    const described = bytes.length ? info.describeProgram(fileName, bytes)
      : { kind: 'unknown', problem: 'The file could not be read, or is empty.' };
    const config = vscode.workspace.getConfiguration('zxspectrum');
    panel.webview.options = { enableScripts: true };
    const picture = described.kind === 'unknown' ? null : info.programScreen(fileName, bytes);
    panel.webview.html = pageHtml(fileName, described, config.get('program.runOnOpen', false), picture);
    panel.webview.onDidReceiveMessage((message) => {
      if (message.type === 'run') {
        runProgram(uri, false);
      } else if (message.type === 'debug') {
        runProgram(uri, true);
      } else if (message.type === 'auto') {
        config.update('program.runOnOpen', message.on === true, vscode.ConfigurationTarget.Global);
      }
    });
    if (described.kind !== 'unknown' && config.get('program.runOnOpen', false)) {
      runProgram(uri, false);
    }
  }
}

// Continues a session launched with stopOnEntry: false from the stop the
// server makes on entry -- once, and only that one.
function trackStopOnEntry() {
  return vscode.debug.registerDebugAdapterTrackerFactory('zxspectrum', {
    createDebugAdapterTracker(session) {
      if (session.configuration.stopOnEntry !== false) {
        return undefined;
      }
      let done = false;
      return {
        onDidSendMessage(message) {
          if (done || !message || message.type !== 'event' || message.event !== 'stopped') {
            return;
          }
          done = true;
          if (message.body && message.body.reason === 'entry') {
            session.customRequest('continue', { threadId: message.body.threadId || 1 }).then(
              () => {}, () => {});
          }
        }
      };
    }
  });
}

function activatePrograms(context) {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(VIEW_TYPE, new ProgramEditorProvider(), {
      supportsMultipleEditorsPerDocument: true
    }),
    vscode.commands.registerCommand('zxspectrum.runProgram', (uri) => {
      const target = uri instanceof vscode.Uri ? uri : undefined;
      if (target) {
        runProgram(target, false);
      }
    }),
    vscode.commands.registerCommand('zxspectrum.debugProgram', (uri) => {
      const target = uri instanceof vscode.Uri ? uri : undefined;
      if (target) {
        runProgram(target, true);
      }
    }),
    trackStopOnEntry()
  );
}

module.exports = { activatePrograms, romCandidates };
