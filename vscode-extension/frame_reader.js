// Splits the screen stream into frames: each a 4-byte big-endian length and
// that many PNG bytes (cpp-core/src/screen_stream.cpp). No vscode import, so
// it is tested from plain Node (tests/frame_reader_test.js).
//
// Chunks are kept as a list and joined once a frame is whole. Joining every
// chunk onto what came before, as this first did, copied a frame over again
// for each chunk -- harmless at the plain picture's 20 KB, but the RF look's
// 1.3 MB frames arrive in twenty-odd chunks.

class FrameReader {
  constructor() {
    this.chunks = [];
    this.length = 0;
  }

  /// Takes the next chunk off the socket; returns the frames it completed,
  /// oldest first, each a Buffer of its own.
  push(chunk) {
    this.chunks.push(chunk);
    this.length += chunk.length;
    const frames = [];
    for (;;) {
      if (this.length < 4) {
        break;
      }
      const size = this.peekLength();
      if (this.length < 4 + size) {
        break;
      }
      const all = this.chunks.length === 1 ? this.chunks[0] : Buffer.concat(this.chunks, this.length);
      frames.push(Buffer.from(all.subarray(4, 4 + size)));
      const rest = all.subarray(4 + size);
      this.chunks = rest.length ? [rest] : [];
      this.length = rest.length;
    }
    return frames;
  }

  /// The length prefix, which may straddle chunks. Only its four bytes are
  /// gathered: joining the whole list here would copy it all again for
  /// every chunk while a frame is incomplete.
  peekLength() {
    if (this.chunks[0].length >= 4) {
      return this.chunks[0].readUInt32BE(0);
    }
    const head = Buffer.alloc(4);
    let filled = 0;
    for (const c of this.chunks) {
      filled += c.copy(head, filled, 0, Math.min(c.length, 4 - filled));
      if (filled === 4) {
        break;
      }
    }
    return head.readUInt32BE(0);
  }
}

module.exports = { FrameReader };
