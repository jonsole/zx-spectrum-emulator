// The comment above a Z80 routine, and the register contract in it.
//
// A routine's header says what it wants in which registers, what it hands
// back, and what it leaves changed. The hover in asm_language.js shows those
// three first, as a table, and the rest of the comment as prose after them,
// so the one thing a caller has to know is not somewhere in paragraph four.
//
// The format asked for is three labelled lines, directly above the label:
//
//   ; In:  IX -> the object
//   ;      A  = the step in Z
//   ; Out: DE -> the NEXT field that named us
//   ;      Z set if it did not move
//   ; Corrupts: F, BC, HL
//
// with a continuation indented under its line, `->` for a pointer and `=` for
// a value. But sources that predate it are read too, because the workspace is
// full of them: inputs as indented register lines with no label
// (`;   IX -> the object`), `Entry:`/`Exit:` and `On entry:`/`On exit:` as
// other names for In and Out, `Corrupts AF, C.` as a sentence rather than a
// label, and a Corrupts or Preserves sentence tacked onto the end of an Out
// line.
//
// Nothing here touches the vscode API -- tests/asm_doc_test.js runs it from
// plain Node.

// Lines between a header and its label that are not part of either: sjasmplus
// directives a routine is commonly guarded or aligned with.
const BETWEEN_HEADER_AND_LABEL = /^\s+(ASSERT|IFUSED|IFNUSED|ALIGN)\b/i;

