; ---------------------------------------------------------------------------
; Where it starts, and the turn it goes round.
;
; This is the smallest thing that stands up: it builds one room, puts Sabreman
; in it, and then loops. There is no menu yet, no lives, no game to win or
; lose -- what it proves is that the extracted data, the room builder and the
; shared engine agree with each other well enough to draw a Pentagram room and
; walk about in it.
;
; PLAYER_START_ROOM is the room the original itself starts in, which was read
; off it rather than picked: forcing a build and reading the room number the
; builder searched for gives 92, and its doorways lead to 91, 93 and 107,
; which is what rooms.json holds for it.
; ---------------------------------------------------------------------------

PLAYER_START_ROOM   EQU     92
PLAYER_START_U      EQU     128             ; the middle of the floor
PLAYER_START_V      EQU     128

start:              di
                    ld      sp,STACK_TOP        ; off the contended stack, first thing
                    xor     a                   ; the border black and the speaker
                    out     ($FE),a             ; still

                    ; The two rotation buffers he keeps for good. This has to
                    ; happen with the arena empty, which it is here and would
                    ; not be after a room had been built.
                    ld      ix,player
                    call    character_keep

                    ; A new game: four lives on the panel, no score, and one of
                    ; the four rooms the original starts in, at random -- $C2CE
                    ; picks from $C2E8 by the random byte.
new_game:           ld      a,$04
                    ld      (player_lives),a
                    xor     a
                    ld      (score),a
                    ld      (score + 1),a
                    ld      (score + 2),a
                    ld      (player_state),a
                    ld      (player_touched),a
                    dec     a
                    ld      (enter_dir),a       ; he does not walk in
                    ld      a,r
                    and     3
                    ld      e,a
                    ld      d,0
                    ld      hl,start_rooms
                    add     hl,de
                    ld      a,(hl)
                    ld      (room_number),a
                    cpl
                    ld      (room_shown),a      ; anything but it: build it

.enter:             ld      a,(room_number)
                    call    room_build
                    jr      c,.entered
                    ld      a,(room_shown)      ; no such room: stay where we are
                    ld      (room_number),a
                    ld      a,$FF
                    ld      (enter_dir),a       ; and nobody walking in
                    jr      .loop

.entered:           ld      a,(room_number)
                    ld      (room_shown),a
                    call    room_seen           ; for the percentage at the end
                    ld      ix,player
                    ld      hl,room_again
                    bit     0,(hl)
                    jr      nz,.again           ; the room over: where he came in

                    ld      b,PLAYER_START_U
                    ld      c,PLAYER_START_V
                    ld      a,(room_floor_z)
                    ld      hl,enter_dir
                    bit     7,(hl)              ; $FF: he did not walk in
                    call    z,player_entry      ; walked in: by the opposite door
                    ld      (room_entry_at),bc  ; kept for starting the room over
                    ld      (room_entry_z),a
                    jr      .add

.again:             ld      (hl),0
                    ld      bc,(room_entry_at)
                    ld      a,(room_entry_z)
.add:               push    af
                    push    bc
                    call    flyer_room_enter    ; the two slots for the sky
                    pop     bc
                    pop     af
                    ld      ix,player
                    call    character_add
                    call    panel_on            ; and the panel, now it is up

                    ; player_exit changes room_number when he walks out through
                    ; a doorway, and this notices. Poking it from the debugger
                    ; works the same way.
.loop:              ld      a,(room_number)
                    ld      hl,room_shown
                    cp      (hl)
                    jr      nz,.enter

                    ; Nothing waits for the frame, and interrupts stay off for
                    ; good: every part of the drawing path repurposes SP, so
                    ; one taken mid-blit would push a return address into a
                    ; sprite. The keyboard is read directly rather than through
                    ; the ROM's scan, so nothing needs them.
                    call    flyer_step          ; something from the sky?
                    call    movers_step
                    call    player_step
                    call    redraw_flush        ; whatever the turn left waiting
                    call    turn_pace

                    ; His death has played out: a life, and the room built
                    ; again around him where he came in -- or with none left,
                    ; a new game. $C2EC: DEC, and JP M to the end.
                    ld      a,(player_state)
                    cp      PLAYER_DEAD
                    jr      nz,.loop
                    xor     a
                    ld      (player_state),a
                    ld      (player_touched),a
                    ld      a,(player_lives)
                    sub     1
                    daa
                    jp      c,game_over         ; there were none left
                    ld      (player_lives),a
                    ld      a,1
                    ld      (room_again),a
                    jp      .enter


; Which room is wanted, and which is up. room_build is the only thing that
; moves one to the other.
room_number:        DB      PLAYER_START_ROOM
room_shown:         DB      PLAYER_START_ROOM

; Whether the room is being started over, and where he stood when he came into
; it, as .entered found it.
room_again:         DB      0

; Where a game can start: $C2E8.
start_rooms:        DB      51, 92, 100, 12
room_entry_at:      DW      0                   ; C - V, B - U, as BC holds them
room_entry_z:       DB      0
