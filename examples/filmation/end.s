; ---------------------------------------------------------------------------
; The end of the game -- game_over at $BA22 and what it prints.
;
; Three things finish a game: the last life lost, the fortieth day, and the
; wizard getting everything he asked for. Whichever it was, the screen goes
; black and the game says how it went -- the day it ended on, how much of the
; quest was finished, how many charms went into the pot, and what it makes of
; that -- and waits for a key before starting again.
;
; The percentage is the game's own sum, calc_and_display_percent: every room
; seen counts one and every charm two, against 128 rooms and 14 charms, so the
; two together make 100%. The rooms come out of a bitmap marked as each is
; built. Exploring counts for as much as collecting.
;
; The words are the game's, character codes and all: our font is its font, so
; a code is its own index. The colours and the places are its too.

END_LINES           EQU     6
END_RATING_ATTR     EQU     $42
END_ROOMS           EQU     32                  ; a bit a room, 256 of them

; A line: the attribute, the character row and column, then the characters,
; the last of them carrying bit 7.
end_lines:          DB      $47, 4, 11
                    DB      $10,$0A,$16,$0E,$26,$26,$18,$1F,$0E,$1B + $80
                    DB      $46, 8, 10          ; GAME  OVER
                    DB      $1D,$12,$16,$0E,$26,$26,$26,$26,$0D,$0A,$22,$1C + $80
                    DB      $45, 10, 6          ; TIME    DAYS
                    DB      $19,$0E,$1B,$0C,$0E,$17,$1D,$0A,$10,$0E,$26,$18,$0F,$26
                    DB      $1A,$1E,$0E,$1C,$1D + $80
                    DB      $45, 12, 8          ; PERCENTAGE OF QUEST
                    DB      $0C,$18,$16,$19,$15,$0E,$1D,$0E,$0D,$26,$26,$26,$26,$26
                    DB      $27 + $80
                    DB      $43, 14, 6          ; COMPLETED     %
                    DB      $0C,$11,$0A,$1B,$16,$1C,$26,$0C,$18,$15,$15,$0E,$0C,$1D
                    DB      $0E,$0D,$26,$26,$26 + $80
                    DB      $44, 17, 9          ; CHARMS COLLECTED
                    DB      $18,$1F,$0E,$1B,$0A,$15,$15,$26,$1B,$0A,$1D,$12,$17,$10 + $80
                                                ; OVERALL RATING

; What it makes of the game: which quarter of the castle he saw, and whether
; the wizard ever had everything. The game's own words, in its own order.
end_ratings_at:     DB      end_ratings.poor - end_ratings
                    DB      end_ratings.average - end_ratings
                    DB      end_ratings.fair - end_ratings
                    DB      end_ratings.good - end_ratings
                    DB      end_ratings.excellent - end_ratings
                    DB      end_ratings.marvellous - end_ratings
                    DB      end_ratings.hero - end_ratings
                    DB      end_ratings.adventurer - end_ratings
end_ratings:
.poor:              DB      $26,$26,$26,$19,$18,$18,$1B + $80
.average:           DB      $26,$0A,$1F,$0E,$1B,$0A,$10,$0E + $80
.fair:              DB      $26,$26,$26,$0F,$0A,$12,$1B + $80
.good:              DB      $26,$26,$26,$10,$18,$18,$0D + $80
.excellent:         DB      $0E,$21,$0C,$0E,$15,$15,$0E,$17,$1D + $80
.marvellous:        DB      $16,$0A,$1B,$1F,$0E,$15,$15,$18,$1E,$1C + $80
.hero:              DB      $26,$26,$26,$11,$0E,$1B,$18 + $80
.adventurer:        DB      $0A,$0D,$1F,$0E,$17,$1D,$1E,$1B,$0E,$1B + $80

