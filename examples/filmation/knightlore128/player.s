

; --- the player -------------------------------------------------------------
;
; A character like any other -- see character.s. The knight's legs are the
; block at 16 and his body the one at 32; he starts facing away from the
; viewer and up the screen.
PLAYER_LEGS_GFX     EQU     GFX_SABREMAN_LEGS_1_G16
PLAYER_BODY_GFX     EQU     GFX_SABREMAN_BODY_1
PLAYER_U            EQU     128         ; the middle of the room, where the game
PLAYER_V            EQU     128         ; starts him (plyr_spr_init_data)
PLAYER_FACING       EQU     0           ; -U, up and left

player:             walking_character PLAYER_LEGS_GFX, PLAYER_BODY_GFX, PLAYER_FACING
walker_player       EQU     player              ; the character movers collide with

; How many times he can die and carry on. Knight Lore sets five and the start
; of the game takes one, through the same lose_life every death goes through,
; so the panel reads four; the game is over when a death would take the count
; below nothing. The potion that is not wanted gives one back.
PLAYER_LIVES        EQU     4
player_lives:       DB      PLAYER_LIVES

; What he is doing: walking about, dying, or coming back. The two sparkling
; states are his graphics running through Knight Lore's own frames -- 112 to
; 119 on the way out, a frame a turn, and 120 to 127 on the way back, a frame
; every other turn -- during which nothing he presses counts.
PLAYER_ALIVE        EQU     0
PLAYER_DYING        EQU     1
PLAYER_APPEARING    EQU     2
PLAYER_CHANGING     EQU     3                   ; between man and wolf -- see day_step
PLAYER_DEATH_GFX    EQU     GFX_SPELL_1_G112
PLAYER_APPEAR_GFX   EQU     GFX_SPELL_6_G120
player_state:       DB      PLAYER_APPEARING

; Set when he touches something deadly -- see object_touched -- and read at the
; top of his next turn, as the game reads its bit 6 in upd_player_bottom.
player_touched:     DB      0
deadly_touched      EQU     player_touched      ; what the engine sets

; --- day and night -----------------------------------------------------------
;
; Knight Lore's clock is the sun, or the moon, crossing the window in the panel:
; a pixel every eighth turn from x = $B0, and at $E1 the one gives way to the
; other and starts back at $B0 -- print_sun_moon and toggle_day_night, at $C397
; and $C3FF. Forty-nine pixels at eight turns each is 392 turns to a day and as
; many again to a night. Every change of light asks the knight to change too, and
; every dawn is a day gone; the fortieth is the end of the game.
;
; The clock counts turns, as the game's does, so a day is as many steps long as
; it was -- which at our pace is about eleven seconds, where Knight Lore's
; slower turns made it nearer thirty. SUN_TURNS is the knob.
;
; The window it crosses is sun_show's. The day number is printed in the top
; corner beside the lives until the panel has a place for it.
SUN_TURNS           EQU     8                   ; a power of two
SUN_RISE            EQU     $B0
SUN_SET             EQU     $E1
DAYS_ALLOWED        EQU     $40                 ; in BCD, as the game counts
PLAYER_WOLF         EQU     $20                 ; what the wolf adds to the knight's
                                                ; graphics: legs 48, body 64
PLAYER_CHANGE_GFX   EQU     GFX_TRANSFORM_1                  ; 92 to 95, the twinkle between
PLAYER_CHANGE_TURNS EQU     8                   ; ...shown this many times,
PLAYER_HIDDEN_GFX   EQU     GFX_GFX_01                   ; with nothing on top of it

sun_x:              DB      SUN_RISE
night:              DB      0                   ; PLAYER_WOLF by night
days:               DB      0                   ; BCD

; Non-zero when the light has changed and the knight has not changed with it,
; and while he is changing, the twinkles still to come. transform_flag_graphic,
; less the graphic: the game keeps his legs' graphic there to XOR the wolf into
; at the end, and ours changes the bases the frames are worked out from instead.
player_change:      DB      0


