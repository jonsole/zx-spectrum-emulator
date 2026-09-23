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


; ---------------------------------------------------------------------------
; A lift, which carries the player up: while he stands on it it rises
; LIFT_RISE a turn and gives him LIFT_GIVES_HIM, up to LIFT_TOP, where it
; holds; when he is off it, it sinks a unit a turn back to where it stands,
; and waits for him again. It has no gravity of its own. Pentagram's $CDBB.
;
; MOVE_STATE bit 0 is going; bit 1 is on its way back down.
;
; What the game supplies: LIFT_TOP, LIFT_RISE and LIFT_GIVES_HIM, which is one
; more than it means -- the character's own gravity takes that one back.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_lift
mover_lift:         bit     0,(ix+OBJ.MOVE_STATE)
                    jr      nz,.going
                    call    player_on_top       ; waiting: until he is on it
                    ret     nz
                    set     0,(ix+OBJ.MOVE_STATE)

.going:             bit     1,(ix+OBJ.MOVE_STATE)
                    jr      nz,.down
                    call    player_on_top
                    jr      nz,.back            ; he has got off: back down
                    ld      a,(ix+OBJ.Z)
                    cp      LIFT_TOP
                    jr      nc,.hold            ; up: it stays while he does
                    ld      a,LIFT_GIVES_HIM    ; and he goes up with it
                    ld      (walker_player + CHARACTER_DZ),a
                    call    mover_halt
                    ld      (ix+OBJ.DZ),LIFT_RISE + 1   ; net of gravity
                    jp      mover_move_always
.hold:              call    mover_hover
                    ret

.back:              set     1,(ix+OBJ.MOVE_STATE)
.down:              call    mover_halt
                    ld      (ix+OBJ.DZ),0       ; a unit a turn, not a fall
                    call    mover_move
                    ld      a,(collide_hit)
                    and     COLLIDE_Z
                    ret     z
                    ld      (ix+OBJ.MOVE_STATE),0   ; down: waiting again
                    ret
                    ENDIF


; ---------------------------------------------------------------------------
; A conveyor, which pushes whatever stands on it along -- Pentagram's $B866.
; object_carry already hands a thing standing on a record that record's step,
; so a conveyor simply holds a step of its own and never moves by it.
;
; What the game supplies: conveyor_steps, four pairs of (step in U, step in V),
; which the bottom two bits of the graphic choose between.
;
; In:  IX -> the record
; Out: DU and DV in the record = its step
; Corrupts: AF, DE, HL
                    IFUSED  mover_conveyor
mover_conveyor:     ld      a,(ix+OBJ.GFX)
                    and     3
                    add     a,a
                    ld      e,a
                    ld      d,0
                    ld      hl,conveyor_steps
                    add     hl,de
                    ld      a,(hl)
                    ld      (ix+OBJ.DU),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.DV),a
                    ret
                    ENDIF


; ---------------------------------------------------------------------------
; A two-record figure that paces along U, turning at whatever stops it --
; Knight Lore's guards, upd_150_151. The torso carries the step and the legs
; follow it; mover_move_pair moves and re-sorts both.
;
; It does not cancel gravity the way a pacer does: the game calls
; dec_dZ_and_update_XYZ without setting DZ first, so a guard falls if it walks
; off something, and the floor stops it where it stands.
;
; What the game supplies: PAIR_STEP, how far it goes a turn, and pair_frame,
; which wears the frames the step calls for -- both halves' graphics are the
; game's own artwork.
;
; In:  IX -> the first record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_pacer_pair
mover_pacer_pair:	xor		a
					ld		(ix+OBJ.DV),a
					ld		(ix+OBJ.DZ),a
					ld		a,PAIR_STEP
					bit		0,(ix+OBJ.MOVE_STATE)
					jr		nz,.forward
					neg
.forward:			ld		(ix+OBJ.DU),a

					call	pair_frame
					call	mover_move_pair
					ld		a,COLLIDE_U		; which is bit 0 of MOVE_STATE too
					jp		mover_turn_if_hit
					ENDIF


; The four legs of mover_circuit_pair's round, in order: the step in U and V,
; and the axis that has to give before the next leg starts.
CIRCUIT_MASK		EQU		3

					IFUSED	mover_circuit_pair
mover_circuit_tbl:	DB		-PAIR_STEP, 0, COLLIDE_U		; west
					DB		0, PAIR_STEP, COLLIDE_V		; north
					DB		PAIR_STEP, 0, COLLIDE_U		; east
					DB		0, -PAIR_STEP, COLLIDE_V		; south

