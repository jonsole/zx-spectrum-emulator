// Tests for watchpoint_model.js -- how a watchpoint reads in the sidebar, and
// what "player 8" in the Watch Address box means. Plain Node, no vscode API:
//
//   node vscode-extension/tests/watchpoint_model_test.js

const assert = require('assert');
const { watchpointName, watchpointDetail, parseWatchRequest } = require('../watchpoint_model');

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

function watchpoint(extra) {
  return Object.assign(
    {
      id: 1,
      address: 0xf6da,
      symbol: 'room_shown',
      length: 1,
      onWrite: true,
      onRead: false,
      onChange: true,
      test: '',
      value: 0,
      enabled: true,
      hits: 0,
    },
    extra
  );
}

test('a named address reads as its name and its address', () => {
  assert.strictEqual(watchpointName(watchpoint()), 'room_shown ($F6DA)');
});

test('an address nothing names reads as the address', () => {
  assert.strictEqual(watchpointName(watchpoint({ symbol: '' })), '$F6DA');
});

test('a range says how many bytes', () => {
  assert.strictEqual(watchpointName(watchpoint({ length: 8 })), 'room_shown ($F6DA), 8 bytes');
});

test('the detail says what it is watching for', () => {
  assert.strictEqual(watchpointDetail(watchpoint()), 'writes that change it');
  assert.strictEqual(watchpointDetail(watchpoint({ onChange: false })), 'every write');
  assert.strictEqual(
    watchpointDetail(watchpoint({ onWrite: false, onRead: true })),
    'reads'
  );
  assert.strictEqual(
    watchpointDetail(watchpoint({ onRead: true, onChange: false })),
    'every write and reads'
  );
  assert.strictEqual(
    watchpointDetail(watchpoint({ test: '=', value: 0 })),
    'writes of 0'
  );
  assert.strictEqual(
    watchpointDetail(watchpoint({ test: '<>', value: 3 })),
    'writes of anything but 3'
  );
});

test('the detail counts hits, and says when one is switched off', () => {
  assert.strictEqual(watchpointDetail(watchpoint({ hits: 1 })), 'writes that change it · 1 hit');
  assert.strictEqual(watchpointDetail(watchpoint({ hits: 4 })), 'writes that change it · 4 hits');
  assert.strictEqual(
    watchpointDetail(watchpoint({ enabled: false })),
    'writes that change it · off'
  );
});

test('a typed address is passed through for the server to resolve', () => {
  assert.deepStrictEqual(parseWatchRequest('player'), { address: 'player', length: 1 });
  assert.deepStrictEqual(parseWatchRequest('  $5C3A '), { address: '$5C3A', length: 1 });
  assert.strictEqual(parseWatchRequest(''), undefined);
  assert.strictEqual(parseWatchRequest(undefined), undefined);
});

test('a length can follow a space or a comma', () => {
  assert.deepStrictEqual(parseWatchRequest('player 8'), { address: 'player', length: 8 });
  assert.deepStrictEqual(parseWatchRequest('$5C3A,2'), { address: '$5C3A', length: 2 });
  assert.deepStrictEqual(parseWatchRequest('room_shown , 4'), { address: 'room_shown', length: 4 });
});

test('an expression is not mistaken for a length', () => {
  // The server resolves "sprite_x + 4"; the 4 is part of the address.
  assert.deepStrictEqual(parseWatchRequest('sprite_x + 4'), { address: 'sprite_x + 4', length: 1 });
  assert.deepStrictEqual(parseWatchRequest('sprite_x+4'), { address: 'sprite_x+4', length: 1 });
  // ...but a length after a complete expression still counts.
  assert.deepStrictEqual(parseWatchRequest('sprite_x+4 2'), { address: 'sprite_x+4', length: 2 });
});

if (failures > 0) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log('all passed');
