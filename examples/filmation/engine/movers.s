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


; ---------------------------------------------------------------------------
; Something that drifts in a straight line until something stops it, and then
; picks a new way to go -- Knight Lore's ghosts, upd_80_to_83. It keeps
; whatever step it has until it is blocked or has come to nothing, so it
; crosses a room and then turns at random.
;
; It picks BEFORE moving, where the game picks after. Anything riding on it
; reads its step out of the record, and a step it is ABOUT to take carries the
; passenger a turn early; this way the record holds the step actually
; achieved, clamped and all, which is what object_carry copies. What the move
; would have told us is carried in MOVE_STATE instead: it got nowhere last
; turn, so draw again.
;
; The two axes are drawn separately, one from the seed and one from the turn
; counter, so they are not the same number twice.
;
; What the game supplies: drift_deltas, four speeds to pick between;
; drift_sound; drift_turn, called as it decides to pick again and before it
; does -- which is where Knight Lore's flicker goes, since mover_flicker
; clears the step on its way through mover_halt; and drift_frame, the frames
; it wears, called once the new step is in the record.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_drifter
mover_drifter:		call	drift_sound
					ld		a,(ix+OBJ.MOVE_STATE)
					or		a
					jr		nz,.turn
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					jr		nz,.go

.turn:				call	drift_turn
					call	mover_rand
					call	.pick
					ld		(ix+OBJ.DU),a
					ld		a,(move_tick)
					call	.pick
					ld		(ix+OBJ.DV),a
					call	drift_frame

.go:				call	mover_move_always		; which leaves IX -> the record
					ld		a,(collide_hit)		; whether something stopped it, kept
					and		COLLIDE_U | COLLIDE_V	; for next turn to read -- which is
					ld		(ix+OBJ.MOVE_STATE),a	; the game's own test on (IX+$0C),
					ret				; a turn later than it asks it

.pick:				and		3
					ld		c,a
					ld		b,0
					ld		hl,drift_deltas
					add		hl,bc
					ld		a,(hl)
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Something that goes where it is shoved and then stops -- Knight Lore's
; table, upd_84. It clears its step AFTER moving, where mover_falls clears
; before: the difference is that this one keeps what it was given long enough
; to spend it.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_shoved
mover_shoved:		call	mover_shoved_on
					jp		mover_halt
					ENDIF

; Something that never lets go of its step at all -- Knight Lore's chest,
; upd_85. Shove one and it slides on by itself until the clamp takes the step
; away. What the clamp left of the step is what it moved, so that is what says
; whether to make a noise -- the game asks the same way, at $C1A1.
;
; What the game supplies: shoved_sound, played on a turn it went somewhere.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_shoved_on
mover_shoved_on:	call	mover_move
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					jp		nz,shoved_sound
					ret
					ENDIF


; ---------------------------------------------------------------------------
; A ball that hunts: it bounces, and every time it lands it takes a new upward
; push and a new direction along ONE axis, chosen by which side of it the
; player is on -- Knight Lore's upd_182_183. Which axis is a coin toss.
;
; It keeps its horizontal step across the move: the step is saved, the clamp
; has its say, and the original goes straight back. Touching something does
; not cost it its direction; only landing changes that.
;
; Whether it comes for the player or runs from him is the game's to say every
; time it lands, and Knight Lore's answer changes with what he has turned
; into. The game varies the bounce height by room number as well, which is not
; here.
;
; What the game supplies: HUNTER_RISE and HUNTER_STEP; hunter_landed, called
; with B the DZ it had before gravity, so a game can tell a bounce from a ball
; held down by something standing on it; and hunter_flees, which says which
; way to go.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_hunter
mover_hunter:		ld		a,(ix+OBJ.DZ)		; before gravity has had it
					push	af
					ld		c,(ix+OBJ.DU)
					ld		b,(ix+OBJ.DV)
					push	bc
					call	mover_move_always		; which leaves IX -> the record
					pop		bc
					ld		(ix+OBJ.DU),c		; whatever the clamp made of them,
					ld		(ix+OBJ.DV),b		; it still wants to go that way
					pop		bc		; B - that DZ

					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still in the air

					ld		(ix+OBJ.DZ),HUNTER_RISE		; stopped in Z: up again
					call	hunter_landed

					call	mover_rand
					and		1
					jr		z,.along_u

					ld		a,(walker_player + OBJ.V)
					sub		(ix+OBJ.V)
					call	.step
					ld		(ix+OBJ.DV),a
					ret

