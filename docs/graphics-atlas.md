# The graphics atlas (.json)

What the [graphics viewer](vscode-debugging.md#graphics-viewer) writes when you
export a sheet, a group or a single sprite, and reads back on **Import...**.

It is a **TexturePacker "JSON (Hash)"** file, the layout Aseprite also writes
and Phaser loads unchanged, with everything this panel knows added under `zx`
keys that other tools ignore. So the same file is both a sprite sheet a game
engine can load and a record of where every byte came from: which sprite, which
item of it, its offset into that sprite's data, and the Spectrum address it was
read from.

An export writes up to four files, named after the atlas:

| File | When |
|---|---|
| `knight.json` | always |
| `knight.png` | with **Picture** ticked, which it is by default |
| `knight.sna` | with **Point into the snapshot** ticked, and a sprite that was read from memory |
| `knight.s` | with **Assembler source** ticked |

The panel refuses a `.json` that has no `meta.zx.sprites`, so a file this did
not write is never mistaken for one.

## The shape of it

```json
{
  "frames": {
    "knight_walk_0": {
      "frame":            { "x": 0, "y": 0, "w": 16, "h": 8 },
      "rotated": false,
      "trimmed": false,
      "spriteSourceSize": { "x": 0, "y": 0, "w": 16, "h": 8 },
      "sourceSize":       { "w": 16, "h": 8 },
      "zx": { "sprite": "knight_walk", "group": "knight", "item": 0,
              "offset": 0, "address": 39994 }
    },
    "knight_walk_1": {
      "frame":            { "x": 17, "y": 0, "w": 16, "h": 8 },
      "rotated": false,
      "trimmed": false,
      "spriteSourceSize": { "x": 0, "y": 0, "w": 16, "h": 8 },
      "sourceSize":       { "w": 16, "h": 8 },
      "zx": { "sprite": "knight_walk", "group": "knight", "item": 1,
              "offset": 32, "address": 40026 }
    }
  },
  "meta": {
    "app": "ZX Spectrum emulator graphics viewer",
    "version": "1.0",
    "image": "knight.png",
    "format": "RGBA8888",
    "size": { "w": 33, "h": 8 },
    "scale": "1",
    "zx": {
      "version": 1,
      "groups": [
        { "name": "knight",
          "sprites": ["knight_walk"],
          "frames": ["knight_walk_0", "knight_walk_1"] }
      ],
      "sprites": [
        {
          "name": "walk",
          "group": "knight",
          "source": "memory",
          "address": "sprite_030",
          "format": "sprite",
          "width": 2, "height": 8, "count": 2, "columns": 2,
          "header": 0, "first": 32,
          "interleave": "md", "invertMask": false, "bottomUp": true,
          "ink": 7, "paper": 0,
          "label": "knight_walk",
          "origin": "sprite_030",
          "resolvedAddress": 39994,
          "frames": ["knight_walk_0", "knight_walk_1"],
          "length": 64,
          "bytes": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw=="
        }
      ]
    }
  }
}
```

`meta.app`, `meta.version`, `frame`, `rotated`, `trimmed`, `spriteSourceSize`
and `sourceSize` are TexturePacker's. `rotated` and `trimmed` are always false:
nothing is turned or cropped, so a frame's rectangle is its whole picture.

Without a picture -- **Picture** unticked -- there is no `meta.image`, `format`,
`size` or `scale`, and a frame is only `{ "sourceSize": …, "zx": … }`. The
atlas is then a description of the data rather than an index into an image.

## `zx` on a frame

One frame per item that had bytes. An item past the end of the data is left out
rather than exported empty, so a `count` set higher than the data runs costs
nothing.

| Key | Meaning |
|---|---|
| `sprite` | The label of the sprite this frame came from |
| `group` | Its group's name; absent when it is in none |
| `item` | Which item of that sprite, counting from 0 |
| `offset` | Where the item starts in the sprite's own bytes, the header included |
| `address` | Where that byte was in the machine, 0-65535. Only for a sprite read from memory whose address resolved |
| `code` | The character code, in a `font`. `first` plus the item, wrapped to a byte |

**Frame names** are the sprite's label, then the item: `knight_walk_0`. A
sprite of one item, or a screen, is its label alone; a font uses the character
code, so `font_65` is "A". A label is the sprite's name with its group's in
front (`walk` in `knight` is `knight_walk`), which is why two groups can each
hold a `walk`. Every label in an export is unique -- across sprites, their
items, their groups, and the `_bitmap` and `_attrs` a screen adds -- so a
second sprite whose name collides is exported as `ball_2`.

## `meta.zx`

| Key | Meaning |
|---|---|
| `version` | The `zx` block's own version, 1 |
| `groups` | The sheet's groups in order: `name`, the sprite `sprites` labels in it, and all their `frames` |
| `sprites` | Every sprite exported, in sheet order |

## A sprite

The first block is exactly what the **Add...** dialog edits -- one sprite's own
settings, which is why a sheet can hold sprites of different sizes, formats and
sources at once.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `name` | label characters | -- | The sprite's own name, letters, digits and underscores |
| `group` | label characters | absent | Its group's name; absent when in none |
| `source` | `memory`, `file`, `selection`, `sheet` | `memory` | Where its bytes were read from. `selection` and `sheet` have nowhere to be read from again, so they carry their `bytes` |
| `address` | text | `$4000` | For `memory`: the address as typed, a symbol or a sum (`sprite_000+4`). Absent otherwise |
| `file` | path | -- | For `file`: relative to the atlas when it can be, else absolute. Absent otherwise |
| `offset` | 0-2147483647 | 0 | For `file`: bytes skipped at the start |
| `format` | `sprite`, `font`, `screen` | `screen` | How the bytes are laid out |
| `width` | 1-64 | 2 | Bytes across an item, before any mask interleaving |
| `height` | 1-256 | 16 | Pixel rows an item |
| `count` | 1-1024 | 16 | Items |
| `columns` | 1-64 | 8 | Items per row, in the sheet and in the picture |
| `header` | 0-64 | 0 | Bytes skipped before **each** item |
| `first` | 0-255 | 32 | In a `font`: the character code of item 0 |
| `interleave` | `none`, `md`, `dm` | `none` | Mask and data per byte across a row: none, mask first, or data first |
| `invertMask` | boolean | `false` | A **clear** mask bit means transparent |
| `bottomUp` | boolean | `false` | Row 0 of the data is the bottom row of the picture -- the panel's **flip** |
| `ink`, `paper` | 0-15 | 0, 15 | The ULA colours a set and a clear bit are drawn in |

Then what the export adds:

| Key | Meaning |
|---|---|
| `label` | The name used in the atlas and the source: the group's name and the sprite's |
| `origin` | Where it was read from, as the panel showed it (`sprite_030`, `sprite_data.bin+2`) |
| `resolvedAddress` | The address `address` resolved to when it was read, 0-65535. Only for `memory` |
| `frames` | The frame names this sprite produced, in order |
| `length` | How many bytes it holds |
| `bytes` | Its bytes, base64. Absent when the export points instead |
| `snapshot` | Where to read its bytes: `{ file, offset, address }`. Only when pointing |

The byte count follows from the layout: a row is `width` bytes, doubled when
`interleave` is not `none`; an item is `header` plus `height` rows; a sprite is
`count` items. A `screen` is always 6,912 bytes -- 6,144 of bitmap and 768 of
attributes -- or 6,144 with no colour.

## Pointing instead of carrying

With **Point into the snapshot instead of carrying the bytes** ticked, a sprite
whose bytes can be found again is written without `bytes` and with `snapshot`
instead:

- **From memory:** the export saves the machine as `knight.sna` beside the
  atlas and points into it. `offset` is the byte's position in that file (27
  bytes of header, then RAM from `$4000`) and `address` is where it lives in the
  machine. This needs the debug session the sprite was read from, since the
  snapshot is taken at the moment of export.
