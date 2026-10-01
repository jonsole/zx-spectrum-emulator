; ---------------------------------------------------------------------------
; The end of the game -- game_over at $BA22 and what it prints.
;
; For now one thing finishes a game: the last life lost. The screen goes black
; and the game says how it went -- how much of the castle he saw, and what it
; makes of that -- and waits for a key before starting again. Knight Lore's
; screen also has the day it ended on and the charms in the pot, and a verse
; when the wizard has them all; this game has neither clock nor pot, and its
; own quest and ending are stage 8 of README.md.
;
; The percentage is Knight Lore's own sum, calc_and_display_percent, less the
; charms: every room seen counts one, against all the rooms (ROOM_COUNT). The
; rooms come out of a bitmap marked as each is built.
;
; The words are the game's, character codes and all: our font is its font, so
; a code is its own index. The colours and the places are its too.

END_LINES           EQU     4
END_RATING_ATTR     EQU     $42
END_ROOMS           EQU     32                  ; a bit a room, 256 of them

; A line: the attribute, the character row and column, then the characters,
; the last of them carrying bit 7.
end_lines:          DB      $47, 4, 11
                    DB      $10,$0A,$16,$0E,$26,$26,$18,$1F,$0E,$1B + $80
                    DB      $45, 10, 6          ; GAME  OVER
                    DB      $19,$0E,$1B,$0C,$0E,$17,$1D,$0A,$10,$0E,$26,$18,$0F,$26
                    DB      $1A,$1E,$0E,$1C,$1D + $80
                    DB      $45, 12, 8          ; PERCENTAGE OF QUEST
                    DB      $0C,$18,$16,$19,$15,$0E,$1D,$0E,$0D,$26,$26,$26,$26,$26
                    DB      $27 + $80
                    DB      $44, 17, 9          ; COMPLETED     %
                    DB      $18,$1F,$0E,$1B,$0A,$15,$15,$26,$1B,$0A,$1D,$12,$17,$10 + $80
                                                ; OVERALL RATING

; What it makes of the game: which quarter of the castle he saw. Knight Lore's
; own words, in its own order; its other four, for when the wizard had
; everything, are not this game's.
end_ratings_at:     DB      end_ratings.poor - end_ratings
                    DB      end_ratings.average - end_ratings
                    DB      end_ratings.fair - end_ratings
                    DB      end_ratings.good - end_ratings
end_ratings:
.poor:              DB      $26,$26,$26,$19,$18,$18,$1B + $80
.average:           DB      $26,$0A,$1F,$0E,$1B,$0A,$10,$0E + $80
.fair:              DB      $26,$26,$26,$0F,$0A,$12,$1B + $80
.good:              DB      $26,$26,$26,$10,$18,$18,$0D + $80


; The tune, and the notes it and the menu's need. A note is its number
; in bits 0 to 5 and how long to hold it in 6 and 7; the game's frequency table
; has an entry for every note in five octaves, and these are the fifteen the
; three tunes play -- the half period to count out, and how many of them a
; beat is. Knight Lore's second tune, for the end of the quest, is left out
; with its notes still here. The menu's own notes are in menu.s, with the menu.
tune_over:          DB      $2E,$17,$27,$17,$2E,$17,$27,$17,$2C,$19,$27,$19,$2C,$19
                    DB      $27,$19,$2A,$1B,$27,$1B,$2A,$1B,$27,$1B,$2A,$1B,$27,$1B
                    DB      $2A,$1B,$27,$1B,$FF

TUNE_NOTES          EQU     17
tune_notes:         DB      $14
                    DW      $0452
                    DB      $19
                    DB      $16
                    DW      $03F6
                    DB      $1C
                    DB      $17
                    DW      $03CB
                    DB      $1D
                    DB      $19
                    DW      $037D
                    DB      $21
                    DB      $1A
                    DW      $0359
                    DB      $23
                    DB      $1B
                    DW      $0338
                    DB      $25
                    DB      $1C
                    DW      $0318
                    DB      $27
                    DB      $1D
                    DW      $02FA
                    DB      $29
                    DB      $1E
                    DW      $02DD
                    DB      $2C
                    DB      $20
                    DW      $02A9
                    DB      $31
                    DB      $22
                    DW      $027B
                    DB      $37
                    DB      $24
                    DW      $0251
                    DB      $3E
                    DB      $25
                    DW      $023F
                    DB      $41
                    DB      $27
                    DW      $021C
                    DB      $49
                    DB      $2A
                    DW      $01EF
                    DB      $57
                    DB      $2C
                    DW      $01D5
                    DB      $62
                    DB      $2E
                    DW      $01BD
                    DB      $6E

