// The profile's call tree, as a view in the debug sidebar: the worst frames
// (or turns) first, then every routine the profile saw, most expensive first,
// each expanding into the routines it called and what those calls cost it.
// A worst frame expands the same way, into that frame's routines alone. The
// grouping is profile_model.js's; this only turns groups into tree items.

const vscode = require('vscode');
const {
  indexReport,
  rootGroups,
  childGroups,
  groupIdle,
  groupDescription,
  groupTooltip,
  periodName,
  periodsTitle,
  periodDescription,
  periodReport,
  sparkline,
  periodsScale,
  formatCount,
  formatShare,
} = require('./profile_model');

// Share of busy time at which a row's icon is coloured, hottest first.
const ICON_HEAT = [
  { share: 0.1, color: 'charts.red' },
  { share: 0.025, color: 'charts.orange' },
  { share: 0.005, color: 'charts.yellow' },
];
const SPARKLINE_WIDTH = 32;

class ProfileTreeProvider {
  constructor() {
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
    this.model = undefined;
    this.sortBy = 'total';
    this.cumulative = true;
    this.periodModels = new Map(); // period index -> indexed model, per report
  }

  setModel(model) {
    this.model = model;
    this.periodModels = new Map();
    this.emitter.fire();
  }

  setSort(sortBy) {
    this.sortBy = sortBy;
    this.emitter.fire();
  }

  setCumulative(cumulative) {
    this.cumulative = cumulative;
    this.periodModels = new Map();
  }

  /// The indexed model for one worst period, built once per report.
  periodModel(period) {
    let model = this.periodModels.get(period.index);
    if (model === undefined) {
      model = indexReport(periodReport(this.model.report, period), { cumulative: this.cumulative });
      this.periodModels.set(period.index, model);
    }
    return model;
  }

  getChildren(element) {
    const model = this.model;
    if (model === undefined || model.total === 0) {
      return [];
    }
    if (element === undefined) {
      const rows = [];
      const periods = model.periods;
      if (periods !== undefined && periods.worst && periods.worst.length > 0) {
        rows.push({ kind: 'periods' });
      }
      for (const group of rootGroups(model.callTree, this.sortBy)) {
        rows.push(asGroup(group, model));
      }
      return rows;
    }
    if (element.kind === 'periods') {
      const rows = [];
      for (const period of model.periods.worst) {
        rows.push({ kind: 'period', period });
      }
      return rows;
    }
    if (element.kind === 'period') {
      const periodModel = this.periodModel(element.period);
      const rows = [];
      for (const group of rootGroups(periodModel.callTree, this.sortBy, `worst:${element.period.index}/`)) {
        rows.push(asGroup(group, periodModel));
      }
      return rows;
    }
    const rows = [];
    for (const group of childGroups(element.model.callTree, element.group, this.sortBy)) {
      rows.push(asGroup(group, element.model));
    }
    return rows;
  }

  getTreeItem(element) {
    if (element.kind === 'periods') {
      return this.periodsItem();
    }
    if (element.kind === 'period') {
      return this.periodItem(element.period);
    }
    return this.groupItem(element.group, element.model);
  }

  periodsItem() {
    const model = this.model;
    const periods = model.periods;
    const item = new vscode.TreeItem(periodsTitle(model), vscode.TreeItemCollapsibleState.Collapsed);
    item.id = 'worst';
    item.contextValue = 'zxProfilePeriods';
    item.iconPath = new vscode.ThemeIcon('pulse');
    const scale = periodsScale(model);
    item.description = `${sparkline(periods.strip, SPARKLINE_WIDTH, scale)}  busiest ${formatCount(periods.busiest_tstates)} T`;
    const unit = periods.by === 'marker' ? 'turn' : 'frame';
    const rows = [
      `${periods.count.toLocaleString('en-GB')} ${unit}s counted`,
    ];
    if (periods.busy_tstates_average !== undefined) {
      rows.push(`Busy: ${formatCount(periods.busy_tstates_average)} T a ${unit} on average, ${formatCount(periods.busiest_tstates)} at most`);
    }
    if (periods.by !== 'marker') {
      rows.push(`${periods.without_idle.toLocaleString('en-GB')} frames with no idle time at all`);
      if (model.idleNames.length === 0) {
        rows.push('No routines are marked idle, so only a HALT counts as waiting.');
      }
    }
    rows.push(`The strip is busy time per ${unit}, ${periods.bucket > 1 ? `each block the busiest of ${periods.bucket}` : 'one block each'}, ` +
      (periods.by === 'marker' ? 'scaled to the busiest.' : 'scaled to a whole frame.'));
    item.tooltip = rows.join('\n');
    return item;
  }

  periodItem(period) {
    const model = this.model;
    const item = new vscode.TreeItem(periodName(model, period), vscode.TreeItemCollapsibleState.Collapsed);
    item.id = `worst:${period.index}`;
    item.contextValue = 'zxProfilePeriod';
    item.description = periodDescription(model, period);
    const load = model.frameTstates > 0 ? period.busy_tstates / model.frameTstates : 0;
    let color;
    if (load >= 0.99) {
      color = new vscode.ThemeColor('charts.red');
    } else if (load >= 0.8) {
      color = new vscode.ThemeColor('charts.orange');
    }
    item.iconPath = new vscode.ThemeIcon('pulse', color);
    item.tooltip =
      `${periodName(model, period)}, from frame ${period.start_frame.toLocaleString('en-GB')}\n` +
      `${formatCount(period.tstates)} T long: ${formatCount(period.busy_tstates)} busy, ${formatCount(period.idle_tstates)} idle\n` +
      'Click to paint this one on the source; expand for its routines.';
    item.command = {
      command: 'zxspectrum.profileShowPeriod',
      title: 'Show on Source',
      arguments: [{ kind: 'period', period }],
    };
    return item;
  }

  groupItem(group, model) {
    const item = new vscode.TreeItem(
      group.name,
      group.hasChildren ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None
    );
    // The row's path through the tree, so a refresh -- once a second while
    // counting -- keeps what was expanded expanded.
    item.id = group.id;
    item.description = groupDescription(model, group, this.sortBy);
    item.tooltip = groupTooltip(model, group);
    const idle = groupIdle(group);
    item.iconPath = new vscode.ThemeIcon(iconName(group, idle), idle ? undefined : iconColor(model, group));
    if (!group.ownCode) {
      const marked = this.model.idleNames.includes(group.name);
      item.contextValue = marked ? 'zxProfileIdleRoutine' : 'zxProfileRoutine';
    }
    if (group.path) {
      const line = Math.max(0, (group.line || 1) - 1);
      item.command = {
        command: 'vscode.open',
        title: 'Go to routine',
        arguments: [vscode.Uri.file(group.path), { selection: new vscode.Range(line, 0, line, 0), preserveFocus: true }],
      };
    }
    return item;
  }
}

function asGroup(group, model) {
  return { kind: 'group', id: group.id, group, model };
}

function iconName(group, idle) {
  if (idle) {
    return 'watch';
  }
  if (group.interrupt) {
    return 'zap';
  }
  if (group.ownCode) {
    return 'debug-stackframe-dot';
  }
  return 'symbol-function';
}

function iconColor(model, group) {
  const share = model.busy > 0 ? (group.total - group.totalIdle) / model.busy : 0;
  for (const heat of ICON_HEAT) {
    if (share >= heat.share) {
      return new vscode.ThemeColor(heat.color);
    }
  }
  return undefined;
}

module.exports = { ProfileTreeProvider, formatShare };
