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
; V -- fire_sound and fire_turned, in sound_fx.s. Pentagram's platforms and
; pacing dragon's heads use the same movers, so pacer_sound, pacer_frame,
; pacer_move and mover_turned are routines in movers.s that tell the two apart.
PACER_STEP			EQU		FIRE_STEP


; A guard is two records walking as one figure: engine/movers.s's
; mover_pacer_pair along U, and mover_circuit_pair round a square. The frames
; both halves wear are Knight Lore's own artwork, in mover_guard_face.
PAIR_STEP			EQU		GUARD_STEP
pair_frame			EQU		mover_guard_face


; A portcullis: engine/movers.s's mover_gate, upd_8 and upd_9. It hums as it
; climbs -- move_portcullis_up -- and lands with a crash.
GATE_RISE			EQU		31
GATE_DROPS			EQU		4		; before one waits on the dice
gate_rising			EQU		sound_uvz
gate_landed			EQU		sound_gate


; A spiked ball: engine/movers.s's mover_spike_ball, upd_63. One turn in
; sixteen it lets go, and it whistles all the way down.
SPIKE_BALL_DICE		EQU		16
spike_ball_sound	EQU		sound_z


; A sliding block: engine/movers.s's mover_slide_u and _v, loc_B6BF. Its
; travel is eight either way of the middle of its cell, and it hums along the
; axis it slides on -- slide_sound, in sound_fx.s.
SLIDE_MIDDLE		EQU		8


; A ghost drifts until something stops it: engine/movers.s's mover_drifter,
; upd_80_to_83. Its speeds and the frames it wears are Knight Lore's own.
drift_deltas		EQU		ghost_deltas
drift_sound			EQU		sound_uvz
drift_turn			EQU		mover_flicker
drift_frame			EQU		ghost_face


; A table is shoved and stops, a chest is shoved and slides on:
; engine/movers.s's mover_shoved and mover_shoved_on, upd_84 and upd_85. Both
; hum while they are actually going somewhere -- audio_B467.
shoved_sound		EQU		sound_uvz


; The hunting ball: engine/movers.s's mover_hunter, upd_182_183. It springs
; four up and takes two along one axis, and hunter_flees and hunter_landed in
; movers.s are the rest.
HUNTER_RISE			EQU		4
HUNTER_STEP			EQU		2


; The repel spell: engine/movers.s's mover_stalker, upd_164_to_167. Its speed
; and its frames are stalker_speed and stalker_frame, in movers.s.


; The collapsing block: engine/movers.s's mover_collapsing, upd_143. It goes
; straight to the last of its graphics, with the sparkles' noise.
COLLAPSE_GFX		EQU		185
collapse_sound		EQU		sound_sparkle


; A ball bounces on the spot: engine/movers.s's mover_hopper_claim, which is
; upd_178_179, and bounces to BALL_RISE_TO above where the room's first ball
; started -- see there. It flickers where it stands, hums as it goes, and
; bounces with a click.
; Pentagram's bobbing dragon's head uses mover_hopper too, so hopper_frame,
; hopper_sound and hopper_landed are routines in movers.s that tell the two
; apart, and mover_dragon_hops there gives it a top of its own.
hopper_top			EQU		mover_ball_top
HOPPER_ABOVE		EQU		BALL_RISE_TO
HOPPER_RISE			EQU		BALL_RISE
hopper_move			EQU		mover_move_always		; it changes every turn
					ASSERT	MOVE_RISING == 1 << HOPPER_RISING


; ---------------------------------------------------------------------------
; What Pentagram's things are given, as its own shared_movers.s gives them.

; The spider and the creature -- mover_scuttler, $CF22, and mover_roamer, $D1F5.
SCUTTLE_STEP		EQU		4
ROAM_STEP			EQU		4

; The lift -- mover_lift, $CDBB. It stops at Z 176, climbs two a turn, and hands
; what rides it four: three of its own and the one its gravity takes back.
LIFT_TOP			EQU		176
LIFT_RISE			EQU		2
LIFT_GIVES_HIM		EQU		4

; A stump, cube, table or stone at rest looks to itself every fourth turn --
; mover_shoved_pile, $CD81.
SHOVED_REST_EVERY	EQU		4		; a power of two

; The block that cracks -- mover_crumbles, $D2AD: a step every fourth turn,
; through its three cracks to the last.
CRUMBLE_LAST		EQU		GFX_PENTAGRAM_BLOCK_4
CRUMBLE_EVERY		EQU		4		; a power of two
