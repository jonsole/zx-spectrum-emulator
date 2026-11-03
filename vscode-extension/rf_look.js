// The RF look's settings: what each is called in VS Code's settings, in the
// server's rf_filter tool (cpp-core/src/mcp_server.cpp, and retro-spectrum's
// bridge, which takes the same arguments), and in the picker. No vscode
// import, so it is tested from plain Node (tests/rf_look_test.js).
//
// The settings are the panel's: whenever they change, and whenever a screen
// panel connects, every server a panel shows is sent all fourteen. So a server
// started later, or restarted, comes up looking the way the panel was left.

/// Every setting, in the order the picker shows them. `key` is the VS Code
/// setting under zxspectrum.rf, `arg` the rf_filter argument. A switch has no
/// `max`; a level runs `min` (0 if not given) to `max` in steps of `step`
/// (1 if not given).
const RF_SETTINGS = [
  { key: 'on', arg: 'on', label: 'RF look', fallback: false,
    detail: 'The master switch. Off is the plain picture, to the pixel.' },
  { key: 'composite', arg: 'composite', label: 'Composite', fallback: true,
    detail: 'The PAL encode and decode: dot crawl, cross-colour, colour bleed, soft luma. ' +
      'The ghost and the noise need it.' },
  { key: 'ghost', arg: 'ghost', label: 'Ghost', fallback: true,
    detail: 'A delayed echo of the picture, as a mismatched cable gives.' },
  { key: 'noise', arg: 'noise', label: 'Noise', fallback: true, detail: 'RF noise.' },
  { key: 'scanlines', arg: 'scanlines', label: 'Scanlines', fallback: true,
    detail: 'Every second line darker.' },
  { key: 'jail', arg: 'jail', label: 'Jail bars', fallback: 0, max: 3,
    names: ['Off', 'Faint (about 1 %)', 'Clear (about 2 %)', 'Strong (about 4 %)'],
    detail: 'Still vertical bars on the paper, the 48K\'s from its supply noise.' },
  { key: 'jailRgb', arg: 'jail_rgb', label: 'Jail bars on the RGB', fallback: false,
    detail: 'Sharp, as on a 128K\'s RGB output. Off puts them on the composite, where the TV ' +
      'softens them.' },
  { key: 'crystalPpm', arg: 'crystal_ppm', label: 'Crystal offset', fallback: -5.6,
    min: -12.8, max: 12.7, step: 0.1, unit: 'ppm',
    detail: 'How the 48K\'s dots move from frame to frame: 0 nominal crystals (they flip every ' +
      'frame), -5.6 a trimmed machine\'s slow creep. A 128K\'s never move.' },
  { key: 'luma', arg: 'luma', label: 'Luma', fallback: 1, max: 3,
    names: ['No trap (strongest dots)', 'The subcarrier trap', 'Softer', 'Softest'],
    detail: 'How much of the subcarrier is left in the brightness.' },
  { key: 'chroma', arg: 'chroma', label: 'Colour bandwidth', fallback: 2, max: 3,
    names: ['Sharpest', 'Sharp', 'Soft', 'Most bleed'],
    detail: 'How far colour bleeds sideways.' },
  { key: 'ghostDelay', arg: 'ghost_d', label: 'Ghost delay', fallback: 24, max: 63,
    detail: 'In samples of 71 ns; 0 is no ghost.' },
  { key: 'ghostStrength', arg: 'ghost_g', label: 'Ghost strength', fallback: 3, max: 15,
    detail: '0 to 15.' },
  { key: 'noiseLevel', arg: 'noise_n', label: 'Noise level', fallback: 3, max: 15,
    detail: '0 to 15.' },
  { key: 'scanlineDepth', arg: 'scan_d', label: 'Scanline depth', fallback: 6, max: 15,
    detail: 'Sixteenths darker, 0 to 15.' },
];

/// A setting's value as the server can take it: a switch true or false, a
/// level rounded to its step and clamped to its range. Unset or nonsense is
/// the setting's power-on value.
function normaliseSetting(setting, value) {
  if (setting.max === undefined) {
    return typeof value === 'boolean' ? value : setting.fallback;
  }
  // Steps are counted as a whole number of them to the unit (10 to the ppm),
  // so that 0.1 steps come out as -5.6 rather than -5.6000000000000005.
  const perUnit = Math.round(1 / (setting.step || 1));
  const n = Math.round(Number(value) * perUnit) / perUnit;
  if (value === undefined || value === null || value === '' || !Number.isFinite(n)) {
    return setting.fallback;
  }
  const min = setting.min || 0;
  return n < min ? min : n > setting.max ? setting.max : n;
}

/// The rf_filter arguments for a set of VS Code settings, `get(key)` reading
/// one: all fourteen, each normalised.
function rfArguments(get) {
  const args = {};
  for (const s of RF_SETTINGS) {
    args[s.arg] = normaliseSetting(s, get(s.key));
  }
  return args;
}

/// How the picker shows a setting's current value.
function describeValue(setting, value) {
  if (setting.max === undefined) {
    return value ? 'On' : 'Off';
  }
  if (setting.names) {
    return `${value} -- ${setting.names[value]}`;
  }
  if (setting.unit) {
    return `${value} ${setting.unit}`;
  }
  return String(value);
}

module.exports = { RF_SETTINGS, normaliseSetting, rfArguments, describeValue };
