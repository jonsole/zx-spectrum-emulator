# Rebuild Cyberun's landscape technique rather than patch Ultimate's code

Superseded by 0007: Jetrun now runs Cyberun's own renderer and world.

Cyberun is fully disassembled in `game-disassemblies/` (the listing, its notes
and the published pages), so the quickest route to its smooth landscape
would be to build Jetrun from that disassembly, made from the player's own
tape, with patches and new code on top. We write our own engine instead,
using the disassembly only as the description of how the technique works.
The repository is public and Ultimate's code and data cannot be in it; a game
built from someone's own tape could be played by nobody else; and Jetrun's
needs -- a walking astronaut, a following view, masked sprites, locked frames,
Exile-style physics -- would have left little of Cyberun's engine unchanged.
None of Ultimate's code or data is used; the README credits the technique.
