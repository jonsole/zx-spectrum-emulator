; ---------------------------------------------------------------------------
; Sabreman himself: the record the engine walks, the byte it sets when he
; touches something deadly, and the turn that reads what the player asked for.
;
; He is two object records moving as one figure -- legs and body -- which the
; engine's walking_character lays down.
;
; His graphics are the original's: legs 32-35 walking away and 36-39 towards,
; body 40-47 the same way, four frames a block. The engine's generic settings
; for a four-frame walk and for art drawn facing the other way are set in
; pentagram.s.
;
; His body rides 12 above his legs facing away and 8 facing the viewer,
; measured in the original. That is his alone, so it is done here rather than
; in the shared engine: player_body_up puts it there every turn.
; ---------------------------------------------------------------------------

PLAYER_LEGS_GFX     EQU     32
PLAYER_BODY_GFX     EQU     40              ; two blocks of four above the legs
PLAYER_BODY_UP_TOWARDS EQU  8               ; CHARACTER_BODY_UP is facing away

; How many turns a held turn key waits between quarter turns. The original
; turns once every 8 frames while the key is held (7 to 9, timed in the
; emulator), which is about six quarter turns a second. This runs about 35
; turns a second in a light room, so a quarter turn every sixth turn -- one,
; then five waited -- is the same pace. Busy rooms run slower and so turn a
; little slower; the same is true of Knight Lore's PLAYER_TURN_WAIT.
PLAYER_TURN_WAIT    EQU     5

player_turn_wait:   DB      0
PLAYER_FACING       EQU     0

                    ALIGN   32
player:             walking_character PLAYER_LEGS_GFX, PLAYER_BODY_GFX, PLAYER_FACING
walker_player       EQU     player          ; the character movers collide with

; Set to 1 by the engine when he touches something deadly -- object.s writes it
; and the game's turn is expected to notice. Nothing reads it yet, which is why
; he is currently immortal.
player_touched:     DB      0
deadly_touched      EQU     player_touched


; ---------------------------------------------------------------------------
; One turn of the player: read what is being asked for, and either walk him or
; leave him standing.
;
; A character that is only standing there is repainted all the same -- see
; character_stand -- so there is no early out here.
; Corrupts AF, BC, DE, HL.
player_step:        ld      ix,player
                    ld      a,(player_state)
                    or      a
                    jp      nz,player_dying     ; nothing he asks for counts
                    ld      a,(player_touched)
                    or      a
                    jp      nz,player_die

                    ; Nobody else is walking about. The movers point this at him
                    ; so that they bump into him; for his own move it has to be
                    ; clear, or he would collide with himself.
                    ld      hl,0
                    ld      (collide_other),hl

                    ; Whether he is standing in a doorway, worked out before he
                    ; moves: character_collide lifts the room's edge while it is
                    ; set, and player_exit asks whether the step took him out.
                    call    player_door_find

                    call    input_read
                    ld      ix,player

                    ; The jump key first, because gravity asks about it in the
                    ; same turn: holding it is what makes the difference between
                    ; a hop and a full jump. Measured in the original: held, he
                    ; rises +7 down to +1; let go, +7, +5, +3, +1 -- the engine's
                    ; gravity, one a turn held and two let go.
                    call    player_fire
                    call    quest_take

                    ; On a joystick the original jumps with down.
                    ld      a,(menu_mode)
                    and     MENU_KEMPSTON | MENU_CURSOR
                    ld      c,INPUT_JUMP
                    jr      z,.jump_key         ; the keyboard
                    ld      c,INPUT_JUMP | INPUT_DOWN
.jump_key:          ld      a,(input_now)
                    and     c
                    ld      a,0
                    jr      z,.no_jump
                    inc     a
                    call    character_jump
