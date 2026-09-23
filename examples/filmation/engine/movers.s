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
; A routine the game supplies is usually one it already has, named by EQU:
; hopper_move EQU mover_move costs nothing, and a game that wants nothing done
; points the name at any RET it has. Only what a game does that no routine of
; its own already does needs code of its own.
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
;
; In:  A = the template index
; Out: A = the behaviour
; Corrupts: F, C, HL
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
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_falls_noisy
mover_falls_noisy:	call	sound_falls
					ASSERT	$ == mover_falls
					ENDIF

; See mover_falls_noisy.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
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
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
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


ON_TOP_SLACK		EQU		6		; see player_on_top


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
;
; In:  IX -> the record
; Out: Z set if he is
; Corrupts: A, C
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
;
; In:  IX -> the record
; Out: nothing
; Corrupts: everything
					IFUSED	object_hide
object_hide:		call	region_reset
					call	region_add
					call	depth_unlink
					call	object_blank
					jp		redraw_view
					ENDIF

; A slot with nothing in it: no graphic, no behaviour, and nothing collides.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: nothing
					IFUSED	object_blank
object_blank:		ld		(ix+OBJ.GFX),0
					ld		(ix+OBJ.BEHAVIOUR),0
					ld		(ix+OBJ.FLAGS),OBJ_PASSABLE
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Pacing to and fro along one axis, turning round whenever something stops it
; -- Knight Lore's fires, upd_86_87 and upd_180_181, and Pentagram's platforms
; and dragon's heads, $CEA3 and $CEDD. Both games wrote it as one routine with
; the axis patched in, because (IX+d) takes its displacement as an immediate,
; and so does this.
;
; The neat part is Knight Lore's: the bit of MOVE_STATE that says which way it
; is going is numbered by axis, and so is the bit collide_hit sets for the axis
; the clamp had to cut, so the same mask does both and the turn is an XOR.
; From rest -- the bit clear -- it goes the negative way first, as both do.
; It does not fall: mover_hover holds it up for the turn.
;
; What the game supplies:
;   PACER_STEP    how far it goes a turn
;   pacer_sound   called first, with L the axis's collide bit, and H the
;                 step's offset in the record. Knight Lore hums along U or V.
;   pacer_frame   called once the step is cleared and the thing held up; may
;                 change the graphic. Knight Lore's fires flicker.
;   pacer_move    moves it by the step now in the record: mover_move, or
;                 mover_move_always for one whose graphic changes every turn.
;   mover_turned  see mover_turn_if_hit.
; Each may corrupt anything but IX.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_pacer_u
mover_pacer_u:		ld		hl,OBJ.DU * 256 + COLLIDE_U
					jr		mover_pacer
					ENDIF

; See mover_pacer_u.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_pacer_v
mover_pacer_v:		ld		hl,OBJ.DV * 256 + COLLIDE_V
					ASSERT	$ == mover_pacer
					ENDIF

; See mover_pacer_u. The axis comes in HL: H its offset in the record, L its
; collide bit.
;
; In:  IX -> the record; mover_ix names it too
;      H  = OBJ.DU or OBJ.DV
;      L  = COLLIDE_U or COLLIDE_V
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_pacer
mover_pacer:		ld		a,h
					ld		(.step + 2),a		; LD (IX+d),A is DD 77 d
					ld		a,l
					ld		(.which + 1),a		; the axis, as a mask
					call	pacer_sound
					call	mover_hover		; it does not fall
					call	pacer_frame

					ld		a,(ix+OBJ.MOVE_STATE)
.which:				and		0		; patched: the axis bit
					ld		a,PACER_STEP
					jr		nz,.forward
					neg
.forward:
.step:				ld		(ix+OBJ.DU),a		; patched: DU or DV

					call	pacer_move
					ld		a,(.which + 1)		; the same bit again
					ASSERT	$ == mover_turn_if_hit
					ENDIF


; Turn round if the move just made was stopped along the axis in A: flip that
; bit of MOVE_STATE, which is numbered by axis the same way collide_hit is,
; and tell the game's mover_turned, with the bit in A. Knight Lore's fires
; bounce off whatever stops them along V; Pentagram's paced things are silent.
;
; In:  A  = the axis's bit
;      IX -> the record
; Out: nothing
; Corrupts: AF, C, and whatever mover_turned does
					IFUSED	mover_turn_if_hit
mover_turn_if_hit:	ld		c,a
					ld		a,(collide_hit)
					and		c
					ret		z		; nothing in the way
					ld		a,(ix+OBJ.MOVE_STATE)
					xor		c
					ld		(ix+OBJ.MOVE_STATE),a
					ld		a,c
					jp		mover_turned
					ENDIF


HOPPER_RISING		EQU		2		; the bit of MOVE_STATE -- see mover_hopper


; ---------------------------------------------------------------------------
; Bouncing on the spot: it falls, and on landing climbs again until it is
; above hopper_top, and then falls again -- Knight Lore's balls, upd_178_179,
; and Pentagram's bobbing dragon's head, $CE31.
;
; Falling needs no code: mover_clamp's DEC is the gravity, and the clamp stops
; it on the floor or on whatever it lands on. Climbing sets DZ to HOPPER_RISE,
; which the same DEC takes one off. MOVE_STATE bit HOPPER_RISING says it is
; on the way up -- the game's own bit 2 of $0D, in Knight Lore.
;
; mover_hopper_claim is Knight Lore's odd rule, and worth saying twice. The
; room's top is one variable, zeroed when the room is built, and if it is
; still zero -- which it is until the first ball of the room takes its turn --
; that ball fills it in from its own Z plus HOPPER_ABOVE. Every other ball in
; the room then bounces to THAT height, wherever it sits itself; whichever the
; object walk reaches first decides for all of them ($5BBD). Pentagram's top
; is fixed, and its hopper starts at mover_hopper.
;
; What the game supplies:
;   hopper_top     a byte: it rises until its Z is past this. Pentagram's is
;                  one below Z 176, where it stops.
;   HOPPER_RISE    the DZ it climbs with, before gravity takes one back
;   HOPPER_ABOVE   for mover_hopper_claim only: how far above the first one
;   hopper_frame   called first; must clear DU and DV -- mover_halt, or
;                  mover_flicker for one that flickers as it goes
;   hopper_sound   called every turn after that
;   hopper_move    moves it while it falls: mover_move, or mover_move_always
;                  for one whose graphic changes every turn
;   hopper_landed  jumped to on the turn it lands
; Each may corrupt anything but IX.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_hopper_claim
mover_hopper_claim:	ld		a,(hopper_top)
					or		a
					jr		nz,mover_hopper		; somebody has claimed it
					ld		a,(ix+OBJ.Z)
					add		a,HOPPER_ABOVE
					ld		(hopper_top),a
					ASSERT	$ == mover_hopper
					ENDIF

; See mover_hopper_claim.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_hopper
mover_hopper:		call	hopper_frame
					call	hopper_sound
					bit		HOPPER_RISING,(ix+OBJ.MOVE_STATE)
					jr		nz,.rising

					call	hopper_move		; DZ is whatever gravity left it
					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still in the air
					set		HOPPER_RISING,(ix+OBJ.MOVE_STATE)	; landed: up again
					jp		hopper_landed

.rising:			ld		(ix+OBJ.DZ),HOPPER_RISE
					call	mover_move_always
					ld		a,(hopper_top)
					cp		(ix+OBJ.Z)
					ret		nc		; not past it yet
					res		HOPPER_RISING,(ix+OBJ.MOVE_STATE)
					ret
					ENDIF
