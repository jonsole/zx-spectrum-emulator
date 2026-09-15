// The execution profile as the editor shows it: which lines of which files
// are hot, how hot, and what to write beside them; the call tree grouped by
// routine; and the worst frames.
//
// The server does the counting and the folding into source lines (see
// cpp-core/src/profile_report.h); this turns its report into what the heat
// map and the tree need, and nothing here touches the vscode API -- so it can
// be tested from plain Node, see tests/profile_model_test.js.
//
// Shares are of BUSY time: everything counted, less what was idle (a HALT
// waiting, or a routine marked idle). A game that spends most of each frame
// in its pacing loop would otherwise read as 58% pacer and a squeezed few
// percent of everything worth optimising. Idle lines and routines are shown
// as idle, with their time, but no share and no heat.

const path = require('path');
const { fileKey } = require('./asm_index');

// Share of busy time at which a line reaches each heat level. A line has to
// earn its colour: a 64-line routine evenly spread would otherwise paint the
// whole screen one shade and point at nothing.
const HEAT_THRESHOLDS = [0.001, 0.0025, 0.01, 0.025, 0.05, 0.1];
const HEAT_LEVELS = HEAT_THRESHOLDS.length;
// Lines at or above this share get their numbers written beside them. Below
// it the colour alone says "some", and text on every line that ran would
// drown the code.
const LABEL_SHARE = 0.005;
// How much of something's time has to be idle for it to count as idle. Not
// all of it: the pass that first reaches a HALT is not waiting yet.
const IDLE_FRACTION = 0.9;
const SPARK_BLOCKS = '▁▂▃▄▅▆▇█';

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

function isIdle(tstates, idle) {
  return tstates > 0 && idle >= tstates * IDLE_FRACTION;
}

/// A report, indexed for the editor:
///
///   total      T-states profiled, interrupts included
///   idle       the idle part of it; busy = total - idle
///   frames     video frames that passed while counting (0 when only stepped,
///              or for a single period)
///   byFile     file key -> Map(line -> { hits, tstates, idle, symbol, share })
///   routines   by file key -> Map(line -> routine), for the label lines
///   byName     base name -> [file keys], for a path the SLD spelt differently
///   callTree   the call nodes, indexed -- see the call tree below
///   periods    the report's periods, strip and worst, as sent
///
/// Lines are 1-based, as the report has them.
function indexReport(report) {
  const total = report.tstates || 0;
  const idle = report.idle_tstates || 0;
  const model = {
    report,
    active: !!report.active,
    frames: report.frames || 0,
    total,
    idle,
    busy: total - idle,
    interruptTstates: report.interrupt_tstates || 0,
    unmappedTstates: report.unmapped_tstates || 0,
    frameTstates: report.frame_tstates || 0,
    idleNames: report.idle || [],
    unresolved: report.unresolved || [],
    periods: report.periods,
    period: report.period, // set when this model is one worst period
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
    lines.set(line.line, statsFor(model, line, { symbol: line.symbol }));
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
    lines.set(routine.line, statsFor(model, routine, { name: routine.name }));
  }
  return model;
}

