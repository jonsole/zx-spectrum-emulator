// Tests for server_launch.js -- finding and starting the emulator from the
// extension. Plain Node, no vscode API and no test framework:
//
//   node vscode-extension/tests/server_launch_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/server_launch_test.js)

const assert = require('assert');
const path = require('path');
const s = require('../server_launch');

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

const HOME = path.join(path.sep, 'home', 'me');
const REPO = path.join(path.sep, 'src', 'zx');

test('path settings expand the way VS Code does', () => {
  assert.strictEqual(s.expandVariables('${workspaceFolder}/bin/zx_server', REPO, HOME),
                     REPO + '/bin/zx_server');
  assert.strictEqual(s.expandVariables('~/zx/zx_server', REPO, HOME), HOME + '/zx/zx_server');
  assert.strictEqual(s.expandVariables('${userHome}/zx', REPO, HOME), HOME + '/zx');
  assert.strictEqual(s.expandVariables('${workspaceFolder}/x', undefined, HOME), null);
  assert.strictEqual(s.expandVariables('   ', REPO, HOME), null);
});

test('the setting is tried first, then each folder\'s build, then PATH', () => {
  const found = s.serverCandidates({
    setting: '~/custom/zx_server.exe', folders: [REPO, path.join(path.sep, 'other')],
    pathEnv: 'C:\\tools;;C:\\bin', platform: 'win32', home: HOME
  });
  assert.deepStrictEqual(found.candidates, [
    HOME + '/custom/zx_server.exe',
    path.join(REPO, 'cpp-core', 'build', 'RelWithDebInfo', 'zx_server.exe'),
    path.join(path.sep, 'other', 'cpp-core', 'build', 'RelWithDebInfo', 'zx_server.exe'),
    path.join('C:\\tools', 'zx_server.exe'),
    path.join('C:\\bin', 'zx_server.exe')
  ]);
  assert.strictEqual(found.configured, HOME + '/custom/zx_server.exe');
  const unix = s.serverCandidates({ setting: '', folders: [], pathEnv: '/usr/bin:/opt/zx', platform: 'linux', home: HOME });
  assert.deepStrictEqual(unix.candidates, [path.join('/usr/bin', 'zx_server'), path.join('/opt/zx', 'zx_server')]);
  assert.strictEqual(unix.configured, null);
});

test('a release\'s bundled server comes after a checkout\'s build and before PATH', () => {
  const EXT = path.join(HOME, '.vscode', 'extensions', 'jonsole.zxspectrum-debug-0.3.0-win32-x64');
  const found = s.serverCandidates({
    setting: '', folders: [REPO], pathEnv: 'C:\\tools', platform: 'win32', home: HOME,
    bundled: path.join(EXT, 'bin')
  });
  assert.deepStrictEqual(found.candidates, [
    path.join(REPO, 'cpp-core', 'build', 'RelWithDebInfo', 'zx_server.exe'),
    path.join(EXT, 'bin', 'zx_server.exe'),
    path.join('C:\\tools', 'zx_server.exe')
  ]);
});

test('the bundled ROMs stand in for each one the workspace lacks', () => {
  const BUNDLED = path.join(HOME, 'ext', 'roms');
  const has = (files) => (f) => files.includes(f);
  // Nothing in the workspace: both bundled.
  assert.deepStrictEqual(
    s.serverRoms([], REPO, HOME, has([path.join(BUNDLED, '48.rom'), path.join(BUNDLED, '128.rom')]), BUNDLED),
    [path.join(BUNDLED, '48.rom'), path.join(BUNDLED, '128.rom')]);
  // The workspace's own 48K wins; the 128K it lacks comes from the bundle.
  assert.deepStrictEqual(
    s.serverRoms([], REPO, HOME,
      has([path.join(REPO, 'roms', '48.rom'), path.join(BUNDLED, '48.rom'), path.join(BUNDLED, '128.rom')]), BUNDLED),
    [path.join(REPO, 'roms', '48.rom'), path.join(BUNDLED, '128.rom')]);
  // The setting beats both.
  assert.deepStrictEqual(s.serverRoms(['~/mine.rom'], REPO, HOME, () => true, BUNDLED), [HOME + '/mine.rom']);
});

test('the first candidate that exists wins', () => {
  const there = new Set(['b', 'c']);
  assert.strictEqual(s.findServer(['a', 'b', 'c'], (f) => there.has(f)), 'b');
  assert.strictEqual(s.findServer(['a'], (f) => there.has(f)), null);
});

test('a build inside a checkout runs from the checkout', () => {
  const exe = path.join(REPO, 'cpp-core', 'build', 'RelWithDebInfo', 'zx_server.exe');
  assert.strictEqual(s.serverRoot(exe, ['/elsewhere']), path.resolve(REPO));
  const loose = path.join(path.sep, 'opt', 'zx', 'zx_server');
  assert.strictEqual(s.serverRoot(loose, ['/work']), '/work');
  assert.strictEqual(s.serverRoot(loose, []), path.dirname(loose));
});

test('ports come from the settings, with the defaults for anything odd', () => {
  const values = { dapPort: 4799, mcpPort: 'x', screenPort: 70000, audioPort: undefined };
  assert.deepStrictEqual(s.serverPorts((k) => values[k]), { dap: 4799, mcp: 8000, screen: 8500, audio: 8501 });
});

test('the ROMs are the setting\'s, or the checkout\'s own', () => {
  const there = new Set([path.join(REPO, 'roms', '48.rom')]);
  assert.deepStrictEqual(s.serverRoms([], REPO, HOME, (f) => there.has(f)), [path.join(REPO, 'roms', '48.rom')]);
  assert.deepStrictEqual(s.serverRoms(['${workspaceFolder}/a.rom', '~/b.rom'], REPO, HOME, () => false),
                         [REPO + '/a.rom', HOME + '/b.rom']);
});

test('the command line carries the ports, the sound choice, the ROMs and the extras', () => {
  const ports = { dap: 1, mcp: 2, screen: 3, audio: 4 };
  const base = ['--dap-port', '1', '--mcp-port', '2', '--screen-port', '3', '--audio-port', '4'];
  assert.deepStrictEqual(s.serverArgs({ ports, sound: 'device', roms: ['r.rom'], extra: ['--ffmpeg', 'f'] }),
                         base.concat(['--audio-device', '--no-audio', '--rom', 'r.rom', '--ffmpeg', 'f']));
  assert.deepStrictEqual(s.serverArgs({ ports, sound: 'panel' }), base);
  assert.deepStrictEqual(s.serverArgs({ ports, sound: 'off' }), base.concat(['--no-audio']));
  assert.deepStrictEqual(s.serverArgs({ ports, sound: 'loud' }), base.concat(['--audio-device', '--no-audio']));
});

test('the process behind a port is read from netstat', () => {
  const text = [
    '',
    'Active Connections',
    '',
    '  Proto  Local Address          Foreign Address        State           PID',
    '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1200',
    '  TCP    127.0.0.1:47110        0.0.0.0:0              LISTENING       99',
    '  TCP    127.0.0.1:4711         127.0.0.1:50000        ESTABLISHED     35388',
    '  TCP    127.0.0.1:4711         0.0.0.0:0              LISTENING       35388',
    '  TCP    [::1]:8000             [::]:0                 LISTENING       35388'
  ].join('\r\n');
  assert.strictEqual(s.pidListeningOn(text, 4711), 35388);
  assert.strictEqual(s.pidListeningOn(text, 8000), 35388);
  assert.strictEqual(s.pidListeningOn(text, 4712), null);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
