# The RF look

An optional filter on the displayed picture that makes it look as it did on a
TV through the Spectrum's RF lead: the PAL colour subcarrier's dot crawl and
cross-colour, colour bleed, soft luma, a ghost, noise, scanlines and jail
bars. It is a
display setting only. The machine runs the same with it on or off, and
nothing about it is machine state: a reset keeps it, snapshots don't hold it,
and stepping backwards doesn't see it.

It is a full PAL encode and decode, not an imitation. Each line's colours are
turned into the composite signal with the subcarrier's real phase, then
decoded the way a simple TV would. The filter is specified to the bit in
retro-spectrum's `docs/spec/rf.md`, so this emulator, retro-spectrum's C++
model and its FPGA (the same filter on the SpecNext's HDMI) give the same
pixels. The emulator was asked to be the reference.

## Using it

In VS Code:

- **ZX Spectrum: Toggle RF Look** turns it on and off. It is also the
  colour-mode button on the screen panel's title bar.
- **ZX Spectrum: RF Look...** lists every setting with its value. Pick a
  switch to flip it, or a level to choose a new one. **Put back the
  defaults** resets everything except the master switch.
- The same settings are `zxspectrum.rf.*` in the Settings editor.

The settings belong to VS Code, and the server draws the picture. Whenever a
setting changes, and whenever a screen panel connects, every server a panel
shows is sent all eighteen. A server started or restarted later therefore
comes up looking the way you left it, and so does the board through its
bridge, which answers the same call.

From MCP, the `rf_filter` tool reads and changes them (see
[mcp.md](mcp.md)). Only the arguments given change, and it replies with all
eighteen. `{"on": true}` turns it on; `{}` just reports.

While it is on, `get_screen` and the screen panel get a **704x624**
picture instead of 352x312: two samples per Spectrum pixel, and each line
drawn twice so the scanlines have a line to darken. The panel's own border
crop and scaling work on it unchanged.

## The settings

The defaults are the board's power-on settings (rf.md section 5), its Good
TV preset with the master switch off: FLAGS 0x7E, BAND 0xB7, then 6, 0x42,
0x41, 6 and 0xC7.

| Setting | `rf_filter` | Range | Default | What it does |
|---|---|---|---|---|
| RF look | `on` | on/off | off | The master switch. Off is the plain picture, to the pixel |
| Composite | `composite` | on/off | on | The PAL encode and decode. Off leaves the RGB picture with scanlines only: the ghost and the noise are on the RF signal, so they need it |
| Ghost | `ghost` | on/off | on | A delayed echo of the picture |
| Noise | `noise` | on/off | on | RF noise |
| Scanlines | `scanlines` | on/off | on | The second copy of each line darker |
| Jail bars | `jail` | 0-3 | 3 | Still vertical bars on the paper: 0 off, 1-3 about 1, 2 and 4 % of white |
| Jail bars on the RGB | `jail_rgb` | on/off | off | Sharp on the decoded picture rather than softened on the composite. With the composite off they are on the RGB anyway |
| Crystal offset | `crystal_ppm` | -12.8 to 12.7 | -5.7 | The 48K's, in ppm, steps of 0.1: how its dots move from frame to frame |
| Luma | `luma` | 0-3 | 3 | 0 no trap (the strongest dots), 1 the subcarrier trap, 2 and 3 softer still |
| Colour bandwidth | `chroma` | 0-3 | 3 | The chroma's filter: 0 a 2-sample box, 1 a 9-tap low-pass, 2 and 3 8- and 16-sample boxes |
| PAL delay line | `pal_delay` | on/off | on | As a better TV: U and V averaged with the line above, which steadies colour edges |
| Colour gain | `colour` | 0-3 | 2 | x1, x7/8, x3/4 or x5/8: weaker cross-colour dots, paler colours |
| Ghost delay | `ghost_d` | 0-63 | 6 | In samples of 71 ns; 0 is no ghost |
| Ghost strength | `ghost_g` | 0-15 | 2 | G/32 of the picture |
| Noise level | `noise_n` | 0-15 | 1 | |
| Scanline depth | `scan_d` | 0-15 | 6 | Sixteenths darker |
| Dot crawl cut | `dots_cut` | 0-15 | 4 | Eighths of the dot crawl taken out: the luma drawn that far towards the picture's own. 0 is the full PAL look, 8 and up none left |
| Colour fringes cut | `fringes_cut` | 0-15 | 4 | Eighths of the colour fringes taken out: U and V drawn that far towards the picture's own. 8 and up is the picture's own colour |

## Why the 48K crawls and the 128K does not

The 48K's ULA draws the picture from a 14 MHz crystal, and the colour comes
from a second crystal of 4.43361875 MHz in the modulator. The two are
unrelated, so the subcarrier's phase moves 0.3167 of a cycle per sample. A
line is 283.75 cycles, so the dots shift by three-quarters of a cycle per
line, which gives diagonals. The 128K makes its subcarrier from its own pixel
clock: 5/16 of a cycle per sample, whole cycles per line and per frame. Its
dots sit still, as vertical stripes on colour edges.

How the 48K's dots move from frame to frame depends on the machine. With
both crystals exactly nominal a frame is 88,530.4992 cycles and the dots
nearly invert every frame, a harsh 25 Hz shimmer. But 1 ppm of difference
between the crystals moves each frame's phase by 0.0885 of a turn, and real
machines are a few ppm apart and drift as they warm: one flips its dots,
another creeps, another stands still. Sinclair fitted a trimmer to the 14 MHz
crystal of the issue 2 "to minimise dot crawl". So the setting is the
crystal offset itself. The default, -5.7 ppm, is a trimmed machine whose dots
creep slowly; 0 is the nominal shimmer. A 128K has the one
crystal, so its dots stand still whatever the setting says.

## Jail bars

Still vertical bars on the paper, from the supply noise of the ULA's screen
fetches. They repeat every 16 pixels, the ULA's 8 T-state fetch, and stop at
the border, where it does not fetch. Their shape is the 48K's, read from a
photo of a 48K before its fix: three thin dark lines 4 pixels apart, then
quiet. On the composite (the default) the TV's filters soften them; on the
RGB they are sharp, as on a 128K's RGB output. A 128K's own softer bands
are not drawn yet; a 128K gets the 48K's.

## How it works

`cpp-core/src/rf_filter.cpp`, following rf.md section 4:

1. **Encode.** Each sample's colour index and phase look up the composite
   level in retro-spectrum's own table, copied in by
   `scripts/rf_tables_inc.py` rather than worked out again. Then the jail
   bars, if they go on the composite.
2. **Ghost.** Add a delayed, scaled copy.
3. **Noise.** Add a 16-bit LFSR's low byte, scaled. At the start of line L of
   frame F the generator has stepped (F x 312 + L) x 704 times from 0xACE1,
   so a frame's noise is the same however many frames were skipped before
   it. The emulator only filters the frames it publishes.
4. **Luma.** No trap, or the trap (a notch at the subcarrier, 91/74/91) and
   up to two [1,2,1] stages. Then the dot crawl dial draws it towards the picture's own luma, with the
   ghost and the noise as the composite has them.
5. **Chroma.** The composite less the trap's output, demodulated with the
   encoder's own phase (a perfect burst lock), then a box of 2, 8 or 16
   samples or, at setting 1, a 9-tap low-pass. The colour fringes dial draws
   U and V towards the picture's own. Then the PAL delay line, if on, adds
   the line above's U and V, and the colour gain scales them. The first version of the spec demodulated the whole composite,
   and a flat bright area came out full of false colour. The box is not a
   whole number of subcarrier cycles long, so it doesn't cancel a steady
   level.
6. **RGB** from Y, U and V in fixed point. Then the jail bars, if they go
   on the RGB.
7. **Scanlines** on the second copy of each line.

The phase at frame F is F times the per-frame step that the crystal offset
gives, rather than a running sum, for the same reason as the noise. Changing
the offset makes the pattern jump, which is harmless.

The filter runs on the emulator thread each time a frame is published, after
the raster marker and the write overlay, so those are filtered too. It maps
each pixel back to a colour index first. That is exact for the palette, and
the nearest index for the overlay's dimmed colours.

The filter takes about 4 ms a frame (Release). What cost more was getting
the picture to the panel: the noise leaves 704x624 almost incompressible,
and compressing it to PNG took about 100 ms a frame, which held the panel to
ten frames a second. So the screen stream sends the filtered picture as a
PNG with its data stored rather than compressed (about 4 ms, 1.3 MB a frame,
on the local socket), and the panel takes the frames as bytes rather than
base64. `get_screen` still compresses, since its reply goes into a
conversation.

`cpp-core/tests/rf_filter_tests.cpp` checks the tables against the spec's
formula and the phase constants against the crystals. When retro-spectrum is
checked out beside this repository, it also diffs 400 runs of four lines,
each filtered twice as the board does, with random settings against that
repository's model, sample for sample. Running lines in order is what lets
the delay line be checked: it needs the line above.

## Not done

- **Video and frame sequences** (`start_video`, `get_screen_sequence`)
  record the plain picture. The filter is applied only to what is published
  for the panel and `get_screen`.
- **The DAP side** has no request for it. VS Code sets it over MCP, which the
  board's bridge also answers.
