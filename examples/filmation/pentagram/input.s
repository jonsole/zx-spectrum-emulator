; ---------------------------------------------------------------------------
; What the player is asking for -- the four readers behind input_read, one for
; each thing the menu can choose.
;
; They all leave the same byte, in this bit order:
;
;   0  left        1  right        2  forward
;   3  jump        4  back
;
; Nothing here decides anything: player_turn reads the byte and works out which
; way he should face. That split is what lets one reader serve both control
; schemes.
;
; -- directional control, which Pentagram itself does not have ---------------
;
; The game is rotational only: left and right turn him, forward walks him the
; way he is facing. Knight Lore offers directional control as a menu option --
; each direction names an absolute way to face, and he turns and walks in one
; -- and this remake offers it too, because it is a better way to play and
; there is no reason the engine cannot do both.
;
; It costs less here than it does in Knight Lore. There, turning directional
; control on makes "down" a direction, which displaces pick up / put down onto
; bit 5 and a separate scan of the letter keys -- see the two jobs its bit 4
; does. Pentagram has nothing to displace: there is no pick up, so bit 4 is
; free to be "back" whichever scheme is running, and is simply ignored while
; the controls are rotational.
;
; So the toggle changes nothing in this file. It lives in menu_mode bit 3 and
; player_turn is the only thing that reads it.
;
; -- the keys ----------------------------------------------------------------
;
; Whole half-rows, as the game itself reads them -- it never looks at a single
; key, which is why any of A to ENTER walks him and why pressing G does the
; same as pressing A. Measured against the original: the A-to-G and H-to-ENTER
; rows walk him, the Q-to-P rows jump, and the CAPS-to-V row is its fourth
; action. The number rows do nothing in the original, so they are free here,
; and back is put on them.
; ---------------------------------------------------------------------------

INPUT_LEFT          EQU     1 << 0
INPUT_RIGHT         EQU     1 << 1
INPUT_FORWARD       EQU     1 << 2
INPUT_JUMP          EQU     1 << 3
INPUT_BACK          EQU     1 << 4              ; only steers while directional

; The keyboard's half-rows.
KEY_ROW_SHIFT_V     EQU     $FEFE               ; CAPS, Z, X, C, V
KEY_ROW_SPACE_B     EQU     $7FFE               ; SPACE, SYM SHIFT, M, N, B
KEY_ROWS_A_ENTER    EQU     $BDFE               ; A to G and H to ENTER
KEY_ROWS_Q_P        EQU     $DBFE               ; Q to T and Y to P
KEY_ROWS_1_0        EQU     $E7FE               ; 1 to 5 and 6 to 0
KEY_STICK_1_5       EQU     $F7FE               ; 1 to 5: the cursor keys' 5, and
                                                ; Interface II's second stick
KEY_STICK_0_6       EQU     $EFFE               ; 0, 9, 8, 7, 6: the rest of the
                                                ; cursor keys, and its first stick
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


; Both of the Interface II's sticks at once. The first is keys 6 to 0 -- 6
; left, 7 right, 8 down, 9 up, 0 to fire -- and the second is 1 to 5, the same
; five in the same order. They sit at opposite ends of their rows, so one is
; read from bit 4 down and the other from bit 0 up.
input_interface_ii: ld      e,0
                    ld      bc,KEY_STICK_1_5    ; the second stick
                    in      a,(c)
                    cpl
                    bit     0,a                 ; 1 left
                    jr      z,.r2
                    set     0,e
.r2:                bit     1,a                 ; 2 right
                    jr      z,.d2
                    set     1,e
.d2:                bit     2,a                 ; 3 down
                    jr      z,.u2
                    set     4,e
.u2:                bit     3,a                 ; 4 up
                    jr      z,.f2
                    set     2,e
.f2:                bit     4,a                 ; 5 fire
                    jr      z,.first
                    set     3,e

.first:             ld      bc,KEY_STICK_0_6    ; the first stick
                    in      a,(c)
                    cpl
                    bit     4,a                 ; 6 left
                    jr      z,.r1
                    set     0,e
.r1:                bit     3,a                 ; 7 right
                    jr      z,.d1
                    set     1,e
.d1:                bit     2,a                 ; 8 down
                    jr      z,.u1
                    set     4,e
.u1:                bit     1,a                 ; 9 up
                    jr      z,.f1
                    set     2,e
.f1:                bit     0,a                 ; 0 fire
                    jp      z,input_store
                    set     3,e
                    jp      input_store


; The Kempston's own port, where a bit is set while it is held -- the other way
; round from the keyboard.
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
                    jp      nc,input_store
                    set     3,e
                    jp      input_store


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
                    jp      z,input_store
                    set     4,e
                    jp      input_store


; The keyboard. Left and right are Z, X, C and V along the bottom row and
; SYM SHIFT, M, N and B beside them -- Z, C, M and B turn him one way and
; X, V, SYM and N the other. Any letter of the middle row walks him forward,
; any of the top row jumps, and any number is back.
input_keyboard:     ld      e,0

                    ld      bc,KEY_ROW_SHIFT_V  ; CAPS, Z, X, C, V
                    in      a,(c)
                    cpl
                    rra                         ; past CAPS SHIFT
                    and     $0F                 ; Z, X, C, V
                    ld      d,a
                    and     $05                 ; Z and C
                    jr      z,.x_v
                    set     0,e
.x_v:               ld      a,d
                    and     $0A                 ; X and V
                    jr      z,.space_row
                    set     1,e

.space_row:         ld      bc,KEY_ROW_SPACE_B  ; SPACE, SYM SHIFT, M, N, B
                    in      a,(c)
                    cpl
                    rra                         ; past SPACE
                    and     $0F                 ; SYM SHIFT, M, N, B
                    ld      d,a
                    and     $0A                 ; M and B
                    jr      z,.sym_n
                    set     0,e
.sym_n:             ld      a,d
                    and     $05                 ; SYM SHIFT and N
                    jr      z,.forward
                    set     1,e

.forward:           ld      bc,KEY_ROWS_A_ENTER ; any of A to ENTER
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,.jump
                    set     2,e

.jump:              ld      bc,KEY_ROWS_Q_P     ; any of Q to P
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,.back
                    set     3,e

.back:              ld      bc,KEY_ROWS_1_0     ; any number
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,input_store
                    set     4,e

                    ;; NB: fall through into input_store


; Keep what the reader made of it.
;   E - the bits
input_store:        ld      a,e
                    ld      (input_now),a
                    ret
