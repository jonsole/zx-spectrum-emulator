# The screen is never cleared: plain sky, checkered rock, even moves

Drawing the whole play area every pass would leave no time for anything
else, so, as in Cyberun, the landscape is drawn only where it can have
changed. That rests on an art rule: the sky is plain black and the inside of
rock is a checker of alternate pixels, and both look the same after the view
moves an even number of pixels. So the view moves in even steps only, and a
pixel can change only if a surface has crossed it -- which is within a band
around each surface. The cost is that rock has no texture of its own and the
sky has none; colour comes from the attribute cells, written only along
the surfaces. A new life,
where the view jumps rather than moves, gets a full render instead.

Each pass every step in view is drawn, and the strips a moving edge
uncovers are filled, by Cyberun's own renderer (0007). (We first drew each
step as a band with a margin above and below its surface instead of separate
fills; that was too slow, and 0007 replaced it.)
