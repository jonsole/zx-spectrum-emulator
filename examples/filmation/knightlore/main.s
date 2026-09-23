; ---------------------------------------------------------------------------
; Knight Lore's main loop: the menu, a new game, and one turn after another.
; ---------------------------------------------------------------------------

; Interrupts stay off for good. Every part of the drawing path repurposes
; SP as a data pointer -- object_update walks sprite data with it,
; objects_draw_all reads object records with it, the blitters read their
; sprites with it, and redraw_view clears the view buffer by pushing
; through it. An interrupt taken during any of those would push a return
; address into whatever SP was aimed at.
;
; In:  nothing
; Out: nothing -- it never returns
; Corrupts: everything
start:              di
                    ld      sp,STACK_TOP        ; off the contended stack, first thing
                    xor     a                   ; the border black and the speaker
                    out     ($FE),a             ; still, as clear_scrn leaves them

                    ; The menu first, every time: a game that ends comes back
                    ; through here, and the game itself goes back to its menu.
                    call    menu_run

                    ; A game from the beginning -- which is also where losing the
                    ; last life comes back to.
                    ld      a,r                 ; init_start_location: one of four
                    and     3
                    ld      e,a
                    ld      d,0
                    ld      hl,start_rooms
                    add     hl,de
                    ld      a,(hl)
                    ld      (room_number),a
                    ld      a,$FF
                    ld      (enter_dir),a
                    ld      (entered_by),a
                    ld      a,PLAYER_LIVES
                    ld      (player_lives),a
                    ld      a,PLAYER_APPEARING
                    ld      (player_state),a
                    xor     a
                    ld      (player_touched),a
                    ld      (days),a
                    ld      (night),a
                    ld      (player_change),a
                    ld      a,SUN_RISE
                    ld      (sun_x),a
                    ld      a,PLAYER_LEGS_GFX
                    call    player_form
                    ld      ix,player
                    call    character_keep      ; his rotation buffers, for good
                    ld      hl,end_rooms_seen   ; no room seen yet
                    ld      de,end_rooms_seen + 1
                    ld      bc,END_ROOMS - 1
                    ld      (hl),0
                    ldir
                    call    special_init

        ; Nothing goes into a room that was not built. room_build leaves the
        ; old room up when it is handed a number no record carries,
        ; and the old room's objects are still in the list -- so adding the
        ; characters again would insert records that are already there, and
        ; an object compared against itself ties, which makes the scan take
        ; itself as its own insertion point and link its NEXT to itself.
.enter:             call    special_room_leave
                    ld      a,(room_number)
                    call    room_build
                    jr      c,.entered
                    ld      a,(room_shown)      ; stay where we are
                    ld      (room_number),a
                    ld      a,$FF
                    ld      (enter_dir),a       ; and nobody walking in
                    jr      .loop
.entered:           xor     a
                    call    busy_set            ; every room starts quiet
                    ld      a,(room_number)
                    ld      (room_shown),a
                    ld      a,(enter_dir)       ; kept for starting the room over
                    ld      (entered_by),a
                    call    special_room_enter
                    call    player_add

                    ; The room is drawn, still black: now it appears, all at
                    ; once. Then the carried objects and the panel, and the sun
                    ; window on top as it always was -- drawn now rather than in
                    ; the dark, so they are drawn once each: drawing a panel
                    ; piece over itself is not harmless, since a data bit
                    ; outside its mask XORs back off, as it does in the game.
                    call    room_paper
                    call    special_show
                    call    sun_show_all

                    ; Poke room_number from the debugger and the castle turns
                    ; over. The 1 and 2 keys do it from the keyboard, in a
                    ; build with DEBUG_ROOM.
.loop:              ld      a,(room_number)
                    ld      hl,room_shown
                    cp      (hl)
                    jr      nz,.enter

                    ; Nothing waits for the frame. There used to be an
                    ; `ei; halt; di` here, and it cost more than it bought: the
                    ; drawing takes longer than a frame, so the HALT found the
                    ; interrupt already gone and sat out a whole second one --
                    ; the loop ran at 25Hz to stay in step with a raster it was
                    ; never going to keep up with anyway. Knight Lore does not
                    ; wait either.
                    ;
                    ; Interrupts stay off, then, as they are everywhere else in
                    ; the engine: every part of the drawing path repurposes SP,
                    ; so one taken mid-blit would push a return address into a
                    ; sprite. Nothing needs them -- the keyboard is read
                    ; directly, in player_step, rather than through the ROM's
                    ; scan.
                    ;
                    ; He goes before everything else, as he does in the game:
                    ; his two records are the first two slots of its object
                    ; table at $5C08, and it updates them in slot order. It
                    ; matters for a shove. The table he walks into takes his
                    ; step and spends it in the same turn, so it is drawn a
                    ; step clear of him. The other way round, it moved before
                    ; he did, and he was drawn pressed up against it every turn,
                    ; his legs under its top.
                    call    special_step
                    call    player_step
                    call    movers_step
                    call    day_step
                    call    redraw_flush        ; whatever the turn left waiting
                    call    print_room
                IFDEF   DEBUG_ROOM
                    call    room_keys
                ENDIF
                    call    busy_check          ; before turn_pace resets the count
                    call    turn_pace
                    jr      .loop

KEY_ROOMS           EQU     $F7FE       ; 1 bit 0, 2 bit 1

                IFDEF   DEBUG_ROOM

; 1 goes back a room, 2 on to the next -- with DEBUG_ROOM defined,
; `build.py --debug-room`, which is also what puts the room number in the
; corner. It is behind that option because the game wants those keys: the
; numbers pick up and put down, and an Interface II joystick is 1 to 5.
;
; Most numbers between one room and the next have no room against them, so
; this steps over them rather than making you press the key twenty times: it
; asks room_find for each number in turn. A room always finds itself again if
; there is nothing else, so the walk cannot run away.
;
; room_find is itself a walk now, so an unlucky press can cost a few thousand
; T-states. It is a key press, and it only ever happens between rooms.
;
; One room a press, not one a frame -- the whole row is compared against what
; it read last time, so holding the key down does nothing after the first.
;
; In:  nothing
; Out: room_number = the room to go to, if a key was pressed
; Corrupts: AF, BC, E, HL
room_keys:          ld      bc,KEY_ROOMS
                    in      a,(c)
                    cpl                         ; a key reads 0 while it is held
                    and     3
                    ld      hl,room_key_held
                    cp      (hl)
                    ld      (hl),a              ; LD does not touch the flags
                    ret     z                   ; nothing has changed
                    and     a
                    ret     z                   ; ...and nothing is held now
                    rra
                    ld      e,-1                ; 1: back a room
                    jr      c,.step
                    ld      e,1                 ; 2: on to the next
.step:              ld      a,(room_number)
.try:               add     a,e
                    ld      c,a
                    push    de
                    push    bc
                    call    room_find
                    pop     bc
                    pop     de
                    ld      a,c                 ; the number we tried
                    jr      nc,.try             ; no room there: keep going
                    ld      (room_number),a
                    ret

room_key_held:      DB      0
                ENDIF


; Which room to build, and the one on the screen. A game begins in one of four,
; chosen at random -- Knight Lore's start_locations at $D1E2.
start_rooms:        DB      $2F, $44, $B3, $8F
room_number:        DB      $B3
room_shown:         DB      $B3

; Which side of the room being built the player is walking in through, or $FF
; for a room he did not walk into. player_entry spends it and puts it back.
enter_dir:          DB      $FF