; And what it says when the wizard has everything -- game_complete_msg, which
; the game shows before the same tally.
END_VERSE_LINES     EQU     6
end_verse:          DB      $47, 7, 8
                    DB      $1D,$11,$0E,$26,$19,$18,$1D,$12,$18,$17,$26,$0C,$0A,$1C
                    DB      $1D,$1C + $80       ; THE POTION CASTS
                    DB      $46, 9, 8
                    DB      $12,$1D,$1C,$26,$16,$0A,$10,$12,$0C,$26,$1C,$1D,$1B,$18
                    DB      $17,$10 + $80       ; ITS MAGIC STRONG
                    DB      $45, 11, 6
                    DB      $0A,$15,$15,$26,$0E,$1F,$12,$15,$26,$16,$1E,$1C,$1D,$26
                    DB      $0B,$0E,$20,$0A,$1B,$0E + $80   ; ALL EVIL MUST BEWARE
                    DB      $44, 13, 6
                    DB      $1D,$11,$0E,$26,$1C,$19,$0E,$15,$15,$26,$11,$0A,$1C,$26
                    DB      $0B,$1B,$18,$14,$0E,$17 + $80   ; THE SPELL HAS BROKEN
                    DB      $43, 15, 10
                    DB      $22,$18,$1E,$26,$0A,$1B,$0E,$26,$0F,$1B,$0E,$0E + $80
                    DB      $42, 17, 6          ; YOU ARE FREE
                    DB      $10,$18,$26,$0F,$18,$1B,$1D,$11,$26,$1D,$18,$26,$16,$12
                    DB      $1B,$0E,$26,$16,$0A,$1B,$0E + $80   ; GO FORTH TO MIRE MARE

; The two tunes, and the notes they need. A note is its number in bits 0 to 5
; and how long to hold it in 6 and 7; the game's frequency table has an entry
; for every note in five octaves, and these are the twelve these two play --
; the half period to count out, and how many of them a beat is.
tune_over:          DB      $2E,$17,$27,$17,$2E,$17,$27,$17,$2C,$19,$27,$19,$2C,$19
                    DB      $27,$19,$2A,$1B,$27,$1B,$2A,$1B,$27,$1B,$2A,$1B,$27,$1B
                    DB      $2A,$1B,$27,$1B,$FF
tune_complete:      DB      $1B,$1D,$1E,$1B,$1D,$1E,$20,$1D,$1E,$20,$22,$1E,$1D,$1E
                    DB      $20,$1D,$1B,$1D,$1E,$1B,$1A,$1B,$1D,$1A,$9B,$FF

TUNE_NOTES          EQU     12
tune_notes:         DB      $17
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
;   A - its number
; Corrupts AF, BC, HL.
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
                    ld      a,(hl)
                    or      b
                    ld      (hl),a
                    ret


; The end. Nothing comes back: it starts a new game.
game_over:          di
                    ld      sp,STACK_TOP

                    ; The spell broken, first, if he broke it.
                    ld      a,(special_count)
                    cp      SPECIAL_WANTED
                    jr      c,.tally
                    ld      hl,end_verse
                    ld      b,END_VERSE_LINES
                    call    end_show
                    ld      de,tune_complete
                    call    tune_play
                    call    end_pause

.tally:             ld      hl,end_lines
                    ld      b,END_LINES
                    call    end_show

                    ld      a,(days)            ; the day it ended on
                    ld      de,8 * 256 + 15
                    call    end_number
                    ld      a,(special_count)   ; and the charms in the pot
                    call    end_bcd
                    ld      de,14 * 256 + 23
                    call    end_number

                    call    end_percent
                    call    end_rating

                    ; And the game's own dirge over it, which a key cuts short.
                    ld      de,tune_over
                    call    tune_play

                    ;; NB: fall through into end_wait


; Wait for a key, pressed and let go, and start again.
end_wait:           call    end_key
                    jr      nz,end_wait
.press:             call    end_key
                    jr      z,.press
.release:           call    end_key
                    jr      nz,.release
                    jp      start