; A two-record figure that walks a circuit: west until something stops it,
; then north, then east, then south, and round again -- Knight Lore's square
; guards, upd_30_31_158_159 through the four routines in guard_NSEW_tbl.
;
; Nothing measures the square out. Each leg simply runs until the clamp says
; that axis gave, and the next leg starts from wherever that was, so the shape
; of the walk is the shape of the room and whatever is standing in it. The two
; bits of MOVE_STATE are which leg it is on, and they are the game's own bits
; 0 and 1 of $0D.
;
; What the game supplies: PAIR_STEP and pair_frame, as mover_pacer_pair has
; them.
;
; In:  IX -> the first record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_circuit_pair:	ld		a,(ix+OBJ.MOVE_STATE)
					and		CIRCUIT_MASK
					ld		c,a
					ld		b,0
					ld		hl,mover_circuit_tbl
					add		hl,bc
					add		hl,bc
					add		hl,bc		; three bytes a leg

					ld		a,(hl)
					ld		(ix+OBJ.DU),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.DV),a
					inc		hl
					ld		a,(hl)
					ld		(.blocked + 1),a		; the axis this leg walks
					ld		(ix+OBJ.DZ),0

					call	pair_frame
					call	mover_move_pair

					ld		a,(collide_hit)
.blocked:			and		0		; patched just above
					ret		z		; the leg is not done yet

					ld		a,(ix+OBJ.MOVE_STATE)
					inc		a		; on to the next side
					and		CIRCUIT_MASK
					ld		(ix+OBJ.MOVE_STATE),a
					ret
					ENDIF


; ---------------------------------------------------------------------------
; A portcullis: rises a unit a turn to GATE_RISE above the floor, waits, then
; drops under its own weight and waits again -- Knight Lore's upd_8 and upd_9.
;
; The game splits it across two graphics: one gate standing still, whose turn
; only decides whether to set off, and the same gate in motion, which does the
; moving. Bit 0 of the graphic is which, so it changes its own mind for no
; state at all -- and the two frames are the same size, so the rotation buffer
; one took from the arena fits the other.
;
; Two facts belong to the room rather than the gate, and both are the game's:
; only one gate moves at a time ($5BAF), and a gate drops to a schedule for
; its first GATE_DROPS drops and on the dice after that ($5BB0). Room $87 has
; four of them and they take it in turns.
;
; Rising is a unit a turn. Falling is not: the game decrements dZ itself on
; top of the one dec_dZ_and_update_XYZ already does, so a dropping portcullis
; accelerates at two a turn and lands hard.
;
; What the game supplies: GATE_RISE and GATE_DROPS, and two sounds --
; gate_rising every turn it climbs, gate_landed on the turn it hits the floor.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_gate
mover_gate_busy:	DB		0		; a gate has the room
mover_gate_drops:	DB		0		; how many times one has fallen

mover_gate:			call	mover_halt		; it only ever moves in Z

					bit		0,(ix+OBJ.GFX)
					jr		nz,.moving

					; Standing still, at one end of its travel or the other.
					ld		a,(mover_gate_busy)
					or		a
					ret		nz

					ld		a,(room_floor_z)
					cp		(ix+OBJ.Z)
					jr		z,.go_up		; fully down
					add		a,GATE_RISE
					cp		(ix+OBJ.Z)
					jr		nc,.go_up		; not up yet

					; Fully up. The first few drops come without waiting.
					ld		a,(mover_gate_drops)
					cp		GATE_DROPS
					jr		c,.drop
					call	mover_dice
					ret		nz
.drop:				ld		hl,mover_gate_drops
					inc		(hl)
					ld		(ix+OBJ.DZ),-1
					jr		.set_off

.go_up:				call	mover_dice
					ret		nz
					ld		(ix+OBJ.DZ),1
.set_off:			set		0,(ix+OBJ.GFX)		; the moving frame
					ld		a,1
					ld		(mover_gate_busy),a
					ret

.moving:			ld		a,(ix+OBJ.DZ)
					or		a
					jp		p,.rising

					dec		(ix+OBJ.DZ)		; falling, and gathering pace
					call	mover_move_always
					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still on its way down
					call	gate_landed		; and down with a crash, upd_9
					jr		.stop

.rising:			ld		(ix+OBJ.DZ),2		; a unit a turn, after the DEC
					call	gate_rising		; move_portcullis_up
					call	mover_move_always
					ld		a,(room_floor_z)
					add		a,GATE_RISE
					cp		(ix+OBJ.Z)
					ret		nc		; not at the top yet

