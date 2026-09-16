// Tests for rewind_model.js -- the words for where the machine is in its
// history. Plain Node, no vscode API:
//
//   node vscode-extension/tests/rewind_model_test.js

const assert = require('assert');
const { describeBehind, statusFor } = require('../rewind_model');

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

// A 48K frame: 312 lines of 224 T-states, two half-clocks each.
const FRAME_48K = 312 * 224 * 2;

test('at the head it is live', () => {
  assert.strictEqual(describeBehind(0, FRAME_48K), 'live');
});

test('less than a frame back is counted in T-states', () => {
  assert.strictEqual(describeBehind(2, FRAME_48K), '1 T-state before live');
  assert.strictEqual(describeBehind(278, FRAME_48K), '139 T-states before live');
  assert.strictEqual(describeBehind(2 * 12345, FRAME_48K), '12,345 T-states before live');
});

test('less than a second back is counted in frames', () => {
  assert.strictEqual(describeBehind(FRAME_48K, FRAME_48K), '1.0 frames before live');
  assert.strictEqual(describeBehind(FRAME_48K * 4.5, FRAME_48K), '4.5 frames before live');
});

test('further back is counted in seconds', () => {
  assert.strictEqual(describeBehind(FRAME_48K * 50, FRAME_48K), '1.0 s before live');
  assert.strictEqual(describeBehind(FRAME_48K * 202, FRAME_48K), '4.0 s before live');
});

test('a live machine, or a server without rewind, shows nothing', () => {
  assert.strictEqual(statusFor(undefined), undefined);
  assert.strictEqual(statusFor({ rewind: false }), undefined);
  assert.strictEqual(
    statusFor({ rewind: true, live: true, headHalfClock: 10, positionHalfClock: 10, oldestHalfClock: 0 }),
    undefined
  );
});

test('in the past, the status says how far back and how far into the history', () => {
  const status = statusFor({
    rewind: true,
    live: false,
    oldestHalfClock: 1000,
    headHalfClock: 1000 + FRAME_48K * 100,
    positionHalfClock: 1000 + FRAME_48K * 75,
    halfClocksPerFrame: FRAME_48K,
  });
  assert.strictEqual(status.text, '25.0 frames before live');
  assert.strictEqual(status.share, 0.25);
});

if (failures > 0) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log('all passed');
