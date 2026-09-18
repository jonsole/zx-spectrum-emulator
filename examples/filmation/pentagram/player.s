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
player_step:        call    input_read
                    ld      ix,player
                    call    player_turn
                    jr      nc,.stand
                    push    af
                    call    player_body_up      ; for the facing about to be walked
                    pop     af
                    jp      character_walk      ; A is the facing to walk
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
; What the input byte means, which is the whole of the difference between the
; two control schemes.
;
; ROTATIONAL, which is how Pentagram itself plays: left and right turn him a
; quarter where he stands, forward walks him the way he is already facing.
; Turning does not move him, so a turn and a step are different turns of the
; loop -- which is what "turn then walk" means to play.
;
; DIRECTIONAL, which the original does not offer and this does: each direction
; names an absolute facing, and he turns and walks in one. The facing is taken
; from the input bit and walked the same turn, so holding a direction walks him
; that way whatever he was facing before.
;
; The mapping from the four bits to the four facings is a choice, not a fact:
; the engine's facings are 0 and 1 walking away from the viewer and 2 and 3
; towards it, so forward/right/back/left onto 0/1/2/3 puts "forward" away up
; the screen. If it plays the wrong way round, this is the place to rotate it.
;
;   IX -> the legs record
; Out: carry set and A the facing to walk; carry clear to stand.
; Corrupts AF, BC, HL.
player_turn:        ld      a,(menu_mode)
                    and     MENU_DIRECTIONAL
                    ld      a,(input_now)
                    jr      nz,.directional

                    ; -- rotational ------------------------------------------
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

                    ; -- directional -----------------------------------------
                    ; The first bit set wins, so pressing two at once picks one
                    ; rather than fighting.
.directional:       ld      b,a
                    ld      c,0                 ; facing 0: forward
                    and     INPUT_FORWARD
                    jr      nz,.go
                    inc     c                   ; facing 1: right
                    ld      a,b
                    and     INPUT_RIGHT
                    jr      nz,.go
                    inc     c                   ; facing 2: back
                    ld      a,b
                    and     INPUT_BACK
                    jr      nz,.go
                    inc     c                   ; facing 3: left
                    ld      a,b
                    and     INPUT_LEFT
                    ret     z                   ; nothing asked for: stand
.go:                ld      a,c
                    ld      (ix+CHARACTER_FACING),a
                    scf
                    ret
