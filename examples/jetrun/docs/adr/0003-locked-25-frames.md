# A pass is exactly two frames, synced on the interrupt

Cyberun has no frame sync: a pass takes as long as its work, two or three
frames, and the game's speed wobbles with what is on the screen. Jetrun locks
every pass to two frames, 25 a second, waiting on the frame interrupt (IM 2).
Everything a pass does has to fit its worst case into those two frames, so the
budget is set by the worst screen, not the average one: the number of live
objects, the length of surface in view and the sounds are all sized to it, and
nothing is skipped when the screen is quiet.
