; ---------------------------------------------------------------------------
; What the player is asking for -- read_input at $D022 and the four readers
; behind it, one for each thing the menu can choose.
;
; They all leave the same byte, in the game's own bit order:
;
;   0  left        1  right        2  forward
;   3  jump        4  pick up / put down, or DOWN on a joystick
;   5  pick up / put down while a joystick is steering
;
; Bit 4 does two jobs because a joystick steering by itself has no use for
; down -- left, right and forward are all the knight needs -- so down is where
; the game puts pick up / put down. Turn directional control on and down
; becomes a direction, so pick up moves to bit 5 and the letter keys, which
; the stick has then left free. input_done sets that bit whatever is steering.
;
; Nothing here decides anything: player_turn reads the byte and works out which
; way he should face.
; ---------------------------------------------------------------------------

INPUT_LEFT          EQU     1 << 0
INPUT_RIGHT         EQU     1 << 1
INPUT_FORWARD       EQU     1 << 2
INPUT_JUMP          EQU     1 << 3
INPUT_PICKUP        EQU     1 << 4              ; and down, on a joystick
INPUT_PICKUP_DIR    EQU     1 << 5

; The keyboard's half-rows. Knight Lore takes whole rows rather than single
; keys, so any of A to ENTER walks him forward and any of Q to P jumps.
KEY_ROW_SHIFT_V     EQU     $FEFE               ; SHIFT, Z, X, C, V
KEY_ROW_SPACE_B     EQU     $7FFE               ; SPACE, SYM SHIFT, M, N, B
KEY_ROWS_A_ENTER    EQU     $BDFE               ; A to G and H to ENTER
KEY_ROWS_Q_P        EQU     $DBFE               ; Q to T and Y to P
KEY_ROWS_1_0        EQU     $E7FE               ; 1 to 5 and 6 to 0
KEY_ROWS_Z_B        EQU     $7EFE               ; the letters of the bottom row
KEY_ROWS_LETTERS    EQU     $99FE               ; A to G, Q to T, Y to P, H to ENTER
KEY_STICK_1_5       EQU     $F7FE               ; 1 to 5: cursor 5, Interface II
KEY_STICK_0_6       EQU     $EFFE               ; 0, 9, 8, 7, 6: the same again
KEMPSTON_PORT       EQU     $1F

input_now:          DB      0


; Read whichever the menu chose.
; Corrupts AF, BC, DE.
input_read:         ld      a,(menu_mode)
                    rrca
                    and     3                   ; 00 keyboard, 01 Kempston,
                    jp      z,input_keyboard    ; 10 cursor, 11 Interface II
                    dec     a
                    jp      z,input_kempston
                    dec     a
                    jp      z,input_cursor
                    ;; NB: fall through into input_interface_ii


; Both sticks at once, as the game reads them: the first is keys 1 to 5 and
; the second 0 to 6, and the first runs the other way round, so its five bits
; are turned over and the two are merged.
input_interface_ii: ld      bc,KEY_STICK_1_5
                    in      a,(c)
                    cpl                         ; a key reads 0 while it is held
                    and     $1F
                    ld      d,0
                    ld      b,5
.reverse:           rra
                    rl      d
                    djnz    .reverse

                    ld      bc,KEY_STICK_0_6
                    in      a,(c)
                    cpl
                    and     $1F
                    or      d
                    ld      e,0
                    rra                         ; fire
                    jr      nc,.up
                    set     3,e
.up:                rra
                    jr      nc,.down
                    set     2,e
.down:              rra
                    jr      nc,.right
                    set     4,e
.right:             rra
                    jr      nc,.left
                    set     1,e
.left:              rra
                    jp      nc,input_done
                    set     0,e
                    jp      input_done


; The Kempston's own port, where a bit is set while it is held -- the other
; way round from the keyboard.
input_kempston:     ld      e,0
                    in      a,(KEMPSTON_PORT)
                    rra                         ; right
                    jr      nc,.left
                    set     1,e
.left:              rra
                    jr      nc,.down
                    set     0,e
.down:              rra
                    jr      nc,.up
                    set     4,e
.up:                rra
                    jr      nc,.fire
                    set     2,e
.fire:              rra
                    jp      nc,input_done
                    set     3,e
                    jp      input_done


; The cursor keys: 5 left, 8 right, 7 up, 6 down and 0 to fire.
input_cursor:       ld      e,0
                    ld      bc,KEY_STICK_1_5
                    in      a,(c)
                    cpl
                    bit     4,a                 ; 5
                    jr      z,.rest
                    set     0,e
.rest:              ld      bc,KEY_STICK_0_6
                    in      a,(c)
                    cpl
                    bit     0,a                 ; 0
                    jr      z,.up
                    set     3,e
.up:                bit     3,a                 ; 7
                    jr      z,.right
                    set     2,e
.right:             bit     2,a                 ; 8
                    jr      z,.down
                    set     1,e
.down:              bit     4,a                 ; 6
                    jp      z,input_done
                    set     4,e
                    jp      input_done


; The keyboard. Left and right are Z, X, C and V along the bottom row and
; SYM SHIFT, M, N and B beside them -- Z, C, M and B turn him one way and
; X, V, SYM and N the other. Any letter of the middle row walks him forward,
; any of the top row jumps, and any number picks up or puts down.
input_keyboard:     ld      bc,KEY_ROW_SHIFT_V
                    in      a,(c)
                    cpl
                    rra                         ; past CAPS SHIFT
                    ld      d,a
                    and     $03                 ; Z left, X right
                    ld      e,a
                    ld      a,d
                    rra
                    rra                         ; C and V down onto them
                    and     $03
                    or      e
                    and     $03
                    ld      e,a

                    ld      bc,KEY_ROW_SPACE_B
                    in      a,(c)
                    cpl
                    bit     1,a                 ; SYM SHIFT
                    jr      z,.m
                    set     1,e
.m:                 bit     2,a                 ; M
                    jr      z,.n
                    set     0,e
.n:                 bit     3,a                 ; N
                    jr      z,.b
                    set     1,e
.b:                 bit     4,a                 ; B
                    jr      z,.forward
                    set     0,e

.forward:           ld      bc,KEY_ROWS_A_ENTER
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,.jump
                    set     2,e
.jump:              ld      bc,KEY_ROWS_Q_P
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,.pickup
                    set     3,e
.pickup:            ld      bc,KEY_ROWS_1_0
                    in      a,(c)
                    cpl
                    and     $1F
                    jp      z,input_done
                    set     4,e

                    ;; NB: fall through into input_done


; Bit 5, which is where pick up and put down go while a joystick is steering:
; any letter at all, which is what the game asks for at finished_input.
;   E - what the reader made of it
input_done:         ld      bc,KEY_ROWS_Z_B
                    in      a,(c)
                    cpl
                    and     $1E                 ; Z to V and SYM SHIFT to B
                    ld      d,a
                    ld      bc,KEY_ROWS_LETTERS
                    in      a,(c)
                    cpl
                    and     $1F
                    or      d
                    jr      z,.store
                    set     5,e
.store:             ld      a,e
                    ld      (input_now),a
                    ret