.along_u:			ld		a,(walker_player + OBJ.U)
					sub		(ix+OBJ.U)
					call	.step
					ld		(ix+OBJ.DU),a
					ret

					; The step along that axis: HUNTER_STEP towards him, turned
					; round again if the game says to run. Carry from the SUB
					; above means he is the lower of the two.
					;
					; The turn is A XOR mask less mask, which is A for a mask of
					; nought and -A for one of $FF: the two's complement, without
					; a branch.
.step:				ld		a,HUNTER_STEP
					jr		nc,.towards
					neg
.towards:			ld		c,a
					call	hunter_flees		; 0 to come for him, $FF to run
					ld		b,a
					ld		a,c
					xor		b
					sub		b
					ret
					ENDIF


; ---------------------------------------------------------------------------
; Something that follows the player about, so many units a turn on each axis
; at once -- Knight Lore's repel spell, upd_164_to_167 and move_towards_plyr.
;
; The way to go is the SIGN of the difference, not its carry, as the game has
; it: level with him counts as past him, so it jitters about his position
; rather than settling on it. It does not set DZ, so it falls like anything
; else.
;
; What the game supplies: stalker_speed, which hands back the step for this
; turn in C -- Knight Lore creeps at one while he stands in an arch, which is
; what gives him the chance to leave the room ahead of it -- and
; stalker_frame, called once the step is set.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
					IFUSED	mover_stalker
mover_stalker:		call	stalker_speed
					ld		hl,walker_player + OBJ.U
					ld		a,(ix+OBJ.U)
					sub		(hl)
					ld		a,c
					jp		m,.u		; short of him: towards
					neg
.u:					ld		(ix+OBJ.DU),a

					inc		hl		; the player's V
					ld		a,(ix+OBJ.V)
					sub		(hl)
					ld		a,c
					jp		m,.v
					neg
.v:					ld		(ix+OBJ.DV),a

					call	stalker_frame
					jp		mover_move_always
					ENDIF


; ---------------------------------------------------------------------------
; A block that crumbles away the turn after something lands on it -- Knight
; Lore's upd_143. The game turns it into one graphic and steps it straight on
; to COLLAPSE_GFX, draws that for a turn, and then takes it out of the room.
; The dropping block, which sinks under the same mark instead, is mover_sinks.
;
; object_landed_on leaves the mark, MOVE_STATE bit 3, so a collapsing block's
; behaviour has to sit between BEHAVIOUR_GIVES and BEHAVIOUR_GIVES_LAST. Bit 4
; is this routine's own: crumbled, and gone next turn.
;
; What the game supplies: COLLAPSE_GFX, and collapse_sound with A the graphic.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything -- IX only on the turn object_hide takes it away
					IFUSED	mover_collapsing
mover_collapsing:	bit		4,(ix+OBJ.MOVE_STATE)
					jp		nz,object_hide		; crumbled last turn: gone
					bit		3,(ix+OBJ.MOVE_STATE)
					ret		z
					ld		(ix+OBJ.MOVE_STATE),$10
					ld		a,COLLAPSE_GFX
					ld		(ix+OBJ.GFX),a
					call	collapse_sound
					call	mover_halt
					ld		(ix+OBJ.DZ),a
					jp		mover_paint
					ENDIF


; Animation at half the turn rate. The original flips and steps its creatures'
; frames every turn -- $A715, which it bumps once round its main loop, is a
; turn counter like move_tick -- but it manages only 5 to 20 turns a second,
; and the remake 16 to 33. Every other turn keeps the flicker nearer what the
; original looks like, and each frame not changed is a sprite not re-mirrored
; and re-rotated: a mover that did not move, and did not change, is not
; repainted at all.
;
; mover_move_anim repaints if this was an animating turn, and only if the
; thing moved otherwise.
;
; In:  IX -> the record, with DU, DV and DZ set; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_move_anim
mover_move_anim:    ld      a,(room_busy)       ; taking turns, it animates
                    or      a                   ; every time it moves
                    jp      nz,mover_move_always
                    ld      a,(move_tick)
                    rra
                    jp      nc,mover_move_always ; an even turn: it changed
                    jp      mover_move
                    ENDIF


