// How big the screen panel draws the Spectrum's picture, and through which
// filter. No vscode import, so it is tested from plain Node
// (tests/screen_scaling_test.js) -- and the functions are written to stand
// alone, with no outside names, because the webview needs them too and gets
// them as source text (see getHtml in extension.js).
//
// The picture is 352x312, border included, and the border setting crops it
// down towards the 256x192 paper before anything is scaled. Every size here is
// worked out in DEVICE pixels first and only then turned back into CSS pixels:
// on a 150% display a "2x" picture is three device pixels a Spectrum pixel,
// and a nearest-neighbour filter is only crisp when that number is whole.

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

/// The part of the 352x312 frame that is shown, for a border setting: `x`,
/// `y`, `w` and `h` in Spectrum pixels. 100 is all the border the emulator
/// draws, 0 the paper alone, and in between each side keeps that share of its
/// own depth -- the border is not the same all round (48 pixels each side, 64
/// lines above and 56 below), so a flat number of pixels would leave it
/// lopsided. Whole pixels only, so the crop always starts on a line and a
/// column, and scanlines and nearest neighbour stay aligned with them.
function visibleRect(borderPercent) {
  const LEFT = 48;
  const RIGHT = 48;
  const TOP = 64;
  const BOTTOM = 56;
  const share = borderPercent >= 0 && borderPercent <= 100 ? borderPercent / 100 : 1;
  const left = Math.round(LEFT * share);
  const right = Math.round(RIGHT * share);
  const top = Math.round(TOP * share);
  const bottom = Math.round(BOTTOM * share);
  return { x: LEFT - left, y: TOP - top, w: left + 256 + right, h: top + 192 + bottom };
}

/// The canvas size for a scale setting, in a panel `availW` x `availH` CSS
/// pixels on a display with `dpr` device pixels to the CSS pixel, for a
/// picture `srcW` x `srcH` Spectrum pixels (the whole frame unless the border
/// is cropped). `canvasW` and `canvasH` are the backing store, in device
/// pixels; `cssW` and `cssH` are what it is laid out at, so the two map one to
/// one and the browser never rescales the canvas behind the filter's back.
function layoutFor(scale, availW, availH, dpr, srcW, srcH) {
  const NATIVE_W = srcW > 0 ? srcW : 352;
  const NATIVE_H = srcH > 0 ? srcH : 312;
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
/// not overshoot the canvas, and never less than 1. `srcW` x `srcH` is the
/// picture being scaled, as for layoutFor.
function prescaleFactor(canvasW, canvasH, srcW, srcH) {
  const w = srcW > 0 ? srcW : 352;
  const h = srcH > 0 ? srcH : 312;
  const k = Math.floor(Math.min(canvasW / w, canvasH / h));
  return k >= 1 ? k : 1;
}

/// The border sizes offered in the picker, as percentages of the border the
/// emulator draws. Any whole number from 0 to 100 works.
const BORDER_PRESETS = [100, 75, 50, 25, 0];

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
  return {
    filter,
    scale,
    scanlines: percent(v.scanlines, 0),
    // Unset means all of it: a panel with no setting shows what it always has.
    border: percent(v.border, 100),
  };
}

/// A whole percentage from 0 to 100, or `fallback` when it is not a number.
function percent(value, fallback) {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }
  const n = Math.round(Number(value));
  if (!Number.isFinite(n)) {
    return fallback;
  }
  return n < 0 ? 0 : n > 100 ? 100 : n;
}

module.exports = {
  FILTERS,
  SCALES,
  SCANLINE_PRESETS,
  BORDER_PRESETS,
  visibleRect,
  layoutFor,
  prescaleFactor,
  scanlinesPossible,
  scanlineBand,
  normaliseView,
};