; The side he came into this room by, or $FF, and where he stood once he was
; in, so that dying puts him back in the doorway he entered by. Knight Lore does
; the same with a copy of his whole record taken on the way in
; (plyr_spr_1_scratchpad). Both floor axes are wanted: player_entry only sets
; the one he crossed, and the other is wherever he died.
entered_by:         DB      $FF
entered_at:         DW      0                   ; V, then U


; Put the player in the room that has just been built.
;
; In:  nothing
; Out: nothing
; Corrupts: everything
player_add:         ld      ix,player
                    ld      bc,PLAYER_U << 8 | PLAYER_V
                    ld      a,CHARACTER_Z
                    ld      hl,enter_dir
                    bit     7,(hl)              ; $FF: he did not walk in
                    jr      nz,.place
                    call    player_entry
.place:             ld      (entered_at),bc
                    call    character_add

                    ; Starting the room over, or the game: he comes in as a
                    ; sparkle. Drawn now rather than at the end of the turn, so
                    ; that the knight character_add has just drawn is not left
                    ; standing there for a turn first.
                    ld      a,(player_state)
                    cp      PLAYER_APPEARING
                    ret     nz
                    ld      ix,player
                    ld      a,PLAYER_APPEAR_GFX
                    call    player_sparkle
                    jp      redraw_flush


; Where the player stands when he walks into a room: two units inside the far
; wall, plus his own half, so his leading edge is already through the arch and
; he is standing in the opening. The axis he did not cross keeps its value,
; which is the middle of the room or near enough -- he had to be in the
; doorway to get out of the last one.
;
; His height comes from the arch itself, not from the floor. That is what
; carries him along the raised walkway of a tall room instead of dropping him
; into it, and it is what Knight Lore does too: adjust_plyr_Z_for_arch hunts
; down the arch he is entering by and takes its Z.
;
; In:  IX -> the player's legs
;      enter_dir = the side he is coming in by
; Out: B  = U
;      C  = V
;      A  = the Z to stand at
;      enter_dir = $FF: it is spent
; Corrupts: F, E, HL
player_entry:       ld      a,(enter_dir)
                    ld      e,a
                    ld      c,a
                    ld      b,0
                    ld      hl,room_door_z
                    add     hl,bc
                    ld      a,(hl)
                    or      a
                    jr      nz,.height
                    ld      a,CHARACTER_Z       ; no arch that side: the floor
.height:            push    af

                    ld      b,(ix+OBJ.U)
                    ld      c,(ix+OBJ.V)
                    ld      hl,room_half_v      ; north and south cross V
                    bit     0,e
                    jr      z,.axis
                    ld      hl,room_half_u      ; east and west cross U
.axis:              ld      a,(hl)
                    sub     2
                    bit     1,e                 ; south and west are the near
                    jr      nz,.near            ; walls, north and east the far
                    add     a,128 + CHARACTER_HALF_U
                    jr      .store
.near:              neg
                    add     a,128 - CHARACTER_HALF_U
.store:             bit     0,e
                    jr      nz,.u
                    ld      c,a
                    jr      .done
.u:                 ld      b,a
.done:              ld      a,$FF
                    ld      (enter_dir),a
                    pop     af
                    ret


; How long he waits between quarter turns. The game gives itself two frames
; ($C8F2). Two is wrong here: it runs at six to twelve frames a second and
; this engine runs at eighteen to thirty-five, so the same number spins him at
; eleven quarter turns a second against the game's three. Eight put ours back
; on about three, which played too slow to steer by; four is about six a second.
PLAYER_TURN_WAIT    EQU     4           ; turns before he will turn again

player_turn_wait:   DB      0

