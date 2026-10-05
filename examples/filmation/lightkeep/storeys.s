; ---------------------------------------------------------------------------
; Storeys: falling through a hole into the room below, and climbing stairs into
; the room above.
;
; Knight Lore's castle is one floor, and every way out of a room is a doorway in
; a wall. Fairlight has holes as well, twelve of them. Here a room may name a
; room below it ("down" in rooms.json) and a room above ("up"), and the two are
; joined by one rule: a storey is STOREY units, so a place in one room is the
; same U and V in the other, STOREY higher in the room below.
;
;   down   whatever goes DROP_DEPTH below this room's floor is in the room
;          below, STOREY higher
;   up     the knight, climbing to DROP_DEPTH short of STOREY above the floor,
;          is in the room above, STOREY lower
;
; The two lines are exactly a storey apart, so arriving can never put him past
; the line that would send him straight back. A staircase between two rooms is
; one staircase: the treads under the hole in the room below go on in the hole
; above, a storey lower, and he walks from one set onto the other.
;
; The floor is not an object -- it is room_floor_z, which the engine stops every
; fall at. A room with a way down has it lowered by HOLE_DEPTH once the room is
; built and drawn, and what stands on the floor stands on invisible solid boxes
; laid round the hole instead, background scenery that draws nothing. The
; engine's own floor is then only the bottom of the pit. Two movers read it
; too, the portcullis and the spiked ball, so a room with a hole has neither.
; ---------------------------------------------------------------------------

STOREY              EQU     96          ; how much higher the room below is
DROP_DEPTH          EQU     24          ; below the floor: in the room below
HOLE_DEPTH          EQU     64          ; how far a hole room's floor is lowered
                    ASSERT  HOLE_DEPTH > DROP_DEPTH     ; the pit is past the line

ENTER_FROM_ABOVE    EQU     4           ; enter_dir, beside the four walls
ENTER_FROM_BELOW    EQU     5

; The room being played's ways down and up, ROOM_NO_EXIT for none; the floor's
; height as built, which room_floor_z is not in a room with a hole; and where
; the knight comes in when he goes up or down, which a death puts him back at.
room_down:          DB      ROOM_NO_EXIT
room_up:            DB      ROOM_NO_EXIT
room_ground_z:      DB      0
vertical_z:         DB      0

; Set when he comes in from above, until he has once been below the way up's
; line. A thing that fell through ahead of him can leave him standing on it
; past that line, and without this he would go straight up, fall through the
; hole onto it again, and go back and forth for ever: the thing is in this
; room's table only, so the room above has nothing there to stand on.
vertical_hold:      DB      0


; A room's ways down and up, from room_vertical_tbl, and its floor lowered if it
; has a hole. Called last of all by room_build: everything has been placed and
; drawn at the floor's own height by then.
;
; In:  room_number = the room just built
; Out: room_down, room_up, room_ground_z; room_floor_z
; Corrupts: AF, BC, HL
room_vertical:      ld      a,(room_floor_z)
                    ld      (room_ground_z),a
                    ld      a,ROOM_NO_EXIT
                    ld      (room_down),a
                    ld      (room_up),a
                IF ROOM_VERTICALS
                    ld      a,(room_number)
                    ld      c,a
                    ld      hl,room_vertical_tbl
                    ld      b,ROOM_VERTICALS
.next:              ld      a,(hl)
                    cp      c
                    jr      z,.found
                    inc     hl
                    inc     hl
                    inc     hl
                    djnz    .next
                    ret

.found:             inc     hl
                    ld      a,(hl)
                    ld      (room_down),a
                    inc     hl
                    ld      a,(hl)
                    ld      (room_up),a
                    ld      a,(room_down)
                    cp      ROOM_NO_EXIT
                    ret     z
                    ld      a,(room_ground_z)
                    sub     HOLE_DEPTH
                    ld      (room_floor_z),a
                ENDIF
                    ret


; Has the knight gone down through a hole, or up the stairs? Asked every turn
; he is about, after he has moved, walking or not.
;
; In:  IX -> the player's legs
; Out: room_number, enter_dir and vertical_z = where he goes, if he has gone
; Corrupts: AF, B
player_vertical:    ld      a,(room_down)
                    cp      ROOM_NO_EXIT
                    jr      z,.up
                    ld      a,(room_ground_z)
                    sub     DROP_DEPTH
                    ld      b,a
                    ld      a,(ix+OBJ.Z)
                    cp      b
                    jr      nc,.up              ; not that far down
                    add     a,STOREY
                    ld      (vertical_z),a
                    ld      a,(room_down)
                    ld      (room_number),a
                    ld      a,ENTER_FROM_ABOVE
                    ld      (enter_dir),a
                    ret

.up:                ld      a,(room_up)
                    cp      ROOM_NO_EXIT
                    ret     z
                    ld      a,(room_ground_z)
                    add     a,STOREY - DROP_DEPTH
                    ld      b,a
                    ld      a,(ix+OBJ.Z)
                    cp      b
                    jr      nc,.high
                    xor     a                   ; below the line: the way up
                    ld      (vertical_hold),a   ; is open again
                    ret
.high:              ld      a,(vertical_hold)
                    or      a
                    ret     nz                  ; not until he has been below it
                    ld      a,(ix+OBJ.Z)
                    sub     STOREY
                    ld      (vertical_z),a
                    ld      a,(room_up)
                    ld      (room_number),a
                    ld      a,ENTER_FROM_BELOW
                    ld      (enter_dir),a
                    ret


