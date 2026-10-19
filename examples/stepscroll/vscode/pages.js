// A designer page put together: the .html with each /*@name.js@*/ marker
// replaced by that file, and /*@host@*/ by the host it runs under -- the
// extension's, talking to VS Code, or standalone_host.js for a page opened
// straight in a browser (standalone.py does the same for that one).
//
// No vscode import, so tests/pages_test.js can assemble a page from Node.

'use strict';

const fs = require('fs');
const path = require('path');

const MARKER = /\/\*@([\w.]+\.js)@\*\//g;

// The page `htmlName` with its files inlined and `hostJs` as its host. With a
// nonce, a Content-Security-Policy allowing only the page's own script.
function assemble(htmlName, hostJs, nonce) {
  let html = fs.readFileSync(path.join(__dirname, htmlName), 'utf8');
  html = html.replace(MARKER, (marker, name) => fs.readFileSync(path.join(__dirname, name), 'utf8'));
  html = html.replace('/*@host@*/', () => hostJs);
  if (nonce) {
    const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
                'script-src \'nonce-' + nonce + '\'; style-src \'unsafe-inline\'; img-src data: blob:;">';
    html = html.replace('<meta charset="utf-8">', () => '<meta charset="utf-8">\n' + csp)
               .replace('<script>', () => '<script nonce="' + nonce + '">');
  }
  return html;
}

module.exports = { assemble, MARKER };
