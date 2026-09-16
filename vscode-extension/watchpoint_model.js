// Watchpoints as the editor lists them. No vscode import, so it is tested
// from plain Node (tests/watchpoint_model_test.js).
//
// The emulator answers with addresses, access flags and hit counts (the DAP
// `watchpoints` request); this turns one into the row the debug sidebar
// shows, and reads what somebody typed into "Watch Address..." back into a
// request.

function hex4(value) {
  return '$' + value.toString(16).toUpperCase().padStart(4, '0');
}

/// "room_shown ($F6DA)", or just the address when nothing names it.
function watchpointName(w) {
  const address = hex4(w.address);
  let name = w.symbol ? `${w.symbol} (${address})` : address;
  if (w.length > 1) {
    name += `, ${w.length} bytes`;
  }
  return name;
}

/// What it is watching for: "writes that change it", "every write", "reads",
/// "writes of 0", and so on.
function watchpointDetail(w) {
  const parts = [];
  if (w.onWrite) {
    if (w.test === '=') {
      parts.push(`writes of ${w.value}`);
    } else if (w.test === '<>') {
      parts.push(`writes of anything but ${w.value}`);
    } else {
      parts.push(w.onChange ? 'writes that change it' : 'every write');
    }
  }
  if (w.onRead) {
    parts.push('reads');
  }
  let detail = parts.join(' and ') || 'nothing';
  if (w.hits > 0) {
    detail += ` · ${w.hits} hit${w.hits === 1 ? '' : 's'}`;
  }
  if (!w.enabled) {
    detail += ' · off';
  }
  return detail;
}

/// Reads "player", "player 8", "$5C3A,2" or "room_shown +1 4" into the
/// address text and a length. The address itself is left as typed, since the
/// server resolves symbols and expressions and this side cannot.
function parseWatchRequest(text) {
  const trimmed = (text || '').trim();
  if (trimmed === '') {
    return undefined;
  }
  // A length is a plain number after a comma, or after the last space --
  // but "sprite_x + 4" is an expression, not a length, so a trailing number
  // only counts when something separates it from an operator.
  const comma = trimmed.match(/^(.*?)\s*,\s*(\d+)$/);
  if (comma) {
    return { address: comma[1].trim(), length: Number(comma[2]) };
  }
  const spaced = trimmed.match(/^(.*[^\s+\-*/])\s+(\d+)$/);
  if (spaced) {
    return { address: spaced[1].trim(), length: Number(spaced[2]) };
  }
  return { address: trimmed, length: 1 };
}

module.exports = { watchpointName, watchpointDetail, parseWatchRequest, hex4 };
