// Filmation Designer extension.
//
// The editors for a Filmation remake's data: the room designer on rooms.json,
// the templates editor on templates.json, and the graphic map on
// graphics.json, plus the JSON schemas package.json registers for every file
// a remake is built from. It knows nothing of the emulator and needs nothing
// from it -- Build runs the game's own build.py as a task -- which is why it
// is an extension of its own rather than part of the ZX Spectrum one.
//
// Each editor's host is its own file, and what it edits is in files with no
// vscode import, tested from plain Node (tests/).

const { activateRoomDesigner } = require('./room_view');
const { activateTemplatesEditor } = require('./templates_view');
const { activateGraphicMap } = require('./graphic_map_view');

function activate(context) {
  activateRoomDesigner(context);
  activateTemplatesEditor(context);
  activateGraphicMap(context);
}

function deactivate() {
}

module.exports = { activate, deactivate };
