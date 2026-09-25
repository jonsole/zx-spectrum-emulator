// Fetching sjasmplus, the Z80 assembler, the first time something needs it.
//
// The example workspaces' build tasks and the tape designer's moved loaders
// assemble with it. A release does not carry it: it is fetched instead, from
// sjasmplus's own GitHub release, the version scripts/fetch_sjasmplus.py pins
// for the repository -- checked against the same SHA-256s before anything is
// unpacked or run -- and kept in the extension's storage from then on.
//
// No vscode API, so it is tested from plain Node
// (node tests/sjasmplus_fetch_test.js); server_view.js does the asking,
// the progress and the caching.

'use strict';

const crypto = require('crypto');
const https = require('https');
const zlib = require('zlib');

// Kept the same as scripts/fetch_sjasmplus.py.
const SJASMPLUS = {
  version: '1.23.1',
  url: 'https://github.com/z00m128/sjasmplus/releases/download/v1.23.1/sjasmplus-1.23.1.win.zip',
  zipSha256: 'fa0ca77e6e6dcdad77b2c64607b325dd6366844ab6438bfc97661fdfbc29aa35',
  exeSha256: '69a24ea87dd142814217a1ed7927a0386f3ed9ff8cea99ce57f7ff25a3f8c10e',
};

const MAX_REDIRECTS = 5;

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

// One file out of a zip, found by the end of its name: its central directory
// entry says where its data is and how it is stored (0, as it is, or 8,
// deflated). Enough for one release archive; not a general zip reader --
// no zip64, no encryption, no spanning.
function readZipEntry(zip, nameEndsWith) {
  const END = 0x06054b50;
  const CENTRAL = 0x02014b50;
  const LOCAL = 0x04034b50;
  // The end-of-central-directory record: 22 bytes, then up to 64K of comment.
  let end = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 22 - 0xffff); i--) {
    if (zip.readUInt32LE(i) === END) {
      end = i;
      break;
    }
  }
  if (end < 0) {
    throw new Error('not a zip file');
  }
  const count = zip.readUInt16LE(end + 10);
  let at = zip.readUInt32LE(end + 16);
  for (let n = 0; n < count; n++) {
    if (zip.readUInt32LE(at) !== CENTRAL) {
      throw new Error('damaged zip: bad central directory');
    }
    const method = zip.readUInt16LE(at + 10);
    const compressed = zip.readUInt32LE(at + 20);
    const nameLength = zip.readUInt16LE(at + 28);
    const extraLength = zip.readUInt16LE(at + 30);
    const commentLength = zip.readUInt16LE(at + 32);
    const local = zip.readUInt32LE(at + 42);
    const name = zip.toString('utf8', at + 46, at + 46 + nameLength);
    if (name.endsWith(nameEndsWith)) {
      if (zip.readUInt32LE(local) !== LOCAL) {
        throw new Error('damaged zip: bad local header for ' + name);
      }
      // The local header's own name and extra lengths, which need not match
      // the central directory's.
      const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
      const data = zip.subarray(start, start + compressed);
      if (method === 0) {
        return Buffer.from(data);
      }
      if (method === 8) {
        return zlib.inflateRawSync(data);
      }
      throw new Error(`${name} is stored with method ${method}, which this cannot unpack`);
    }
    at += 46 + nameLength + extraLength + commentLength;
  }
  throw new Error(`no file ending ${nameEndsWith} in the zip`);
}

// A URL's whole body, following GitHub's redirects to where a release's
// files actually are.
function download(url, redirects = MAX_REDIRECTS) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'zxspectrum-debug' } }, (response) => {
      const status = response.statusCode;
      if (status >= 300 && status < 400 && response.headers.location) {
        response.resume();
        if (redirects <= 0) {
          reject(new Error('too many redirects fetching ' + url));
          return;
        }
        resolve(download(new URL(response.headers.location, url).toString(), redirects - 1));
        return;
      }
      if (status !== 200) {
        response.resume();
        reject(new Error(`HTTP ${status} fetching ${url}`));
        return;
      }
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve(Buffer.concat(chunks)));
      response.on('error', reject);
    }).on('error', reject);
  });
}

// The release zip -> sjasmplus.exe's bytes, or an error saying which check
// failed. Nothing is unpacked from a zip that is not the one pinned.
function unpackSjasmplus(zip) {
  const zipHash = sha256(zip);
  if (zipHash !== SJASMPLUS.zipSha256) {
    throw new Error(`the download's SHA-256 is ${zipHash}, not sjasmplus ${SJASMPLUS.version}'s`);
  }
  const exe = readZipEntry(zip, '/sjasmplus.exe');
  const exeHash = sha256(exe);
  if (exeHash !== SJASMPLUS.exeSha256) {
    throw new Error(`sjasmplus.exe's SHA-256 is ${exeHash}, not ${SJASMPLUS.version}'s`);
  }
  return exe;
}

module.exports = { SJASMPLUS, sha256, readZipEntry, download, unpackSjasmplus };
