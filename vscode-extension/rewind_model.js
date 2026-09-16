// How far back in its history the machine is, in words -- the rewind status
// bar item's text. No vscode import, so it is tested from plain Node
// (tests/rewind_model_test.js).
//
// The emulator measures positions in half-clocks (two to a T-state). Nobody
// thinks in those: a few T-states back is best said as T-states, a few frames
// as frames, and anything longer as seconds.

const HALF_CLOCKS_PER_TSTATE = 2;
// Both machines draw a picture about fifty times a second (48K 50.08, 128K
// 50.02) -- close enough for "3.2 s before live".
const FRAMES_PER_SECOND = 50;

function formatCount(n) {
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/// "live", "137 T-states before live", "4.5 frames before live" or
/// "12.3 s before live".
function describeBehind(behindHalfClocks, halfClocksPerFrame) {
  if (!(behindHalfClocks > 0)) {
    return 'live';
  }
  const frames = halfClocksPerFrame > 0 ? behindHalfClocks / halfClocksPerFrame : 0;
  if (frames < 1) {
    const tstates = Math.round(behindHalfClocks / HALF_CLOCKS_PER_TSTATE);
    return `${formatCount(tstates)} T-state${tstates === 1 ? '' : 's'} before live`;
  }
  if (frames < FRAMES_PER_SECOND) {
    return `${frames.toFixed(1)} frames before live`;
  }
  return `${(frames / FRAMES_PER_SECOND).toFixed(1)} s before live`;
}

/// The status bar item for a `history` response: undefined when there is
/// nothing to show (live, or a server without rewind).
function statusFor(history) {
  if (!history || !history.rewind || history.live) {
    return undefined;
  }
  const behind = history.headHalfClock - history.positionHalfClock;
  const available = history.headHalfClock - history.oldestHalfClock;
  return {
    text: describeBehind(behind, history.halfClocksPerFrame),
    // How far into the recorded history, for the tooltip.
    share: available > 0 ? behind / available : 0,
  };
}

module.exports = { describeBehind, statusFor, formatCount };