; Read what the player is asking for and walk him.
;
; The four isometric directions are the two floor axes both ways, and
; character_steps is in the order a quarter turn clockwise on the screen goes:
; 0 is -U (up and left, the castle's west), 1 is +V (north), 2 is +U (east)
; and 3 is -V (south). So a turn is the facing plus or minus one, and a
; direction on a joystick is one of the four outright.
;
; In:  nothing
; Out: nothing -- and when the last life is lost it never returns: game_over
;        starts a new game
; Corrupts: everything
player_step:        ld      ix,player
                    ld      a,(player_state)
                    or      a
                    jp      nz,player_phase
                    ld      a,(player_touched)
                    or      a
                    jp      nz,player_die
                    call    player_glance

                    ; Nobody else is walking about. object_collide tests this
                    ; on top of the room's pool, for the characters that are
                    ; not in it; there is one of those now, and it is him.
                    ld      hl,0
                    ld      (collide_other),hl

                    ; Whether he is standing in a doorway, worked out before
                    ; he moves and read twice after: character_collide lifts
                    ; the room's edge while it is set, and player_exit asks
                    ; whether the step took him right out.
                    call    character_door_find

                    ; The light has changed. He changes with it as soon as he
                    ; is standing on something -- chk_and_init_transform will not
                    ; start it in the air -- and is not waiting on the pot.
                    ld      a,(special_busy)
                    or      a
                    jr      nz,.busy
                    ld      a,(player_change)
                    or      a
                    jr      z,.keys
                    ld      a,(ix+CHARACTER_STATE)
                    or      (ix+CHARACTER_DZ)
                    jp      z,player_changing
                    jr      .keys

                    ; While something he dropped is on its way into the pot he
                    ; hangs where he is and nothing he presses counts. The game
                    ; gives him a dZ of two, which its gravity takes back to
                    ; nothing -- and ours takes two a turn off a knight who is
                    ; not holding jump, so the same number does the same.
.busy:              ld      (ix+CHARACTER_DZ),2
                    xor     a
                    ld      (character_jump_held),a
                    jp      character_stand

                    ; Picking up and putting down come first, as the game
                    ; has them. Everything below reads what input_read left,
                    ; so it is read once, here, whatever is steering.
.keys:              call    input_read
                    call    special_keys
                    ld      ix,player

                    ; The jump key first, because gravity asks about it in the
                    ; same turn: holding it is what makes the difference
                    ; between a hop and a full jump.
                    ld      a,(input_now)
                    and     INPUT_JUMP
                    ld      a,0
                    jr      z,.no_jump
                    inc     a
                    call    character_jump
.no_jump:           ld      (character_jump_held),a

                    call    player_turn
                    ld      a,(ix+CHARACTER_FACING)
                    jr      c,.walk

                    ; Not walking -- nothing held, or the move was the turn
                    ; itself. He still has to fall, and he is still drawn, so
                    ; that a turn costs about the same either way.
                    jp      character_stand

.walk:              push    af
                    bit     0,(ix+OBJ.GFX)          ; a footstep every other frame
                    ld      a,(move_tick)           ; of the walk, audio_B4BB
                    ld      b,$60
                    call    z,sound_step
                    pop     af
                    call    character_walk
                    ld      ix,player               ; the repaint took IX

                    ;; NB: fall through into player_exit -- player_turn is
                    ;; PAST it, deliberately: anything put here instead is
                    ;; what a walking turn runs into, and the room never
                    ;; changes.


; Has the step taken him right out through the doorway he was in? The test is
; Knight Lore's, at screen_west and its three neighbours ($CA9A): out when the
; whole of him has passed the wall, not when he touches it.
;
; The castle is sixteen rooms by sixteen, and the number is a row and a column
; in it: north is a row on, east a column, and east and west wrap inside the
; row rather than carrying into it. Every one of the 260 doorways in the data
; has a matching one in the room that arithmetic lands on, which is as good a
; proof of it as measuring the game would be.
;
; In:  IX -> the player's legs
; Out: room_number and enter_dir = where he goes, if he has left
; Corrupts: AF, BC, DE, HL
player_exit:        ld      a,(ix+CHARACTER_DOOR)
                    inc     a
                    ret     z                       ; not in a doorway
                    dec     a
                    ld      c,a

                    ld      a,(ix+OBJ.V)            ; north and south cross V
                    ld      hl,room_half_v
                    bit     0,c
                    jr      z,.axis
                    ld      a,(ix+OBJ.U)            ; east and west cross U
                    ld      hl,room_half_u
.axis:              ld      b,(hl)
                    bit     1,c
                    jr      nz,.near

                    ; North and east: his trailing edge has to be past the
                    ; far wall.
                    sub     CHARACTER_HALF_U
                    ld      e,a
                    ld      a,b
                    add     a,127                   ; one below the bound, so
                    cp      e                       ; carry means he is past it
                    ret     nc
                    jr      .out

                    ; South and west: his leading edge below the near wall.
.near:              add     a,CHARACTER_HALF_U
                    ld      e,a
                    ld      a,128
                    sub     b                       ; the near bound
                    ld      d,a
                    ld      a,e
                    cp      d
                    ret     nc                      ; not below it yet

.out:               ld      a,(room_number)
                    bit     0,c
                    jr      nz,.column
                    bit     1,c
                    jr      nz,.south
                    add     a,$10                   ; north, a row on
                    jr      .go
.south:             sub     $10
                    jr      .go
.column:            ld      e,a
                    inc     a                       ; east
                    bit     1,c
                    jr      z,.wrap
                    dec     a
                    dec     a                       ; west
.wrap:              and     $0F
                    ld      d,a
                    ld      a,e
                    and     $F0
                    or      d
.go:                ld      (room_number),a

                    ; He comes in by the opposite wall of the new room.
                    ld      a,c
                    xor     2
                    ld      (enter_dir),a
                    ret


; Which way he is being asked to face, and whether that leaves him a step.
;
; Turning is a move of its own: the game turns him on the spot and walks him
; only once he faces the way he is going -- handle_left_right at $C89F and
; the four chk_facing routines under it.
;
; Left and right turn him and forward walks, which is all the keyboard can
; do. A joystick with directional control on names the direction outright
; instead, and he turns towards it a quarter at a time until he faces it.
;
; A jump is a leap: once he is off the ground he goes on the way he faces,
; whatever is held, and cannot turn until he is down -- move_player at $C9AB
; walks him on whenever the jumping flag is set, and neither turning routine
; will turn him while it is. Without it a jump let go of forward stopped dead
; in the air, and a ball took a run-up and a held key to clear.
;
; In:  IX -> the player
; Out: carry set if he should walk, clear if he should stand
; Corrupts: A, C, HL
player_turn:        bit     0,(ix+CHARACTER_STATE)  ; CHARACTER_JUMPING
                    scf
                    ret     nz
                    ld      a,(menu_mode)
                    and     $06                 ; directional control needs a
                    jr      z,.rotating         ; stick: a keyboard has no
                    ld      a,(menu_mode)       ; up and down of its own
                    and     $08
                    jr      z,.rotating

                    ; The stick says which way, so the only question is
                    ; whether he is facing it yet.
                    ld      a,(input_now)
                    ld      c,$FF               ; nothing held
                    bit     0,a
                    jr      z,.not_left
                    ld      c,0                 ; -U, west
.not_left:          bit     2,a
                    jr      z,.not_up
                    ld      c,1                 ; +V, north
.not_up:            bit     1,a
                    jr      z,.not_right
                    ld      c,2                 ; +U, east
.not_right:         bit     4,a
                    jr      z,.not_down
                    ld      c,3                 ; -V, south
.not_down:          ld      a,c
                    inc     a
                    ret     z                   ; nothing held: he stands

                    ld      a,c
                    sub     (ix+CHARACTER_FACING)
                    and     3
                    scf
                    ret     z                   ; facing it already: walk

                    ; A quarter turn the short way round, which is the move.
                    cp      3
                    ld      a,1
                    jr      nz,.turn
                    ld      a,-1
.turn:              add     a,(ix+CHARACTER_FACING)
                    and     3
                    ld      (ix+CHARACTER_FACING),a
                    or      a                   ; cf clear: no step as well
                    ret

                    ; Left and right a quarter at a time. Without a wait on it
                    ; he would spin: the game gives itself two frames
                    ; ($C8F2), and counts them down whether or not it turns.
.rotating:          ld      a,(input_now)
                    and     INPUT_LEFT | INPUT_RIGHT
                    jr      z,.forward
                    ld      c,a
                    ld      hl,player_turn_wait
                    ld      a,(hl)
                    or      a
                    jr      z,.may_turn
                    dec     (hl)
                    jr      .forward            ; too soon, but he may still walk
.may_turn:          ld      (hl),PLAYER_TURN_WAIT
                    ld      a,1                 ; right goes clockwise
                    bit     0,c
                    jr      z,.by
                    ld      a,-1
.by:                add     a,(ix+CHARACTER_FACING)
                    and     3
                    ld      (ix+CHARACTER_FACING),a

.forward:           ld      a,(input_now)
                    and     INPUT_FORWARD
                    ret     z                   ; cf clear: he stands, turned
                    scf
                    ret


; He has touched something that kills. upd_player_bottom at $C82B turns both
; halves to the first sparkle, and init_death_sparkles makes him something
; nothing collides with, so that whatever killed him walks on through.
;
; In:  IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_die:         ld      a,PLAYER_DYING
                    ld      (player_state),a
                    set     2,(ix+OBJ.FLAGS)    ; OBJ_PASSABLE
                    ld      a,PLAYER_DEATH_GFX
                    jr      player_phase.death


; A turn of dying or of coming back.
;
; In:  A  = player_state
;      IX -> the player's legs
; Out: nothing -- and when the last life is lost it never returns: game_over
;        starts a new game
; Corrupts: everything
player_phase:       cp      PLAYER_CHANGING
                    jr      z,player_change_turn
                    cp      PLAYER_DYING
                    jr      nz,.appearing
                    ld      a,(ix+OBJ.GFX)
                    cp      PLAYER_DEATH_GFX + 7
                    jr      z,.gone
                    inc     a                   ; upd_112_to_118_184: a frame a turn
                    ; player_die starts here, with the first sparkle.
                    ;
                    ; In:  A  = the graphic
                    ;      IX -> the player's legs
                    ; Out: nothing
                    ; Corrupts: everything
.death:             push    af                  ; and a noise each, audio_B403
                    call    sound_sparkle
                    pop     af
                    jr      player_sparkle

                    ; The last sparkle has had its turn. lose_life: a life, and
                    ; the room built again around him in the doorway he came in
                    ; by -- or, with none left, a new game.
.gone:              ld      hl,player_lives
                    dec     (hl)
                    jp      m,game_over
                    ld      a,PLAYER_APPEARING
                    ld      (player_state),a
                    ld      a,(entered_by)      ; the arch, for his height
                    ld      (enter_dir),a
                    ld      bc,(entered_at)
                    ld      (ix+OBJ.U),b
                    ld      (ix+OBJ.V),c
                    xor     a                   ; and in the shape the light says,
                    ld      (player_change),a   ; with no change still owing
                    ld      a,(night)
                    add     a,PLAYER_LEGS_GFX
                    call    player_form
                    ld      a,(room_number)
                    cpl                         ; anything but the room it is
                    ld      (room_shown),a
                    ret

.appearing:         ld      a,(ix+OBJ.GFX)
                    cp      PLAYER_APPEAR_GFX + 7
                    jr      z,.back
                    ld      a,(move_tick)       ; upd_120_to_126: every other turn
                    rra
                    ret     c
                    ld      a,(ix+OBJ.GFX)
                    inc     a
                    push    af                  ; audio_B419
                    call    sound_appear
                    pop     af
                    jr      player_sparkle

                    ; upd_127: himself again, and whatever touched him while he
                    ; was arriving forgotten. player_change_turn ends here too.
                    ;
                    ; In:  IX -> the player's legs
                    ; Out: nothing
                    ; Corrupts: everything
.back:              xor     a
                    ld      (player_state),a
                    ld      (player_touched),a
                    ld      (ix+OBJ.DU),a       ; nor anything that shoved him
                    ld      (ix+OBJ.DV),a
                    call    character_frame
                    jr      player_repaint

; Both halves to one graphic, repainted where they stand.
;
; In:  A  = the graphic
;      IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_sparkle:     ld      (ix+OBJ.GFX),a
                    ld      (ix+CHARACTER_BODY+OBJ.GFX),a

; See player_sparkle: the graphics he has, repainted.
;
; In:  IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_repaint:     ld      de,0
                    ld      (ix+OBJ.DZ),0
                    jp      character_move


; A turn of changing, upd_92_to_95: something deadly still kills him, and every
; fourth turn he twinkles on, until the last twinkle turns him into the other one.
;
; In:  IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_change_turn: ld      a,(player_touched)
                    or      a
                    jr      z,.alive
                    call    player_legs_short   ; he dies in two halves again
                    jp      player_die
.alive:             ld      a,(move_tick)
                    and     3
                    ret     nz
                    ld      a,(ix+OBJ.GFX)      ; audio_B472
                    call    sound_change
                    ld      hl,player_change
                    dec     (hl)
                    jr      nz,player_twinkle
                    call    player_legs_short
                    ld      a,(ix+CHARACTER_LEGS)
                    xor     PLAYER_WOLF
                    call    player_form
                    ld      a,(ix+OBJ.BUF_H)    ; his own rotation buffer back, if
                    or      a                   ; he was ever given one
                    jp      z,player_phase.back
                    res     3,(ix+OBJ.FLAGS)    ; OBJ_SHARED_SHIFT
                    jp      player_phase.back


; He starts to change: nothing on top, and the legs twinkling. The twinkles are
; up to 38 rows tall, taller than the buffer his legs rotate into, so they
; rotate at draw time for the few turns they are up.
;
; In:  IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_changing:    ld      a,PLAYER_CHANGING
                    ld      (player_state),a
                    ld      a,PLAYER_CHANGE_TURNS
                    ld      (player_change),a
                    set     3,(ix+OBJ.FLAGS)    ; OBJ_SHARED_SHIFT
                    ld      (ix+CHARACTER_BODY+OBJ.GFX),PLAYER_HIDDEN_GFX

                    ; With nothing on top, the twinkle is the whole of him, and
                    ; it reaches up through where his body was. So his legs are
                    ; sorted as the whole figure while it is up -- Knight Lore's
                    ; legs are that all the time, H=23 -- or the block above
                    ; the one he stands against is drawn over it.
                    ld      a,COLLIDE_HEIGHT
                    call    player_legs_height

                    ;; NB: fall through into player_twinkle


; One of the four twinkles at random, never the one he already shows, turned
; the other way round each time -- rand_legs_sprite, at $C357.
;
; In:  IX -> the player's legs
; Out: nothing
; Corrupts: everything
player_twinkle:     call    mover_rand
                    and     3
                    add     a,PLAYER_CHANGE_GFX
                    cp      (ix+OBJ.GFX)
                    jr      nz,.other
                    xor     1
.other:             ld      (ix+OBJ.GFX),a
                    ld      a,(ix+OBJ.FLAGS)
                    xor     OBJ_FLIP_H
                    ld      (ix+OBJ.FLAGS),a
                    jr      player_repaint


; How tall his legs are to the depth sort, and his place in it again to match. A
; step of nothing re-sorts nothing -- depth_step_upper returns early -- so a
; repaint where he stands would leave him wherever the old height put him.
;
; player_legs_short puts back the height the legs have with a body on top of them.
;
; In:  A  = the height (player_legs_height only)
;      IX -> the player's legs
; Out: nothing
; Corrupts: AF, BC, DE, HL, IY
player_legs_short:  ld      a,CHARACTER_BODY_UP
                    ;; NB: fall through into player_legs_height
player_legs_height: ld      (ix+OBJ.SIZE_Z),a
                    jp      depth_relink


; The knight's two graphic bases, for man or wolf. character_frame works each
; frame out from them, so the wolf walks and turns with the knight's own code.
;
; In:  A = the legs' base: PLAYER_LEGS_GFX, plus PLAYER_WOLF for the wolf
; Out: nothing
; Corrupts: AF
player_form:        ld      (player + CHARACTER_LEGS),a
                    add     a,PLAYER_BODY_GFX - PLAYER_LEGS_GFX
                    ld      (player + CHARACTER_BODY_G),a
                    ret
