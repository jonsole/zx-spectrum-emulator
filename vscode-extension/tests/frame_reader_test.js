// The screen stream's framing (frame_reader.js): node vscode-extension/tests/frame_reader_test.js
const assert = require('assert');
const { FrameReader } = require('../frame_reader');

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name + '\n     ' + err.message);
  }
}

function framed(bytes) {
  const head = Buffer.alloc(4);
  head.writeUInt32BE(bytes.length, 0);
  return Buffer.concat([head, Buffer.from(bytes)]);
}

/// Feeds `stream` in pieces of `size` bytes and returns every frame.
function feed(stream, size) {
  const reader = new FrameReader();
  const frames = [];
  for (let at = 0; at < stream.length; at += size) {
    frames.push(...reader.push(stream.subarray(at, at + size)));
  }
  return frames;
}

const a = Buffer.alloc(100000, 7);
const b = Buffer.from([1, 2, 3]);
const stream = Buffer.concat([framed(a), framed(b), framed([])]);

test('whole frames come out whatever the chunk size', () => {
  // 1 splits the length prefix itself; 3 and 65536 straddle everything.
  for (const size of [1, 3, 4, 5, 1000, 65536, stream.length]) {
    const frames = feed(stream, size);
    assert.strictEqual(frames.length, 3, 'chunks of ' + size);
    assert.ok(frames[0].equals(a), 'first frame, chunks of ' + size);
    assert.ok(frames[1].equals(b), 'second frame, chunks of ' + size);
    assert.strictEqual(frames[2].length, 0);
  }
});

test('a partial frame waits for the rest', () => {
  const reader = new FrameReader();
  assert.deepStrictEqual(reader.push(stream.subarray(0, 50000)), []);
  const frames = reader.push(stream.subarray(50000));
  assert.strictEqual(frames.length, 3);
});

test('each frame is its own copy, not a view of the next chunk', () => {
  const frames = feed(stream, stream.length);
  frames[0][0] = 99;
  assert.strictEqual(stream[4], 7);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
