# Use Cyberun's own landscape renderer, and for now its world

Supersedes 0001, and the band drawing of 0002.

The bands we rebuilt the technique with were correct but cost two to five
times a pass's budget. Cyberun's renderer draws the same kind of landscape in
a fraction of that, so Jetrun now runs Ultimate's own code: `cyberun.s` is
the renderer's source taken from the Cyberun disassembly in
`game-disassemblies` -- scroll_landscape, draw_landscape, the POP blitters,
the fills behind moving edges, colour_piece and the pre-shifted step graphics
-- with every address the listing had as a number turned into a label, so it
assembles wherever Jetrun puts it. It was checked against the original,
patched and at its own addresses, over 4,132 passes of random scrolling:
every screen identical. Jetrun's changes to it are marked `Jetrun:` in the
source: its map and tiles, no fly-in, objects, beams or ship, draw_landscape
keeping its own SP instead of Cyberun's fixed stack depth, and speed-ups,
each checked byte for byte against the unchanged renderer.

For now the world is Cyberun's too: its 96 x 28 map and 171 tiles, in
`world/*.json` in the form its tile records take (with its upside-down and
mirrored markers), each encoding back to exactly Cyberun's bytes. Our own
test tiles kept breaking rules the renderer relies on -- which end codes a
joint needs, where a rock-left wall's edge is, that a wall's bottom must not
meet a roof square on -- and Cyberun's world is known to draw cleanly. A
world of our own comes back with the editor (0006).

So Ultimate's code and world data are in this repository, by the owner's
decision; the README must credit them. Two consequences carried over from
Cyberun: its blitters borrow SP, so Jetrun's interrupt routine mends the two
graphic bytes the interrupt's push can land on (keeping the frame lock of
0003 with interrupts on), and its colouring writes attributes only along the
surfaces, so the play area takes the surface colour once, at power-on.
