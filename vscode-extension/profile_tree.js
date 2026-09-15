// The profile's call tree, as a view in the debug sidebar: every routine the
// profile saw, most expensive first, each expanding into the routines it
// called and what those calls cost it. The grouping is profile_model.js's;
// this only turns groups into tree items.

const vscode = require('vscode');
const { rootGroups, childGroups, groupDescription, groupTooltip } = require('./profile_model');

// Share of all profiled time at which a row's icon is coloured, hottest first.
const ICON_HEAT = [
  { share: 0.1, color: 'charts.red' },
  { share: 0.025, color: 'charts.orange' },
  { share: 0.005, color: 'charts.yellow' },
];

class ProfileTreeProvider {
  constructor() {
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
    this.model = undefined;
    this.sortBy = 'total';
  }

  setModel(model) {
    this.model = model;
    this.emitter.fire();
  }

  setSort(sortBy) {
    this.sortBy = sortBy;
    this.emitter.fire();
  }

  getChildren(group) {
    if (this.model === undefined || this.model.total === 0) {
      return [];
    }
    if (group === undefined) {
      return rootGroups(this.model.callTree, this.sortBy);
    }
    return childGroups(this.model.callTree, group, this.sortBy);
  }

  getTreeItem(group) {
    const model = this.model;
    const item = new vscode.TreeItem(
      group.name,
      group.hasChildren ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None
    );
    // The row's path through the tree, so a refresh -- once a second while
    // counting -- keeps what was expanded expanded.
    item.id = group.id;
    item.description = groupDescription(model, group, this.sortBy);
    item.tooltip = groupTooltip(model, group);
    item.iconPath = new vscode.ThemeIcon(iconName(group), iconColor(model, group));
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

function iconName(group) {
  if (group.interrupt) {
    return 'zap';
  }
  if (group.ownCode) {
    return 'debug-stackframe-dot';
  }
  return 'symbol-function';
}

function iconColor(model, group) {
  const share = model.total > 0 ? group.total / model.total : 0;
  for (const heat of ICON_HEAT) {
    if (share >= heat.share) {
      return new vscode.ThemeColor(heat.color);
    }
  }
  return undefined;
}

module.exports = { ProfileTreeProvider };
