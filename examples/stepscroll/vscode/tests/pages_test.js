// Tests for pages.js -- the designer's pages put together. A page exists whole
// only at runtime, built by string replacement, so a mistake in it is a
// syntax error in a file nobody sees: these assemble each page the way VS
// Code and standalone.py do and compile its script. Plain Node:
//
//   node examples/stepscroll/vscode/tests/pages_test.js

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const pages = require('../pages');

const HERE = path.join(__dirname, '..');
const PAGES = ['steps_view.html'];

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log('     ' + (err && err.stack ? err.stack : err));
  }
}

function scriptOf(html) {
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
  assert.strictEqual(scripts.length, 1, 'one script a page');
  return scripts[0][1];
}

// The VS Code host as steps_view.js writes it, without requiring vscode.
const vscodeHost = 'window.designerHost = { standalone: false, boot: null, edit() {}, state() { return {}; }, ' +
                   'keep() {}, onReload() {} };';

for (const page of PAGES) {
  test(page + ': every marker is filled and the script compiles, in VS Code', () => {
    const html = pages.assemble(page, vscodeHost, 'abc123');
    assert.ok(!/\/\*@[\w.]+@\*\//.test(html), 'a marker left unfilled');
    assert.ok(html.includes('<script nonce="abc123">'));
    assert.ok(html.includes("script-src 'nonce-abc123'"));
    new vm.Script(scriptOf(html), { filename: page });
  });

  test(page + ': standalone, with standalone_host.js', () => {
    const host = fs.readFileSync(path.join(HERE, 'standalone_host.js'), 'utf8');
    const html = pages.assemble(page, host);
    assert.ok(!/\/\*@[\w.]+@\*\//.test(html), 'a marker left unfilled');
    assert.ok(!html.includes('Content-Security-Policy'));
    new vm.Script(scriptOf(html), { filename: page });
  });
}

console.log(failures ? failures + ' failed' : 'all passed');
process.exit(failures ? 1 : 0);
