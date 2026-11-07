// The RF look's settings (rf_look.js): node vscode-extension/tests/rf_look_test.js
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { RF_SETTINGS, normaliseSetting, rfArguments, describeValue } = require('../rf_look');

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name + '\n     ' + err.message);
  }
}

test('the arguments are the eighteen rf_filter takes', () => {
  assert.deepStrictEqual(RF_SETTINGS.map((s) => s.arg),
    ['on', 'composite', 'ghost', 'noise', 'scanlines', 'jail', 'jail_rgb', 'crystal_ppm',
      'luma', 'chroma', 'pal_delay', 'colour', 'ghost_d', 'ghost_g', 'noise_n', 'scan_d',
      'dots_cut', 'fringes_cut']);
});

// Power-on, the board's Good TV with the switch off: FLAGS 0x7E (the
// composite, ghost, noise, scanlines, 4 % bars on the composite), BAND 0xB7
// (luma 3, the delay line, chroma 3, colour x3/4), ghost
// 6 and 0x42, noise 0x41 (the dials at 4/8), scanlines 6, crystal 0xC7,
// -5.7 ppm -- retro-spectrum's docs/spec/rf.md section 5 and
// cpp-core/src/rf_filter.h.
test('unset settings are the power-on values', () => {
  assert.deepStrictEqual(rfArguments(() => undefined), {
    on: false, composite: true, ghost: true, noise: true, scanlines: true, jail: 3,
    jail_rgb: false, crystal_ppm: -5.7, luma: 3, chroma: 3, pal_delay: true,
    colour: 2, ghost_d: 6, ghost_g: 2, noise_n: 1, scan_d: 6, dots_cut: 4, fringes_cut: 4,
  });
});

test('the crystal offset is tenths of a ppm, -12.8 to 12.7', () => {
  const crystal = RF_SETTINGS.find((s) => s.key === 'crystalPpm');
  assert.strictEqual(normaliseSetting(crystal, -5.6), -5.6);
  assert.strictEqual(normaliseSetting(crystal, 0.1 + 0.2), 0.3);
  assert.strictEqual(normaliseSetting(crystal, '1.04'), 1);
  assert.strictEqual(normaliseSetting(crystal, -20), -12.8);
  assert.strictEqual(normaliseSetting(crystal, 13), 12.7);
  assert.strictEqual(normaliseSetting(crystal, 'fast'), -5.7);
  assert.strictEqual(describeValue(crystal, -5.6), '-5.6 ppm');
});

test('levels are clamped and rounded, switches need a boolean', () => {
  const delay = RF_SETTINGS.find((s) => s.key === 'ghostDelay');
  assert.strictEqual(normaliseSetting(delay, 99), 63);
  assert.strictEqual(normaliseSetting(delay, -4), 0);
  assert.strictEqual(normaliseSetting(delay, '12.6'), 13);
  assert.strictEqual(normaliseSetting(delay, 'many'), 6);
  const on = RF_SETTINGS.find((s) => s.key === 'on');
  assert.strictEqual(normaliseSetting(on, 'yes'), false);
  assert.strictEqual(normaliseSetting(on, true), true);
});

test('values are described by name where they have one', () => {
  const luma = RF_SETTINGS.find((s) => s.key === 'luma');
  assert.strictEqual(describeValue(luma, 0), '0 -- No trap (strongest dots)');
  assert.strictEqual(describeValue(RF_SETTINGS[0], true), 'On');
  assert.strictEqual(describeValue(RF_SETTINGS.find((s) => s.key === 'noiseLevel'), 7), '7');
});

// package.json declares a zxspectrum.rf setting for each, with the same
// default and range, or the Settings editor and the picker would disagree.
test('package.json declares every setting alike', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
  const props = pkg.contributes.configuration.properties;
  for (const s of RF_SETTINGS) {
    const p = props['zxspectrum.rf.' + s.key];
    assert.ok(p, 'zxspectrum.rf.' + s.key + ' is declared');
    // cpp-core/CMakeLists.txt reads package.json for the version through an
    // unquoted variable, which splits at a semicolon outside [ ] -- and then
    // no build configures at all.
    assert.ok(!JSON.stringify(p).includes(';'), s.key + ' has no semicolon');
    assert.strictEqual(p.default, s.fallback, s.key + ' default');
    if (s.max === undefined) {
      assert.strictEqual(p.type, 'boolean', s.key + ' type');
    } else {
      assert.strictEqual(p.type, s.step === undefined ? 'integer' : 'number', s.key + ' type');
      assert.strictEqual(p.minimum, s.min || 0, s.key + ' minimum');
      assert.strictEqual(p.maximum, s.max, s.key + ' maximum');
    }
  }
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
