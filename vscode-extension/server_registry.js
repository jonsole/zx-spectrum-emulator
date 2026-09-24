// Finding every zx_server on this machine, from the adverts they write.
//
// Each server writes `<pid>.json` into one directory once all its ports are
// bound (cpp-core/src/server_registry.h): its pid, the ports it is really on,
// when it started and the program it last loaded. A server that is killed
// outright cannot remove its own, so an advert is a claim to check -- the
// process has to be alive -- and one that fails is deleted here.
//
// No vscode API, so it is tested from plain Node
// (node tests/server_registry_test.js); server_view.js and extension.js do
// the connecting and showing.

'use strict';

const path = require('path');

const ADVERT_VERSION = 1;

// Where adverts are, worked out exactly as the server works it out:
// $ZX_SERVER_ADVERT_DIR, else %LOCALAPPDATA%\zx-spectrum\servers on Windows
// and $XDG_RUNTIME_DIR (or ~/.cache)/zx-spectrum/servers elsewhere.
function advertDirectory({ env, platform, home, tmp }) {
  if (env.ZX_SERVER_ADVERT_DIR) {
    return env.ZX_SERVER_ADVERT_DIR;
  }
  let base;
  if (platform === 'win32') {
    base = env.LOCALAPPDATA;
  } else {
    base = env.XDG_RUNTIME_DIR || (home ? path.join(home, '.cache') : '');
  }
  return path.join(base || tmp, 'zx-spectrum', 'servers');
}

function validPort(value) {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}

// One advert's text -> a server, or null when it is not one this reads: bad
// JSON, a newer layout, or no usable DAP and screen port. `audio` is null
// when the server streams no sound.
function parseAdvert(text) {
  let info;
  try {
    info = JSON.parse(text);
  } catch (err) {
    return null;
  }
  if (!info || typeof info !== 'object' || info.version !== ADVERT_VERSION) {
    return null;
  }
  const ports = info.ports || {};
  if (!Number.isInteger(info.pid) || !validPort(ports.dap) || !validPort(ports.screen)) {
    return null;
  }
  return {
    pid: info.pid,
    host: typeof info.host === 'string' && info.host ? info.host : '127.0.0.1',
    ports: {
      dap: ports.dap,
      mcp: validPort(ports.mcp) ? ports.mcp : null,
      screen: ports.screen,
      audio: validPort(ports.audio) ? ports.audio : null
    },
    started: typeof info.started === 'string' ? info.started : '',
    program: typeof info.program === 'string' && info.program ? info.program : null,
    exe: typeof info.exe === 'string' ? info.exe : '',
    cwd: typeof info.cwd === 'string' ? info.cwd : '',
    audioDevice: info.audioDevice === true
  };
}

// Whether a process is still there. Signal 0 checks without sending
// anything; EPERM means it exists but belongs to someone else.
function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

// Every live server advertised in `dir`, newest first. Adverts whose process
// has gone are deleted, and so are leftovers a writer abandoned (`.tmp`).
// `io` is { readdir, readFile, unlink, alive }, so the test can stand in for
// the disk and the process table.
function liveServers(dir, io) {
  let names;
  try {
    names = io.readdir(dir);
  } catch (err) {
    return [];
  }
  const servers = [];
  for (const name of names) {
    const file = path.join(dir, name);
    const match = /^(\d+)\.json(\.tmp)?$/.exec(name);
    if (!match) {
      continue;
    }
    const pid = Number(match[1]);
    if (!io.alive(pid)) {
      try {
        io.unlink(file);
      } catch (err) {
        // Someone else tidied it first, or it is locked; either way it is
        // not a server.
      }
      continue;
    }
    if (match[2]) {
      continue; // being written right now
    }
    let text;
    try {
      text = io.readFile(file);
    } catch (err) {
      continue;
    }
    const server = parseAdvert(text);
    // The file's name is the pid that wrote it: one that disagrees is not
    // to be trusted with the other's ports.
    if (server && server.pid === pid) {
      servers.push(server);
    }
  }
  servers.sort((a, b) => (a.started < b.started ? 1 : a.started > b.started ? -1 : b.pid - a.pid));
  return servers;
}

// A short name for a server: what it is running and where. The program's
// file name when it has one, else the ROM it booted.
function describeServer(server) {
  const program = server.program ? path.basename(server.program.replace(/\\/g, '/')) : 'ROM';
  return `${program} on :${server.ports.dap}`;
}

// The longer line under it in a list.
function detailServer(server) {
  const parts = [`pid ${server.pid}`, `screen :${server.ports.screen}`];
  if (server.ports.mcp) {
    parts.push(`MCP :${server.ports.mcp}`);
  }
  parts.push(server.ports.audio ? `audio :${server.ports.audio}` : 'no audio stream');
  if (server.started) {
    parts.push(`started ${server.started.replace('T', ' ').replace('Z', ' UTC')}`);
  }
  return parts.join(' · ');
}

// Whether two descriptions are the same server: the same process, or the
// same DAP port when either side has no pid to go by (a server too old to
// answer serverInfo is known by the ports in the settings alone).
function sameServer(a, b) {
  if (!a || !b) {
    return false;
  }
  if (a.pid && b.pid) {
    return a.pid === b.pid;
  }
  return a.ports.dap === b.ports.dap;
}

// A serverInfo body (the same shape as an advert) -> a server, or null.
function fromServerInfo(body) {
  return body ? parseAdvert(JSON.stringify(body)) : null;
}

// What a launch configuration's `ports` asks for:
//   undefined          -> null: the server in the settings, as ever
//   "auto"             -> { auto: true }: a new server on free ports, just
//                         for this session
//   { dap, mcp, ... }  -> { ports }: that server, each missing port from the
//                         settings (`defaults`)
// Anything else is an error message.
function launchPorts(value, defaults) {
  if (value === undefined || value === null) {
    return { request: null };
  }
  if (value === 'auto') {
    return { request: { auto: true } };
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    return { error: '"ports" must be "auto" or an object of ports ({ "dap": 14711, ... })' };
  }
  const ports = Object.assign({}, defaults);
  for (const key of ['dap', 'mcp', 'screen', 'audio']) {
    if (value[key] === undefined) {
      continue;
    }
    if (!validPort(value[key])) {
      return { error: `"ports.${key}" must be a port number from 1 to 65535` };
    }
    ports[key] = value[key];
  }
  return { request: { ports } };
}

module.exports = {
  ADVERT_VERSION, advertDirectory, parseAdvert, processAlive, liveServers, describeServer,
  detailServer, sameServer, fromServerInfo, launchPorts
};
