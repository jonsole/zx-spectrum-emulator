# Jetrun

A 48K Spectrum game in the making: a jetpack astronaut explores a cavern
planet, after Exile, Jetpac and Cyberun. Stage 1 is the landscape and the
astronaut walking, flying and colliding with it.

The landscape is drawn by **Ultimate Play The Game's own renderer from
Cyberun** (1986), and for now the world is Cyberun's own map and tiles.
`cyberun.s` is that renderer's source, taken from the Cyberun disassembly in
[`game-disassemblies`](../../game-disassemblies) (its `notes/cyberun/landscape.md`
explains how it works), made relocatable and changed where marked `Jetrun:`.
Cyberun's code, graphics and world are Ultimate's (now Rare's); they are here
as a study of how the game draws its landscape. See
[docs/adr/0007](docs/adr/0007-cyberuns-own-renderer-and-world.md).

## Building and checking

```
python examples/jetrun/build.py     # output/jetrun.sna, .sld, .sym
python examples/jetrun/check.py     # the Z80 against the Python model
```

`build.py` generates `output/data.s` from `world/*.json` and the Python
modules and assembles `jetrun.s` with sjasmplus. `check.py` runs the built
game in SkoolKit's simulator and compares it, pass by pass, with `game.py`'s
model -- the astronaut's physics, sprite, colours and the view -- taking the
landscape from the Z80; it also runs the whole game with the frame interrupt
and checks every pass starts exactly two frames after the last.

Keys: Interface II (9 thrust, 6 left, 7 right) or Q, O, P.

## Files

| File | What |
|---|---|
| `jetrun.s` | the start, the frame interrupt, the pass, the variables |
| `cyberun.s` | Cyberun's landscape renderer |
| `landscape.s` | driving it: each pass's scroll, and the full render at a life's start |
| `astronaut.s` | controls, physics, collision read from the screen, the view |
| `sprite.s` | the astronaut's masked sprite and its cells' colours |
| `world.py`, `world/*.json` | the map and tiles, and their geometry |
| `model.py`, `game.py`, `sprites.py` | the Python model `check.py` compares with |
| `docs/renderer.md` | how the landscape is drawn, with a pass traced step by step |
| `GLOSSARY.md`, `docs/adr/` | the words used, and the decisions made |
