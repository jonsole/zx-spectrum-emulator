; ---------------------------------------------------------------------------
; The behaviours more than one game has. Knight Lore and Pentagram each wrote
; their own movers, and where the two turned out to be the same routine, or
; the same routine but for a sound, it lives here instead and both games point
; their mover_tbl at it. A third game gets these for nothing, and a fix to one
; of them lands in one place.
;
; Every routine is wrapped in IFUSED, so a game assembles only the ones its
; own code names and an unused one costs no bytes. That is the whole of how a
; game chooses: there is no switch in here for which game is being built.
; What differs between games comes in from the game by name -- a constant it
; defines or a routine it supplies, listed under "What the game supplies" in
; README.md -- with no default in here, so that one a game forgot is an
; assembly error and not a silent guess.
;
; Where two behaviours differ only by a call at the start, the one with the
; call is a second entry that falls into the other, and an ASSERT holds the
; two together. The ASSERT names the second label, which is also what makes
; IFUSED keep it when a game names only the first.
;
; Which behaviour number means what stays the game's: the numbers are an
; ordered enum the engine reads by bands, and the two games order theirs
; differently. So mover_of and mover_tbl stay in the game's movers.s, and only
; the routines they point at are here.
;
; Included after engine/mover.s, which the game's movers.s may fall into.
; ---------------------------------------------------------------------------


; What drives a template, or 0 for nothing. Room-build time only, so a walk
; will do. The game's mover_of is pairs of (template, behaviour), ended by
; $FF, which is not a template.
;   A  - the template index
; Out: A - the behaviour. Preserves DE.
					IFUSED	mover_find
mover_find:			ld		hl,mover_of
.next:				ld		c,(hl)
					inc		c		; $FF ends the list
					jr		z,.none
					dec		c
					cp		c
					inc		hl
					jr		z,.found
					inc		hl
					jr		.next
.found:				ld		a,(hl)
					ret
.none:				xor		a
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Something that only falls, and goes wherever whatever it stands on goes.
;
; Clear the step, then fall, and that is all -- Knight Lore's upd_62 and
; Pentagram's $CD75 both. Everything else happens inside the clamp, where
; object_carry hands it the step of whatever stopped its fall. Clearing DU and
; DV every turn is what makes that safe: the ride is the only thing that ever
; writes them, so it can never accumulate. Whether it can also be shoved is
; not this routine's business but its behaviour's band -- BEHAVIOUR_LOOSE.
;
; It is worth noticing that this needs no notion of "standing on" at all. The
; thing is always falling a little and always landing, and landing is where
; the question gets asked.
;
; mover_falls_noisy is the same with the game's sound_falls every turn first:
; Knight Lore's moveable block chirps as upd_62 does, and Pentagram's makes no
; sound and uses mover_falls.
;   IX -> the record
					IFUSED	mover_falls_noisy
mover_falls_noisy:	call	sound_falls
					ASSERT	$ == mover_falls
					ENDIF

					IFUSED	mover_falls
mover_falls:		call	mover_halt
					jp		mover_move		; DZ is left to gravity
					ENDIF


; ---------------------------------------------------------------------------
; A platform that sinks a unit every turn something is standing on it --
; Knight Lore's dropping block, upd_91, and Pentagram's $CDA0. It has no
; gravity of its own and moves only while it is weighed down.
;
; object_landed_on leaves the mark, MOVE_STATE bit 3, when whatever is on top
; comes down on it in its own clamp; Knight Lore does the same at $CC6C and
; Pentagram at $B838. Behaviours from BEHAVIOUR_GIVES to BEHAVIOUR_GIVES_LAST
; get the mark, so this one's must be among them.
;
; It sounds the game's sound_z while it is going down -- Knight Lore's hum
; for falling things. Pentagram's sound_z is silent.
;   IX -> the record
					IFUSED	mover_sinks
mover_sinks:		bit		3,(ix+OBJ.MOVE_STATE)
					ret		z
					res		3,(ix+OBJ.MOVE_STATE)
					ld		(ix+OBJ.DZ),0		; one unit, not a fall
					call	mover_move
					ld		a,(collide_hit)		; sounding if it went down
					and		COLLIDE_Z
					jp		z,sound_z
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Is the player standing on this record? His feet on its top or a little
; above it, and over it along both floor axes.
;
; The slack is Pentagram's lift's: it gives him his rise before it takes its
; own, so for a turn his feet are above its top, and the two leapfrog up.
;
; The boxes are half-widths, and boxes that only touch count as apart, as the
; clamp has them. So he is over it when the distance between the centres is
; less than its half-width and his together.
;   IX -> the record
; Out: zf set if he is. Corrupts AF, C.
ON_TOP_SLACK		EQU		6

					IFUSED	player_on_top
player_on_top:		ld		a,(ix+OBJ.Z)
					add		a,(ix+OBJ.SIZE_Z)
					ld		c,a
					ld		a,(walker_player + OBJ.Z)
					sub		c
					cp		ON_TOP_SLACK + 1
					jr		nc,.off		; below its top, or well above
					ld		a,(walker_player + OBJ.U)
					sub		(ix+OBJ.U)
					call	character_door_find.abs
					ld		c,a
					ld		a,(ix+OBJ.SIZE_U)
					add		a,CHARACTER_HALF_U
					cp		c
					jr		c,.off
					jr		z,.off
					ld		a,(walker_player + OBJ.V)
					sub		(ix+OBJ.V)
					call	character_door_find.abs
					ld		c,a
					ld		a,(ix+OBJ.SIZE_V)
					add		a,CHARACTER_HALF_V
					cp		c
					jr		c,.off
					jr		z,.off
					xor		a		; zf: on it
					ret
.off:				or		1		; nz: not
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Take a record out of the room: repaint where it was, without it, and leave
; the slot empty. Knight Lore gives a taken object graphic 1, which the next
; draw wipes and turns to 0; this does both at once.
;   IX -> the record
; Corrupts everything, IX included.
					IFUSED	object_hide
object_hide:		call	region_reset
					call	region_add
					call	depth_unlink
					call	object_blank
					jp		redraw_view
					ENDIF

; A slot with nothing in it: no graphic, no behaviour, and nothing collides.
;   IX -> the record
					IFUSED	object_blank
object_blank:		ld		(ix+OBJ.GFX),0
					ld		(ix+OBJ.BEHAVIOUR),0
					ld		(ix+OBJ.FLAGS),OBJ_PASSABLE
					ret
					ENDIF
