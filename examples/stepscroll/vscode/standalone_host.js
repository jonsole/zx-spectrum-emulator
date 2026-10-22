// The host a designer page has when it is opened straight in a browser, with
// nothing behind it: the files come from a folder the browser is given (or
// from the files themselves), and Save writes what changed back into that
// folder -- or, in a browser without folder access, downloads it. Edits not
// yet saved are kept in this browser's storage, so a closed tab loses nothing.
//
// standalone.py puts this where the page's host marker is; in VS Code, the
// extension puts its own host there instead. The page says which files it
// edits, and what to call its storage, by setting window.designerPage before
// this runs: { files: ['tiles.json', 'blocks.json'], key: 'stepscroll.tiles' }.

(function () {
  'use strict';
  const page = window.designerPage;
  const READS = ['tiles.json', 'blocks.json', 'map.json'];
  let folder = null;                      // a FileSystemDirectoryHandle
  let where = '';

  function storage(name, value) {
    try {
      if (value === undefined) return localStorage.getItem(page.key + '.' + name);
      if (value === null) localStorage.removeItem(page.key + '.' + name);
      else localStorage.setItem(page.key + '.' + name, value);
    } catch (err) {
      // Storage refused (a private window): drafts and settings just don't keep.
    }
    return null;
  }

  function bootFrom(texts) {
    const missing = READS.filter((n) => texts[n] === undefined);
    if (missing.length) throw new Error('missing ' + missing.join(', ') + ' -- open examples/stepscroll/world/');
    return { tiles: texts['tiles.json'], blocks: texts['blocks.json'], map: texts['map.json'] };
  }

  async function readFolder(dir) {
    const texts = {};
    for (const name of READS) {
      try {
        const handle = await dir.getFileHandle(name);
        texts[name] = await (await handle.getFile()).text();
      } catch (err) {
        // Not there; bootFrom says which.
      }
    }
    return texts;
  }

  function download(name, text) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // The page's names for its files ('tiles') and the files' own ('tiles.json').
  const fileOf = (short) => short + '.json';

  window.designerHost = {
    standalone: true,
    boot: null,
    hasFolderPicker: () => typeof window.showDirectoryPicker === 'function',
    async openFolder() {
      let dir = await window.showDirectoryPicker({ id: 'stepscroll-world', mode: 'readwrite' });
      let texts = await readFolder(dir);
      // Given examples/stepscroll rather than its world/, look inside.
      if (texts['tiles.json'] === undefined) {
        try {
          dir = await dir.getDirectoryHandle('world');
          texts = await readFolder(dir);
        } catch (err) {
          // No world/ either; bootFrom says what is missing.
        }
      }
      const boot = bootFrom(texts);
      folder = dir;
      where = dir.name + '/';
      return boot;
    },
    openFiles() {
      return new Promise((resolve, reject) => {
        const input = document.createElement('input');
        input.type = 'file';
        input.multiple = true;
        input.accept = '.json,application/json';
        input.addEventListener('change', async () => {
          try {
            const texts = {};
            for (const f of input.files) texts[f.name] = await f.text();
            const boot = bootFrom(texts);
            folder = null;
            where = 'files (Save downloads what changed)';
            resolve(boot);
          } catch (err) {
            reject(err);
          }
        });
        input.click();
      });
    },
    canSave: () => where !== '',
    where: () => where,
    // texts: { 'tiles.json': text, ... }, only the files that changed.
    async save(texts) {
      for (const [name, text] of Object.entries(texts)) {
        if (folder) {
          const handle = await folder.getFileHandle(name, { create: true });
          const out = await handle.createWritable();
          await out.write(text);
          await out.close();
        } else {
          download(name, text);
        }
      }
      for (const name of page.files) storage('draft.' + name, null);
    },
    edit(file, text) { storage('draft.' + fileOf(file), text); },
    drafts() {
      const out = {};
      for (const name of page.files) {
        const text = storage('draft.' + name);
        if (text) out[name] = text;
      }
      return out;
    },
    dropDrafts() {
      for (const name of page.files) storage('draft.' + name, null);
    },
    state() {
      try { return JSON.parse(storage('ui') || '{}'); } catch (err) { return {}; }
    },
    keep(s) { storage('ui', JSON.stringify(s)); },
    onReload() {},
    // What the address asks to show (tiles_editor.html#floor-1), if anything.
    onSelect(fn) {
      const name = decodeURIComponent(location.hash.slice(1));
      if (name) fn(name);
    },
    // The tiles page, beside this one, in a new tab, showing tile `name`.
    openTile(name) {
      window.open('tiles_editor.html#' + encodeURIComponent(name), '_blank');
    },
  };
})();