- **From a `.sna` file:** it points into that file, with the address its bytes
  load at.
- **From any other file:** nothing is added. Its own `file` and `offset` already
  say where the bytes are.
- **From a selection or a sheet, or from the ROM:** there is nowhere to point,
  so those carry their `bytes` whatever the tick box says.

Paths are written relative to the atlas when that is possible, so an export
inside a repository still finds its files from another clone.

## Reading one back

**Import...** adds an atlas's sprites to the end of the sheet, in their groups.
A group whose name is already on the sheet comes in beside it as `knight_2`
rather than the two mixing.

A hand-edited atlas is read field by field, so one bad value costs that field
rather than the file:

- `source`, `format` and `interleave` fall back to `selection`, `sprite` and
  `none` when they are not one of the values above.
- The numbers are clamped to the ranges in the table.
- `invertMask` and `bottomUp` are true only when they really are `true`.
- `name` and `group` are reduced to label characters.
- `bytes` that are not valid base64 are reported, and that sprite comes in with
  none.
- A sprite whose `source` is `selection` or `sheet` and which carries no bytes
  is reported: there is nothing to re-read it from.

An imported sprite stays tied to where it came from. A `memory` one is re-read
from the running machine on the next **Refresh** or stop, which is the point of
importing one -- the atlas says where to look, the machine says what is there
now.

A `sheet` one is the opposite: it was drawn rather than found, so the bytes in
the atlas are all there is. That is the source for an atlas written by a tool
of your own -- `examples/filmation/knightlore/sprite_sheet.py` writes one for
Knight Lore's artwork -- and the panel never asks the host for its bytes, so
changing its width or its height re-reads nothing. Only **Grab selection** and
**Re-read** go back to the host. It is offered in the dialog but cannot be
chosen: it is what an imported sprite has, not something to make a new one
from.

**Clear** empties the sheet. It asks first, because a sprite that carries its
own bytes cannot be read back once it is gone, and it takes the groups with
it.

## Using one in a game engine

The picture and the frames are ordinary TexturePacker, so Phaser's
`load.atlas(key, 'knight.png', 'knight.json')` takes it as it stands, and any
tool that reads that layout will find the frames where it expects them. What is
Spectrum about the data is all under `zx`, which such tools pass over.

Two things worth knowing if you write your own loader:

- Frames are **one image pixel per Spectrum pixel** and a pixel apart, so
  filtering never bleeds one frame into the next. Each sprite keeps its own
  `columns`, and each group starts a new row of the picture.
- Masked pixels are fully transparent; everything else is the sprite's own
  `ink` and `paper`, from the ULA's palette, except a `screen`, which uses its
  own attributes.
