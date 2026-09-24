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
                    pop     bc
                    ld      a,PAGE_PLAY
                    call    page_in
                    ld      hl,room_record
                    scf
                    ret

.none:              ld      a,PAGE_PLAY         ; page_in's OR leaves carry
                    jp      page_in             ; clear, which is the answer