; ---------------------------------------------------------------------------
; Moved by a shove, once, and then still -- $CD81 and $CD87. The engine's
; object_shove gives a LOOSE object the shover's step; this spends it, with
; gravity, and then forgets it, which is the original clearing +9 to +11
; after the move.
;
; Whatever is stacked on it goes too: shoot the bottom log of a pile and the
; original moves the pile. The engine does carry a rider -- object_carry, in
; the rider's own clamp -- but only if the thing under it still has its step
; when the rider's turn comes, and this clears its step the moment it has
; moved; a rider later in the pool found nothing to take. So the step is
; handed up here instead, before it is forgotten, to anything loose sitting
; on top. That rider spends it on its own turn and hands it up again, so a
; stack of any height moves as one.
;
; At rest it looks to itself only every fourth turn. A pushable's turn is
; mostly its clamp -- gravity against everything under it -- and a busy room
; is busy with pushables, not monsters: room 13 has six stumps and two
; spiders, 9 and 133 eight stumps and one. The original clamps every one of
; them every turn, which is why it runs room 13 at under five turns a second.
; A shove is acted on at once, and once it is falling it moves every turn
; until it lands; only standing still is checked less often -- staggered by
; slot, so a room's pushables share the turns. A support taken away is
; noticed within four turns. MOVE_STATE bit 7 is "was falling".
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_shoved_pile
mover_shoved_pile:       ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.moves           ; shoved: now
                    bit     7,(ix+OBJ.MOVE_STATE)
                    jr      nz,.moves           ; falling: every turn
                    ld      a,ixl               ; standing: its slot's turn
                    rlca                        ; of four -- records are 32
                    rlca                        ; apart, so bits 5 and 6
                    rlca
                    ld      c,a
                    ld      a,(move_tick)
                    add     a,c
                    and     SHOVED_REST_EVERY - 1
                    ret     nz

.moves:             call    mover_move
                    ld      a,(collide_hit)     ; landed, or still going down?
                    and     COLLIDE_Z
                    res     7,(ix+OBJ.MOVE_STATE)
                    jr      nz,.landed
                    set     7,(ix+OBJ.MOVE_STATE)
.landed:            ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    call    nz,shoved_carry     ; it moved: take the pile with it
                    jp      mover_halt


; Give this object's step to everything loose standing on it that has none of
; its own: the same thing object_carry does, from underneath.
;
; In:  IX -> the record that has just moved, DU and DV what it moved by
; Out: nothing
; Corrupts: AF, BC, DE, IY
shoved_carry:       ld      a,(room_object_count)
                    ld      b,a
                    ld      iy,room_objects
                    ld      a,(ix+OBJ.Z)
                    add     a,(ix+OBJ.SIZE_Z)
                    ld      c,a                 ; C - its top
