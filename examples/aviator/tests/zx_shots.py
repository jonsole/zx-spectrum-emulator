"""Screens from the Spectrum version as it runs: the snapshot run in
snapshot_probe for a number of frames at a time, its screen saved as a PNG,
and the shots put together in a contact sheet.

    python tests/zx_shots.py --every 150 --count 8 --png output/zx-run.png
"""

import argparse
import sys

import zx as zxprobe

FRAME_COLOURS = [(0, 0, 0), (0, 0, 205), (205, 0, 0), (205, 0, 205), (0, 205, 0), (0, 205, 205),
                 (205, 205, 0), (205, 205, 205)]


def screen_image(screen):
    """A 6,912-byte Spectrum screen as a PIL image (bright and flash shown
    as plain colours)."""
    from PIL import Image
    img = Image.new("RGB", (256, 192))
    px = img.load()
    for y in range(192):
        row = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
        for cx in range(32):
            b = screen[row + cx]
            attr = screen[6144 + (y >> 3) * 32 + cx]
            ink = FRAME_COLOURS[attr & 7]
            paper = FRAME_COLOURS[(attr >> 3) & 7]
            if attr & 0x40:
                ink = tuple(min(255, c * 255 // 205) for c in ink)
                paper = tuple(min(255, c * 255 // 205) for c in paper)
            for bit in range(8):
                px[cx * 8 + bit, y] = ink if b & (0x80 >> bit) else paper
    return img


def run_frames(z, frames):
    """Let the program run for this many frames."""
    try:
        z.request(f"runto 0 {frames}")
    except zxprobe.ProbeError:
        pass                                    # "timeout": it ran them all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--every", type=int, default=150)
    ap.add_argument("--count", type=int, default=8)
    ap.add_argument("--png", default=str(zxprobe.ROOT / "output" / "zx-run.png"))
    args = ap.parse_args()
    from PIL import Image
    shots = []
    with zxprobe.Spectrum() as z:
        for _ in range(args.count):
            run_frames(z, args.every)
            shots.append(screen_image(z.peek(0x4000, 6912)))
    cols = 4
    rows = (len(shots) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * 264, rows * 200), (40, 40, 40))
    for i, s in enumerate(shots):
        sheet.paste(s, ((i % cols) * 264 + 4, (i // cols) * 200 + 4))
    sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
    sheet.save(args.png)
    print(f"saved {args.png}")


if __name__ == "__main__":
    sys.exit(main())
