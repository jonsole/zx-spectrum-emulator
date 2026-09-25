// Tests for sjasmplus_fetch.js -- unpacking sjasmplus from its release zip,
// and refusing anything that is not the pinned one. Plain Node:
//
//   node vscode-extension/tests/sjasmplus_fetch_test.js
//
// The zips here are written by hand, stored and deflated, the two ways a zip
// holds a file. With SJASMPLUS_ZIP naming a downloaded sjasmplus-1.23.1.win.zip,
// the real one is unpacked and checked too.

const assert = require('assert');
const fs = require('fs');
const zlib = require('zlib');
const f = require('../sjasmplus_fetch');

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

// A zip of { name: Buffer }, each entry stored (0) or deflated (8), with a
// comment on the end so the reader has to look for the end record.
function makeZip(files, method) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, content] of Object.entries(files)) {
    const data = method === 8 ? zlib.deflateRawSync(content) : content;
    const nameBytes = Buffer.from(name);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    locals.push(local, nameBytes, data);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBytes);
    offset += 30 + nameBytes.length + data.length;
  }
  const directory = Buffer.concat(centrals);
  const comment = Buffer.from('a comment');
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(comment.length, 20);
  return Buffer.concat([...locals, directory, end, comment]);
}

const EXE = Buffer.from('MZ pretend assembler '.repeat(50));
const FILES = {
  'sjasmplus-1.23.1.win/docs/documentation.html': Buffer.from('<html></html>'),
  'sjasmplus-1.23.1.win/sjasmplus.exe': EXE,
};

test('a stored file is read out of a zip by the end of its name', () => {
  assert.deepStrictEqual(f.readZipEntry(makeZip(FILES, 0), '/sjasmplus.exe'), EXE);
});

test('a deflated one too', () => {
  assert.deepStrictEqual(f.readZipEntry(makeZip(FILES, 8), '/sjasmplus.exe'), EXE);
});

test('a name that is not there, or no zip at all, is an error', () => {
  assert.throws(() => f.readZipEntry(makeZip(FILES, 8), '/missing.exe'), /no file ending/);
  assert.throws(() => f.readZipEntry(Buffer.from('not a zip at all'), '/sjasmplus.exe'), /not a zip/);
});

test('nothing is unpacked from a zip that is not the pinned release', () => {
  assert.throws(() => f.unpackSjasmplus(makeZip(FILES, 8)), /SHA-256/);
});

test('the pin is the one scripts/fetch_sjasmplus.py uses', () => {
  const script = fs.readFileSync(require('path').join(__dirname, '..', '..', 'scripts', 'fetch_sjasmplus.py'), 'utf8');
  assert.ok(script.includes(`VERSION = "${f.SJASMPLUS.version}"`));
  assert.ok(script.includes(f.SJASMPLUS.zipSha256));
  assert.ok(script.includes(f.SJASMPLUS.exeSha256));
});

if (process.env.SJASMPLUS_ZIP) {
  test('the real release unpacks to the pinned sjasmplus.exe', () => {
    const exe = f.unpackSjasmplus(fs.readFileSync(process.env.SJASMPLUS_ZIP));
    assert.strictEqual(f.sha256(exe), f.SJASMPLUS.exeSha256);
  });
}

if (failures > 0) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log('\nall passed');