.no_jump:           ld      (character_jump_held),a

                    call    player_turn
                    jr      nc,.stand
                    push    af
                    call    player_body_up      ; for the facing about to be walked
                    pop     af
                    call    character_walk      ; A is the facing to walk
                    call    sound_step
                    ld      ix,player           ; the repaint took IX
                    jp      player_exit
.stand:             ld      a,(ix+CHARACTER_FACING)
                    call    player_body_up
                    jp      character_stand


; Put his body at the height the original gives it for this facing: 12 above
; the legs facing away, 8 facing the viewer (bit 1 of the facing, the same bit
; the engine picks the block with). Jumps and falls move both records by one
; step, so setting it from the legs each turn keeps it right; and the region
; the move repaints comes from where he was drawn, not from Z.
;   IX -> the legs record, A - the facing
; Corrupts AF.
player_body_up:     and     2
                    ld      a,CHARACTER_BODY_UP
                    jr      z,.away
                    ld      a,PLAYER_BODY_UP_TOWARDS
.away:              add     a,(ix+OBJ.Z)
                    ld      (ix+CHARACTER_BODY+OBJ.Z),a
                    ret


; ---------------------------------------------------------------------------
; Which way he walks: left and right turn him a quarter where he stands,
; forward walks him the way he is already facing -- rotational, as Pentagram
; plays. Turning does not move him, so a turn and a step are different turns of
; the loop, which is what "turn then walk" means to play.
;
;   IX -> the legs record
; Out: carry set and A the facing to walk; carry clear to stand.
; Corrupts AF, BC, HL.
player_turn:        ; A jump is a leap. Once he is off the ground he goes on the
                    ; way he faces, whatever is held, and cannot turn until he
                    ; is down: in the original, jumping with nothing else held
                    ; still carries him three units a turn along his facing.
                    bit     0,(ix+CHARACTER_STATE)  ; CHARACTER_JUMPING
                    jr      z,.grounded
                    ld      a,(ix+CHARACTER_FACING)
                    scf
                    ret

.grounded:          ld      a,(input_now)

                    ; A held turn key turns him once, then waits PLAYER_TURN_WAIT
                    ; turns before the next quarter. Letting go clears the wait,
                    ; so a tap always turns at once, as it does in the original.
                    ld      b,a
                    and     INPUT_LEFT | INPUT_RIGHT
                    ld      hl,player_turn_wait
                    jr      nz,.turning
                    ld      (hl),a              ; nothing held: no wait owed
                    jr      .not_right

.turning:           ld      a,(hl)
                    or      a
                    jr      z,.may_turn
                    dec     (hl)                ; too soon: he stands, turned
                    xor     a                   ; carry clear
                    ret

.may_turn:          ld      (hl),PLAYER_TURN_WAIT
                    ld      a,b
                    and     INPUT_LEFT
                    jr      z,.not_left
                    ld      a,(ix+CHARACTER_FACING)
                    dec     a
                    and     3
                    ld      (ix+CHARACTER_FACING),a
                    or      a                   ; turning is not walking
                    ret                         ; ...and `and 3` left carry clear

.not_left:          ld      a,(ix+CHARACTER_FACING)
                    inc     a                   ; right, then
                    and     3
                    ld      (ix+CHARACTER_FACING),a
                    or      a
                    ret

.not_right:         ld      a,b
                    and     INPUT_FORWARD
                    ret     z                   ; nothing asked for: stand
                    ld      a,(ix+CHARACTER_FACING)
                    scf
                    ret



; ---------------------------------------------------------------------------
; Has the step taken him right out through the doorway he was in? Out when the
; whole of him has passed the wall, not when he touches it -- Knight Lore's
; test, which this is.
;
; Where it leads is where Pentagram differs. Knight Lore's castle is a grid and
; works the next room out with an add; Pentagram's map is not, so the builder
; kept each side's destination in room_door_to as the scenery went by, and this
; reads it. Every doorway in the data but one has a matching door on the
; opposite side of the room it leads to -- 288 of 289 -- so he comes in by the
; opposite wall.
;   IX -> the legs record
; Corrupts AF, BC, DE, HL.
player_exit:        ld      a,(ix+CHARACTER_DOOR)
                    inc     a
                    ret     z                   ; not in a doorway
                    dec     a
                    ld      c,a

                    ld      a,(ix+OBJ.V)        ; north and south cross V
                    ld      hl,room_half_v
                    bit     0,c
                    jr      z,.axis
                    ld      a,(ix+OBJ.U)        ; east and west cross U
                    ld      hl,room_half_u
