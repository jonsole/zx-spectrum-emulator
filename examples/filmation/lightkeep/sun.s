; --- the sun and moon window ---------------------------------------------------
;
; display_sun_moon_frame and display_frame, at $C3A4 and $C3C3. The window is six
; bytes by 31 rows in the bottom-right corner, x = 184 to 231. The game clears
; it, draws the sun or the moon at sun_x -- at a height out of a little table
; that bows its path up across the middle -- lays the two leaves of the frame
; over it, and copies the six by 31 to the screen. The leaves are graphics 90
; and 186, three bytes each, and their solid ends are what hide the disc as it
; comes in and goes out. The colours are colour_panel's and colour_sun_moon's:
; the frame bright red, and the four cells the disc crosses bright yellow by
; day and white by night.
;
; The disc goes onto nothing, so its own mask can never matter: a byte of the
; window is the disc's data there, if it has any, under the frame's mask and
; data -- (disc AND mask) XOR data, and nothing else. So each byte is worked
; out once and written once, straight to the screen, and the screen never shows
; the disc without the frame in front of it.
;
; And a step of the clock only has to write where the disc is and where it has
; just been: the same sixteen or seventeen rows, and three or four columns, out
; of the window's 31 by six. The frame everywhere else is already there.
SUN_COLUMN          EQU     23                  ; the window's first byte
SUN_COLUMNS         EQU     6
SUN_ROWS            EQU     31
SUN_ROW             EQU     SCREEN_ROWS - SUN_ROWS
SUN_GFX             EQU     GFX_SUN_1                  ; the sun, and 89 the moon
SUN_DISC_ROWS       EQU     16                  ; ...both 2x16
SUN_FRAME_ATTR      EQU     $42
SUN_ATTR            EQU     $46                 ; and $47 by night
SUN_COST            EQU     93                  ; turn units, for turn_pace: a step,
SUN_COST_ALL        EQU     221                 ; measured at 16,000 T, and the whole
                                                ; window at 38,000

; How high the disc's bottom row sits above the screen's, by (x + 16) / 4 --
; sun_moon_yoff, at $C440.
sun_heights:        DB      5, 6, 7, 8, 9, 10, 10, 9, 8, 7, 6, 5, 5

; Where the disc is. The column is the window column of its first byte, plus
; one so that the -1 it starts at compares as the smallest. sun_draw reads the
; two as one word.
sun_disc_at:        DB      0
sun_disc_top:       DB      0                   ; its first row in the window
                    ASSERT  PLAYER_WOLF == $20


; Draw the whole window, with its colours: when a room is shown, when a repaint
; has wiped it, and when the sun and the moon change places.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sun_show_all:       ld      a,SUN_FRAME_ATTR
                    ld      hl,$5800 + 20 * 32 + SUN_COLUMN
                    ld      bc,SUN_COLUMNS << 8 | 4
                    call    sun_fill
                    ld      a,(night)
                    rlca
                    rlca
                    rlca                        ; PLAYER_WOLF to 1
                    add     a,SUN_ATTR
                    ld      hl,$5800 + 21 * 32 + SUN_COLUMN + 1
                    ld      bc,4 << 8 | 2
                    call    sun_fill
                    call    sun_place
                    ld      bc,0 << 8 | SUN_ROWS
                    ld      de,0 << 8 | SUN_COLUMNS
                    ld      a,SUN_COST_ALL
                    jr      sun_draw


; A step of the clock: the rows and columns between where the disc was and
; where it is now.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sun_show:           ld      hl,(sun_disc_at)    ; where it was: L the column, H the row
                    push    hl
                    call    sun_place
                    pop     hl
                    ld      de,(sun_disc_at)    ; and where it is: E and D

                    ld      a,h                 ; rows from the higher top...
                    cp      d
                    ld      b,h
                    ld      c,d
                    jr      c,.rows
                    ld      b,d
                    ld      c,h
