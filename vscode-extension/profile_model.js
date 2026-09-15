// The execution profile as the editor shows it: which lines of which files
// are hot, how hot, and what to write beside them.
//
// The server does the counting and the folding into source lines (see
// cpp-core/src/profile_report.h); this turns its report into what the heat
// map needs, and nothing here touches the vscode API -- so it can be tested
// from plain Node, see tests/profile_model_test.js.

const path = require('path');
const { fileKey } = require('./asm_index');

// Share of all profiled time at which a line reaches each heat level. A line
// has to earn its colour: a 64-line routine evenly spread would otherwise
// paint the whole screen one shade and point at nothing.
const HEAT_THRESHOLDS = [0.001, 0.0025, 0.01, 0.025, 0.05, 0.1];
const HEAT_LEVELS = HEAT_THRESHOLDS.length;
// Lines at or above this share get their numbers written beside them. Below
// it the colour alone says "some", and text on every line that ran would
// drown the code.
const LABEL_SHARE = 0.005;

/// 0 for a line too cool to colour, 1..HEAT_LEVELS otherwise.
function heatLevel(share) {
  let level = 0;
  for (let i = 0; i < HEAT_THRESHOLDS.length; i++) {
    if (share >= HEAT_THRESHOLDS[i]) {
      level = i + 1;
    }
  }
  return level;
}

function formatCount(n) {
  if (n >= 100) {
    return Math.round(n).toLocaleString('en-GB');
  }
  if (n >= 10) {
    return n.toFixed(1);
  }
  return n.toFixed(2);
}

function formatShare(share) {
  const percent = share * 100;
  if (percent >= 10) {
    return percent.toFixed(0) + '%';
  }
  return percent.toFixed(1) + '%';
}

/// A report, indexed for the editor:
///
///   total      T-states profiled, interrupts included
///   frames     video frames that passed while counting (0 when only stepped)
///   byFile     file key -> Map(line -> { hits, tstates, symbol, share })
///   routines   by file key -> Map(line -> routine), for the label lines
///   byName     base name -> [file keys], for a path the SLD spelt differently
///
/// Lines are 1-based, as the report has them.
function indexReport(report) {
  const model = {
    active: !!report.active,
    frames: report.frames || 0,
    total: report.tstates || 0,
    interruptTstates: report.interrupt_tstates || 0,
    unmappedTstates: report.unmapped_tstates || 0,
    lines: report.lines || [],
    routines: report.routines || [],
    callTree: indexCallTree(report),
    byFile: new Map(),
    routinesByFile: new Map(),
    byName: new Map(),
  };
  for (const line of model.lines) {
    const key = fileKey(line.path);
    let lines = model.byFile.get(key);
    if (lines === undefined) {
      lines = new Map();
      model.byFile.set(key, lines);
      const base = path.basename(key);
      let keys = model.byName.get(base);
      if (keys === undefined) {
        keys = [];
        model.byName.set(base, keys);
      }
      keys.push(key);
    }
    lines.set(line.line, {
      hits: line.hits,
      tstates: line.tstates,
      symbol: line.symbol,
      share: model.total > 0 ? line.tstates / model.total : 0,
    });
  }
  for (const routine of model.routines) {
    if (!routine.path) {
      continue;
    }
    const key = fileKey(routine.path);
    let lines = model.routinesByFile.get(key);
    if (lines === undefined) {
      lines = new Map();
      model.routinesByFile.set(key, lines);
    }
    lines.set(routine.line, {
      name: routine.name,
      hits: routine.hits,
      tstates: routine.tstates,
      share: model.total > 0 ? routine.tstates / model.total : 0,
    });
  }
  return model;
}

/// The key the report files `filePath` under: its own if the report has it,
/// otherwise the one report file with the same name -- an SLD records files
/// the way the assembler was handed them, which is not always how the editor
/// opened them. Undefined if neither.
function reportKeyFor(model, filePath) {
  const key = fileKey(filePath);
  if (model.byFile.has(key) || model.routinesByFile.has(key)) {
    return key;
  }
  const keys = model.byName.get(path.basename(key));
  if (keys !== undefined && keys.length === 1) {
    return keys[0];
  }
  return undefined;
}

/// What each measure reads per: per frame when frames passed, so the numbers
/// mean the same thing whether the profile ran for one second or a minute;
/// totals when it was only stepped.
function perFrame(model, value) {
  return model.frames > 0 ? value / model.frames : value;
}