.stop:				xor		a
					ld		(mover_gate_busy),a
					res		0,(ix+OBJ.GFX)
					ret
					ENDIF


; ---------------------------------------------------------------------------
; A spiked ball, which hangs where the room put it until, one turn in
; SPIKE_BALL_DICE, it lets go and drops until it lands -- Knight Lore's
; upd_63. One at a time: while one is falling no other may start. The test is
; the game's own, the random seed below sixteen.
;
; What the game supplies: SPIKE_BALL_DICE; spike_ball_held, a byte the room
; sets while its balls are to stay up; and spike_ball_sound, played every turn
; one is on its way down.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_spike_ball
spike_ball_falling:	DB		0		; one is on its way down, so no other starts

mover_spike_ball:	ld		a,(spike_ball_held)
					or		a
					ret		nz
					bit		2,(ix+OBJ.MOVE_STATE)
					jr		nz,.drop
					ld		a,(spike_ball_falling)
					or		a
					ret		nz
					call	mover_rand
					cp		SPIKE_BALL_DICE
					ret		nc
					set		2,(ix+OBJ.MOVE_STATE)
					ld		a,1
					ld		(spike_ball_falling),a
					ret

					; Falling: gravity has DZ, which it has been taking one off a
					; turn since the ball let go, so it gathers speed as it goes.
.drop:				call	mover_move		; which leaves IX -> the record
					ld		a,(collide_hit)
					and		COLLIDE_Z
					jp		z,spike_ball_sound	; whistling down, spiked_ball_drop
					res		2,(ix+OBJ.MOVE_STATE)
					xor		a
					ld		(spike_ball_falling),a
					ret
					ENDIF


; ---------------------------------------------------------------------------
; A block that slides to and fro along one axis, a unit a turn -- Knight
; Lore's loc_B6BF, which upd_54 and upd_55 share by patching the two
; instructions that name the axis, as this does: (IX+d) takes its displacement
; as an immediate.
;
; The block does not remember which way it is going. Instead the turn counter
; is folded into a triangle: bit 4 says which way the ramp runs and the low
; four bits are how far along it is, so the wave climbs 0 to 15 and falls back
; over thirty-two turns. The block compares where it is against where the wave
; says it should be and steps one unit towards it.
;
; Bit 5 of the record's own address is added in first. Records are thirty-two
; bytes apart, so that bit alternates, and neighbouring blocks run in
; antiphase -- one going out as the other comes back.
;
; Position is taken as (coordinate + SLIDE_MIDDLE) & 15, so a block standing
; in the middle of its cell is in the middle of its travel and swings half of
; SLIDE_MIDDLE either way.
;
; What the game supplies: SLIDE_MIDDLE, and slide_sound, called with the axis
; in HL every turn -- Knight Lore hums along the one it slides on.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_slide_u
mover_slide_u:		ld		hl,OBJ.DU * 256 + OBJ.U
					jr		mover_slide
					ENDIF

; See mover_slide_u.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_slide_v
mover_slide_v:		ld		hl,OBJ.DV * 256 + OBJ.V
					ASSERT	$ == mover_slide
					ENDIF

; See mover_slide_u. The axis comes in HL: H the offset of its step in the
; record, L of its position.
;
; In:  IX -> the record; mover_ix names it too
;      H  = OBJ.DU or OBJ.DV
;      L  = OBJ.U or OBJ.V
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_slide
mover_slide:		call	slide_sound
					ld		a,l
					ld		(.here + 2),a		; LD A,(IX+d) is DD 7E d
					ld		a,h
					ld		(.step + 2),a		; LD (IX+d),A is DD 77 d

					call	mover_hover		; it moves along one axis and no
										; other, and does not fall

					; Where the wave says it should be.
					ld		a,ixl
					rrca
					and		$10		; half a cycle for every other record
					ld		c,a
					ld		a,(move_tick)
					add		a,c
					bit		4,a
					jr		z,.climbing
					cpl				; the falling half of the ramp
.climbing:			and		$0F
					ld		c,a

					; ...and where it is.
.here:				ld		a,(ix+OBJ.U)		; patched: U or V
					add		a,SLIDE_MIDDLE
					and		$0F
					cp		c
					ret		z		; already there, and nothing to draw

					ld		a,1
					jr		c,.step		; below the wave: out
					neg				; above it: back
.step:				ld		(ix+OBJ.DU),a		; patched: DU or DV
					jp		mover_move
					ENDIF
