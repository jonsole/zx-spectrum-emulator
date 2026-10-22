// Stepscroll Designer extension.
//
// Editors for examples/stepscroll's world: the tiles (tiles.json) and the
// blocks (blocks.json); the map (map.json) to follow. Independent of the
// emulator's extension, as the Filmation designer is. Each editor's page also
// builds as a standalone HTML file (standalone.py) for use without VS Code.
// designer_host.js is the VS Code side of both.

'use strict';

const { activateEditor } = require('./designer_host');

function activate(context) {
  activateEditor(context, 'stepscroll.tiles', 'tiles_view.html', 'tiles.json', 'stepscroll.openTiles');
  activateEditor(context, 'stepscroll.blocks', 'blocks_view.html', 'blocks.json', 'stepscroll.openBlocks');
}

function deactivate() {
}

module.exports = { activate, deactivate };