.next:              ld      a,(iy+OBJ.BEHAVIOUR)
                    cp      BEHAVIOUR_LOOSE
                    jr      c,.skip             ; not the sort that rides
                    ld      a,(iy+OBJ.Z)
                    cp      c
                    jr      nz,.skip            ; not sitting on our top
                    ld      a,(iy+OBJ.DU)
                    or      (iy+OBJ.DV)
                    jr      nz,.skip            ; going somewhere already

                    ld      a,(iy+OBJ.U)        ; over us along U?
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      e,a
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    cp      e
                    jr      c,.skip
                    jr      z,.skip
                    ld      a,(iy+OBJ.V)        ; ...and along V?
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      e,a
                    ld      a,(iy+OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    cp      e
                    jr      c,.skip
                    jr      z,.skip

                    ld      a,(ix+OBJ.DU)
                    ld      (iy+OBJ.DU),a
                    ld      a,(ix+OBJ.DV)
                    ld      (iy+OBJ.DV),a
.skip:              ld      de,ROOM_STRIDE
                    add     iy,de
                    djnz    .next
                    ret


                    ENDIF


; ---------------------------------------------------------------------------
; The spider -- $CF22. It walks diagonally, four units a turn on both axes,
; and whenever anything stops it on either axis, or it has no step at all, it
; picks a new diagonal at random. It is drawn mirrored every other turn, which
; is the whole of its animation: one sprite, flipped.
;
; It falls a unit a turn if there is nothing under it: the original zeroes its
; Z step and then applies gravity, every turn.
;
; MOVE_STATE keeps which axes stopped it last turn.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_scuttler
mover_scuttler:       call    monster_sits_out
                    ret     c
                    ld      (ix+OBJ.DZ),0

                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_U | COLLIDE_V
                    jr      nz,.new             ; stopped: somewhere else
                    ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go
.new:               call    mover_rand
                    and     SCUTTLE_STEP * 2     ; 0 or 8, less 4: -4 or +4
                    sub     SCUTTLE_STEP
                    ld      (ix+OBJ.DU),a
                    call    mover_rand
                    and     SCUTTLE_STEP * 2
                    sub     SCUTTLE_STEP
                    ld      (ix+OBJ.DV),a

.go:                ; Mirrored for two turns, then not for two -- see
                    ; mover_move_anim for why two.
                    ld      a,(move_tick)
                    rrca
                    and     1
                    ld      c,a
                    ld      a,(ix+OBJ.FLAGS)
                    ld      b,a
                    and     ~OBJ_FLIP_H & $FF
                    or      c
                    ld      (ix+OBJ.FLAGS),a
                    ASSERT  OBJ_FLIP_H == 1
                    xor     b                   ; did the mirror change?
                    ld      b,a
                    call    monster_double
                    ld      a,b
                    or      a
                    jr      z,.same
                    call    mover_move_always
                    jr      .moved
.same:              call    mover_move          ; only if it went anywhere
.moved:             call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret
                    ENDIF


; ---------------------------------------------------------------------------
; A creature that walks one axis at a time -- $D1F5, graphics 16 and 17. It
; flips its mirror every turn, which is its animation. When it has no step
; left -- something stopped it -- it picks four units either way at random,
; along U if the last thing that stopped it was across V and along V
; otherwise, and wears 16 for U and 17 for V.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_roamer
mover_roamer:     call    monster_sits_out
                    ret     c
                    ld      a,(move_tick)
                    rra
                    jr      c,.kept             ; flips on even turns only
                    ld      a,(ix+OBJ.FLAGS)
                    xor     OBJ_FLIP_H
                    ld      (ix+OBJ.FLAGS),a
.kept:

                    ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go

                    call    mover_rand
                    and     ROAM_STEP * 2
                    sub     ROAM_STEP
                    ld      c,a
                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_V
                    jr      nz,.along_u
                    ld      (ix+OBJ.DV),c
                    set     0,(ix+OBJ.GFX)      ; 17: along V
                    jr      .go
.along_u:           ld      (ix+OBJ.DU),c
                    res     0,(ix+OBJ.GFX)      ; 16: along U

.go:                call    monster_double
                    call    mover_move_anim
                    call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


                    ENDIF


; ---------------------------------------------------------------------------
; What falls out of the sky and flies at him -- $CC4B, for 48-51 and 160-167.
; flyers.s drops it.
;
; It steers on all three axes at once: each turn it adds three towards him to
; a velocity it keeps in sixteenths -- towards his legs' U and V and his body's
; Z -- held between -72 and +56, and moves by that sixteenth, rounded: four a
; turn at most. Anything that stops it along U or V turns that velocity round,
; so it bounces off walls rather than sticking to them. It animates through
; the four graphics of its block, a frame a turn.
;
; It is not deadly: $CC4B never calls $C291, and its record carries neither
; bit. Harmless it may be, but it gets in the way.
;
; The original moves it first, with last turn's velocity, and then steers for
; the next; so does this. The sixteenths live in the two bytes past the end of
; the record and in MOVE_STATE.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_homer
mover_homer:        call    monster_sits_out
                    ret     c
                    call    monster_double
                    call    mover_move_always
                    call    monster_halve

                    ; Bounce: what stopped it along an axis turns it round there.
                    ld      a,(collide_hit)
                    and     COLLIDE_U
                    jr      z,.u_free
                    ld      a,(ix+HOMER_ACC_U)
                    neg
                    ld      (ix+HOMER_ACC_U),a
.u_free:            ld      a,(collide_hit)
                    and     COLLIDE_V
                    jr      z,.v_free
                    ld      a,(ix+HOMER_ACC_V)
                    neg
                    ld      (ix+HOMER_ACC_V),a
.v_free:
                    ; Steer: towards him on each axis.
                    ld      a,(walker_player + OBJ.U)
                    sub     (ix+OBJ.U)
                    ld      a,(ix+HOMER_ACC_U)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_U),a
                    ld      a,(walker_player + OBJ.V)
                    sub     (ix+OBJ.V)
                    ld      a,(ix+HOMER_ACC_V)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_V),a
                    ld      a,(walker_player + CHARACTER_BODY + OBJ.Z)
                    sub     (ix+OBJ.Z)
                    ld      a,(ix+HOMER_ACC_Z)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_Z),a

                    ; ...and the step for next turn, in whole units.
                    ld      a,(ix+HOMER_ACC_U)
                    call    homer_whole
                    ld      (ix+OBJ.DU),a
                    ld      a,(ix+HOMER_ACC_V)
                    call    homer_whole
                    ld      (ix+OBJ.DV),a
                    ld      a,(ix+HOMER_ACC_Z)
                    call    homer_whole
                    ld      (ix+OBJ.DZ),a

                    ; The next frame of its four, every other turn.
                    ld      a,(move_tick)
                    rrca
                    and     3
                    ld      c,a
                    ld      a,(ix+OBJ.GFX)
                    and     $FC
                    or      c
                    ld      (ix+OBJ.GFX),a
                    ret

