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

                    ld      a,PLAYER_START_ROOM
                    ld      (room_number),a
                    ld      (room_shown),a

.enter:             ld      a,(room_number)
                    call    room_build
                    jr      c,.entered
                    ld      a,(room_shown)      ; no such room: stay where we are
                    ld      (room_number),a
                    jr      .loop

.entered:           ld      a,(room_number)
                    ld      (room_shown),a
                    ld      ix,player
                    ld      b,PLAYER_START_U
                    ld      c,PLAYER_START_V
                    ld      a,(room_floor_z)
                    call    character_add

                    ; Poke room_number from the debugger and the game moves
                    ; house, which is the only way to change rooms until
                    ; player_exit exists to read room_door_to.
.loop:              ld      a,(room_number)
                    ld      hl,room_shown
                    cp      (hl)
                    jr      nz,.enter

                    ; Nothing waits for the frame, and interrupts stay off for
                    ; good: every part of the drawing path repurposes SP, so
                    ; one taken mid-blit would push a return address into a
                    ; sprite. The keyboard is read directly rather than through
                    ; the ROM's scan, so nothing needs them.
                    call    movers_step
                    call    player_step
                    call    redraw_flush        ; whatever the turn left waiting
                    call    turn_pace
                    jr      .loop


; Which room is wanted, and which is up. room_build is the only thing that
; moves one to the other.
room_number:        DB      PLAYER_START_ROOM
room_shown:         DB      PLAYER_START_ROOM
