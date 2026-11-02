// The pure half of the second target: retro-spectrum's SpecNext board, an FPGA
// 48K driven through its bridge, tools/zx_bridge.py in jonsole/retro-spectrum.
// The bridge owns the board's FT232H link and serves zx_server's own three
// front ends -- DAP, MCP and the screen stream -- on ports of its own, and
// advertises itself in the same registry with "target": "specnext" and the list of
// what it can do (server_registry.js's CAPABILITIES). So the extension drives
// the board as it drives the emulator: this says how the bridge is started,
// when it is ready, and what a launch for the board becomes.
//
// The bridge lives in retro-spectrum and is never copied here; the setting
// says where it is. No vscode API, so it is tested from plain Node
// (node tests/board_target_test.js); board_view.js does the starting.

'use strict';

const launch = require('./server_launch');

const TARGETS = ['emulator', 'specnext'];
const BOARD_TARGET = 'specnext';
// What a bridge's advert and serverInfo may call it: "specnext", and "ks2",
// what the bridge called the board until it was renamed.
const BOARD_ADVERT_TARGETS = [BOARD_TARGET, 'ks2'];
const BOARD_LABEL = 'SpecNext';
const DEFAULT_BOARD_PORTS = { dap: 4712, mcp: 8001, screen: 8502 };
// The board's serial port: "auto" has the bridge find the FT232H by its USB
// VID:PID, 0403:6014, and use it if there is exactly one.
const DEFAULT_SERIAL_PORT = 'auto';

// What the bridge prints, once, when all three ports are bound:
//   zx_bridge: on COM3: DAP 4712, MCP 8001, screen 8502
// on stdout and flushed, even with --quiet; everything else it says is on
// stderr. A fatal start is one stderr line starting "zx_bridge: " and exit 1.
const READY_LINE = /^zx_bridge: on (\S+): DAP (\d+)/m;

function clampPort(value, fallback) {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) && n >= 1 && n <= 65535 ? n : fallback;
}

// The board settings, zxspectrum.board.*, each with its default. `get` reads
// one by its name under zxspectrum.board.
function boardSettings(get) {
  const ports = get('ports') || {};
  const text = (key, fallback) => {
    const value = get(key);
    return typeof value === 'string' ? value.trim() : fallback;
  };
  return {
    bridge: text('bridge', ''),
    python: text('python', '') || 'python',
    port: text('port', '') || DEFAULT_SERIAL_PORT,
    // Unset is "auto", the bridge's own search for a capture device; set
    // empty, no picture.
    capture: text('capture', 'auto'),
    ports: {
      dap: clampPort(ports.dap, DEFAULT_BOARD_PORTS.dap),
      mcp: clampPort(ports.mcp, DEFAULT_BOARD_PORTS.mcp),
      screen: clampPort(ports.screen, DEFAULT_BOARD_PORTS.screen)
    }
  };
}

// How to start the bridge: { command, args }, or { error } saying what is
// missing. The setting is zx_bridge.py, run with the python setting, or
// anything else, run as it is -- a wrapper, an installed script. ${workspaceFolder},
// ${userHome} and ~ are filled in as the server's own path setting has them.
function bridgeCommand(settings, workspaceFolder, home) {
  if (!settings.bridge) {
    return { error: 'zxspectrum.board.bridge is not set. Point it at tools/zx_bridge.py in your ' +
                    'retro-spectrum checkout.' };
  }
  const bridge = launch.expandVariables(settings.bridge, workspaceFolder, home);
  if (!bridge) {
    return { error: `zxspectrum.board.bridge (${settings.bridge}) names \${workspaceFolder}, and no folder is open.` };
  }
  const args = ['--port', settings.port];
  if (settings.capture) {
    args.push('--capture', settings.capture);
  }
  args.push('--dap-port', String(settings.ports.dap),
            '--mcp-port', String(settings.ports.mcp),
            '--screen-port', String(settings.ports.screen));
  if (/\.py$/i.test(bridge)) {
    return { command: settings.python, args: [bridge].concat(args), script: bridge };
  }
  return { command: bridge, args: args, script: null };
}

// Whether what the bridge has printed so far says it is ready: the serial
// port and DAP port it is on, or null.
function readyIn(text) {
  const found = READY_LINE.exec(String(text || ''));
  return found ? { serial: found[1], dap: Number(found[2]) } : null;
}

// The last thing the bridge said about why it stopped: its last line that
// starts "zx_bridge:", or failing that its last line of all.
function bridgeComplaint(text) {
  const lines = String(text || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].indexOf('zx_bridge:') === 0) {
      return lines[i];
    }
  }
  return lines.length ? lines[lines.length - 1] : null;
}

// Which machine a launch is for: its own "target", or else the one the
// status bar has chosen. Anything but the two names is an error.
function targetOf(config, chosen) {
  const asked = config && config.target !== undefined ? config.target : chosen;
  if (asked === undefined || asked === null || asked === '') {
    return { target: 'emulator' };
  }
  if (TARGETS.indexOf(asked) < 0) {
    return { error: `"target" must be "emulator" or "specnext", not ${JSON.stringify(asked)}` };
  }
  return { target: asked };
}