; A screen of the game's words: black, and then the lines.
;   HL -> the lines, B - how many
end_show:           push    bc
                    push    hl
                    call    room_wipe
                    xor     a                   ; black on black: the words bring
                    ld      hl,$5800            ; their own colours
                    ld      de,$5801
                    ld      bc,767
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


; A tune: its notes until $FF, which a key cuts short -- play_audio.
;   DE -> the notes
tune_play:          ld      a,(de)
                    cp      $FF
                    ret     z
                    push    de
                    call    tune_note
                    pop     de
                    inc     de
                    call    end_key
                    jr      z,tune_play
                    ret


; One note: its number in bits 0 to 5, and how long to hold it in 6 and 7.
;   A - the note
tune_note:          push    af
                    and     $3F
                    ld      hl,tune_notes
                    ld      b,TUNE_NOTES
.find:              cp      (hl)
                    jr      z,.found
                    ld      de,4
                    add     hl,de
                    djnz    .find
                    pop     af                  ; a note these tunes never play
                    ret

.found:             inc     hl
                    ld      b,(hl)              ; the half period: B of them, C
                    inc     hl                  ; times over, as the game counts it
                    ld      c,(hl)
                    inc     hl
                    ld      e,(hl)              ; and how long one beat is
                    ld      d,0
                    pop     af
                    rlca
                    rlca
                    and     3
                    inc     a                   ; one to four beats
                    ld      hl,0
.beats:             add     hl,de
                    dec     a
                    jr      nz,.beats

.period:            push    bc
                    xor     a
                    out     ($FE),a
.low:               djnz    .low
                    dec     c
                    jr      nz,.low
                    pop     bc
                    push    bc
                    ld      a,SOUND_EAR
                    out     ($FE),a
.high:              djnz    .high
                    dec     c
                    jr      nz,.high
                    pop     bc
                    dec     hl
                    ld      a,h
                    or      l
                    jr      nz,.period
                    ret


; Is any key down? Z if none is -- the game asks the same way, at $B5F7 with
; nothing selected: every half-row at once, in one read.
; Corrupts AF, BC.
end_key:            ld      bc,$00FE
                    in      a,(c)
                    cpl
                    and     $1F
                    ret


; A string in end_ink, from the character row and column, the last character
; carrying bit 7.
;   HL -> the characters, D - the row, E - the column
; Returns HL past the string.
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
;   A - the byte, D - the row, E - the column
end_number:         push    af
                    call    end_at
                    pop     af
                    jp      print_hex


; Ten or more of the charms, in BCD, as the game turns them at $BA72.
end_bcd:            cp      10
                    ret     c
                    sub     10
                    or      $10
                    ret


; The percentage of the quest -- calc_and_display_percent. $A41A is a
; hundredth of the 156 that one room and two-a-charm add up to, counted in BCD
; as it goes; the $28 at the end is what rounds the last of them up to 100.
end_percent:        call    end_seen
                    ld      a,(special_count)
                    add     a,a
                    add     a,e
                    ld      e,a
                    ld      bc,$A41A
                    ld      hl,0
                    xor     a
.count:             add     hl,bc
                    adc     a,0
                    daa
                    dec     e
                    jr      nz,.count
                    ld      bc,$0028
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


; What it makes of it: the quarter of the castle he saw, and whether the wizard
; ever had everything.
end_rating:         call    end_seen
                    ld      a,e
                    rrca
                    rrca
                    rrca
                    rrca
                    rrca
                    and     3
                    ld      c,a
                    ld      a,(special_count)
                    cp      SPECIAL_WANTED
                    ld      a,c
                    jr      c,.words
                    add     a,4
.words:             ld      e,a
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
; Out: E - the count. Corrupts AF, BC, HL.
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


; Where a cell is on the screen, and where its attribute is.
;   D - the row, E - the column
end_at:             ld      a,d
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      b,a
                    ld      a,e
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      c,a
                    jp      pixelAddress

end_attr_at:        ld      h,0
                    ld      l,d
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; the row * 32
                    ld      c,e
                    ld      b,$58
                    add     hl,bc
                    ret