end_rooms_seen:     DS      END_ROOMS           ; one bit a room, set as it is built
end_ink:            DB      0                   ; the colour the line being printed is in


; Mark this room as seen, for the percentage.
;
; In:  A = its number
; Out: nothing
; Corrupts: AF, BC, HL
room_seen:          ld      c,a
                    and     7
                    inc     a
                    ld      b,a
                    ld      a,1
.bit:               rlca                        ; its bit within the byte
                    djnz    .bit
                    ld      b,a
                    ld      a,c
                    rrca
                    rrca
                    rrca
                    and     $1F                 ; and which byte
                    ld      c,a
                    ld      hl,end_rooms_seen
                    ld      a,l
                    add     a,c
                    ld      l,a
                    jr      nc,.page            ; the table can straddle a page: it
                    inc     h                   ; did once the menu and the end
.page:              ld      a,(hl)              ; screens moved down to $6000
                    or      b
                    ld      (hl),a
                    ret


; The end. Nothing comes back: it starts a new game.
;
; In:  nothing
; Out: nothing -- it never returns
; Corrupts: everything
game_over:          di
                    ld      sp,STACK_TOP
                    ld      hl,end_lines
                    ld      b,END_LINES
                    ld      c,0
                    call    end_show
                    call    end_percent
                    call    end_rating

                    ; And the game's own dirge over it, which a key cuts short --
                    ; but only a key pressed for it. Whatever was held when he
                    ; died has to be let go first, as the game waits at $BA87,
                    ; or the walk he died in stops the tune before its first note.
.release:           call    end_key
                    jr      nz,.release
                    ld      de,tune_over
                    call    tune_play

                    ; Then a while to read it, which a key cuts short, and back
                    ; to the start without being asked -- $BA93 to $BA98.
                    call    end_pause
                    jp      start


; A screen of the game's words: one colour, and then the lines.
;
; In:  HL -> the lines
;      B  = how many
;      C  = the colour to lay under them
; Out: HL -> past the lines
; Corrupts: AF, B, DE
end_show:           ld      a,c                 ; before room_wipe, which
                    ld      (.paper + 1),a      ; counts BC down to nothing
                    push    bc
                    push    hl
                    call    room_wipe
.paper:             ld      a,0                 ; patched: black on black for the
                    ld      hl,$5800            ; end screens, whose words bring
                    ld      de,$5801            ; their own colours; the menu lays
                    ld      bc,767              ; its frame's yellow under all
                    ld      (hl),a
                    ldir
                    pop     hl
                    pop     bc
.line:              push    bc
                    ld      a,(hl)
                    ld      (end_ink),a
                    inc     hl
                    ld      d,(hl)
                    inc     hl
                    ld      e,(hl)
                    inc     hl
                    call    end_string
                    pop     bc
                    djnz    .line
                    ret


; Long enough to read it, or until a key says otherwise -- wait_for_key_press.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, D, HL
end_pause:          ld      d,8                 ; not B: end_key reads the keyboard
.turn:              ld      hl,0                ; through BC
.spin:              call    end_key
                    ret     nz
                    dec     hl
                    ld      a,h
                    or      l
                    jr      nz,.spin
                    dec     d
                    jr      nz,.turn
                    ret


; What Knight Lore gives engine/tune.s, which plays its two tunes and the
; menu's: where a note's pitch comes from, and what counts as a key.
;
; A note's entry is four bytes -- the note itself, the half period as B DJNZs
; and C runs of 256, and how long one beat of it lasts -- and the table holds
; only the notes these tunes play, so it is searched rather than indexed.
;
; In:  A = the note, 1 to 63
; Out: carry set: B, C = the half period and E = one beat
;      carry clear: a note the tunes never play, which is then skipped
; Corrupts: D, HL, and B and E when the carry is clear
tune_note_at:       ld      hl,tune_notes
                    ld      b,TUNE_NOTES
.find:              cp      (hl)
                    jr      z,.found
                    ld      de,4
                    add     hl,de
                    djnz    .find
                    or      a                   ; no entry: carry clear
                    ret

.found:             inc     hl
                    ld      b,(hl)              ; the half period: B of them, C
                    inc     hl                  ; times over, as the game counts it
                    ld      c,(hl)
                    inc     hl
                    ld      e,(hl)              ; and how long one beat is
                    scf
                    ret