.axis:              ld      b,(hl)
                    bit     1,c
                    jr      nz,.near

                    ; North and east: his trailing edge has to be past the far
                    ; wall.
                    sub     CHARACTER_HALF_U
                    ld      e,a
                    ld      a,b
                    add     a,127               ; one below the bound, so
                    cp      e                   ; carry means he is past it
                    ret     nc
                    jr      .out

                    ; South and west: his leading edge below the near wall.
.near:              add     a,CHARACTER_HALF_U
                    ld      e,a
                    ld      a,128
                    sub     b                   ; the near bound
                    ld      d,a
                    ld      a,e
                    cp      d
                    ret     nc                  ; not below it yet

.out:               ld      b,0
                    ld      hl,room_door_to
                    add     hl,bc
                    ld      a,(hl)
                    or      a
                    ret     z                   ; walled up: nowhere to go
                    ld      (room_number),a
                    ld      a,c                 ; he comes in by the opposite
                    xor     2                   ; wall of the new room
                    ld      (enter_dir),a
                    ret


; Which side of the next room he walks in by, or $FF when he did not walk in.
enter_dir:          DB      $FF


; ---------------------------------------------------------------------------
; Is he standing in one of the room's doorways, and which? Sets
; CHARACTER_DOOR to the side, or $FF.
;
; The engine's character_door_find, but measured across the opening from
; room_door_mid rather than from 128: Pentagram's raised doorways stand off to
; one side of their wall, and the engine's test would never find him in one.
; The box is the engine's -- DOOR_ACROSS either side of the centre, DOOR_ALONG
; either side of the arch, and DOOR_LEVEL below to DOOR_HEIGHT above its floor.
;   IX -> the legs record
; Corrupts AF, BC, DE, HL.
player_door_find:   ld      (ix+CHARACTER_DOOR),$FF
                    ld      c,0

.side:              ld      b,0
                    ld      hl,room_door_z
                    add     hl,bc
                    ld      a,(hl)
                    or      a
                    jr      z,.next             ; no door on this side

                    ld      a,(ix+OBJ.Z)
                    sub     (hl)
                    add     a,DOOR_LEVEL - 1
                    cp      DOOR_LEVEL - 1 + DOOR_HEIGHT
                    jr      nc,.next            ; the wrong storey

                    ; North and south face along V, east and west along U; the
                    ; other axis is the one across the opening.
                    ld      e,(ix+OBJ.U)
                    ld      a,(ix+OBJ.V)
                    bit     0,c
                    jr      z,.along
                    ld      e,(ix+OBJ.V)
                    ld      a,(ix+OBJ.U)
.along:             ld      hl,room_door_at
                    add     hl,bc
                    sub     (hl)
                    call    character_door_find.abs
                    cp      DOOR_ALONG
                    jr      nc,.next            ; not up to the wall yet

                    ld      hl,room_door_mid
                    add     hl,bc
                    ld      a,e
                    sub     (hl)
                    call    character_door_find.abs
                    cp      DOOR_ACROSS
                    jr      nc,.next            ; beside it, not in it

                    ld      (ix+CHARACTER_DOOR),c
                    ret

.next:              inc     c
                    ld      a,c
                    cp      4
                    jr      c,.side
                    ret


