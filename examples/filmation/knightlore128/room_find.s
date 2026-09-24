; ---------------------------------------------------------------------------
; Finding a room's record, which on the 128K is in another bank.
;
; room_list.s, the rooms themselves, is in bank 4 at $C000, where the castle can
; grow without taking room from anything else. It is paged in only here. The
; record that is wanted is copied out into room_record, and bank 0 goes back
; before anything else runs, because room_build goes on to place graphics, and
; the graphics are in bank 0. The templates the record names stay in the $6000
; region, in room_data.s, which is always there.
;
; The stack is below $C000, in bank 2, so paging bank 0 out here does not take
; the return address with it.
; ---------------------------------------------------------------------------

ROOM_BANK           EQU     4

; A copy of the room being built: its number, its skip, its attribute byte and
; its body. room_build walks it with DE from start to finish, and nothing
; writes to it but room_find.
ROOM_RECORD_SIZE    EQU     ROOM_MAX_BODY + 3
room_record:        DS      ROOM_RECORD_SIZE


; Find a room's record, by walking the list and comparing each record's own
; number. That is how Knight Lore does it -- find_screen at $D3CF -- and for
; the reason its author will have had: an index over all 256 numbers is 512
; bytes to hold 128 rooms, and half of it is zero. The walk is a few hundred
; T-states and it happens once, when the room changes.
;
; Each record says how far it is to the next, so a step is one add. And it
; never has to ask whether the list has ended: the records are in ascending
; order and the last one is room $FF -- rooms_source.py asserts both -- so the walk
; always reaches a number at least the one it wants, and stops there.
;
; In:  C = the room wanted
; Out: carry set and HL -> room_record, a copy of its record; carry clear if
;        there is no such room. Bank 0 is at $C000 either way.
; Corrupts: A, DE
room_find:          ld      a,ROOM_BANK
                    call    page_in
                    ld      hl,room_list
                    ld      d,0
.next:              ld      a,(hl)
                    cp      c
                    jr      nc,.here            ; this room, or already past it
                    inc     hl
                    ld      e,(hl)              ; the skip, counted from its own byte
                    add     hl,de
                    jr      .next
.here:              jr      nz,.none            ; past it: no such room

                    ; The record is its number and then the skip's worth of
                    ; bytes from the skip on. rooms_source.py keeps every skip
                    ; below ROOM_MAX_BODY + 3, so the count cannot wrap to 0.
                    push    bc
                    inc     hl
                    ld      c,(hl)
                    dec     hl
                    ld      b,d
                    inc     c
                    ld      de,room_record
                    ldir
                    call    room_templates_copy
                    pop     bc
                    ld      a,PAGE_PLAY
                    call    page_in
                    ld      hl,room_record
                    scf
                    ret

.none:              ld      a,PAGE_PLAY         ; page_in's OR leaves carry
                    jp      page_in             ; clear, which is the answer


; ---------------------------------------------------------------------------
; The templates the room in room_record names, copied out of bank 4 into
; room_templates, with room_bg_at and room_fg_at pointed at the copies -- which
; is where room_build looks them up, by the index the record gives. The
; templates themselves live in bank 4 with the rooms (room_list.s), because
; both games' together no longer fit anywhere that is always paged in; a room
; names only a handful, ROOM_TEMPLATES_MOST bytes at most.
;
; A template named twice -- a group of blocks split in two -- is copied twice,
; and the table points at the second. Only room_build reads either, and only
; while the room is being built.
;
; In:  room_record = the room's record; bank 4 at $C000
; Out: nothing
; Corrupts: AF, BC, DE, HL
room_templates_copy:
                    ld      de,room_templates
                    ld      hl,room_record + 1
                    ld      a,(hl)              ; the skip
                    sub     2
                    ld      c,a                 ; the body's bytes
                    inc     hl
                    ld      a,(hl)              ; the attribute
                    inc     hl                  ; -> the body
                    ASSERT  ROOM_SCN_SHIFT == 5
                    rlca
                    rlca
                    rlca
                    and     7                   ; the scenery entries
                    jr      z,.objects
                    ld      b,a

.scenery:           ld      a,(hl)              ; a template, then where it leads
                    inc     hl
                    inc     hl
                    dec     c
                    dec     c
                    push    hl
                    push    bc
                    ld      hl,SCENERY_STRIDE
                    ld      (room_template_stride),hl
                    ld      hl,background_type_tbl
                    ld      bc,room_bg_at
                    call    room_template_one
                    pop     bc
                    pop     hl
                    djnz    .scenery

.objects:           ld      a,c                 ; groups: a template, a count,
                    or      a                   ; then that many positions
                    ret     z
                    ld      a,(hl)
                    inc     hl
                    ld      b,(hl)              ; the count
                    inc     hl
                    push    bc
                    ld      c,b
                    ld      b,0
                    add     hl,bc               ; past the positions
                    pop     bc
                    push    hl
                    ld      h,a                 ; the template, for a moment
                    ld      a,c
                    sub     2
                    sub     b
                    ld      c,a                 ; what is left of the body
                    ld      a,h
                    push    bc
                    ld      hl,OBJECT_STRIDE
                    ld      (room_template_stride),hl
                    ld      hl,block_type_tbl
                    ld      bc,room_fg_at
                    call    room_template_one
                    pop     bc
                    pop     hl
                    jr      .objects

SCENERY_STRIDE      EQU     8                   ; as rooms_source.py writes them
OBJECT_STRIDE       EQU     6
room_template_stride: DW    0


; One template copied, and its entry in a live table pointed at the copy.
;
; In:  A  = its index
;      HL -> the table of where each is, in bank 4
;      BC -> the live table
;      DE -> where the copy goes
;      room_template_stride = the bytes in each of its pieces
; Out: DE -> past the copy
; Corrupts: AF, BC, HL
room_template_one:  push    de                  ; the copy's address
                    add     a,a
                    push    af
                    ld      e,a
                    ld      d,0
                    add     hl,de               ; -> where it is
                    ld      a,(hl)
                    inc     hl
                    ld      h,(hl)
                    ld      l,a                 ; HL -> the template
                    pop     af
                    ld      e,a
                    ld      d,0
                    ex      de,hl               ; HL = two a template, DE -> it
                    add     hl,bc               ; -> its live entry
                    pop     bc                  ; the copy's address
                    ld      (hl),c
                    inc     hl
                    ld      (hl),b
                    ex      de,hl               ; HL -> the template
                    ld      d,b
                    ld      e,c                 ; DE -> the copy
.piece:             ld      a,(hl)              ; a graphic of 0 ends it
                    or      a
                    jr      z,.end
                    ld      bc,(room_template_stride)
                    ldir
                    jr      .piece
.end:               ldi
                    ret
