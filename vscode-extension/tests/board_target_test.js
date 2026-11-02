// Tests for board_target.js -- the SpecNext board as a second target -- and for
// the registry's reading of a bridge's advert. Plain Node, no vscode API:
//
//   node vscode-extension/tests/board_target_test.js
//
// The advert and the ready line are the layouts retro-spectrum's bridge,
// tools/zx_bridge.py, writes (its docs/spec/bridge.md).

const assert = require('assert');
const b = require('../board_target');
const r = require('../server_registry');

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

const BRIDGE_ADVERT = JSON.stringify({
  version: 1, pid: 4321, host: '127.0.0.1',
  ports: { dap: 4712, mcp: 8001, screen: 8502, audio: null },
  started: '2026-11-01T18:00:00Z', label: 'SpecNext', target: 'specnext',
  capabilities: ['debug', 'breakpoints', 'watchpoints', 'memory', 'snapshots', 'tape', 'keys', 'screen']
});

test('a bridge\'s advert says it drives the board, and what it can do', () => {
  const server = r.parseAdvert(BRIDGE_ADVERT);
  assert.strictEqual(server.target, 'specnext');
  assert.strictEqual(server.label, 'SpecNext');
  assert.strictEqual(server.ports.audio, null);
  assert.ok(r.serverCan(server, 'watchpoints'));
  assert.ok(r.serverCan(server, 'screen'));
  for (const cannot of ['rewind', 'profile', 'trace', 'audio', 'speed', 'graphics', 'logpoints',
                        'paging', 'overlay']) {
    assert.ok(!r.serverCan(server, cannot), cannot);
  }
});

test('a server that lists nothing is the emulator, and can do everything', () => {
  const server = r.parseAdvert(JSON.stringify({ version: 1, pid: 7, ports: { dap: 4711, screen: 8500 } }));
  assert.strictEqual(server.target, 'emulator');
  assert.strictEqual(server.capabilities, null);
  for (const c of r.CAPABILITIES) assert.ok(r.serverCan(server, c), c);
  assert.ok(r.serverCan(null, 'rewind'), 'nor does one not known yet hide anything');
});

test('the settings fall back to finding the board, and the bridge\'s own ports', () => {
  const s = b.boardSettings(() => undefined);
  assert.deepStrictEqual(s, { bridge: '', python: 'python', port: 'auto', capture: 'auto',
                              ports: { dap: 4712, mcp: 8001, screen: 8502 } });
  const t = b.boardSettings((k) => ({ port: ' COM7 ', ports: { dap: 5000, mcp: 'x' } })[k]);
  assert.strictEqual(t.port, 'COM7');
  assert.deepStrictEqual(t.ports, { dap: 5000, mcp: 8001, screen: 8502 });
});

test('zx_bridge.py runs with python, and the arguments are the bridge\'s', () => {
  const s = b.boardSettings((k) => ({ bridge: '${workspaceFolder}/../retro-spectrum/tools/zx_bridge.py',
                                      capture: 'auto' })[k]);
  const c = b.bridgeCommand(s, 'C:/ws/zx', 'C:/Users/me');
  assert.strictEqual(c.command, 'python');
  assert.deepStrictEqual(c.args, ['C:/ws/zx/../retro-spectrum/tools/zx_bridge.py', '--port', 'auto',
    '--capture', 'auto', '--dap-port', '4712', '--mcp-port', '8001', '--screen-port', '8502']);
});

test('no capture device is no --capture; anything not .py runs as it is', () => {
  const s = b.boardSettings((k) => ({ bridge: '~/bin/specnext-bridge.cmd', capture: '' })[k]);
  const c = b.bridgeCommand(s, null, 'C:/Users/me');
  assert.strictEqual(c.command, 'C:/Users/me/bin/specnext-bridge.cmd');
  assert.ok(c.args.indexOf('--capture') < 0);
  assert.ok(/not set/.test(b.bridgeCommand(b.boardSettings(() => undefined), null, '').error));
  assert.ok(/no folder is open/.test(b.bridgeCommand(
    b.boardSettings((k) => ({ bridge: '${workspaceFolder}/x.py' })[k]), null, '').error));
});

test('ready is the bridge\'s line, wherever in its output it comes', () => {
  assert.strictEqual(b.readyIn('starting...\n'), null);
  assert.deepStrictEqual(b.readyIn('opening\nzx_bridge: on COM3: DAP 4712, MCP 8001, screen 8502\n'),
                         { serial: 'COM3', dap: 4712 });
});

test('the reason a bridge gives for stopping is its last zx_bridge: line', () => {
  assert.strictEqual(b.bridgeComplaint('a\nzx_bridge: COM3 is busy\nTraceback\n  x\n'), 'zx_bridge: COM3 is busy');
  assert.strictEqual(b.bridgeComplaint('just this\n'), 'just this');
  assert.strictEqual(b.bridgeComplaint(''), null);
});

test('a launch goes where it says, or where the status bar points', () => {
  assert.deepStrictEqual(b.targetOf({}, undefined), { target: 'emulator' });
  assert.deepStrictEqual(b.targetOf({}, 'specnext'), { target: 'specnext' });
  assert.deepStrictEqual(b.targetOf({ target: 'emulator' }, 'specnext'), { target: 'emulator' });
  assert.ok(b.targetOf({ target: 'next' }, 'specnext').error);
});

