; ---------------------------------------------------------------------------
; What Knight Lore gives engine/movers.s, the behaviours it shares with
; Pentagram: the constants and routine names the library asks for, and which
; of Knight Lore's own things they are.
;
; Included after engine/mover.s and before engine/movers.s. Most of these name
; a routine in mover.s, and an EQU of a label still to come takes the value
; that label had in the pass before -- which sjasmplus warns about, because
; IFUSED moves code about between the first passes. Here the labels are
; already known.
; ---------------------------------------------------------------------------

; What the moveable block plays every turn it falls or rides. mover_falls_noisy,
; in engine/movers.s, calls it: the chirp upd_62 makes, every frame.
sound_falls			EQU		sound_chirp


; ---------------------------------------------------------------------------
; A fire paces to and fro along one axis, turning round whenever something
; stops it: engine/movers.s's mover_pacer_u and _v, which are Knight Lore's
; upd_86_87 and upd_180_181. What makes it a fire is what it is given here.
;
; It animates as it goes, between its graphic and the one below it. The
; template names the taller of the two -- 181 of 180/181, 87 of 86/87 -- so
; the rotation buffer the first frame takes from the arena fits the second.
; And it hums along the axis it paces, and bounces off whatever stops it along
; V -- pacer_sound and mover_turned, in sound_fx.s.
PACER_STEP			EQU		FIRE_STEP
pacer_frame			EQU		mover_flicker
pacer_move			EQU		mover_move_always		; it changes every turn


; A ball bounces on the spot: engine/movers.s's mover_hopper_claim, which is
; upd_178_179, and bounces to BALL_RISE_TO above where the room's first ball
; started -- see there. It flickers where it stands, hums as it goes, and
; bounces with a click.
hopper_top			EQU		mover_ball_top
HOPPER_ABOVE		EQU		BALL_RISE_TO
HOPPER_RISE			EQU		BALL_RISE
hopper_frame		EQU		mover_flicker
hopper_sound		EQU		sound_z
hopper_move			EQU		mover_move_always		; it changes every turn
hopper_landed		EQU		sound_bounce
					ASSERT	MOVE_RISING == 1 << HOPPER_RISING
