# miniz

Vendored verbatim from miniz 3.0.2 (https://github.com/richgel999/miniz),
the single-file amalgamation from that release. MIT licensed -- see LICENSE.

Here for exactly one reason: .csw v2 and .tzx block 0x18 store their pulse
lists as a zlib (Z-RLE) stream, so reading an audio-recorded tape needs an
inflate. Nothing else in the emulator compresses or decompresses anything.

Built by CMakeLists.txt with MINIZ_NO_DEFLATE_APIS, MINIZ_NO_ARCHIVE_APIS,
MINIZ_NO_STDIO and MINIZ_NO_TIME, which reduces it to the tinfl decompressor
alone -- no compressor, no .zip reader/writer, no file I/O. Only
tinfl_decompress_mem_to_heap() and mz_free() are actually called, from
src/tape_audio.cpp.

Do not edit these files. To update, drop in a newer amalgamation.