.rows:              ld      a,c                 ; ...to the lower one's bottom
                    add     a,SUN_DISC_ROWS
                    ld      c,a

                    ld      a,l                 ; columns to the rightmost's third
                    cp      e
                    jr      nc,.right
                    ld      a,e
.right:             add     a,2                 ; (unbiased, plus three)
                    cp      SUN_COLUMNS + 1
                    jr      c,.inside
                    ld      a,SUN_COLUMNS
.inside:            ld      h,a
                    ld      a,l                 ; from the leftmost's first
                    cp      e
                    jr      c,.left
                    ld      a,e
.left:              sub     1                   ; unbiased, and not left of the window
                    adc     a,0
                    ld      d,a
                    ld      e,h
                    ld      a,SUN_COST

                    ;; NB: fall through into sun_draw


; Draw a block of the window straight onto the screen. The disc's rows must be
; in shift_shared, from sun_place.
;
; In:  A = what it costs, in turn units
;      B = the first row
;      C = the row after the last
;      D = the first column
;      E = the column after the last
; Out: nothing
; Corrupts: AF, BC, DE, HL
sun_draw:           call    turn_add
                    push    ix
                    push    iy
                    ld      iyh,b
                    ld      a,c
                    ld      (.end + 1),a
                    ld      a,e
                    sub     d
                    ld      (.count + 2),a
                    ld      a,(sun_disc_top)
                    ld      (.top + 1),a

                    ; How far along the disc the first column is, and so which of
                    ; its bytes each row starts from. IYL counts along the row,
                    ; and anything but 0 to 2 is off the disc.
                    ld      a,d
                    inc     a
                    ld      hl,sun_disc_at
                    sub     (hl)
                    ld      (.along + 2),a
                    ld      hl,shift_shared
                    jp      m,.disc_start       ; short of it: from its first byte
                    ld      c,a
                    ld      b,0
                    add     hl,bc
.disc_start:        ld      (.disc + 1),hl

                    ; The frame's first byte: six a row and two a column into
                    ; graphic 90, or into 186 from the fourth column. IXH counts
                    ; down the columns before a row crosses from one to the other.
                    ld      a,iyh
                    add     a,a
                    ld      c,a
                    add     a,a
                    add     a,c
                    add     a,d
                    add     a,d
                    ld      l,a
                    ld      h,0
                    ld      bc,sprite_window_1 + 2
                    add     hl,bc
                    ld      a,3
                    sub     d
                    jr      z,.leaf_186
                    jr      nc,.leaf_90
.leaf_186:          ld      bc,sprite_window_2 - sprite_window_1 - 6
                    add     hl,bc
                    xor     a                   ; so that it never counts down to 0
.leaf_90:           ld      (.cross + 2),a
                    ld      (.leaf + 1),hl

                    ; And the screen's.
                    ld      a,iyh
                    add     a,SUN_ROW
                    ld      b,a
                    ld      a,d
                    add     a,SUN_COLUMN
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      c,a
                    call    pixelAddress
                    ld      (.screen + 1),hl

                    ; From here each row only steps the three pointers on.
                    ; The window is in the bottom third, where the screen's
                    ; high byte is $50 plus the line within the character: a
                    ; row on is a line on, or line 0 of the next character.
                    ASSERT  SUN_ROW >= 128
.row:
.screen:            ld      hl,0                ; patched: this row's first byte
                    ld      b,h
                    ld      c,l
                    inc     h
                    ld      a,h
                    cp      $58
                    jr      c,.line
                    ld      h,$50
                    ld      a,l
                    add     a,32
                    ld      l,a
.line:              ld      (.screen + 1),hl

                    ld      a,iyh
.top:               sub     0                   ; patched: the disc's first row
                    cp      SUN_DISC_ROWS
                    ld      iyl,8
                    jr      nc,.frame           ; a row the disc does not reach