// What is on the board's port: the bridge asks it, and says in its advert and
// serverInfo which CPU core and which machine the loaded bitstream is --
// "cpu" and "machine", by these names. Until it has said (no bridge running
// yet, or one from before it could), the board is taken to be what it was
// built as first: a Z80 in a 48K Spectrum.
const CPU_NAMES = { z80: 'Z80', '68000': '68000', 6502: '6502' };
const MACHINE_NAMES = {
  '48k': 'ZX Spectrum 48K', '128k': 'ZX Spectrum 128', '+2a': 'ZX Spectrum +2A',
  timex2068: 'Timex TC2068', next: 'ZX Spectrum Next',
  // The same KS2 board with another bitstream on it: retro-z80's bare Z80
  // system and retro68k. The bridge says what they are and debugs neither.
  'retro-z80': 'retro-z80 (a bare Z80 system)', retro68k: 'retro68k'
};
// The machines a Spectrum program is for, and those that run a 128K one:
// the paging, the AY, the 32K ROM.
const SPECTRUMS = ['48k', '128k', '+2a', 'timex2068', 'next'];
const RUNS_128 = ['128k', '+2a', 'next'];
const ASSUMED = { cpu: 'z80', machine: '48k' };

// The board's CPU and machine, from its advert or serverInfo (or null for
// none yet), with what is assumed in place of what it has not said.
//
// A bridge that has asked and been answered with a tag it has no name for
// sends the tag alone, as machine_tag: that board is something, just not
// something known, and is not taken for a 48K.
function boardIdentity(server) {
  const said = server || {};
  if (!said.cpu && !said.machine && said.machineTag) {
    return { cpu: null, machine: null, known: true, tag: said.machineTag };
  }
  return {
    cpu: said.cpu || ASSUMED.cpu,
    machine: said.machine || ASSUMED.machine,
    known: !!(said.cpu || said.machine),
    tag: said.machineTag || null
  };
}

// The board in words: "ZX Spectrum 48K, Z80".
function describeBoard(server) {
  const id = boardIdentity(server);
  if (!id.cpu && !id.machine) {
    return `a machine the bridge has no name for ('${id.tag}')`;
  }
  return (MACHINE_NAMES[id.machine] || id.machine) + ', ' + (CPU_NAMES[id.cpu] || id.cpu) +
    (id.known ? '' : ' (assumed)');
}

// Why a program for a Spectrum -- a Z80, 48K or 128K -- cannot run on the
// board, or null if it can.
function identityRefusal(server, needs128) {
  const id = boardIdentity(server);
  if (!id.cpu && !id.machine) {
    return `the board is ${describeBoard(server)}, not a Spectrum`;
  }
  if (id.cpu !== 'z80') {
    return `the board is running a ${CPU_NAMES[id.cpu] || id.cpu}, not a Z80`;
  }
  if (SPECTRUMS.indexOf(id.machine) < 0) {
    return `the board is ${MACHINE_NAMES[id.machine] || id.machine}, not a Spectrum`;
  }
  if (needs128 && RUNS_128.indexOf(id.machine) < 0) {
    return `it needs a 128K, and the board is a ${MACHINE_NAMES[id.machine] || id.machine}`;
  }
  return null;
}

// Why a launch cannot go to the board, or null if it can: a launch asking
// for the 128 on a 48K, or anything on a board that is not a Z80. Refused
// here, before anything is connected, with words a person can act on. The
// bridge refuses one too -- this is so the refusal says what to do.
function boardRefusal(config, server) {
  const why = identityRefusal(server, !!config && String(config.machine || '') === '128');
  return why ? `This cannot run on the SpecNext: ${why}. Run it on the emulator instead.` : null;
}

// Whether a program described by program_info.describeProgram can run on
// the board, and if not why.
function boardCanRun(described, server) {
  if (!described || described.kind === 'unknown') {
    return { ok: false, why: 'it is not a snapshot or a tape' };
  }
  const why = identityRefusal(server, described.needs128);
  return why ? { ok: false, why: why } : { ok: true, why: null };
}

// A launch configuration for the board, from one for the emulator: the same,
// with the target said, and without what the board has no use for -- a ROM
// (the board has its own) and a server's ports.
function boardLaunchConfig(config) {
  const out = Object.assign({}, config, { target: BOARD_TARGET });
  delete out.rom;
  delete out.ports;
  if (typeof out.name === 'string') {
    out.name = out.name.replace(/^ZX Spectrum:/, BOARD_LABEL + ':');
  }
  return out;
}

// The bridge among the servers advertised on this machine, newest first, or
// null.
function isBoard(server) {
  return !!server && BOARD_ADVERT_TARGETS.indexOf(server.target) >= 0;
}

function advertisedBoard(servers) {
  for (const server of servers || []) {
    if (isBoard(server)) {
      return server;
    }
  }
  return null;
}

module.exports = {
  TARGETS, BOARD_TARGET, BOARD_LABEL, DEFAULT_BOARD_PORTS, DEFAULT_SERIAL_PORT,
  boardSettings, bridgeCommand, readyIn, bridgeComplaint, targetOf, boardRefusal,
  boardCanRun, boardLaunchConfig, advertisedBoard, isBoard, boardIdentity, describeBoard
};
