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

function pageHtml(fileName, described, runOnOpen) {
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
  body { font: 13px var(--vscode-font-family, system-ui, sans-serif); color: var(--vscode-foreground);
         background: var(--vscode-editor-background); padding: 28px 32px; }
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
</style>
</head>
<body>
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
  name beside this one are loaded with it, for stepping through its source.</p>`}
<script nonce="${nonce}">
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
    panel.webview.html = pageHtml(fileName, described, config.get('program.runOnOpen', false));
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

module.exports = { activatePrograms };
