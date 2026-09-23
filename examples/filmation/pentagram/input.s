; ---------------------------------------------------------------------------
; What the player is asking for -- the four readers behind input_read, one for
; each thing the menu can choose.
;
; They all leave the same byte, in this bit order:
;
;   0  left        1  right        2  forward
;   3  jump        4  down         5  fire
;   6  pick up or put down
;
; Nothing here decides anything: player_step and player_turn read the byte.
; Bit 4 is a stick's down, which is how the original jumps on one; the
; keyboard never sets it.
;
; -- the keys ----------------------------------------------------------------
;
; Mostly whole half-rows, as the game itself reads them, which is why any of A
; to ENTER walks him and pressing G does the same as pressing A. The top row
; is the exception: the original splits it key by key, alternately, reading
; each half on its own ($BEC8 and $BEE7) --
;
;   Q E T  U O    jump
;   W R  Y I P    fire
;
; so it cannot be read as the one port $DBFE, which ORs the halves together
; and would give Q and P the same bit. The number rows pick up and put down,
; as they do in the original.
;
; On a joystick the original fires with the button and jumps with down --
; bit 4 here -- which player_step takes as a jump.
;
; The game is rotational only, as the original is: left and right turn him,
; forward walks him the way he faces. The remake offered directional control
; for a while, as Knight Lore's does, but a stick has five inputs and the game
; wants six -- four ways, jump and fire -- and no way of folding the sixth in
; played well, so it went.
; ---------------------------------------------------------------------------

; The bit numbers first: engine/input.s's stick readers SET them. A stick's
; fire is Pentagram's own fire, and its down is where the original jumps.
INPUT_LEFT_B        EQU     0
INPUT_RIGHT_B       EQU     1
INPUT_FORWARD_B     EQU     2
INPUT_JUMP_B        EQU     3
INPUT_DOWN_B        EQU     4                   ; a stick's down: it jumps
INPUT_FIRE_B        EQU     5
INPUT_TAKE_B        EQU     6                   ; pick up and put down
INPUT_STICK_FIRE_B  EQU     INPUT_FIRE_B

INPUT_LEFT          EQU     1 << INPUT_LEFT_B
INPUT_RIGHT         EQU     1 << INPUT_RIGHT_B
INPUT_FORWARD       EQU     1 << INPUT_FORWARD_B
INPUT_JUMP          EQU     1 << INPUT_JUMP_B
INPUT_DOWN          EQU     1 << INPUT_DOWN_B
INPUT_FIRE          EQU     1 << INPUT_FIRE_B
INPUT_TAKE          EQU     1 << INPUT_TAKE_B

; The keyboard's half-rows.
KEY_ROW_SHIFT_V     EQU     $FEFE               ; CAPS, Z, X, C, V
KEY_ROW_SPACE_B     EQU     $7FFE               ; SPACE, SYM SHIFT, M, N, B
KEY_ROWS_A_ENTER    EQU     $BDFE               ; A to G and H to ENTER
KEY_ROW_Q_T         EQU     $FBFE               ; Q, W, E, R, T
KEY_ROW_Y_P         EQU     $DFFE               ; P, O, I, U, Y
KEY_ROWS_1_0        EQU     $E7FE               ; 1 to 5 and 6 to 0

; The keyboard. Left and right are Z, X, C and V along the bottom row and
; SYM SHIFT, M, N and B beside them -- Z, C, M and B turn him one way and
; X, V, SYM and N the other. Any letter of the middle row walks him forward,
; the top row jumps and fires by turns, and any number picks up or puts down.
;
; In:  nothing
; Out: input_now = what the player is asking for
; Corrupts: AF, BC, DE
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

.jump:              ld      bc,KEY_ROW_Q_T
                    in      a,(c)
                    cpl
                    ld      d,a
                    and     $15                 ; Q, E, T
                    jr      z,.fire_wr
                    set     3,e
.fire_wr:           ld      a,d
                    and     $0A                 ; W, R
                    jr      z,.y_p
                    set     5,e
.y_p:               ld      bc,KEY_ROW_Y_P
                    in      a,(c)
                    cpl
                    ld      d,a
                    and     $0A                 ; O, U
                    jr      z,.fire_piy
                    set     3,e
.fire_piy:          ld      a,d
                    and     $15                 ; P, I, Y
                    jr      z,.back
                    set     5,e

.back:              ld      bc,KEY_ROWS_1_0     ; any number: pick up or
                    in      a,(c)               ; put down, as $BF66 reads it
                    cpl
                    and     $1F
                    jp      z,input_store
                    set     6,e
                    jp      input_store


; With a joystick, pick up and put down is on the keyboard's bottom two rows --
; $BEFD reads Z to V and SYM SHIFT to B together through port $7E -- since
; the number keys are Interface II's sticks. Every stick reader in
; engine/input.s ends here, and input_store is there too.
;
; In:  E = what the stick reader made of it
; Out: input_now = E, and the take bit if either row has a key down
; Corrupts: AF, E
input_stick_done:
; See input_stick_done.
;
; In:  E = what the stick reader made of it
; Out: input_now = E, and the take bit if either row has a key down
; Corrupts: AF, E
input_stick_take:   ld      a,$7E
                    in      a,($FE)
                    cpl
                    and     $1E
                    jp      z,input_store
                    set     6,e
                    jp      input_store