/// The text written after a hot line: its share, its cost, how often it ran.
/// Undefined for lines too cool to label. A routine's label line leads with
/// the routine's total.
function lineLabel(model, stats, routine) {
  const parts = [];
  const unit = model.frames > 0 ? '/frame' : '';
  if (routine !== undefined && routine.share >= LABEL_SHARE) {
    parts.push(`${routine.name} ${formatShare(routine.share)} · ${formatCount(perFrame(model, routine.tstates))} T${unit}`);
  }
  if (stats !== undefined && stats.share >= LABEL_SHARE) {
    parts.push(`${formatShare(stats.share)} · ${formatCount(perFrame(model, stats.tstates))} T${unit} · ${formatCount(perFrame(model, stats.hits))}×${unit}`);
  }
  if (parts.length === 0) {
    return undefined;
  }
  return parts.join('   |   ');
}

/// The hover for a line that ran: every number, not just the rounded ones.
function lineHover(model, stats, routine) {
  const rows = [];
  if (stats !== undefined) {
    const average = stats.hits > 0 ? stats.tstates / stats.hits : 0;
    rows.push(`**Profile** -- ${formatShare(stats.share)} of ${formatCount(model.total)} T-states profiled`);
    rows.push(`${stats.tstates.toLocaleString('en-GB')} T-states over ${stats.hits.toLocaleString('en-GB')} runs, ${average.toFixed(1)} T a run`);
    if (model.frames > 0) {
      rows.push(`${formatCount(stats.tstates / model.frames)} T and ${formatCount(stats.hits / model.frames)} runs a frame, over ${model.frames.toLocaleString('en-GB')} frames`);
    }
    if (stats.symbol) {
      rows.push(`at \`${stats.symbol}\``);
    }
  }
  if (routine !== undefined) {
    rows.push(`**${routine.name}**, the whole routine: ${formatShare(routine.share)}, ${formatCount(perFrame(model, routine.tstates))} T${model.frames > 0 ? ' a frame' : ''}`);
  }
  return rows.join('  \n');
}

// ---- the call tree ------------------------------------------------------------
//
// The server sends the calling-context tree flat: one node per call path,
// with its parent, its own time and its total. The profile view shows it
// grouped by routine instead, because that is the question asked of it --
// "what does sprite_blit cost, and what in it" -- and sprite_blit may be
// called along a dozen paths:
//
//   top level     every routine, with everything spent in it however it was
//                 reached (a routine that recurses counted once, from its
//                 outermost call)
//   expanded      the routines IT called, with what those calls cost it --
//                 merged across all its paths, and each expandable the same
//                 way -- plus a row for its own code

/// Indexes report.call_nodes: children by id, and each node's key -- its
/// routine name, with interrupt handlers kept apart from calls to the same
/// code.
function indexCallTree(report) {
  const nodes = report.call_nodes || [];
  const children = [];
  for (let i = 0; i < nodes.length; i++) {
    children.push([]);
  }
  for (let i = 0; i < nodes.length; i++) {
    const parent = nodes[i].parent;
    if (parent !== null && parent !== undefined && parent < nodes.length) {
      children[parent].push(i);
    }
  }
  return { nodes, children };
}

function groupKey(node) {
  return (node.interrupt ? 'interrupt:' : 'call:') + node.name;
}

function newGroup(node, id) {
  return {
    key: groupKey(node),
    name: node.name,
    interrupt: !!node.interrupt,
    ownCode: false,
    path: node.path,
    line: node.line,
    nodes: [],
    calls: 0,
    self: 0,
    total: 0,
    hasChildren: false,
    id,
  };
}

function addNode(tree, group, index) {
  const node = tree.nodes[index];
  group.nodes.push(index);
  group.calls += node.calls;
  group.self += node.self_tstates;
  group.total += node.tstates;
  if (tree.children[index].length > 0) {
    group.hasChildren = true;
  }
}

function sortGroups(groups, sortBy) {
  groups.sort((a, b) => {
    const x = sortBy === 'self' ? a.self : a.total;
    const y = sortBy === 'self' ? b.self : b.total;
    if (x !== y) {
      return y - x;
    }
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  });
  return groups;
}

