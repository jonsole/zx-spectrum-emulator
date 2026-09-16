// How big the screen panel draws the Spectrum's picture, and through which
// filter. No vscode import, so it is tested from plain Node
// (tests/screen_scaling_test.js) -- and the functions are written to stand
// alone, with no outside names, because the webview needs them too and gets
// them as source text (see getHtml in extension.js).
//
// The picture is 352x312, border included. Every size here is worked out in
// DEVICE pixels first and only then turned back into CSS pixels: on a 150%
// display a "2x" picture is three device pixels a Spectrum pixel, and a
// nearest-neighbour filter is only crisp when that number is whole.

/// The filters, in the order they are offered.
const FILTERS = [
  {
    id: 'nearest',
    label: 'Nearest neighbour',
    detail: 'Hard-edged pixels, as the ULA drew them. Uneven at in-between sizes.',
  },
  {
    id: 'sharp-bilinear',
    label: 'Sharp bilinear',
    detail: 'Hard-edged pixels, evenly sized at any size: only their edges are blended.',
  },
  {
    id: 'bilinear',
    label: 'Bilinear',
    detail: 'Smoothed, as a television would soften it.',
  },
];

/// The sizes, in the order they are offered.
const SCALES = [
  {
    id: 'fit-integer',
    label: 'Fit, whole multiples',
    detail: 'As large as the panel allows in whole steps -- every pixel the same size.',
  },
  { id: 'fit', label: 'Fit', detail: 'Fill the panel, keeping the shape.' },
  { id: '1', label: '1x', detail: '352 x 312' },
  { id: '2', label: '2x', detail: '704 x 624' },
  { id: '3', label: '3x', detail: '1056 x 936' },
  { id: '4', label: '4x', detail: '1408 x 1248' },
];

/// The canvas size for a scale setting, in a panel `availW` x `availH` CSS
/// pixels on a display with `dpr` device pixels to the CSS pixel. `canvasW`
/// and `canvasH` are the backing store, in device pixels; `cssW` and `cssH`
/// are what it is laid out at, so the two map one to one and the browser
/// never rescales the canvas behind the filter's back.
function layoutFor(scale, availW, availH, dpr) {
  const NATIVE_W = 352;
  const NATIVE_H = 312;
  const ratio = dpr > 0 ? dpr : 1;
  // Device pixels per Spectrum pixel.
  let perPixel;
  if (scale === 'fit') {
    perPixel = Math.min((availW * ratio) / NATIVE_W, (availH * ratio) / NATIVE_H);
  } else if (scale === '1' || scale === '2' || scale === '3' || scale === '4') {
    perPixel = Number(scale) * ratio;
  } else {
    // fit-integer, and anything unrecognised: the safe choice.
    perPixel = Math.floor(Math.min((availW * ratio) / NATIVE_W, (availH * ratio) / NATIVE_H));
  }
  // Never smaller than the picture itself: below that there is nothing a
  // filter can do but drop pixels.
  if (!(perPixel >= 1)) {
    perPixel = 1;
  }
  const canvasW = Math.max(1, Math.round(NATIVE_W * perPixel));
  const canvasH = Math.max(1, Math.round(NATIVE_H * perPixel));
  return { canvasW, canvasH, cssW: canvasW / ratio, cssH: canvasH / ratio };
}

/// Sharp bilinear's first pass: the whole multiple to scale up to with
/// nearest neighbour before bilinear covers the rest. The largest that does
/// not overshoot the canvas, and never less than 1.
function prescaleFactor(canvasW, canvasH) {
  const k = Math.floor(Math.min(canvasW / 352, canvasH / 312));
  return k >= 1 ? k : 1;
}

/// The scanline darknesses offered in the picker, as percentages. Any whole
/// number from 0 to 100 works; these are the ones worth a click.
const SCANLINE_PRESETS = [0, 25, 50, 75, 100];

/// Whether scanlines can be drawn at `rowHeight` device pixels to a Spectrum
/// line. A gap needs a pixel of its own and the line needs at least one to
/// show: below two, darkening part of a line is darkening the picture.
function scanlinesPossible(rowHeight) {
  return rowHeight >= 2;
}

/// The dark gap in one Spectrum line `rowHeight` device pixels tall: where it
/// starts below the top of the line, and how tall it is. The lower half of the
/// line, as a CRT's beam leaves it -- in whole pixels when the line is a whole
/// number of them, so every gap is the same crisp band rather than one full
/// pixel and one half-shaded one.
function scanlineBand(rowHeight) {
  let height = rowHeight / 2;
  if (Number.isInteger(rowHeight)) {
    height = Math.max(1, Math.floor(rowHeight / 2));
  }
  return { offset: rowHeight - height, height: height };
}

/// A setting value as the renderer can use it: unknown values fall back to
/// the defaults rather than to nothing, since they come from user settings.
function normaliseView(view) {
  const v = view || {};
  const filter = FILTERS.some((f) => f.id === v.filter) ? v.filter : 'nearest';
  const scale = SCALES.some((s) => s.id === v.scale) ? v.scale : 'fit-integer';
  let scanlines = Math.round(Number(v.scanlines));
  if (!Number.isFinite(scanlines) || scanlines < 0) {
    scanlines = 0;
  } else if (scanlines > 100) {
    scanlines = 100;
  }
  return { filter, scale, scanlines };
}

module.exports = {
  FILTERS,
  SCALES,
  SCANLINE_PRESETS,
  layoutFor,
  prescaleFactor,
  scanlinesPossible,
  scanlineBand,
  normaliseView,
};