test('the board is a 48K: a 128 launch or program is refused, with why', () => {
  assert.ok(/48K/.test(b.boardRefusal({ machine: '128' })));
  assert.strictEqual(b.boardRefusal({ machine: '48' }), null);
  assert.strictEqual(b.boardRefusal({}), null);
  assert.deepStrictEqual(b.boardCanRun({ kind: 'snapshot', needs128: false }), { ok: true, why: null });
  assert.ok(!b.boardCanRun({ kind: 'snapshot', needs128: true }).ok);
});

test('the bridge says what is on the port: CPU and machine', () => {
  const next = r.parseAdvert(BRIDGE_ADVERT.replace('"label"', '"cpu":"z80","machine":"next","label"'));
  assert.strictEqual(next.cpu, 'z80');
  assert.strictEqual(next.machine, 'next');
  assert.strictEqual(b.describeBoard(next), 'ZX Spectrum Next, Z80');
  // Until it says, a 48K Z80, and the words say it is assumed.
  assert.strictEqual(b.describeBoard(null), 'ZX Spectrum 48K, Z80 (assumed)');
  assert.deepStrictEqual(b.boardIdentity(r.parseAdvert(BRIDGE_ADVERT)), { cpu: 'z80', machine: '48k', known: false, tag: null });
});

test('a 128K program runs on a board that is a 128, and nothing runs on another CPU', () => {
  const as = (cpu, machine) => ({ cpu: cpu, machine: machine });
  const program128 = { kind: 'snapshot', needs128: true };
  assert.ok(b.boardCanRun(program128, as('z80', '128k')).ok);
  assert.ok(b.boardCanRun(program128, as('z80', 'next')).ok);
  assert.ok(/Timex TC2068/.test(b.boardCanRun(program128, as('z80', 'timex2068')).why));
  assert.strictEqual(b.boardRefusal({ machine: '128' }, as('z80', '+2a')), null);
  const on68k = b.boardCanRun({ kind: 'tape', needs128: false }, as('68000', null));
  assert.ok(!on68k.ok && /68000, not a Z80/.test(on68k.why));
  assert.ok(/not a Z80/.test(b.boardRefusal({}, as('6502', 'next'))));
});

test('another bitstream on the board is named, and Spectrum programs are refused', () => {
  // What the bridge sends for retro-z80's bitstream, tag and all.
  const z80 = r.parseAdvert(BRIDGE_ADVERT.replace('"label"',
    '"cpu":"z80","machine":"retro-z80","machine_tag":"Z80 ","label"'));
  assert.strictEqual(z80.machineTag, 'Z80 ');
  assert.ok(/retro-z80 \(a bare Z80 system\), Z80/.test(b.describeBoard(z80)));
  assert.ok(/not a Spectrum/.test(b.boardCanRun({ kind: 'snapshot', needs128: false }, z80).why));
  // A tag it has no name for: known to be something, so not taken for a 48K.
  const odd = r.parseAdvert(BRIDGE_ADVERT.replace('"label"', '"machine_tag":"QL  ","label"'));
  assert.strictEqual(b.describeBoard(odd), 'a machine the bridge has no name for (\'QL  \')');
  assert.ok(/not a Spectrum/.test(b.boardRefusal({}, odd)));
  // What this board is today.
  const zx48 = r.parseAdvert(BRIDGE_ADVERT.replace('"label"', '"cpu":"z80","machine":"48k","machine_tag":"ZX48","label"'));
  assert.strictEqual(b.describeBoard(zx48), 'ZX Spectrum 48K, Z80');
  assert.ok(b.boardCanRun({ kind: 'tape', needs128: false }, zx48).ok);
});

test('a launch for the board is the emulator\'s, less its ROM and ports', () => {
  const config = { type: 'zxspectrum', request: 'launch', name: 'ZX Spectrum: game.sna',
                   rom: 'roms/48.rom', snapshot: 'game.sna', ports: 'auto', stopOnEntry: false };
  assert.deepStrictEqual(b.boardLaunchConfig(config), { type: 'zxspectrum', request: 'launch',
    name: 'SpecNext: game.sna', snapshot: 'game.sna', stopOnEntry: false, target: 'specnext' });
  assert.strictEqual(config.rom, 'roms/48.rom', 'the one it was given changed');
});

test('the bridge is found among the servers by its target', () => {
  const emulator = r.parseAdvert(JSON.stringify({ version: 1, pid: 7, ports: { dap: 4711, screen: 8500 } }));
  const board = r.parseAdvert(BRIDGE_ADVERT);
  assert.strictEqual(b.advertisedBoard([emulator, board]), board);
  assert.strictEqual(b.advertisedBoard([emulator]), null);
  // ...and by the name the bridge gave it before it was SpecNext.
  const old = r.parseAdvert(BRIDGE_ADVERT.replace('"target":"specnext"', '"target":"ks2"'));
  assert.strictEqual(old.target, 'ks2');
  assert.strictEqual(b.advertisedBoard([emulator, old]), old);
  assert.ok(b.isBoard(old) && b.isBoard(board) && !b.isBoard(emulator) && !b.isBoard(null));
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
