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

; The bit numbers first: engine/input.s's stick readers SET them, and a stick
; has five inputs, so Knight Lore points its fire at jump and its down at
; pick up -- which is what the game does, and why bit 4 has two names.
INPUT_LEFT_B        EQU     0
INPUT_RIGHT_B       EQU     1
INPUT_FORWARD_B     EQU     2
INPUT_JUMP_B        EQU     3
INPUT_PICKUP_B      EQU     4                   ; and down, on a joystick
INPUT_STICK_FIRE_B  EQU     INPUT_JUMP_B
INPUT_DOWN_B        EQU     INPUT_PICKUP_B

INPUT_LEFT          EQU     1 << INPUT_LEFT_B
INPUT_RIGHT         EQU     1 << INPUT_RIGHT_B
INPUT_FORWARD       EQU     1 << INPUT_FORWARD_B
INPUT_JUMP          EQU     1 << INPUT_JUMP_B
INPUT_PICKUP        EQU     1 << INPUT_PICKUP_B
INPUT_PICKUP_DIR    EQU     1 << 5
INPUT_FIRE_B        EQU     6                   ; his bolt: see player_fire
INPUT_FIRE          EQU     1 << INPUT_FIRE_B

; The keyboard's half-rows. Knight Lore takes whole rows rather than single
; keys, so any of A to ENTER walks him forward and any of Q to P jumps.
KEY_ROW_SHIFT_V     EQU     $FEFE               ; SHIFT, Z, X, C, V
KEY_ROW_SPACE_B     EQU     $7FFE               ; SPACE, SYM SHIFT, M, N, B
KEY_ROWS_A_ENTER    EQU     $BDFE               ; A to G and H to ENTER
KEY_ROW_Q_T         EQU     $FBFE               ; Q, W, E, R, T in bits 0-4
KEY_ROW_Y_P         EQU     $DFFE               ; P, O, I, U, Y in bits 0-4
KEY_ROWS_1_0        EQU     $E7FE               ; 1 to 5 and 6 to 0
KEY_ROWS_Z_B        EQU     $7EFE               ; the letters of the bottom row
KEY_ROWS_LETTERS    EQU     $99FE               ; A to G, Q to T, Y to P, H to ENTER

; The keyboard. Left and right are Z, X, C and V along the bottom row and
; SYM SHIFT, M, N and B beside them -- Z, C, M and B turn him one way and
; X, V, SYM and N the other. Any letter of the middle row walks him forward,
; the top row jumps and fires by turns, and any number picks up or puts down.
;
; The top row is Pentagram's, key by key and alternately -- Q E T  U O jump,
; W R  Y I P fire -- so each half is read on its own: the one port $DBFE would
; OR them together, and give Q and P the same bit. Knight Lore jumps on the
; whole row, and has no bolt to fire. On a joystick the button still jumps, as
; it does there, and nothing fires.
;
; In:  nothing
; Out: input_now = what the player is asking for
; Corrupts: AF, BC, DE
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
.jump:              ld      bc,KEY_ROW_Q_T
                    in      a,(c)
                    cpl
                    ld      d,a                 ; Q W E R T
                    ld      b,high KEY_ROW_Y_P
                    in      a,(c)
                    cpl
                    ld      b,a                 ; P O I U Y
                    and     $0A                 ; O and U
                    ld      c,a
                    ld      a,d
                    and     $15                 ; Q, E and T
                    or      c
                    jr      z,.fire
                    set     INPUT_JUMP_B,e
.fire:              ld      a,b
                    and     $15                 ; P, I and Y
                    ld      c,a
                    ld      a,d
                    and     $0A                 ; W and R
                    or      c
                    jr      z,.pickup
                    set     INPUT_FIRE_B,e
.pickup:            ld      bc,KEY_ROWS_1_0
                    in      a,(c)
                    cpl
                    and     $1F
                    jp      z,input_done
                    set     4,e

                    ;; NB: fall through into input_done -- input_stick_done


; Bit 5, which is where pick up and put down go while a joystick is steering:
; any letter at all, which is what the game asks for at finished_input. Every
; stick reader in engine/input.s ends here.
;
; In:  E = what the reader made of it
; Out: input_now = that, and bit 5 for any letter
; Corrupts: AF, BC, DE
input_stick_done:
; See input_stick_done.
;
; In:  E = what the reader made of it
; Out: input_now = that, and bit 5 for any letter
; Corrupts: AF, BC, DE
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
                    jp      z,input_store
                    set     5,e
                    jp      input_store