; Three more towards him, held to the range: carry from the SUB before this
; means he is below us on that axis. $CD04 and $CD0D.
;
; In:  A = the velocity, in sixteenths
;      carry set if he is below us
; Out: A = the velocity, steered
; Corrupts: F
homer_pull:         jr      c,.down
                    add     a,HOMER_PULL
                    ret     m
                    cp      HOMER_MOST
                    ret     c
                    ld      a,HOMER_MOST
                    ret
.down:              sub     HOMER_PULL
                    ret     p
                    cp      HOMER_LEAST
                    ret     nc
                    ld      a,HOMER_LEAST
                    ret

; Sixteenths to whole units, rounded, sign kept.
;
; In:  A = the velocity, in sixteenths
; Out: A = the step, in whole units
; Corrupts: F
homer_whole:        add     a,8
                    sra     a
                    sra     a
                    sra     a
                    sra     a
                    ret


                    ENDIF


; ---------------------------------------------------------------------------
; What falls out of the sky and then roams -- $D1FD for 80 and 81, $D251 for
; 168 to 171. Deadly both. It falls under gravity like anything else; along
; the floor it goes four units a turn along one axis, and when something
; stops it -- or before it has ever moved -- picks four either way at random,
; along U if the thing that stopped it was across V, along V otherwise.
;
; Its graphic says which way. For 80 and 81, bit 0 is the axis and the mirror
; tells the two directions on it apart; 168-171 do the same with bit 1, and
; flip bit 0 every turn besides, which is their animation. Going the negative
; way flips the axis bit as well -- the original's own sums.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
                    IFUSED  mover_faller4
mover_faller4:      call    monster_sits_out
                    ret     c
                    ld      a,(move_tick)
                    rra
                    jr      c,.kept             ; the frame, on even turns
                    ld      a,(ix+OBJ.GFX)
                    xor     1
                    ld      (ix+OBJ.GFX),a
.kept:
                    ld      c,2                 ; the axis is bit 1
                    jr      mover_faller_c

; See mover_faller4.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_faller:       call    monster_sits_out
                    ret     c
                    ld      c,1                 ; ...and bit 0 here