; ---------------------------------------------------------------------------
; Where he stands when he walks into a room: in the doorway he came through,
; on the line of its wall, at the middle of its opening and the height of its
; floor. All three are the original's, measured: out of room 92 by the east
; door he stands in room 93 at U 64, V 96, Z 176 -- the west wall, the middle
; of its raised doorway, and that doorway's floor -- and out by the west door
; he stands in room 91 at U 192, its east wall.
;
; That is not Knight Lore's rule, which keeps the axis he did not cross and
; stands him two units inside the wall; Pentagram's doorways are not all in
; the middle of their walls, so it cannot.
;
; One doorway in the data leads to a room with no partner on that side. There
; he stands on the floor, at the wall, where he was across it.
;   IX -> the legs record, still holding where he was in the last room
; Out: B - U, C - V, A - the Z to stand at. (enter_dir) is spent.
; Corrupts DE, HL.
player_entry:       ld      a,(enter_dir)
                    ld      e,a                 ; E - the side he comes in by
                    ld      b,(ix+OBJ.U)
                    ld      c,(ix+OBJ.V)
                    ld      hl,room_door_z
                    call    .side
                    ld      a,(hl)
                    or      a
                    jr      nz,.door
                    ld      a,(room_floor_z)    ; no doorway that side
                    push    af
                    jr      .wall

.door:              push    af                  ; its floor
                    ld      hl,room_door_mid
                    call    .side
                    ld      a,(hl)              ; the middle of its opening:
                    bit     0,e
                    jr      nz,.across_v
                    ld      b,a                 ; U, in a north or south wall
                    jr      .wall
.across_v:          ld      c,a                 ; V, in an east or west one

                    ; On the line of the wall: 128 and the room's half-width,
                    ; beyond the centre for north and east, short of it for
                    ; south and west.
.wall:              ld      hl,room_half_v      ; north and south cross V
                    bit     0,e
                    jr      z,.axis
                    ld      hl,room_half_u      ; east and west cross U
.axis:              ld      a,(hl)
                    bit     1,e                 ; south and west are the near
                    jr      z,.far              ; walls, north and east the far
                    neg
.far:               add     a,128
                    bit     0,e
                    jr      nz,.u
                    ld      c,a
                    jr      .done
.u:                 ld      b,a
.done:              ld      a,$FF
                    ld      (enter_dir),a
                    pop     af
                    ret

; HL += E.
.side:              ld      a,e
                    add     a,l
                    ld      l,a
                    ret     nc
                    inc     h
                    ret


; ---------------------------------------------------------------------------
; Fire a bolt, if fire has just been pressed and he has one to spare -- $C126.
;
; A press, not a hold: the original latches it until the key is let go. Two
; bolts at most, in the two slots after the flyers'. It goes the way he faces,
; eight a turn, from two turns' flight ahead of him and four up; if that is
; outside the room there is no shot.
;   IX -> the legs record
; Corrupts AF, BC, DE, HL, IY. IX comes back as it was.
BOLT_STEP           EQU     8
BOLT_UP             EQU     4
BOLT_START_GFX      EQU     150
BOLT_LARGEST        EQU     sprite_030      ; 3x17: the largest of its frames
                                            ; and its puff's

fire_held:          DB      0

; The step for each facing, as character_steps orders them.
bolt_steps:         DB      -BOLT_STEP, 0       ; 0  -U
                    DB      0, BOLT_STEP        ; 1  +V
                    DB      BOLT_STEP, 0        ; 2  +U
                    DB      0, -BOLT_STEP       ; 3  -V

player_fire:        ld      a,(input_now)
                    and     INPUT_FIRE
                    ld      hl,fire_held
                    jr      nz,.pressed
                    ld      (hl),a              ; let go: the next press counts
                    ret
