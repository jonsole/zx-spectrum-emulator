; ---------------------------------------------------------------------------
; Sabreman himself: the record the engine walks, the byte it sets when he
; touches something deadly, and the turn that reads what the player asked for.
;
; He is two object records moving as one figure -- legs and body -- which the
; engine's walking_character lays down. The graphic blocks are eight apart and
; the body rides twelve above the legs, and both of those are confirmed against
; the original rather than assumed: his legs were seen wearing graphics 32 to
; 35 and his body 41, which is 40 plus a phase, and his body record sat at
; Z 140 with his legs at 128.
; ---------------------------------------------------------------------------

PLAYER_LEGS_GFX     EQU     32
PLAYER_BODY_GFX     EQU     40              ; two blocks of four above the legs
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
                    jp      character_walk      ; A is the facing to walk
.stand:             jp      character_stand


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
                    ld      b,a
                    and     INPUT_LEFT
                    jr      z,.not_left
                    ld      a,(ix+CHARACTER_FACING)
                    dec     a
                    and     3
                    ld      (ix+CHARACTER_FACING),a
                    or      a                   ; turning is not walking
                    ret                         ; ...and `and 3` left carry clear

.not_left:          ld      a,b
                    and     INPUT_RIGHT
                    jr      z,.not_right
                    ld      a,(ix+CHARACTER_FACING)
                    inc     a
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
