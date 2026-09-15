// Z80 assembly symbol index.
//
// What Go to Definition, Find All References, hover and the outline all stand
// on: every label, constant, macro, struct and define in every assembly file
// of the workspace, and every place a name is used. It is read the way
// sjasmplus reads a source -- which is the assembler every .s and .asm here is
// built with -- so a local label is known by its full name (.loop under
// sprite_blit is sprite_blit.loop), a struct field by its struct's (OBJ.FLAGS),
// and a macro's parameters only inside that macro.
//
// Nothing here touches the vscode API, so the parser can be exercised from a
// plain Node script -- see tests/asm_index_test.js.
//
// One workspace holds several programs that share label names -- the ROM
// disassembly, the filmation engine, the Knight Lore remake each have a
// "start" -- so a name is resolved within the files the current one is
// INCLUDEd together with first, and only across the whole workspace if it is
// not defined there.

const fs = require('fs');
const path = require('path');

// Words that are never a symbol of the program's own, compared lower-case: the
// instruction set, registers and conditions. A token that is one of these is
// never recorded as a reference.
const CPU_WORDS = new Set([
  // instructions
  'adc', 'add', 'and', 'bit', 'call', 'ccf', 'cp', 'cpd', 'cpdr', 'cpi', 'cpir', 'cpl',
  'daa', 'dec', 'di', 'djnz', 'ei', 'ex', 'exx', 'halt', 'im', 'in', 'inc', 'ind', 'indr',
  'ini', 'inir', 'jp', 'jr', 'ld', 'ldd', 'lddr', 'ldi', 'ldir', 'neg', 'nop', 'or', 'otdr',
  'otir', 'out', 'outd', 'outi', 'pop', 'push', 'res', 'ret', 'reti', 'retn', 'rl', 'rla',
  'rlc', 'rlca', 'rld', 'rr', 'rra', 'rrc', 'rrca', 'rrd', 'rst', 'sbc', 'scf', 'set', 'sla',
  'sli', 'sll', 'sra', 'srl', 'sub', 'xor',
  // registers and conditions
  'a', 'b', 'c', 'd', 'e', 'h', 'l', 'i', 'r', 'af', 'bc', 'de', 'hl', 'sp', 'ix', 'iy',
  'ixh', 'ixl', 'iyh', 'iyl', 'xh', 'xl', 'yh', 'yl', 'hx', 'lx', 'hy', 'ly',
  'nz', 'z', 'nc', 'po', 'pe', 'p', 'm',
]);

// sjasmplus's directives. These are only skipped where a directive goes --
// the ROM has a label called CHARSET, and its uses are references like any
// other. A word in the first column that is one of these or a CPU word, with
// no colon, is not taken as a label: other assemblers do let a directive
// start a line.
const DIRECTIVE_WORDS = new Set([
  'org', 'disp', 'phase', 'ent', 'dephase', 'unphase', 'textarea', 'end', 'equ', 'defl',
  'define', 'undefine', 'include', 'incbin', 'binary', 'insert', 'inchob', 'inctrd',
  'includelua', 'output', 'outend', 'tapout', 'tapend', 'savesna', 'savebin', 'savetap',
  'savetrd', 'savenex', 'savedev', 'savecdt', 'save3dos', 'saveamsdos', 'emptytap',
  'emptytrd', 'device', 'slot', 'page', 'mmu', 'labelslist', 'cspectmap', 'bplist', 'setbp',
  'setbreakpoint', 'sldopt', 'display', 'assert', 'fpos', 'shellexec', 'lua', 'endlua', 'opt',
  'relocate_start', 'relocate_end', 'encoding', 'charset', 'export', 'memorymap', 'fieldsize',
  'db', 'defb', 'dw', 'defw', 'dd', 'defd', 'ds', 'defs', 'dm', 'defm', 'dz', 'dc', 'd24',
  'dg', 'defg', 'dh', 'defh', 'hex', 'block', 'byte', 'word', 'dword', 'abyte', 'abytec',
  'abytez', 'align', 'if', 'ifn', 'ifdef', 'ifndef', 'ifused', 'ifnused', 'elseif', 'else',
  'endif', 'while', 'endw', 'dup', 'rept', 'edup', 'endr', 'macro', 'endm', 'struct', 'ends',
  'module', 'endmodule',
  // operators sjasmplus spells as words
  'high', 'low', 'not', 'mod', 'shl', 'shr', 'norel',
]);