; Where the knight can come in from above or below without being inside
; something: raised onto the top of anything solid his box would overlap, as
; often as that takes. A thing that fell through the hole ahead of him arrives
; where he does -- it waits in the air at the height it crossed the line, a
; storey up, until someone enters the room -- and two records inside each
; other never move again. So he lands on it. Scenery is asked too, which only
; matters if two rooms' stairs do not quite meet.
;
; In:  A = the Z he would have; B = U, C = V
; Out: A = the Z to give him
; Corrupts: F, DE, HL, IY
VERTICAL_PASSES     EQU     4           ; a thing on a thing on a thing...
vertical_passes:    DB      0

vertical_clear:     ld      e,a
                    ld      a,VERTICAL_PASSES
                    ld      (vertical_passes),a
.pass:              ld      a,(room_object_count)
                    or      a
                    jr      z,.done
                    ld      l,a                 ; records left
                    ld      h,0                 ; nothing has lifted him yet
                    ld      iy,room_objects
.record:            ld      a,(iy+OBJ.GFX)
                    or      a
                    jr      z,.next             ; an empty slot
                    ld      a,(iy+OBJ.FLAGS)
                    and     OBJ_PASSABLE
                    jr      nz,.next

                    ; Along U: inside when U less its U is strictly between
                    ; minus and plus the two half-widths together -- that sum
                    ; plus the difference is above 0 and below twice the sum.
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,CHARACTER_HALF_U
                    ld      d,a
                    add     a,b
                    sub     (iy+OBJ.U)
                    jr      z,.next             ; only touching
                    sla     d
                    cp      d
                    jr      nc,.next
                    ld      a,(iy+OBJ.SIZE_V)   ; and along V
                    add     a,CHARACTER_HALF_V
                    ld      d,a
                    add     a,c
                    sub     (iy+OBJ.V)
                    jr      z,.next
                    sla     d
                    cp      d
                    jr      nc,.next

                    ; And in height: his feet below its top, his head above
                    ; its base.
                    ld      a,(iy+OBJ.Z)
                    add     a,(iy+OBJ.SIZE_Z)
                    ld      d,a                 ; its top
                    ld      a,e
                    cp      d
                    jr      nc,.next            ; on it or above it
                    add     a,COLLIDE_HEIGHT
                    cp      (iy+OBJ.Z)
                    jr      c,.next
                    jr      z,.next             ; under it
                    ld      e,d                 ; onto it
                    ld      h,1

.next:              push    bc
                    ld      bc,ROOM_STRIDE
                    add     iy,bc
                    pop     bc
                    dec     l
                    jr      nz,.record

                    ld      a,h
                    or      a
                    jr      z,.done             ; nothing lifted him: clear
                    ld      hl,vertical_passes
                    dec     (hl)
                    jr      nz,.pass
.done:              ld      a,e
                    ret


; Things that have fallen through the hole: each one's entry in the thing table
; is given the room below, a storey higher, and it is taken out of this room.
; The room below finds it there when it is built, at the top of its view, and it
; falls from there onto whatever is under it. A soldier goes the same way, legs
; and all. Asked every turn, after the movers, and only in a room with a hole.
;
; In:  things_here = the room's things
; Out: nothing
; Corrupts: everything
things_fall:        ld      a,(room_down)
                    cp      ROOM_NO_EXIT
                    ret     z
                    ld      a,(things_here_count)
                    or      a
                    ret     z
                    ld      b,a
                    ld      iy,things_here
.thing:             ld      l,(iy+HERE_RECORD)
                    ld      h,(iy+HERE_RECORD+1)
                    ld      a,h
                    or      l
                    jr      z,.next             ; gone already
                    push    hl
                    pop     ix
                    ld      a,(room_ground_z)
                    sub     DROP_DEPTH
                    cp      (ix+OBJ.Z)
                    jr      c,.next             ; the line is below it
                    jr      z,.next             ; ...or level with it
                    push    bc
                    push    iy
                    call    thing_drop
                    pop     iy
                    pop     bc
.next:              ld      de,HERE_STRIDE
                    add     iy,de
                    djnz    .thing
                    ret


; One thing through the floor: its entry written as things_save would, then
; moved to the room below and a storey up, and its records taken out of the
; room, one after another -- a soldier is two.
;
; In:  IY -> its things_here entry; IX -> its driving record
; Out: nothing
; Corrupts: everything
thing_drop:         ld      a,ROOM_BANK
                    call    page_in
                    call    thing_write         ; HL -> its THING_Z
                    ld      a,(hl)
                    add     a,STOREY
                    ld      (hl),a
                    ld      l,(iy+HERE_AT)
                    ld      h,(iy+HERE_AT+1)
                    ld      a,(room_down)
                    ld      (hl),a              ; THING_ROOM
                    ld      a,PAGE_PLAY
                    call    page_in

                    ld      b,(iy+HERE_COUNT)
                    xor     a
                    ld      (iy+HERE_RECORD),a  ; it is not this room's now
                    ld      (iy+HERE_RECORD+1),a
.record:            push    bc
                    push    ix
                    call    object_hide
                    pop     ix
                    ld      bc,ROOM_STRIDE
                    add     ix,bc
                    pop     bc
                    djnz    .record
                    ret