.pressed:           ld      a,(hl)
                    or      a
                    ret     nz                  ; still the same press
                    ld      (hl),1

                    push    ix
                    ld      iy,(flyer_slots)
                    ld      de,FLYER_SLOTS * ROOM_STRIDE
                    add     iy,de
                    ld      a,(iy+OBJ.GFX)
                    or      a
                    jr      z,.free
                    ld      de,ROOM_STRIDE
                    add     iy,de
                    ld      a,(iy+OBJ.GFX)
                    or      a
                    jp      nz,.none            ; both in flight

.free:              ld      a,(ix+CHARACTER_FACING)
                    add     a,a
                    ld      e,a
                    ld      d,0
                    ld      hl,bolt_steps
                    add     hl,de
                    ld      b,(hl)              ; B - the step in U
                    inc     hl
                    ld      c,(hl)              ; C - the step in V

                    ; Two steps ahead of him, and inside the room.
                    ld      a,b
                    add     a,a
                    add     a,(ix+OBJ.U)
                    ld      d,a
                    sub     128
                    call    character_door_find.abs
                    ld      hl,room_half_u
                    cp      (hl)
                    jr      nc,.none
                    ld      a,c
                    add     a,a
                    add     a,(ix+OBJ.V)
                    ld      e,a
                    sub     128
                    call    character_door_find.abs
                    ld      hl,room_half_v
                    cp      (hl)
                    jr      nc,.none

                    ld      (iy+OBJ.U),d
                    ld      (iy+OBJ.V),e
                    ld      a,(ix+OBJ.Z)
                    add     a,BOLT_UP
                    ld      (iy+OBJ.Z),a
                    ld      (iy+BOLT_DU),b
                    ld      (iy+BOLT_DV),c
                    ld      (iy+OBJ.GFX),BOLT_START_GFX
                    ld      (iy+OBJ.BEHAVIOUR),MOVE_BOLT
                    ld      (iy+OBJ.SIZE_U),CHARACTER_HALF_U
                    ld      (iy+OBJ.SIZE_V),CHARACTER_HALF_V
                    ld      (iy+OBJ.SIZE_Z),8
                    xor     a
                    ld      (iy+OBJ.FLAGS),a
                    ld      (iy+OBJ.DU),a
                    ld      (iy+OBJ.DV),a
                    ld      (iy+OBJ.DZ),a
                    ld      (iy+OBJ.MOVE_STATE),a

                    push    iy
                    pop     ix
                    ld      a,(ix+OBJ.BUF_H)
                    or      a
                    jr      nz,.buffered
                    ld      hl,BOLT_LARGEST
                    call    shift_alloc
.buffered:          call    room_adjust
                    call    object_place
                    call    depth_insert
                    call    redraw_object
                    call    sound_fire

.none:              pop     ix
                    ret


; ---------------------------------------------------------------------------
; Dying. Something deadly has touched him: both halves go out in the puff
; everything in Pentagram goes out in -- graphics 64 to 70, a frame a turn,
; $C107 and $C111 -- and then main.s takes a life and puts him back. There is
; no coming back sparkle, as there is in Knight Lore: he is simply there.
PLAYER_ALIVE        EQU     0
PLAYER_DYING        EQU     1
PLAYER_DEAD         EQU     2               ; played out: main.s's to act on

player_state:       DB      PLAYER_ALIVE

;   IX -> the legs record
player_die:         ld      a,PLAYER_DYING
                    ld      (player_state),a
                    set     2,(ix+OBJ.FLAGS)    ; OBJ_PASSABLE, and nothing else
                    ld      a,POOF_FIRST
                    jr      player_dying.frame

player_dying:       ld      a,(ix+OBJ.GFX)
                    cp      POOF_LAST
                    jr      nc,.done
                    inc     a
.frame:             ld      (ix+OBJ.GFX),a      ; both halves the one frame,
                    ld      (ix+CHARACTER_BODY+OBJ.GFX),a
                    ld      de,0                ; repainted where they stand
                    ld      (ix+OBJ.DZ),0
                    jp      character_move
.done:              ld      a,PLAYER_DEAD
                    ld      (player_state),a
                    ret