// The directives whose quoted argument names another file.
const FILE_DIRECTIVES = new Set(['include', 'incbin', 'binary', 'insert', 'includelua']);

// The instructions the call hierarchy follows. A jump counts as well as a
// call: a tail JP to another routine is a call in all but the return address,
// and hand-written Z80 is full of them.
const CALL_OPS = new Set(['call', 'jp', 'jr', 'djnz']);

// What a rename may produce: one segment of a name, so no dots.
const SEGMENT_PATTERN = /^[A-Za-z_][\w?!#@]*$/;

// What kind of thing a definition is. The provider maps these onto VS Code's
// SymbolKind; kept as strings here so this file needs no vscode import.
const KIND_LABEL = 'label';
const KIND_LOCAL = 'local';
const KIND_CONSTANT = 'constant';
const KIND_MACRO = 'macro';
const KIND_PARAM = 'param';
const KIND_STRUCT = 'struct';
const KIND_FIELD = 'field';
const KIND_DEFINE = 'define';

function isIdentStart(ch) {
  return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch === '_';
}

function isIdentChar(ch) {
  return (
    isIdentStart(ch) ||
    (ch >= '0' && ch <= '9') ||
    ch === '.' ||
    ch === '?' ||
    ch === '!' ||
    ch === '#' ||
    ch === '@'
  );
}

function isHexDigit(ch) {
  return (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F') || (ch >= 'a' && ch <= 'f');
}

/// Splits one line into its identifiers and quoted strings, skipping comments
/// and numbers. `inBlockComment` carries a /* */ across lines: pass the value
/// the previous line returned.
function scanLine(text, inBlockComment) {
  const words = [];   // { col, text, colon }
  const strings = []; // { col, len, text } -- col is the opening quote's
  let firstCol = -1;  // where the line's first non-blank, non-comment thing is
  let i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (inBlockComment) {
      const close = text.indexOf('*/', i);
      if (close < 0) {
        i = n;
      } else {
        i = close + 2;
        inBlockComment = false;
      }
      continue;
    }
    if (ch === ' ' || ch === '\t' || ch === '\r') {
      i++;
      continue;
    }
    if (ch === ';' || (ch === '/' && text[i + 1] === '/')) {
      break;
    }
    if (ch === '/' && text[i + 1] === '*') {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (firstCol < 0) {
      firstCol = i;
    }
    if (isIdentStart(ch) || ((ch === '.' || ch === '@') && isIdentStart(text[i + 1] || ''))) {
      let j = i + 1;
      while (j < n && isIdentChar(text[j])) {
        j++;
      }
      words.push({ col: i, text: text.slice(i, j), colon: text[j] === ':' });
      i = j;
      continue;
    }
    if (ch >= '0' && ch <= '9') {
      // A number, whatever its base: 0FFh and 10b must not leave FFh or b
      // behind to be read as names.
      let j = i + 1;
      while (j < n && (isIdentChar(text[j]) || text[j] === "'") && text[j] !== '.') {
        j++;
      }
      i = j;
      continue;
    }
    if ((ch === '$' || ch === '#' || ch === '%') && isHexDigit(text[i + 1] || '')) {
      let j = i + 1;
      while (j < n && isHexDigit(text[j])) {
        j++;
      }
      i = j;
      continue;
    }
    if (ch === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"') {
        if (text[j] === '\\') {
          j++;
        }
        j++;
      }
      strings.push({ col: i, len: Math.min(j, n) - i + 1, text: text.slice(i + 1, Math.min(j, n)) });
      i = j + 1;
      continue;
    }
    if (ch === "'") {
      // af' is the shadow register, not the start of a character literal.
      const last = words.length > 0 ? words[words.length - 1] : undefined;
      if (last && last.col + last.text.length === i && last.text.toLowerCase() === 'af') {
        i++;
        continue;
      }
      let j = i + 1;
      while (j < n && text[j] !== "'") {
        if (text[j] === '\\') {
          j++;
        }
        j++;
      }
      if (j < n) {
        strings.push({ col: i, len: j - i + 1, text: text.slice(i + 1, j) });
        i = j + 1;
      } else {
        i++;
      }
      continue;
    }
    i++;
  }
  return { words, strings, firstCol, inBlockComment };
}

/// Reads one file's text into its definitions, references and includes.
///
///   defs      { name, line, col, len, kind, container }  container is the
///             enclosing label's or struct's name, for the outline
///   lines     lines[i] is that line's tokens, { col, len, name, def }, or
///             undefined; def is true on the word a definition names
///   ops       ops[i] is the instruction or directive on that line, lower-case
///             and where it is, { op, col }, or undefined
///   includes  { target, line, col, len, directive }  col/len cover the quotes
function parseAsm(text) {
  const defs = [];
  const lines = [];
  const ops = [];
  const includes = [];
  const sourceLines = text.split('\n');

  let inBlockComment = false;
  let parent = '';        // the last non-local label: what a .local hangs off
  let structName = '';    // inside STRUCT ... ENDS
  let macroName = '';     // inside MACRO ... ENDM
  let macroParams = new Set();
  let savedParent = '';   // parent outside the macro being defined

  for (let line = 0; line < sourceLines.length; line++) {
    const text = sourceLines[line];
    const scan = scanLine(text, inBlockComment);
    inBlockComment = scan.inBlockComment;
    const words = scan.words;
    if (words.length === 0) {
      continue;
    }

    // Which word, if any, this line defines as a label.
    let labelIndex = -1;
    const first = words[0];
    const firstLower = first.text.toLowerCase();
    const firstReserved = CPU_WORDS.has(firstLower) || DIRECTIVE_WORDS.has(firstLower);
    if (first.col === 0 && (first.colon || !firstReserved)) {
      labelIndex = 0;
    } else if (first.col === scan.firstCol && first.colon) {
      labelIndex = 0;
    } else if (
      first.col === scan.firstCol &&
      words.length >= 2 &&
      (words[1].text.toLowerCase() === 'equ' || words[1].text.toLowerCase() === 'defl')
    ) {
      labelIndex = 0;
    } else if (first.col === scan.firstCol && !firstReserved && /^\s*[^\s=]+\s*=(?!=)/.test(text)) {
      labelIndex = 0;
    }

    const directiveIndex = labelIndex >= 0 ? 1 : 0;
    let directive = '';
    if (directiveIndex < words.length) {
      directive = words[directiveIndex].text.toLowerCase();
      if (directive[0] === '.') {
        directive = directive.slice(1);
      }
      ops[line] = { op: directive, col: words[directiveIndex].col };
    }

    // The name each word on this line stands for; filled in below for the
    // words that are definitions, and by the general rule for the rest.
    const names = new Array(words.length);
    const defines = new Array(words.length); // true where names[k] is a definition

    if (directive === 'endm' && macroName !== '') {
      macroName = '';
      macroParams = new Set();
      parent = savedParent;
    } else if (directive === 'ends') {
      structName = '';
    }

    if (directive === 'macro') {
      // Either "name MACRO p1, p2" or "MACRO name p1, p2".
      let nameIndex = labelIndex;
      if (nameIndex < 0) {
        nameIndex = directiveIndex + 1;
      }
      if (nameIndex < words.length) {
        const word = words[nameIndex];
        macroName = word.text;
        names[nameIndex] = macroName;
        defines[nameIndex] = true;
        defs.push({ name: macroName, line, col: word.col, len: word.text.length, kind: KIND_MACRO, container: '' });
        macroParams = new Set();
        for (let k = Math.max(nameIndex, directiveIndex) + 1; k < words.length; k++) {
          const param = words[k];
          const paramName = macroName + '(' + param.text + ')';
          macroParams.add(param.text);
          names[k] = paramName;
          defines[k] = true;
          defs.push({ name: paramName, line, col: param.col, len: param.text.length, kind: KIND_PARAM, container: macroName });
        }
        savedParent = parent;
        parent = macroName;
      }
      labelIndex = -1; // the name is taken; it is not also a label
    } else if (directive === 'struct' && directiveIndex + 1 < words.length) {
      const word = words[directiveIndex + 1];
      structName = word.text;
      names[directiveIndex + 1] = structName;
      defines[directiveIndex + 1] = true;
      defs.push({ name: structName, line, col: word.col, len: word.text.length, kind: KIND_STRUCT, container: '' });
    } else if ((directive === 'define' || directive === 'undefine') && directiveIndex + 1 < words.length) {
      const word = words[directiveIndex + 1];
      names[directiveIndex + 1] = word.text;
      if (directive === 'define') {
        defines[directiveIndex + 1] = true;
        defs.push({ name: word.text, line, col: word.col, len: word.text.length, kind: KIND_DEFINE, container: '' });
      }
    }

    if (labelIndex >= 0) {
      const word = words[0];
      let label = word.text;
      let kind = KIND_LABEL;
      let container = '';
      if (directive === 'equ' || directive === 'defl') {
        kind = KIND_CONSTANT;
      } else if (/^\s*[^\s=]+\s*=(?!=)/.test(text)) {
        kind = KIND_CONSTANT;
      }
      if (structName !== '') {
        // A struct's fields are offsets, named through the struct, and do not
        // start a new scope for local labels.
        if (label[0] === '.') {
          label = label.slice(1);
        }
        container = structName;
        label = structName + '.' + label;
        kind = KIND_FIELD;
      } else if (label[0] === '.') {
        container = parent;
        label = parent + label;
        if (kind === KIND_LABEL) {
          kind = KIND_LOCAL;
        }
      } else {
        if (label[0] === '@') {
          label = label.slice(1);
        }
        parent = label;
      }
      names[0] = label;
      defines[0] = true;
      defs.push({ name: label, line, col: word.col, len: word.text.length, kind, container });
    }

    if (FILE_DIRECTIVES.has(directive) && scan.strings.length > 0) {
      const s = scan.strings[0];
      includes.push({ target: s.text, line, col: s.col, len: s.len, directive });
    }

    // Every word that names something is a reference to it -- the definition
    // itself included, which Find All References filters out when asked to.
    let tokens;
    for (let k = 0; k < words.length; k++) {
      const word = words[k];
      let name = names[k];
      if (name === undefined) {
        if (macroName !== '' && macroParams.has(word.text)) {
          name = macroName + '(' + word.text + ')';
        } else if (CPU_WORDS.has(word.text.toLowerCase())) {
          continue;
        } else if (k === directiveIndex && DIRECTIVE_WORDS.has(word.text.toLowerCase())) {
          continue;
        } else if (word.text[0] === '.') {
          name = parent + word.text;
        } else if (word.text[0] === '@') {
          name = word.text.slice(1);
        } else {
          name = word.text;
        }
      }
      if (tokens === undefined) {
        tokens = [];
      }
      tokens.push({ col: word.col, len: word.text.length, name, def: defines[k] === true });
    }
    if (tokens !== undefined) {
      lines[line] = tokens;
    }
  }
  return { defs, lines, ops, includes, lineCount: sourceLines.length };
}

/// The key a file is filed under: its absolute path, case-folded on Windows
/// where the file system is.
function fileKey(filePath) {
  const normal = path.normalize(path.resolve(filePath));
  if (process.platform === 'win32') {
    return normal.toLowerCase();
  }
  return normal;
}

class AsmIndex {
  constructor() {
    this.files = new Map();   // key -> { path, parsed }
    this.byName = new Map();  // name -> [{ key, def }]
    this.componentCache = undefined; // key -> Set of keys, rebuilt on demand
  }

  /// Parses `text` as the current contents of `filePath`, replacing whatever
  /// was known about that file.
  update(filePath, text) {
    const key = fileKey(filePath);
    this.removeDefs(key);
    const parsed = parseAsm(text);
    this.files.set(key, { path: filePath, parsed });
    for (const def of parsed.defs) {
      let list = this.byName.get(def.name);
      if (list === undefined) {
        list = [];
        this.byName.set(def.name, list);
      }
      list.push({ key, def });
    }
    this.componentCache = undefined;
    return parsed;
  }

  updateFromDisk(filePath) {
    let text;
    try {
      text = fs.readFileSync(filePath, 'utf8');
    } catch (err) {
      this.remove(filePath);
      return undefined;
    }
    return this.update(filePath, text);
  }

  remove(filePath) {
    const key = fileKey(filePath);
    this.removeDefs(key);
    this.files.delete(key);
    this.componentCache = undefined;
  }

  removeDefs(key) {
    const entry = this.files.get(key);
    if (entry === undefined) {
      return;
    }
    for (const def of entry.parsed.defs) {
      const list = this.byName.get(def.name);
      if (list === undefined) {
        continue;
      }
      const kept = [];
      for (const item of list) {
        if (item.key !== key) {
          kept.push(item);
        }
      }
      if (kept.length > 0) {
        this.byName.set(def.name, kept);
      } else {
        this.byName.delete(def.name);
      }
    }
  }

  has(filePath) {
    return this.files.has(fileKey(filePath));
  }

  parsed(filePath) {
    const entry = this.files.get(fileKey(filePath));
    return entry === undefined ? undefined : entry.parsed;
  }

  /// The file an INCLUDE (or INCBIN) names. Relative to the including file
  /// first, as sjasmplus does; failing that, any indexed file whose path ends
  /// with the name, which covers a build's -I directories without knowing
  /// them. Returns a path or undefined.
  resolveInclude(fromPath, target) {
    const direct = path.resolve(path.dirname(fromPath), target);
    if (this.files.has(fileKey(direct)) || fs.existsSync(direct)) {
      return direct;
    }
    const suffix = fileKey(path.join(path.sep, target));
    for (const [key, entry] of this.files) {
      if (key.endsWith(suffix)) {
        return entry.path;
      }
    }
    return undefined;
  }

  /// The set of files `filePath` is assembled together with: everything
  /// reachable through INCLUDE in either direction.
  component(filePath) {
    if (this.componentCache === undefined) {
      this.buildComponents();
    }
    const found = this.componentCache.get(fileKey(filePath));
    if (found !== undefined) {
      return found;
    }
    return new Set([fileKey(filePath)]);
  }

  buildComponents() {
    const edges = new Map();
    for (const key of this.files.keys()) {
      edges.set(key, []);
    }
    for (const [key, entry] of this.files) {
      for (const inc of entry.parsed.includes) {
        if (inc.directive !== 'include') {
          continue;
        }
        const target = this.resolveInclude(entry.path, inc.target);
        if (target === undefined) {
          continue;
        }
        const targetKey = fileKey(target);
        if (!edges.has(targetKey)) {
          continue;
        }
        edges.get(key).push(targetKey);
        edges.get(targetKey).push(key);
      }
    }
    this.componentCache = new Map();
    for (const start of edges.keys()) {
      if (this.componentCache.has(start)) {
        continue;
      }
      const members = new Set([start]);
      const pending = [start];
      while (pending.length > 0) {
        const key = pending.pop();
        for (const next of edges.get(key)) {
          if (!members.has(next)) {
            members.add(next);
            pending.push(next);
          }
        }
      }
      for (const key of members) {
        this.componentCache.set(key, members);
      }
    }
  }

  /// The token under a position, or undefined. `line` and `col` are 0-based.
  tokenAt(filePath, line, col) {
    const parsed = this.parsed(filePath);
    if (parsed === undefined) {
      return undefined;
    }
    const tokens = parsed.lines[line];
    if (tokens === undefined) {
      return undefined;
    }
    for (const token of tokens) {
      if (col >= token.col && col <= token.col + token.len) {
        return token;
      }
    }
    return undefined;
  }

  /// The quoted file name of an INCLUDE or INCBIN under a position.
  includeAt(filePath, line, col) {
    const parsed = this.parsed(filePath);
    if (parsed === undefined) {
      return undefined;
    }
    for (const inc of parsed.includes) {
      if (inc.line === line && col >= inc.col && col < inc.col + inc.len) {
        return inc;
      }
    }
    return undefined;
  }

  /// The names a click at `col` in `token` could mean, most specific first.
  /// A dotted name is a path, so clicking OBJ in OBJ.FLAGS means the struct,
  /// and clicking FLAGS means the field.
  candidateNames(token, col) {
    const candidates = [];
    const name = token.name;
    // How far into the name the click landed. A local's name is longer than
    // its text by its parent's name, which sits in front.
    const hidden = name.length - token.len;
    const offset = hidden + (col - token.col);
    const nextDot = name.indexOf('.', Math.max(offset, 1));
    if (nextDot > 0 && nextDot < name.length) {
      // Only a prefix of what is actually written counts: the leading dot of
      // .loop is not a click on its parent.
      const prefix = name.slice(0, nextDot);
      if (prefix.length > hidden) {
        candidates.push(prefix);
      }
    }
    candidates.push(name);
    return candidates;
  }

  /// Definitions of the name under a position, as [{ path, def }], and the
  /// name they were found under.
  definitionsAt(filePath, line, col) {
    const token = this.tokenAt(filePath, line, col);
    if (token === undefined) {
      return { name: undefined, results: [] };
    }
    const candidates = this.candidateNames(token, col);
    for (const name of candidates) {
      const results = this.definitionsOf(name, filePath);
      if (results.length > 0) {
        return { name, results };
      }
    }
    // A .local that did not resolve against its parent -- sjasmplus scopes
    // them differently in a few corners (inside a macro expansion, after an
    // EQU) -- so settle for the nearest one above with that tail.
    const tail = token.name.slice(token.name.length - token.len);
    if (tail[0] === '.') {
      const parsed = this.parsed(filePath);
      let best;
      for (const def of parsed.defs) {
        if (def.line <= line && def.name.endsWith(tail) && (best === undefined || def.line > best.line)) {
          best = def;
        }
      }
      if (best !== undefined) {
        return { name: best.name, results: [{ path: filePath, def: best }] };
      }
    }
    return { name: token.name, results: [] };
  }

  /// Definitions of `name`, preferring the ones assembled with `fromPath`.
  definitionsOf(name, fromPath) {
    const list = this.byName.get(name);
    if (list === undefined) {
      return [];
    }
    const component = this.component(fromPath);
    const near = [];
    const all = [];
    for (const item of list) {
      const result = { path: this.files.get(item.key).path, def: item.def };
      all.push(result);
      if (component.has(item.key)) {
        near.push(result);
      }
    }
    return near.length > 0 ? near : all;
  }

  /// Every use of the name under a position, as [{ path, line, col, len }].
  /// The same files are searched that the definition was found in: the
  /// current file's include family if it defines the name, otherwise
  /// wherever it is defined, otherwise the whole workspace.
  referencesAt(filePath, line, col, includeDeclaration) {
    const found = this.definitionsAt(filePath, line, col);
    if (found.name === undefined) {
      return [];
    }
    const name = found.name;
    let scope;
    if (found.results.length > 0) {
      scope = new Set();
      for (const result of found.results) {
        for (const key of this.component(result.path)) {
          scope.add(key);
        }
      }
    }
    const declared = new Set();
    for (const result of found.results) {
      declared.add(fileKey(result.path) + ':' + result.def.line + ':' + result.def.col);
    }
    const references = [];
    for (const [key, entry] of this.files) {
      if (scope !== undefined && !scope.has(key)) {
        continue;
      }
      const lines = entry.parsed.lines;
      for (let i = 0; i < lines.length; i++) {
        const tokens = lines[i];
        if (tokens === undefined) {
          continue;
        }
        for (const token of tokens) {
          if (token.name !== name) {
            continue;
          }
          if (!includeDeclaration && declared.has(key + ':' + i + ':' + token.col)) {
            continue;
          }
          references.push({ path: entry.path, line: i, col: token.col, len: token.len });
        }
      }
    }
    return references;
  }

  // ---- rename ---------------------------------------------------------------

  /// What F2 at a position would rename, or { error }.
  ///
  /// Only the last segment of a dotted name changes -- renaming FLAGS in
  /// OBJ.FLAGS renames the field, renaming OBJ renames the struct and with it
  /// every OBJ.whatever -- and it changes wherever that segment is actually
  /// written. A .loop under start is written .loop inside start and start.loop
  /// elsewhere, and renaming start leaves every .loop exactly as it was.
  ///
  /// Returns { name, start, end, results, range } where [start, end) is the
  /// segment within name, and range is the editable part of the token at the
  /// position, { line, col, len }.
  renameTargetAt(filePath, line, col) {
    const token = this.tokenAt(filePath, line, col);
    if (token === undefined) {
      return { error: 'Nothing to rename here.' };
    }
    const found = this.definitionsAt(filePath, line, col);
    if (found.results.length === 0) {
      return { error: "'" + token.name + "' is not defined anywhere in the workspace." };
    }
    const components = new Set();
    for (const result of found.results) {
      components.add(this.component(result.path));
    }
    if (components.size > 1) {
      return {
        error:
          "'" + found.name + "' is defined in " + found.results.length +
          ' separate programs; rename it from a file that includes one of them.',
      };
    }
    const name = found.name;
    let start = name.lastIndexOf('.') + 1;
    let end = name.length;
    if (found.results[0].def.kind === KIND_PARAM) {
      start = name.indexOf('(') + 1;
      end = name.length - 1;
    }
    const range = this.segmentInToken(token, name, start, end);
    if (range === undefined) {
      return { error: "'" + name + "' is not written out here; rename it where it is." };
    }
    return { name, start, end, results: found.results, range: { line, col: range.col, len: range.len } };
  }

  /// Where the [start, end) segment of `name` is written in `token`, as
  /// { col, len }, or undefined if the token does not name it or leaves that
  /// part implied.
  segmentInToken(token, name, start, end) {
    if (token.name !== name && !token.name.startsWith(name + '.')) {
      return undefined;
    }
    if (name.endsWith(')')) {
      // A macro parameter, filed as macro(param) and written as param.
      return { col: token.col, len: token.len };
    }
    // A token's text is the tail of its name: .loop is written for start.loop,
    // and @label for label, which makes the text one longer than the name.
    const hidden = token.name.length - token.len;
    const textStart = start - hidden;
    if (textStart < 0) {
      return undefined;
    }
    return { col: token.col + textStart, len: end - start };
  }

  /// The edits that rename the symbol at a position to `newText`, as
  /// { edits: [{ path, line, col, len, text }] } or { error }.
  renameEdits(filePath, line, col, newText) {
    const target = this.renameTargetAt(filePath, line, col);
    if (target.error !== undefined) {
      return target;
    }
    let text = newText.trim();
    const kind = target.results[0].def.kind;
    if (kind === KIND_LOCAL && text[0] === '.') {
      text = text.slice(1);
    }
    if (!SEGMENT_PATTERN.test(text)) {
      return { error: "'" + newText + "' is not a name sjasmplus accepts here (no dots, and it starts with a letter or _)." };
    }
    const lower = text.toLowerCase();
    if (CPU_WORDS.has(lower) || DIRECTIVE_WORDS.has(lower)) {
      return { error: "'" + text + "' is a reserved word." };
    }
    const renamed = target.name.slice(0, target.start) + text + target.name.slice(target.end);
    if (renamed === target.name) {
      return { edits: [] };
    }

    const scope = this.component(target.results[0].path);
    const clash = this.byName.get(renamed);
    if (clash !== undefined) {
      for (const item of clash) {
        if (scope.has(item.key)) {
          return { error: "'" + renamed + "' is already defined." };
        }
      }
    }

    const edits = [];
    for (const key of scope) {
      const entry = this.files.get(key);
      if (entry === undefined) {
        continue;
      }
      const lines = entry.parsed.lines;
      for (let i = 0; i < lines.length; i++) {
        const tokens = lines[i];
        if (tokens === undefined) {
          continue;
        }
        for (const token of tokens) {
          const segment = this.segmentInToken(token, target.name, target.start, target.end);
          if (segment !== undefined) {
            edits.push({ path: entry.path, line: i, col: segment.col, len: segment.len, text });
          }
        }
      }
    }
    return { edits };
  }

  // ---- call hierarchy -------------------------------------------------------

  /// The routine the call hierarchy starts from at a position, as
  /// { path, def }: the label, local or macro under the cursor if it is one,
  /// otherwise the routine the cursor is inside.
  callItemAt(filePath, line, col) {
    const found = this.definitionsAt(filePath, line, col);
    for (const result of found.results) {
      if (isCallable(result.def.kind)) {
        return result;
      }
    }
    const parsed = this.parsed(filePath);
    if (parsed === undefined) {
      return undefined;
    }
    const def = enclosingDef(parsed, line, false);
    if (def === undefined) {
      return undefined;
    }
    return { path: filePath, def };
  }

  /// The last line of a routine: the line before the next routine starts.
  /// A label's reach includes its own locals; a local's stops at the next one.
  routineEnd(filePath, def) {
    const parsed = this.parsed(filePath);
    if (parsed === undefined) {
      return def.line;
    }
    const topLevel = def.kind !== KIND_LOCAL;
    for (const other of parsed.defs) {
      if (other.line <= def.line) {
        continue;
      }
      if (other.kind === KIND_LABEL || other.kind === KIND_MACRO || other.kind === KIND_STRUCT) {
        return other.line - 1;
      }
      if (!topLevel && other.kind === KIND_LOCAL) {
        return other.line - 1;
      }
    }
    return parsed.lineCount - 1;
  }

  /// Who calls, jumps to or invokes `item`, as
  /// [{ caller: { path, def }, ranges: [{ line, col, len }] }]. The caller is
  /// the routine each site is in -- its top-level label, so a call from
  /// sprite_blit.loop is listed under sprite_blit -- or, for code above the
  /// first label, a stand-in named after the file.
  incomingCalls(item) {
    const name = item.def.name;
    const groups = new Map();
    const order = [];
    for (const key of this.component(item.path)) {
      const entry = this.files.get(key);
      if (entry === undefined) {
        continue;
      }
      const parsed = entry.parsed;
      for (let i = 0; i < parsed.lines.length; i++) {
        const tokens = parsed.lines[i];
        if (tokens === undefined) {
          continue;
        }
        for (const token of tokens) {
          if (token.def || token.name !== name || !isCallSite(parsed.ops[i], token)) {
            continue;
          }
          let caller = enclosingDef(parsed, i, true);
          if (caller === undefined) {
            caller = { name: path.basename(entry.path), line: 0, col: 0, len: 0, kind: KIND_LABEL, container: '' };
          }
          const groupKey = key + ':' + caller.line + ':' + caller.name;
          let group = groups.get(groupKey);
          if (group === undefined) {
            group = { caller: { path: entry.path, def: caller }, ranges: [] };
            groups.set(groupKey, group);
            order.push(group);
          }
          group.ranges.push({ line: i, col: token.col, len: token.len });
        }
      }
    }
    return order;
  }

  /// What `item` calls, jumps to or invokes, as
  /// [{ target: { path, def }, ranges: [{ line, col, len }] }]. Jumps that
  /// stay inside the routine -- to itself or its own locals -- are control
  /// flow, not calls, and are left out.
  outgoingCalls(item) {
    const parsed = this.parsed(item.path);
    if (parsed === undefined) {
      return [];
    }
    const own = item.def.kind === KIND_LOCAL ? item.def.container : item.def.name;
    const end = this.routineEnd(item.path, item.def);
    const groups = new Map();
    const order = [];
    for (let i = item.def.line; i <= end; i++) {
      const tokens = parsed.lines[i];
      if (tokens === undefined) {
        continue;
      }
      for (const token of tokens) {
        if (token.def || !isCallSite(parsed.ops[i], token)) {
          continue;
        }
        const results = this.definitionsOf(token.name, item.path);
        let target;
        for (const result of results) {
          if (isCallable(result.def.kind)) {
            target = result;
            break;
          }
        }
        if (target === undefined) {
          continue;
        }
        if (target.def.name === own || target.def.container === own) {
          continue;
        }
        const groupKey = fileKey(target.path) + ':' + target.def.line + ':' + target.def.name;
        let group = groups.get(groupKey);
        if (group === undefined) {
          group = { target, ranges: [] };
          groups.set(groupKey, group);
          order.push(group);
        }
        group.ranges.push({ line: i, col: token.col, len: token.len });
      }
    }
    return order;
  }
}

function isCallable(kind) {
  return kind === KIND_LABEL || kind === KIND_LOCAL || kind === KIND_MACRO;
}

/// Whether `token` on a line whose instruction is `op` transfers control to
/// what it names: the operand of a call or jump, or a macro invocation in the
/// instruction's own place.
function isCallSite(op, token) {
  if (op === undefined) {
    return false;
  }
  if (CALL_OPS.has(op.op)) {
    return true;
  }
  return token.col === op.col;
}

/// The routine a line is in: the last label (or macro) at or above it, and
/// when `topLevelOnly` is false a local counts too.
function enclosingDef(parsed, line, topLevelOnly) {
  let best;
  for (const def of parsed.defs) {
    if (def.line > line) {
      break;
    }
    if (def.kind === KIND_LABEL || def.kind === KIND_MACRO || (!topLevelOnly && def.kind === KIND_LOCAL)) {
      best = def;
    }
  }
  return best;
}

module.exports = {
  AsmIndex,
  parseAsm,
  scanLine,
  fileKey,
  KIND_LABEL,
  KIND_LOCAL,
  KIND_CONSTANT,
  KIND_MACRO,
  KIND_PARAM,
  KIND_STRUCT,
  KIND_FIELD,
  KIND_DEFINE,
};
