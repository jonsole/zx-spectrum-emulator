// Stepscroll Designer extension.
//
// Editors for examples/stepscroll's world: the step graphics (steps.json) now,
// the map and its tiles to follow (issue #25). Independent of the emulator's
// extension, as the Filmation designer is. Each editor's page also builds as a
// standalone HTML file (standalone.py) for use without VS Code.

'use strict';

const { activateStepGraphics } = require('./steps_view');

function activate(context) {
  activateStepGraphics(context);
}

function deactivate() {
}

module.exports = { activate, deactivate };