.along:             ld      iyl,0               ; patched
.disc:              ld      hl,0                ; patched: this row of the disc
                    ld      d,h
                    ld      e,l
                    inc     hl
                    inc     hl
                    inc     hl
                    ld      (.disc + 1),hl

.frame:
.leaf:              ld      hl,0                ; patched: this row of the frame
                    push    hl
                    inc     hl
                    inc     hl
                    inc     hl
                    inc     hl
                    inc     hl
                    inc     hl
                    ld      (.leaf + 1),hl
                    pop     hl

.cross:             ld      ixh,0               ; patched
.count:             ld      ixl,0               ; patched: the columns
.column:            ld      a,iyl
                    cp      3
                    ld      a,0
                    jr      nc,.put
                    ld      a,(de)
                    inc     de
.put:               and     (hl)
                    inc     hl
                    xor     (hl)
                    inc     hl
                    ld      (bc),a
                    inc     bc
                    inc     iyl
                    dec     ixh
                    jr      nz,.next
                    push    bc
                    ld      bc,sprite_window_2 - sprite_window_1 - 6
                    add     hl,bc
                    pop     bc
.next:              dec     ixl
                    jr      nz,.column

                    inc     iyh
                    ld      a,iyh
.end:               cp      0                   ; patched: the row after the last
                    jr      c,.row
                    pop     iy
                    pop     ix
                    ret


; Where the disc is, from sun_x, and its sixteen rows put onto their pixel:
; three bytes of data a row into shift_shared. Shifting uses the same tables
; object_update rotates with -- x >> shift, and what falls out, a page each.
;
; In:  nothing
; Out: sun_disc_at, sun_disc_top = where the disc is
;      shift_shared = its sixteen rows
; Corrupts: AF, BC, DE, HL
sun_place:          ld      a,(sun_x)
                    rrca
                    rrca
                    rrca
                    and     $1F
                    sub     SUN_COLUMN - 1      ; biased by one
                    ld      (sun_disc_at),a
                    ld      a,(sun_x)
                    add     a,16
                    rrca
                    rrca
                    and     $0F
                    ld      e,a
                    ld      d,0
                    ld      hl,sun_heights
                    add     hl,de
                    ld      a,SUN_ROWS - SUN_DISC_ROWS
                    sub     (hl)
                    ld      (sun_disc_top),a

                    ld      a,(night)
                    rlca
                    rlca
                    rlca
                    add     a,SUN_GFX
                    ld      l,a
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l
                    ld      h,(hl)
                    ld      l,a
                    inc     hl                  ; the height; each row is then mask,
                    ld      de,shift_shared     ; data, mask, data
                    ld      b,SUN_DISC_ROWS
                    ld      a,(sun_x)
                    and     7
                    jr      nz,.shifted

.plain:             inc     hl
                    inc     hl
                    ld      a,(hl)
                    ld      (de),a
                    inc     de
                    inc     hl
                    inc     hl
                    ld      a,(hl)
                    ld      (de),a
                    inc     de
                    xor     a
                    ld      (de),a
                    inc     de
                    djnz    .plain
                    ret

.shifted:           add     a,a
                    add     a,high SPRITE_ROTATE_BASE
                    ld      c,a
.shift:             inc     hl
                    inc     hl
                    ld      a,(hl)              ; the left byte
                    inc     hl
                    inc     hl
                    push    hl
                    ld      h,c
                    ld      l,a
                    ld      a,(hl)
                    ld      (de),a
                    inc     de
                    inc     h
                    ld      a,(hl)              ; what fell out of it, into the next
                    ld      (de),a
                    pop     hl
                    ld      a,(hl)              ; the right byte
                    push    hl
                    ld      h,c
                    ld      l,a
                    ld      a,(de)
                    or      (hl)
                    ld      (de),a
                    inc     de
                    inc     h
                    ld      a,(hl)
                    ld      (de),a
                    inc     de
                    pop     hl
                    djnz    .shift
                    ret
