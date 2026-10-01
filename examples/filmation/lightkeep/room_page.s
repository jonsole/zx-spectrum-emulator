; ---------------------------------------------------------------------------
; The room page: bank 0, holding what the room being played draws.
;
; Bank 0 is paged in for the whole of play, and every sprite drawn is read from
; it. It starts with the resident sprites, assembled there for good -- the
; knight and everything else the code draws by number -- and the rest of it,
; from room_page on, is refilled each time a room is entered with that room's
; own: its walls, its doorways, its scenery and its movers, copied out of the
; library in banks 1, 3 and 7. sprite_source.py decides which sprites are which
; (ROOM_GROUPS in sprite_sheet.py) and lists what each room loads.
;
; The library and the page are both at $C000, so a record cannot be copied
; from one to the other directly. It goes through the rotation arena, past the
; knight's two kept buffers: nothing else is in the arena while a room is being
; built, since room_build hands the rest of it back first thing afterwards.
; ---------------------------------------------------------------------------

; The largest record has to fit in the arena past the knight's two buffers,
; which are a few hundred bytes between them.
                    ASSERT  LIBRARY_LARGEST <= SHIFT_ARENA_SIZE - 1024

; Load a room's sprites into the page, and point the graphics that draw them at
; where they now are. Every other library graphic is pointed at sprite_missing,
; so that one the room did not load draws a checked square rather than
; whatever the page last held.
;
; In:  C = the room number
; Out: bank 0 at $C000
; Corrupts: AF, BC, DE, HL
room_page_fill:     ld      a,ROOM_BANK
                    call    page_in

                    ; Every graphic back to how the game starts: the resident
                    ; sprites, and sprite_missing for the rest.
                    push    bc
                    ld      hl,sprite_base
                    ld      de,sprite_table
                    ld      bc,SPRITE_TABLE_SIZE
                    ldir
                    pop     bc

                    ; The room's list: a count, then library numbers.
                    ld      l,c
                    ld      h,(high room_sprites_at) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l
                    ld      h,(hl)
                    ld      l,a
                    ld      de,room_page        ; where the first one goes
                    ld      a,(hl)
                    or      a
                    jr      z,.done
                    ld      b,a

.sprite:            inc     hl
                    push    bc
                    push    hl
                    ld      c,(hl)              ; its library number
                    ld      l,c
                    ld      h,high library_bank
                    ld      a,(hl)              ; the bank it is in
                    ld      l,c
                    ld      h,(high library_at) / 2
                    add     hl,hl
                    ld      c,(hl)
                    inc     l
                    ld      h,(hl)
                    ld      l,c                 ; HL -> its record
                    call    page_in

                    ; The graphics that draw it, pointed at where it is going.
                    ; sprite_table is in bank 5, so it is there whatever bank is
                    ; paged in.
                    ld      b,(hl)
.graphic:           inc     hl
                    push    hl
                    ld      l,(hl)
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      (hl),e
                    inc     l
                    ld      (hl),d
                    pop     hl
                    djnz    .graphic

                    ; Then the record, into the arena and out again.
                    inc     hl
                    ld      c,(hl)
                    inc     hl
                    ld      b,(hl)
                    inc     hl                  ; HL -> the record, BC its length
                    push    de
                    push    bc
                    ld      de,(shift_kept)     ; the arena past the knight
                    push    de
                    ldir
                    ld      a,PAGE_PLAY
                    call    page_in
                    pop     hl
                    pop     bc
                    pop     de
                    ldir                        ; DE -> past it in the page

                    ; The next one on a four-byte boundary: the blit steps
                    ; through a record's first bytes with INC L.
                    ld      a,e
                    add     a,3
                    ld      e,a
                    jr      nc,.round
                    inc     d
.round:             ld      a,e
                    and     $FC
                    ld      e,a

                    ld      a,ROOM_BANK         ; back for the next number
                    call    page_in
                    pop     hl
                    pop     bc
                    djnz    .sprite

.done:              ld      a,PAGE_PLAY
                    jp      page_in
