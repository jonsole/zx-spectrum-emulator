// A webview page as the extension assembles it, run against a DOM that records
// rather than renders -- for tests/tape_page_test.js and screen_page_test.js.
//
// The pages are built by string replacement (tape_files.js's pageHtml), so a
// mistake is a syntax error, or a reference to an element that isn't there, in
// a file that exists only at runtime. This assembles one the same way, runs its
// script, and lets a test send it messages, click it, type in it, and read what
// it posted back and what it drew. The canvas counts what reached it, so a page
// that draws nothing can't pass for one that does -- the lesson
// examples/filmation/vscode/tests/room_page_test.js learned.

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const EXT = path.join(__dirname, '..');

// The page's HTML with the model inlined, and its one script.
function assemble(file) {
  const html = fs.readFileSync(path.join(EXT, file), 'utf8')
    .replace('/*@tape_model.js@*/', () => fs.readFileSync(path.join(EXT, 'tape_model.js'), 'utf8'));
  const open = html.indexOf('>', html.indexOf('<script')) + 1;
  return { html, script: html.slice(open, html.indexOf('</script>', open)) };
}

function ids(html) {
  const found = new Set();
  const pattern = /id="([^"]+)"/g;
  let match;
  while ((match = pattern.exec(html))) {
    found.add(match[1]);
  }
  return found;
}

function open(file) {
  const { html, script } = assemble(file);
  const declared = ids(html);
  const listeners = [];
  const posted = [];
  const painted = [];

  function context(canvas) {
    return new Proxy({}, {
      get(target, key) {
        if (key in target) {
          return target[key];
        }
        if (key === 'createImageData') {
          return (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) });
        }
        if (key === 'measureText') {
          return () => ({ width: 8 });
        }
        return (...args) => { painted.push({ canvas: canvas.id, call: key, args }); };
      },
      set(target, key, value) {
        target[key] = value;
        return true;
      }
    });
  }

  function element(tag) {
    const node = {
      tagName: String(tag).toUpperCase(), id: '', children: [], parent: null, dataset: {},
      _classes: new Set(), textContent: '', title: '', value: '', type: '', checked: false,
      disabled: false, draggable: false, placeholder: '', width: 0, height: 0,
      clientWidth: 0, clientHeight: 0, max: '1000',
      style: { setProperty() {} },
      set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
      get className() { return Array.from(this._classes).join(' '); },
      get options() { return this.children; },
      get firstElementChild() { return this.children[0] || null; },
      appendChild(child) { child.parent = this; this.children.push(child); return child; },
      append(...children) { for (const child of children) this.appendChild(child); },
      addEventListener(kind, fn) { listeners.push({ node: this, kind, fn }); },
      getContext() { return context(this); },
      getBoundingClientRect() { return { left: 0, top: 0, width: this.width || 256, height: this.height || 192 }; },
      setPointerCapture() {}, releasePointerCapture() {}, focus() {}, blur() {},
      closest(selector) {
        for (let n = this; n; n = n.parent) {
          if (matches(n, selector)) return n;
        }
        return null;
      },
      querySelectorAll(selector) { return select(this, selector); },
      querySelector(selector) { return select(this, selector)[0] || null; },
      click() { fire(this, 'click', {}); }
    };
    // Assigning textContent clears children, as it does in a browser.
    let text = '';
    Object.defineProperty(node, 'textContent', {
      get() { return text + node.children.map((c) => c.textContent).join(''); },
      set(v) { text = String(v); node.children.length = 0; }
    });
    node.classList = {
      add: (...c) => c.forEach((x) => node._classes.add(x)),
      remove: (...c) => c.forEach((x) => node._classes.delete(x)),
      contains: (c) => node._classes.has(c),
      toggle: (c, on) => {
        const want = on === undefined ? !node._classes.has(c) : !!on;
        if (want) node._classes.add(c); else node._classes.delete(c);
        return want;
      }
    };
    return node;
  }

  function matches(node, token) {
    if (token.startsWith('.')) return node._classes && node._classes.has(token.slice(1));
    if (token.startsWith('#')) return node.id === token.slice(1);
    return node.tagName === token.toUpperCase();
  }

  function descendants(node, out) {
    for (const child of node.children) {
      out.push(child);
      descendants(child, out);
    }
    return out;
  }

  // Simple descendant selectors -- "#list .row .drop" -- which is all the pages use.
  function select(root, selector) {
    let found = [root];
    for (const token of selector.trim().split(/\s+/)) {
      const next = [];
      for (const node of found) {
        for (const d of descendants(node, [])) {
          if (matches(d, token) && !next.includes(d)) next.push(d);
        }
      }
      found = next;
    }
    return found;
  }

  const byId = {};
  const body = element('body');
  function getElementById(id) {
    if (!declared.has(id)) {
      return null;             // the page asked for something its markup doesn't have
    }
    if (!byId[id]) {
      byId[id] = element(id === 'screen' || id === 'overlay' || id === 'map' ? 'canvas' : 'div');
      byId[id].id = id;
      body.appendChild(byId[id]);
    }
    return byId[id];
  }

  const document = {
    body,
    activeElement: null,
    createElement: element,
    createTextNode: (value) => { const n = element('#text'); n.textContent = value; return n; },
    getElementById,
    querySelectorAll: (selector) => select(body, selector),
    querySelector: (selector) => select(body, selector)[0] || null,
    addEventListener: (kind, fn) => listeners.push({ node: 'document', kind, fn })
  };

  function fire(node, kind, event) {
    const target = event.target || node;
    for (const l of listeners.slice()) {
      if (l.node === node && l.kind === kind) {
        l.fn(Object.assign({ target, preventDefault() {}, stopPropagation() {} }, event));
      }
    }
  }

  const window = {
    devicePixelRatio: 1,
    innerHeight: 800,
    addEventListener: (kind, fn) => listeners.push({ node: 'window', kind, fn })
  };
  const sandbox = {
    window, document, console, Math, JSON, Uint8Array, Uint8ClampedArray, Array, Object, Number, String,
    Set, Map, Proxy, Error, parseInt, parseFloat, isNaN,
    atob: (text) => Buffer.from(text, 'base64').toString('binary'),
    acquireVsCodeApi: () => ({ postMessage: (message) => posted.push(JSON.parse(JSON.stringify(message))) }),
    getComputedStyle: () => ({ flexDirection: 'row' }),
    ResizeObserver: function () { this.observe = () => {}; },
    requestAnimationFrame: () => 0,
    performance: { now: () => 0 }
  };
  vm.createContext(sandbox);
  new vm.Script(script, { filename: file }).runInContext(sandbox);

  return {
    posted,
    painted,
    el: getElementById,
    // A message from the extension, as the page's window receives it.
    send(message) {
      for (const l of listeners.filter((x) => x.node === 'window' && x.kind === 'message')) {
        l.fn({ data: message });
      }
    },
    click(node) { fire(node, 'click', {}); },
    type(node, value) {
      node.value = value;
      fire(node, 'input', {});
    },
    choose(node, value) {
      node.value = value;
      fire(node, 'change', { target: node });
    },
    all: (selector) => select(body, selector)
  };
}

module.exports = { open, assemble };