// A line of rules -- ;;;;; or ; ------ -- which separates, and says nothing.
const RULE = /^[-=*;+#~_ ]{3,}$/;

// A labelled line. In and Out need their colon: without one, "In the pool,
// ..." is a sentence. The ones that only ever start a sentence about
// registers do not.
const LABELS = [
  { re: /^(?:In|Inputs?|Entry|On entry)\s*:\s*/i, section: 'in' },
  { re: /^(?:Out|Outputs?|Exit|On exit|Returns)\s*:\s*/i, section: 'out' },
  { re: /^(?:Corrupts|Clobbers|Destroys)\b\s*:?\s*/i, section: 'corrupts' },
  { re: /^Preserves\b\s*:?\s*/i, section: 'preserves' },
];

// A register, or a run of them -- "IX", "B, C", "HL and DE" -- at the front
// of a line, then how it is being described: -> a pointer, = or - a value.
const REGISTER = "(?:AF'|AF|BC|DE|HL|IX|IY|SP|IXH|IXL|IYH|IYL|A|B|C|D|E|H|L|F)";
const REGISTER_LINE = new RegExp(
  '^(' + REGISTER + '(?:\\s*(?:,|and)\\s*' + REGISTER + ')*)\\s*(->|=|-)\\s+(.*)$'
);

// Inside an In or Out list, a variable in memory can be an entry too --
// "collide_mask - the bit to set", "(Sub_FFE4) = the seed" -- where it could
// not start one, because an indented word followed by a dash is as likely to
// be prose.
const NAME = "(?:\\([^)]*\\)|[A-Za-z_][\\w.']*)";
const NAMED_LINE = new RegExp(
  '^(' + NAME + '(?:\\s*(?:,|and)\\s*' + NAME + ')*)\\s*(->|=|-)\\s+(.*)$'
);

// Where an Out line goes on to say what it corrupts or keeps.
const TACKED_ON = /(?<=[.;])\s+(?=(?:Corrupts|Clobbers|Destroys|Preserves)\b)/;

/// The comment block directly above a definition, with the semicolons taken
/// off -- the ROM disassembly and the engine sources both put a routine's
/// description there. Blank comment lines are kept as '' to break paragraphs;
/// a line of rules (;;;;; or ; -----) is dropped. An ASSERT, IFUSED or ALIGN
/// between the comment and the label is stepped over, not taken for the end
/// of the comment. At most `maxLines` are read, counting up from the label,
/// so a long history is cut from the top and never the register lines.
function commentAbove(lines, defLine, maxLines) {
  const block = [];
  let line = defLine - 1;
  while (line >= 0 && BETWEEN_HEADER_AND_LABEL.test(lines[line])) {
    line--;
  }
  while (line >= 0 && block.length < maxLines) {
    const trimmed = lines[line].trim();
    if (trimmed[0] !== ';') {
      break;
    }
    block.push(trimmed.replace(/^;+\s?/, '').replace(/\s+$/, ''));
    line--;
  }
  block.reverse();
  const kept = [];
  for (const text of block) {
    if (RULE.test(text)) {
      continue;
    }
    kept.push(text);
  }
  while (kept.length > 0 && kept[0] === '') {
    kept.shift();
  }
  while (kept.length > 0 && kept[kept.length - 1] === '') {
    kept.pop();
  }
  return kept;
}

/// One In or Out entry: `{ reg: 'IX', op: '->', text: 'the object' }`, or
/// `{ reg: '', op: '', text }` for one that does not start with a register --
/// "Z set if it did not move", "nothing".
function entry(text) {
  const m = REGISTER_LINE.exec(text) || NAMED_LINE.exec(text);
  if (m) {
    return { reg: m[1], op: m[2] === '-' ? '=' : m[2], text: m[3] };
  }
  return { reg: '', op: '', text };
}

function labelOf(text) {
  for (const label of LABELS) {
    const m = label.re.exec(text);
    if (m) {
      return { section: label.section, rest: text.slice(m[0].length) };
    }
  }
  return undefined;
}

/// Splits a comment (as commentAbove returns it) into its register contract
/// and its prose:
///
///   { inputs: [entry], outputs: [entry], corrupts: string, preserves: string,
///     prose: [line] }
///
/// `corrupts` and `preserves` are the text after the word, or '' when the
/// comment does not say. A routine with no contract at all comes back with
/// every part empty but the prose, which is then the whole comment.
function parseContract(comment) {
  const result = { inputs: [], outputs: [], corrupts: '', preserves: '', prose: [] };
  let section = '';     // '' while in prose
  // The entry or field a continuation line extends. An entry also carries
  // the column its text starts at, and whether it hangs off a label: a line
  // indented to that column under a label is the next entry -- "Z set if it
  // moved" under "Out: DE -> ..." -- and one indented further continues it.
  let last = null;

  const addTo = (name, text, col, labelled) => {
    if (name === 'in' || name === 'out') {
      const e = entry(text);
      (name === 'in' ? result.inputs : result.outputs).push(e);
      last = { entry: e, col, labelled };
      return;
    }
    const field = name === 'corrupts' ? 'corrupts' : 'preserves';
    result[field] = result[field] ? result[field] + ' ' + text : text;
    last = { field };
  };
  const extend = (text) => {
    if (last.entry) {
      last.entry.text += ' ' + text;
    } else {
      result[last.field] += ' ' + text;
    }
  };

  for (const raw of comment) {
    if (raw === '') {
      section = '';
      last = null;
      result.prose.push(raw);
      continue;
    }
    const text = raw.trim();
    const indent = raw.length - raw.trimStart().length;
    const indented = indent > 0;

    const label = labelOf(text);
    if (label) {
      section = label.section;
      // "Out: Z set if it moved. Corrupts AF." -- one line, two parts.
      const parts = label.rest.split(TACKED_ON);
      addTo(section, parts[0], indent + text.length - label.rest.length, true);
      for (let i = 1; i < parts.length; i++) {
        const more = labelOf(parts[i]);
        section = more.section;
        addTo(section, more.rest, 0, true);
      }
      continue;
    }

    // An indented register line with no label is an input, in the style
    // that came before In: -- and another input if one is already open.
    if (indented && (section === '' || section === 'in') && REGISTER_LINE.test(text)) {
      section = 'in';
      addTo('in', text, indent, false);
      continue;
    }

    if (section !== '' && last !== null) {
      // Indented under its line: the next entry, or a continuation.
      if (indented) {
        const next = last.entry && indent <= last.col && (last.labelled || NAMED_LINE.test(text));
        if (next) {
          addTo(section, text, indent, last.labelled);
        } else {
          extend(text);
        }
        continue;
      }
      // An Out that ran on to the next line without indenting, as some
      // older headers do: it has not finished its sentence yet.
      if (section === 'out' && last.entry && !/[.;:]$/.test(last.entry.text)) {
        extend(text);
        continue;
      }
    }

    section = '';
    last = null;
    result.prose.push(raw);
  }

  // The contract usually sat between two paragraphs; what is left of the
  // blank lines around it should not double up.
  const prose = [];
  for (const line of result.prose) {
    if (line === '' && (prose.length === 0 || prose[prose.length - 1] === '')) {
      continue;
    }
    prose.push(line);
  }
  while (prose.length > 0 && prose[prose.length - 1] === '') {
    prose.pop();
  }
  result.prose = prose;
  return result;
}

/// Whether a parsed comment says anything about registers.
function hasContract(contract) {
  return contract.inputs.length > 0 || contract.outputs.length > 0 ||
    contract.corrupts !== '' || contract.preserves !== '';
}

function escapeMarkdown(text) {
  return text.replace(/[\\`*_{}[\]()#+\-.!|<>~]/g, '\\$&');
}

/// The contract as a Markdown table: a row an entry, the section named on
/// its first row, registers as code.
function contractMarkdown(contract) {
  const rows = [];
  const cell = (e) => {
    if (e.reg === '') {
      return escapeMarkdown(e.text);
    }
    return '`' + e.reg + '` ' + (e.op === '->' ? '&rarr;' : '=') + ' ' + escapeMarkdown(e.text);
  };
  const section = (name, entries) => {
    entries.forEach((e, i) => rows.push('| ' + (i === 0 ? '**' + name + '**' : '') + ' | ' + cell(e) + ' |'));
  };
  section('In', contract.inputs);
  section('Out', contract.outputs);
  if (contract.corrupts !== '') {
    rows.push('| **Corrupts** | ' + escapeMarkdown(contract.corrupts) + ' |');
  }
  if (contract.preserves !== '') {
    rows.push('| **Preserves** | ' + escapeMarkdown(contract.preserves) + ' |');
  }
  if (rows.length === 0) {
    return '';
  }
  return '| | |\n|:--|:--|\n' + rows.join('\n') + '\n';
}

/// Prose lines as Markdown: each line kept as it is, a blank one a paragraph.
function proseMarkdown(prose) {
  let text = '';
  for (const line of prose) {
    if (line === '') {
      text += '\n\n';
    } else {
      text += escapeMarkdown(line) + '  \n';
    }
  }
  return text;
}

module.exports = {
  commentAbove,
  parseContract,
  hasContract,
  contractMarkdown,
  proseMarkdown,
  escapeMarkdown,
};