; Is any key down? Z if none is -- the game asks the same way, at $B5F7 with
; nothing selected: every half-row at once, in one read.
;
; In:  nothing
; Out: Z set if no key is down
; Corrupts: A, BC
end_key:            ld      bc,$00FE
                    in      a,(c)
                    cpl
                    and     $1F
                    ret


; ...which is also what stops a tune, for engine/tune.s. Named after end_key
; rather than before it: an EQU of a label still to come takes the value it
; had in the pass before, which sjasmplus warns about.
tune_key            EQU     end_key


; A string in end_ink, from the character row and column, the last character
; carrying bit 7.
;
; In:  HL -> the characters
;      D  = the row
;      E  = the column
; Out: HL -> past the string
;      E  = the column after it
; Corrupts: AF, BC
end_string:         ld      a,(hl)
                    and     $7F
                    push    hl
                    push    de
                    push    af                  ; end_at works in A
                    call    end_at
                    pop     af
                    call    print_char
                    pop     de
                    push    de
                    call    end_attr_at
                    ld      a,(end_ink)
                    ld      (hl),a
                    pop     de
                    pop     hl
                    inc     e
                    bit     7,(hl)
                    inc     hl
                    jr      z,end_string
                    ret


; A byte in two digits, in the gap a line left for it.
;
; In:  A = the byte
;      D = the row
;      E = the column
; Out: nothing
; Corrupts: AF, BC, DE, HL
end_number:         push    af
                    call    end_at
                    pop     af
                    jp      print_hex


; The percentage of the castle seen -- calc_and_display_percent. Knight Lore
; adds $A41A for each room seen and two for each charm: in sixteen bits, a
; hundredth of the 156 that its 128 rooms and fourteen charms add up to,
; carried into A in BCD as it goes. The $28 at the end is what rounds the last
; of them up to 100. Here there are no charms, and both come from END_TOTAL,
; so they follow the castle as it grows.
;
; E counts the rooms, so the total has to fit a byte.
END_TOTAL           EQU     ROOM_COUNT
END_STEP            EQU     6553600 / END_TOTAL                 ; a 65536th of a whole
END_ROUND           EQU     6553600 - END_TOTAL * END_STEP      ; what the last falls short by
                    ASSERT  END_TOTAL < 256
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
end_percent:        call    end_seen
                    ld      bc,END_STEP
                    ld      hl,0
                    xor     a
.count:             add     hl,bc
                    adc     a,0
                    daa
                    dec     e
                    jr      nz,.count
                    ld      bc,END_ROUND
                    add     hl,bc
                    adc     a,0
                    daa

                    push    af
                    ld      de,12 * 256 + 19
                    call    end_number
                    pop     af
                    ld      a,0
                    adc     a,a                 ; the hundred, if it got that far
                    ret     z
                    ld      de,12 * 256 + 18
                    jp      end_number


; What it makes of it: the quarter of the castle he saw. Knight Lore took the quarter as the count over 32, which
; is a quarter of its 128 rooms; this compares with the quarters of
; ROOM_COUNT, which comes to the same for 128.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
end_rating:         call    end_seen
                    ld      a,e
                    ld      c,0
                    cp      ROOM_COUNT / 4
                    jr      c,.quarter
                    inc     c
                    cp      ROOM_COUNT / 2
                    jr      c,.quarter
                    inc     c
                    cp      ROOM_COUNT * 3 / 4
                    jr      c,.quarter
                    inc     c
.quarter:           ld      e,c
                    ld      d,0
                    ld      hl,end_ratings_at
                    add     hl,de
                    ld      e,(hl)
                    ld      d,0
                    ld      hl,end_ratings
                    add     hl,de
                    ld      a,END_RATING_ATTR
                    ld      (end_ink),a
                    ld      de,19 * 256 + 11
                    jp      end_string


; How many rooms he saw, less the one he started in.
;
; In:  nothing
; Out: E = the count
; Corrupts: AF, BC, HL
end_seen:           ld      hl,end_rooms_seen
                    ld      c,END_ROOMS
                    ld      e,0
.byte:              ld      a,(hl)
                    inc     hl
                    ld      b,8
.bit:               rrca
                    jr      nc,.next
                    inc     e
.next:              djnz    .bit
                    dec     c
                    jr      nz,.byte
                    dec     e
                    ret