function statsFor(model, entry, extra) {
  const tstates = entry.tstates || 0;
  const idle = entry.idle_tstates || 0;
  return Object.assign(
    {
      hits: entry.hits,
      tstates,
      idleTstates: idle,
      idle: isIdle(tstates, idle),
      share: model.busy > 0 ? (tstates - idle) / model.busy : 0,
    },
    extra
  );
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
/// totals when it was only stepped, or is a single period.
function perFrame(model, value) {
  return model.frames > 0 ? value / model.frames : value;
}

function unitOf(model) {
  return model.frames > 0 ? '/frame' : '';
}

/// The text written after a line that ran: its share, its cost, how often it
/// ran. Undefined for lines too cool to label. An idle line says so instead
/// of having a share. A routine's label line leads with the routine's total.
function lineLabel(model, stats, routine) {
  const parts = [];
  const unit = unitOf(model);
  if (routine !== undefined) {
    if (routine.idle) {
      if (model.total > 0 && routine.tstates / model.total >= LABEL_SHARE) {
        parts.push(`${routine.name} idle · ${formatCount(perFrame(model, routine.tstates))} T${unit}`);
      }
    } else if (routine.share >= LABEL_SHARE) {
      parts.push(`${routine.name} ${formatShare(routine.share)} · ${formatCount(perFrame(model, routine.tstates))} T${unit}`);
    }
  }
  if (stats !== undefined) {
    let text;
    if (stats.idle) {
      if (model.total > 0 && stats.tstates / model.total >= LABEL_SHARE) {
        text = `idle · ${formatCount(perFrame(model, stats.tstates))} T${unit}`;
      }
    } else if (stats.share >= LABEL_SHARE) {
      text = `${formatShare(stats.share)} · ${formatCount(perFrame(model, stats.tstates))} T${unit}`;
    }
    if (text !== undefined) {
      if (stats.hits !== undefined) {
        text += ` · ${formatCount(perFrame(model, stats.hits))}×${unit}`;
      }
      parts.push(text);
    }
  }
  if (parts.length === 0) {
    return undefined;
  }
  return parts.join('   |   ');
}

/// The hover for a line that ran: every number, not just the rounded ones.
function lineHover(model, stats, routine) {
  const rows = [];
  const what = model.period !== undefined ? periodName(model, model.period) : 'Profile';
  if (stats !== undefined) {
    if (stats.idle) {
      rows.push(`**${what}** -- idle: ${stats.tstates.toLocaleString('en-GB')} T-states waiting`);
    } else {
      rows.push(`**${what}** -- ${formatShare(stats.share)} of ${formatCount(model.busy)} busy T-states`);
      rows.push(`${stats.tstates.toLocaleString('en-GB')} T-states`);
    }
    if (stats.hits !== undefined) {
      const average = stats.hits > 0 ? stats.tstates / stats.hits : 0;
      rows[rows.length - 1] += ` over ${stats.hits.toLocaleString('en-GB')} runs, ${average.toFixed(1)} T a run`;
    }
    if (model.frames > 0) {
      let row = `${formatCount(stats.tstates / model.frames)} T`;
      if (stats.hits !== undefined) {
        row += ` and ${formatCount(stats.hits / model.frames)} runs`;
      }
      rows.push(`${row} a frame, over ${model.frames.toLocaleString('en-GB')} frames`);
    }
    if (stats.symbol) {
      rows.push(`at \`${stats.symbol}\``);
    }
  }
  if (routine !== undefined) {
    const cost = `${formatCount(perFrame(model, routine.tstates))} T${model.frames > 0 ? ' a frame' : ''}`;
    rows.push(routine.idle
      ? `**${routine.name}**, the whole routine: idle, ${cost}`
      : `**${routine.name}**, the whole routine: ${formatShare(routine.share)}, ${cost}`);
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

/// Indexes report.call_nodes: children by id, and each node's idle time over
/// its whole subtree.
function indexCallTree(report) {
  const nodes = report.call_nodes || [];
  const children = [];
  const idleTotal = [];
  for (let i = 0; i < nodes.length; i++) {
    children.push([]);
    idleTotal.push(nodes[i].idle_tstates || 0);
  }
  for (let i = 0; i < nodes.length; i++) {
    const parent = nodes[i].parent;
    if (parent !== null && parent !== undefined && parent < nodes.length) {
      children[parent].push(i);
    }
  }
  // Parents come before their children, so one backwards pass sums them.
  for (let i = nodes.length - 1; i > 0; i--) {
    const parent = nodes[i].parent;
    if (parent !== null && parent !== undefined && parent < nodes.length) {
      idleTotal[parent] += idleTotal[i];
    }
  }
  return { nodes, children, idleTotal };
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
    selfIdle: 0,
    total: 0,
    totalIdle: 0,
    hasChildren: false,
    id,
  };
}

function addNode(tree, group, index) {
  const node = tree.nodes[index];
  group.nodes.push(index);
  group.calls += node.calls || 0;
  group.self += node.self_tstates;
  group.selfIdle += node.idle_tstates || 0;
  group.total += node.tstates;
  group.totalIdle += tree.idleTotal[index];
  for (const child of tree.children[index]) {
    if (tree.nodes[child].tstates > 0) {
      group.hasChildren = true;
      break;
    }
  }
}

/// Whether a group is waiting rather than working.
function groupIdle(group) {
  return isIdle(group.total, group.totalIdle);
}

function sortGroups(groups, sortBy) {
  groups.sort((a, b) => {
    const x = sortBy === 'self' ? a.self - a.selfIdle : a.total - a.totalIdle;
    const y = sortBy === 'self' ? b.self - b.selfIdle : b.total - b.totalIdle;
    if (x !== y) {
      return y - x;
    }
    // Idle rows, having no busy time, then by how long they waited.
    if (a.total !== b.total) {
      return b.total - a.total;
    }
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  });
  return groups;
}

/// The top level: one group per routine. `prefix` keeps the ids of two trees
/// in one view apart.
function rootGroups(tree, sortBy, prefix) {
  const byKey = new Map();
  const groups = [];
  const nodes = tree.nodes;
  const idPrefix = prefix || '';
  for (let i = 1; i < nodes.length; i++) {
    if (nodes[i].tstates <= 0) {
      continue;
    }
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
      group = newGroup(nodes[i], idPrefix + key);
      byKey.set(key, group);
      groups.push(group);
    }
    addNode(tree, group, i);
  }
  // Code that ran outside any call seen: the main loop, typically.
  if (nodes.length > 0 && nodes[0].self_tstates > 0) {
    const root = newGroup(nodes[0], idPrefix + 'root');
    root.ownCode = true;
    root.self = nodes[0].self_tstates;
    root.selfIdle = nodes[0].idle_tstates || 0;
    root.total = root.self;
    root.totalIdle = root.selfIdle;
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
      if (node.tstates <= 0) {
        continue;
      }
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
    const own = newGroup({ name: '(own code)', path: group.path, line: group.line }, group.id + '/own');
    own.key = 'own';
    own.ownCode = true;
    own.self = group.self;
    own.selfIdle = group.selfIdle;
    own.total = group.self;
    own.totalIdle = group.selfIdle;
    groups.push(own);
  }
  return sortGroups(groups, sortBy);
}

/// The description shown beside a group: its share of busy time, its cost a
/// frame, and how often it was called -- by whichever measure the tree is
/// sorted on, so the numbers read in the order the rows are in.
function groupDescription(model, group, sortBy) {
  const unit = unitOf(model);
  let text;
  if (groupIdle(group)) {
    text = `idle · ${formatCount(perFrame(model, group.total))} T${unit}`;
  } else {
    const own = sortBy === 'self' && !group.ownCode;
    const value = own ? group.self : group.total;
    const busy = own ? group.self - group.selfIdle : group.total - group.totalIdle;
    text = `${own ? 'own ' : ''}${formatShare(model.busy > 0 ? busy / model.busy : 0)} · ${formatCount(perFrame(model, value))} T${unit}`;
    if (own) {
      text += ` · total ${formatShare(model.busy > 0 ? (group.total - group.totalIdle) / model.busy : 0)}`;
    }
  }
  if (!group.ownCode && group.calls > 0) {
    text += ` · ${formatCount(perFrame(model, group.calls))} calls${unit}`;
  }
  return text;
}

function groupTooltip(model, group) {
  const unit = model.frames > 0 ? ' a frame' : '';
  const share = (busy) => formatShare(model.busy > 0 ? busy / model.busy : 0);
  const rows = [];
  rows.push(group.interrupt ? `Interrupt handler ${group.name}` : group.name);
  rows.push(`Total: ${share(group.total - group.totalIdle)} of busy time, ` +
    `${formatCount(perFrame(model, group.total))} T${unit}`);
  if (group.totalIdle > 0) {
    rows.push(`Idle: ${formatCount(perFrame(model, group.totalIdle))} T${unit}`);
  }
  if (!group.ownCode) {
    rows.push(`Own code: ${share(group.self - group.selfIdle)}, ` +
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

// ---- periods ----------------------------------------------------------------
//
// A period is a video frame, or one turn of a routine chosen as the marker.
// The report sends every period's busy time as a strip, and the busiest few
// with their own lines, routines and time per call node -- enough to show one
// of them exactly as the whole profile is shown.

/// "Frame 1,204", or "Turn 57 of turn_pace".
function periodName(model, period) {
  const periods = model.periods || {};
  if (periods.by === 'marker') {
    return `Turn ${(period.index + 1).toLocaleString('en-GB')} of ${periods.name}`;
  }
  return `Frame ${period.start_frame.toLocaleString('en-GB')}`;
}

/// What the worst-periods row says about all of them.
function periodsTitle(model) {
  const periods = model.periods || {};
  return periods.by === 'marker' ? `Worst turns of ${periods.name}` : 'Worst frames';
}

/// A worst period's busy time, and against a frame's length.
function periodDescription(model, period) {
  let text = `${formatCount(period.busy_tstates)} T busy`;
  if (model.frameTstates > 0) {
    if ((model.periods || {}).by === 'marker') {
      text += ` · ${(period.tstates / model.frameTstates).toFixed(2)} frames long`;
    } else {
      text += ` · ${formatShare(period.busy_tstates / model.frameTstates)} of the frame`;
    }
  }
  return text;
}

/// A text sparkline of busy time: `width` blocks, each the busiest of the
/// periods it covers, scaled to `top`.
function sparkline(values, width, top) {
  if (!values || values.length === 0 || !(top > 0)) {
    return '';
  }
  const per = Math.max(1, Math.ceil(values.length / width));
  let text = '';
  for (let i = 0; i < values.length; i += per) {
    let most = 0;
    for (let j = i; j < values.length && j < i + per; j++) {
      most = Math.max(most, values[j]);
    }
    const level = Math.min(SPARK_BLOCKS.length - 1, Math.floor((most / top) * SPARK_BLOCKS.length));
    text += SPARK_BLOCKS[Math.max(0, level)];
  }
  return text;
}

/// The strip's scale: a whole frame when periods are frames (so a full block
/// is a frame with no time to spare), otherwise the busiest period.
function periodsScale(model) {
  const periods = model.periods || {};
  if (periods.by !== 'marker' && model.frameTstates > 0) {
    return model.frameTstates;
  }
  return periods.busiest_tstates || 0;
}

/// One worst period as a report of its own, so everything that shows the
/// whole profile can show it: its lines and routines as sent, and the call
/// tree's nodes carrying that period's time instead of the whole profile's.
function periodReport(report, period) {
  const base = report.call_nodes || [];
  const self = new Map();
  for (const triple of period.nodes || []) {
    self.set(triple[0], { tstates: triple[1], idle: triple[2] });
  }
  const nodes = [];
  for (let i = 0; i < base.length; i++) {
    const own = self.get(i) || { tstates: 0, idle: 0 };
    nodes.push({
      id: i,
      parent: base[i].parent,
      name: base[i].name,
      addr: base[i].addr,
      interrupt: base[i].interrupt,
      path: base[i].path,
      line: base[i].line,
      calls: 0, // a period keeps time, not call counts
      self_tstates: own.tstates,
      idle_tstates: own.idle,
      tstates: own.tstates,
    });
  }
  for (let i = nodes.length - 1; i > 0; i--) {
    const parent = nodes[i].parent;
    if (parent !== null && parent !== undefined && parent < nodes.length) {
      nodes[parent].tstates += nodes[i].tstates;
    }
  }
  return {
    active: false,
    frames: 0,
    tstates: period.tstates,
    idle_tstates: period.idle_tstates,
    unmapped_tstates: period.unmapped_tstates,
    frame_tstates: report.frame_tstates,
    idle: report.idle,
    periods: report.periods,
    period,
    lines: period.lines || [],
    routines: period.routines || [],
    call_nodes: nodes,
  };
}

module.exports = {
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
  indexCallTree,
  rootGroups,
  childGroups,
  groupIdle,
  groupDescription,
  groupTooltip,
  periodName,
  periodsTitle,
  periodDescription,
  sparkline,
  periodsScale,
  periodReport,
};
