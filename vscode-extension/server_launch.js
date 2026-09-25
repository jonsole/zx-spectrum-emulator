// The pure half of starting the emulator from the extension: where
// zx_server is, which directory it runs in, and what it is told. No vscode
// API, so it is tested from plain Node (node tests/server_launch_test.js);
// server_view.js does the starting, stopping and showing.

'use strict';

const path = require('path');

const DEFAULT_PORTS = { dap: 4711, mcp: 8000, screen: 8500, audio: 8501 };
const SOUND_MODES = ['device', 'panel', 'off'];

function exeName(platform) {
  return platform === 'win32' ? 'zx_server.exe' : 'zx_server';
}

// ${workspaceFolder}, ${userHome} and a leading ~ in a path setting, the way
// VS Code's own settings read them. A path with a variable that cannot be
// filled (no folder open) comes back as null rather than half-expanded.
function expandVariables(text, workspaceFolder, home) {
  let out = String(text || '').trim();
  if (!out) {
    return null;
  }
  if (out.includes('${workspaceFolder}')) {
    if (!workspaceFolder) {
      return null;
    }
    out = out.split('${workspaceFolder}').join(workspaceFolder);
  }
  out = out.split('${userHome}').join(home);
  if (out === '~' || out.startsWith('~/') || out.startsWith('~\\')) {
    out = home + out.slice(1);
  }
  return out;
}

// Where to look for the server, in order: the setting, then each workspace
// folder's own RelWithDebInfo build (so this repository needs no setup at
// all), then the one a release bundles in the extension's own bin/ (`bundled`,
// that directory), then every directory on PATH. The bundled one comes after
// a checkout's build on purpose: working on the emulator means running what
// you just built, not what was released.
function serverCandidates({ setting, folders, pathEnv, platform, home, bundled }) {
  const name = exeName(platform);
  const candidates = [];
  const configured = expandVariables(setting, folders[0], home);
  if (configured) {
    candidates.push(configured);
  }
  for (const folder of folders) {
    candidates.push(path.join(folder, 'cpp-core', 'build', 'RelWithDebInfo', name));
  }
  if (bundled) {
    candidates.push(path.join(bundled, name));
  }
  const separator = platform === 'win32' ? ';' : ':';
  for (const dir of String(pathEnv || '').split(separator)) {
    if (dir.trim()) {
      candidates.push(path.join(dir.trim(), name));
    }
  }
  return { candidates, configured };
}

function findServer(candidates, exists) {
  for (const candidate of candidates) {
    if (exists(candidate)) {
      return candidate;
    }
  }
  return null;
}

// The directory the server runs in, which is where it looks for
// rom_disassembly/ and where relative paths from an MCP client land. A build
// inside a checkout (…/cpp-core/build/<config>/zx_server) runs from the
// checkout's root, as the repository's own tasks do; anything else from the
// first workspace folder, or failing that its own directory.
function serverRoot(exe, folders) {
  const parts = path.resolve(exe).split(path.sep);
  const at = parts.length - 4;
  if (at > 0 && parts[at].toLowerCase() === 'cpp-core' && parts[at + 1].toLowerCase() === 'build') {
    return parts.slice(0, at).join(path.sep) || path.sep;
  }
  return folders[0] || path.dirname(exe);
}

function clampPort(value, fallback) {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) && n >= 1 && n <= 65535 ? n : fallback;
}

// The four ports from the settings, each falling back to its default.
function serverPorts(get) {
  return {
    dap: clampPort(get('dapPort'), DEFAULT_PORTS.dap),
    mcp: clampPort(get('mcpPort'), DEFAULT_PORTS.mcp),
    screen: clampPort(get('screenPort'), DEFAULT_PORTS.screen),
    audio: clampPort(get('audioPort'), DEFAULT_PORTS.audio)
  };
}

// The ROMs to load: the setting's, or else roms/48.rom and roms/128.rom --
// each from beside the server's root when it is there, and otherwise from the
// ones a release bundles in the extension's own roms/ (`bundled`, that
// directory). A launch configuration's own `rom` still wins for its session;
// these are what an attach, or a snapshot opened from the Explorer, boots
// with.
function serverRoms(setting, root, home, exists, bundled) {
  const listed = Array.isArray(setting) ? setting : [];
  if (listed.length > 0) {
    return listed.map((rom) => expandVariables(rom, root, home)).filter(Boolean);
  }
  const roms = [];
  for (const name of ['48.rom', '128.rom']) {
    const own = path.join(root, 'roms', name);
    if (exists(own)) {
      roms.push(own);
    } else if (bundled && exists(path.join(bundled, name))) {
      roms.push(path.join(bundled, name));
    }
  }
  return roms;
}

// The command line. Sound is one of three: out of the host's sound card (the
// audio stream server is then not started, so the screen panel does not play
// it a second time), through the screen panel, or not at all.
function serverArgs({ ports, sound, roms, extra }) {
  const args = [
    '--dap-port', String(ports.dap),
    '--mcp-port', String(ports.mcp),
    '--screen-port', String(ports.screen),
    '--audio-port', String(ports.audio)
  ];
  const mode = SOUND_MODES.includes(sound) ? sound : 'device';
  if (mode === 'device') {
    args.push('--audio-device', '--no-audio');
  } else if (mode === 'off') {
    args.push('--no-audio');
  }
  for (const rom of roms || []) {
    args.push('--rom', rom);
  }
  for (const arg of Array.isArray(extra) ? extra : []) {
    args.push(String(arg));
  }
  return args;
}

// `netstat -ano` output -> the PID listening on a TCP port, or null. Used to
// stop a server the extension did not start itself (one from a task, say).
function pidListeningOn(netstatText, port) {
  for (const line of String(netstatText).split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== 'TCP' || cols[3] !== 'LISTENING') {
      continue;
    }
    const local = cols[1];
    if (local.slice(local.lastIndexOf(':') + 1) === String(port)) {
      const pid = Number(cols[4]);
      if (Number.isInteger(pid) && pid > 0) {
        return pid;
      }
    }
  }
  return null;
}

module.exports = {
  DEFAULT_PORTS, SOUND_MODES, exeName, expandVariables, serverCandidates, findServer,
  serverRoot, serverPorts, serverRoms, serverArgs, pidListeningOn
};
