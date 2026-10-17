# The world is JSON with a schema, and gets a standalone HTML editor

The tiles, as lists of pieces, and the map, as the tile each page holds, are
JSON files with a schema, turned into assembler by `build.py`; nothing
generated is committed. The step graphics are painted in a PNG and shifted to
their four positions at build time. A world editor -- one HTML file, no server
-- paints the map and shapes the tiles; it comes once the engine draws a
world, and until then the test world is written by hand.