/// The top level: one group per routine.
function rootGroups(tree, sortBy) {
  const byKey = new Map();
  const groups = [];
  const nodes = tree.nodes;
  for (let i = 1; i < nodes.length; i++) {
    // Only a routine's outermost calls: a node with an ancestor of the same
    // routine is already inside that ancestor's total.
    const key = groupKey(nodes[i]);
    let nested = false;
    let parent = nodes[i].parent;
    while (parent !== null && parent !== undefined && parent > 0) {
      if (groupKey(nodes[parent]) === key) {
        nested = true;
        break;
      }
      parent = nodes[parent].parent;
    }
    if (nested) {
      continue;
    }
    let group = byKey.get(key);
    if (group === undefined) {
      group = newGroup(nodes[i], key);
      byKey.set(key, group);
      groups.push(group);
    }
    addNode(tree, group, i);
  }
  // Code that ran outside any call seen: the main loop, typically.
  if (nodes.length > 0 && nodes[0].self_tstates > 0) {
    const root = newGroup(nodes[0], 'root');
    root.ownCode = true;
    root.calls = 0;
    root.self = nodes[0].self_tstates;
    root.total = nodes[0].self_tstates;
    groups.push(root);
  }
  return sortGroups(groups, sortBy);
}

/// What `group`'s routine called, merged across its paths, and its own code.
function childGroups(tree, group, sortBy) {
  const byKey = new Map();
  const groups = [];
  for (const index of group.nodes) {
    for (const childIndex of tree.children[index]) {
      const node = tree.nodes[childIndex];
      const key = groupKey(node);
      let child = byKey.get(key);
      if (child === undefined) {
        child = newGroup(node, group.id + '/' + key);
        byKey.set(key, child);
        groups.push(child);
      }
      addNode(tree, child, childIndex);
    }
  }
  if (groups.length > 0 && group.self > 0) {
    groups.push({
      key: 'own',
      name: '(own code)',
      interrupt: false,
      ownCode: true,
      path: group.path,
      line: group.line,
      nodes: [],
      calls: 0,
      self: group.self,
      total: group.self,
      hasChildren: false,
      id: group.id + '/own',
    });
  }
  return sortGroups(groups, sortBy);
}

/// The description shown beside a group: its share, its cost a frame, and
/// how often it was called -- by whichever measure the tree is sorted on, so
/// the numbers read in the order the rows are in.
function groupDescription(model, group, sortBy) {
  const unit = model.frames > 0 ? '/frame' : '';
  const own = sortBy === 'self' && !group.ownCode;
  const value = own ? group.self : group.total;
  const share = model.total > 0 ? value / model.total : 0;
  let text = `${own ? 'own ' : ''}${formatShare(share)} · ${formatCount(perFrame(model, value))} T${unit}`;
  if (own) {
    text += ` · total ${formatShare(model.total > 0 ? group.total / model.total : 0)}`;
  }
  if (!group.ownCode && group.calls > 0) {
    text += ` · ${formatCount(perFrame(model, group.calls))} calls${unit}`;
  }
  return text;
}

function groupTooltip(model, group) {
  const unit = model.frames > 0 ? ' a frame' : '';
  const rows = [];
  rows.push(group.interrupt ? `Interrupt handler ${group.name}` : group.name);
  rows.push(`Total: ${formatShare(model.total > 0 ? group.total / model.total : 0)}, ` +
    `${formatCount(perFrame(model, group.total))} T${unit}`);
  if (!group.ownCode) {
    rows.push(`Own code: ${formatShare(model.total > 0 ? group.self / model.total : 0)}, ` +
      `${formatCount(perFrame(model, group.self))} T${unit}`);
    if (group.calls > 0) {
      rows.push(`${formatCount(perFrame(model, group.calls))} calls${unit}, ` +
        `${(group.total / group.calls).toFixed(1)} T a call`);
    }
    if (group.nodes.length > 1) {
      rows.push(`Reached along ${group.nodes.length} call paths`);
    }
  }
  return rows.join('\n');
}

module.exports = {
  indexCallTree,
  rootGroups,
  childGroups,
  groupDescription,
  groupTooltip,
  HEAT_LEVELS,
  LABEL_SHARE,
  heatLevel,
  indexReport,
  reportKeyFor,
  lineLabel,
  lineHover,
  formatShare,
  formatCount,
  perFrame,
};