; See mover_faller4: the turn of either, with the graphic's axis bit in C.
;
; In:  IX -> the record; mover_ix names it too
;      C  = the axis bit: 1 for 80 and 81, 2 for 168 to 171
; Out: nothing
; Corrupts: everything but IX
mover_faller_c:     ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go

                    call    mover_rand
                    and     FALLER_STEP * 2
                    sub     FALLER_STEP
                    ld      b,a
                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_V
                    jr      nz,.along_u

                    ld      (ix+OBJ.DV),b       ; along V: the axis bit set,
                    ld      a,(ix+OBJ.GFX)      ; unmirrored
                    or      c
                    ld      (ix+OBJ.GFX),a
                    res     0,(ix+OBJ.FLAGS)
                    jr      .facing
.along_u:           ld      (ix+OBJ.DU),b       ; along U: clear, mirrored
                    ld      a,c
                    cpl
                    and     (ix+OBJ.GFX)
                    ld      (ix+OBJ.GFX),a
                    set     0,(ix+OBJ.FLAGS)
                    ASSERT  OBJ_FLIP_H == 1
.facing:            bit     7,b
                    jr      z,.go
                    ld      a,(ix+OBJ.GFX)      ; the negative way
                    xor     c
                    ld      (ix+OBJ.GFX),a

.go:                call    monster_double
                    call    mover_move_anim
                    call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


BOLT_DU             EQU     30              ; the velocity it was fired with,
BOLT_DV             EQU     31              ; past OBJ inside the slot
BOLT_LOW            EQU     132
BOLT_FIRST          EQU     149
BOLT_LAST           EQU     151
                    ENDIF


; ---------------------------------------------------------------------------
; A puff -- $C107 starts one, $C111 runs it. Graphics 64 to 70, a frame a
; turn, and then nothing: the slot is emptied. While it plays it neither falls
; nor blocks nor harms.
;
; Only the passable bit is set: the rest of FLAGS is the engine's own
; bookkeeping, and OBJ_SHIFTED in particular says the record's sprite pointer
; is into its rotation buffer. Writing the whole byte cleared that while the
; pointer still pointed there, and the next draw took what lay before the
; copy for a sprite header and mirrored it forever.
;
; What the game supplies: POOF_FIRST and POOF_LAST, the frames it plays;
; POOF_BEHAVIOUR, which its record takes on while it does; and poof_sound.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: nothing
                    IFUSED  mover_poof_start
mover_poof_start:   ld      (ix+OBJ.GFX),POOF_FIRST
                    ld      (ix+OBJ.BEHAVIOUR),POOF_BEHAVIOUR
                    set     2,(ix+OBJ.FLAGS)
                    ASSERT  OBJ_PASSABLE == 1 << 2
                    ret

; A puff's turn: the next frame, or after the last, nothing.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything
mover_poof:         call    poof_sound
                    ld      a,(ix+OBJ.GFX)
                    cp      POOF_LAST
                    jp      nc,object_hide
                    inc     a
                    ld      (ix+OBJ.GFX),a
                    call    mover_hover
                    jp      mover_move_always


                    ENDIF


; ---------------------------------------------------------------------------
; A block that cracks under him and goes -- $D2AD. While he is on it, it
; becomes the next graphic of its four, 136 to 139, and on the step after the
; last it is gone. Only he cracks it: $B890 marks what his legs land on, and
; nothing else's.
;
; The original takes a step every turn, but at its own 5 to 20 turns a second
; that is a quarter to most of a second; at the remake's pace it was an eighth,
; too quick to see. A step every CRUMBLE_EVERY turns puts it back to about half.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything
                    IFUSED  mover_crumbles
mover_crumbles:     call    player_on_top
                    ret     nz
                    ld      a,(move_tick)
                    and     CRUMBLE_EVERY - 1
                    ret     nz
                    ld      a,(ix+OBJ.GFX)
                    cp      CRUMBLE_LAST
                    jp      z,object_hide
                    inc     a
                    ld      (ix+OBJ.GFX),a
                    call    mover_hover
                    jp      mover_move_always
                    ENDIF
