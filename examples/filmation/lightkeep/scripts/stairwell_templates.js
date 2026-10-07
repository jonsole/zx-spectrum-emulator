// stairwell.py's templates, written into templates.json through the room
// designer's own model, so the file keeps the layout the templates editor
// gives it -- and graphics.json passed through the graphic map's, so the line
// stairwell.py adds there is laid out as the editor lays the rest.
//
//   node stairwell_templates.js <game folder> <json>
//
// The JSON is { templates: { name: pieces }, background: [names], retired:
// [names] }: retired templates are taken out (nothing may still place them),
// the others put in or replaced, and the background names added to
// meta.background.

const fs = require('fs');
const path = require('path');

const game = process.argv[2];
const said = JSON.parse(process.argv[3]);
const m = require(path.join(game, '..', 'vscode', 'room_model.js'));

const file = path.join(game, 'metadata', 'templates.json');
const raw = fs.readFileSync(file, 'utf8');
const rooms = fs.readFileSync(path.join(game, 'metadata', 'rooms.json'), 'utf8');
const eol = raw.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
const atlas = m.withTemplates(m.parseAtlas(rooms), m.parseTemplates(raw));

const scenery = atlas.sceneryTemplates;
const kept = {};
for (const name of Object.keys(scenery)) {
  if (said.retired.indexOf(name) < 0 && !(name in said.templates)) kept[name] = scenery[name];
}
for (const name of Object.keys(said.templates)) kept[name] = said.templates[name];
for (const name of Object.keys(scenery)) delete scenery[name];
for (const name of Object.keys(kept)) scenery[name] = kept[name];

const background = atlas.templatesMeta.background;
for (let i = background.length - 1; i >= 0; i--) {
  if (said.retired.indexOf(background[i]) >= 0) background.splice(i, 1);
}
for (const name of said.background) {
  if (background.indexOf(name) < 0) background.push(name);
}

fs.writeFileSync(file, m.serializeTemplates(atlas, eol));

const gm = require(path.join(game, '..', 'vscode', 'graphic_map_model.js'));
const graphicsFile = path.join(game, 'metadata', 'graphics.json');
const graphics = fs.readFileSync(graphicsFile, 'utf8');
const graphicsEol = graphics.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
fs.writeFileSync(graphicsFile, gm.serializeMap(gm.parseMap(graphics), graphicsEol));
console.log('written');
