; ---------------------------------------------------------------------------
; What the player is asking for -- read_input at $D022 and the four readers
; behind it, one for each thing the menu can choose.
;
; They all leave the same byte, in the game's own bit order:
;
;   0  left        1  right        2  forward
;   3  jump        4  DOWN on a joystick, which picks up and puts down
;   5  N, which picks up and puts down whatever is steering
;   6  fire        7  M, use what is in the slot in use
;
; and input_slot says which of Z, X, C, V and B, slots 1 to 5, is held.
;
; Bit 4 does two jobs because a joystick steering by itself has no use for
; down -- left, right and forward are all the knight needs -- so down is where
; the game puts pick up / put down. Turn directional control on and down
; becomes a direction, and only N picks up. input_done reads the bottom row
; whatever is steering.
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
INPUT_PICKUP_DIR_B  EQU     5                   ; N, whatever is steering
INPUT_PICKUP_DIR    EQU     1 << INPUT_PICKUP_DIR_B
INPUT_FIRE_B        EQU     6                   ; nothing yet: the sword, at stage 7
INPUT_FIRE          EQU     1 << INPUT_FIRE_B
INPUT_USE_B         EQU     7                   ; M: use what is in the slot
INPUT_USE           EQU     1 << INPUT_USE_B

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

; The keyboard. O turns him one way and P the other, any letter of the middle
; row walks him forward, and the rest of the top row jumps and fires by turns
; -- Q E T U jump, W R Y I fire. Knight Lore turned on the bottom row and
; picked up on the numbers: the bottom row is carrying's now, in input_done,
; whatever is steering, and these keys are not set in stone.
;
; The top row's two halves are read on their own: the one port $DBFE would OR
; them together, and give Q and P the same bit.
;
; In:  nothing
; Out: input_now = what the player is asking for; input_slot
; Corrupts: AF, BC, DE
input_keyboard:     ld      e,0
                    ld      bc,KEY_ROW_Y_P
                    in      a,(c)
                    cpl
                    ld      d,a                 ; P O I U Y
                    rra                         ; P
                    jr      nc,.o
                    set     INPUT_RIGHT_B,e
.o:                 rra                         ; O
                    jr      nc,.forward
                    set     INPUT_LEFT_B,e

.forward:           ld      bc,KEY_ROWS_A_ENTER
                    in      a,(c)
                    cpl
                    and     $1F
                    jr      z,.jump
                    set     INPUT_FORWARD_B,e

.jump:              ld      bc,KEY_ROW_Q_T
                    in      a,(c)
                    cpl
                    ld      b,a                 ; Q W E R T
                    and     $15                 ; Q, E and T
                    ld      c,a
                    ld      a,d
                    and     $08                 ; U
                    or      c
                    jr      z,.fire
                    set     INPUT_JUMP_B,e
.fire:              ld      a,b
                    and     $0A                 ; W and R
                    ld      c,a
                    ld      a,d
                    and     $14                 ; I and Y
                    or      c
                    jr      z,input_done
                    set     INPUT_FIRE_B,e

                    ;; NB: fall through into input_done -- input_stick_done


; The bottom row, whatever is steering: carrying (carry.s). Z, X, C, V and B
; choose slot 1 to 5, N picks up or puts down, and M uses what is in the slot.
; Every stick reader in engine/input.s ends here too.
;
; In:  E = what the reader made of it
; Out: input_now = that, with INPUT_PICKUP_DIR for N and INPUT_USE for M;
;      input_slot = 1 to 5 for the first of Z X C V B held, or 0
; Corrupts: AF, BC, DE
input_stick_done:
input_done:         ld      bc,KEY_ROW_SPACE_B
                    in      a,(c)
                    cpl
                    ld      d,a                 ; SPACE SYM M N B
                    bit     3,a                 ; N
                    jr      z,.use
                    set     INPUT_PICKUP_DIR_B,e
.use:               bit     2,d                 ; M
                    jr      z,.slots
                    set     INPUT_USE_B,e

.slots:             ld      bc,KEY_ROW_SHIFT_V
                    in      a,(c)
                    cpl
                    rra                         ; past CAPS SHIFT: Z X C V
                    and     $0F
                    bit     4,d                 ; and B, the fifth
                    jr      z,.which
                    or      $10
.which:             ld      c,0
                    or      a
                    jr      z,.slot
.find:              inc     c                   ; the lowest held
                    rra
                    jr      nc,.find
.slot:              ld      a,c
                    ld      (input_slot),a
                    jp      input_store

input_slot:         DB      0
