; Jetman, from Lunar Jetman: drawn and moving as that game does him, on
; stepscroll's terrain. His frames come from the player's own copy of the
; game (jetman_sprite.py, output/jetman_data.s).
;
; Drawing: XOR, as Lunar Jetman draws him -- off at his old place before the
; display list is drawn, on at his new place after it, so the entries never
; draw over him. The image drawn is prepared beforehand (jet_prepare): his
; frame shifted to his pixel, three bytes a row, kept with where it went so
; the same image takes him off again.
;
; Moving: Lunar Jetman's own rules for his speeds, worked out every other
; frame (the game ran about 27 to 31 passes a second; here 25), in 16ths of
; a pixel a pass. He moves every frame, in steps of 2 pixels as the view
; does, when his speed has added up to one (step_of), so the view moves with
; him in the same frame and he stays where it keeps him.
; Walking is a pixel a pass; flying, across, builds up 8 a pass to 64 (4
; pixels) and drifts to a stop with no key; down, gravity adds 8 a pass to
; 64, thrust takes off 8 a pass to -72 (here no faster than 2 lines a
; frame), hover holds still. Thrust while walking takes off (-16, up 2
; lines, where the original went 3); walking off rock, or landing on it,
; changes him over.
;
; The terrain is stepscroll's own, which Lunar Jetman's flat ground never
; was: rock is any set pixel on the screen, looked at just outside his
; 16 x 24 box (so his own XORed pixels are never seen). Walking follows a
; slope up or down up to 2 pixels a step; more is a wall. Flying into rock
; stops him on that axis; falling onto it lands him. Lines off the shown
; screen count as rock.
;
; The view follows: it keeps him at screen x JET_SX (as Lunar Jetman does)
; and his feet near line JET_SY, a move a frame -- 2 pixels across, 2 lines
; up or down, or one of each, diagonally -- since the display list redraws
; only what a single move changes (build.py checks the diagonals too).
; Across, that keeps up with his fastest, 4 pixels every other frame.

JET_SX      equ 120         ; his screen x, as Lunar Jetman keeps it
JET_SY      equ 120         ; the screen line the view keeps his feet on
JET_W       equ 16
WALK_ROWS   equ 22
FLY_ROWS    equ 24

; Controls, as Lunar Jetman reads its keyboard: X V N left, C B M right,
; the top letter row thrust, the number row hover.
C_LEFT      equ 0
C_RIGHT     equ 1
C_THRUST    equ 2
C_HOVER     equ 3

; jstate's bits.
S_WALK      equ 0           ; walking (else flying)
S_RIGHT     equ 1           ; facing right

; ---------------------------------------------------------------------------
; Drawing.

; jet_erase: his image off the screen where it was drawn, before the list
; is drawn.
jet_erase:
    ld a,(jdrawn)
    or a
    ret z
    ld hl,(jold)
    jp xor_image

; jet_draw: the image jet_prepare made onto the screen, after the list; it
; is then the one jet_erase takes off.
jet_draw:
    xor a
    ld (jdrawn),a
    ld a,(jready)
    or a
    ret z
    ld hl,(jnew)
    call xor_image
    ld hl,(jnew)            ; the new one is now the old
    ld de,(jold)
    ld (jold),hl
    ld (jnew),de
    ld a,1
    ld (jdrawn),a
    ret

; xor_image: the image at HL (its column, its bottom line, its rows, then 3
; bytes a row from the bottom) XORed onto the screen, the rows off lines 0
; to LAST_SHOWN left out: the lowest row shown's address from the table,
; then up a line at a time as the blitters go.
xor_image:
    ld a,(hl)
    ld (.col + 1),a
    inc hl
    ld c,(hl)               ; C: the line of the row
    inc hl
    ld b,(hl)               ; B: rows
    inc hl
.below:
    ld a,c
    cp LAST_SHOWN + 1
    jr c,.start
    inc hl                  ; a row below what shows
    inc hl
    inc hl
    dec c
    djnz .below
    ret
.start:
    push hl
    call line_at
.col:
    ld a,0
    add a,l
    ld l,a                  ; HL: its first byte on the screen
    pop de                  ; DE: the image's row
.row:
    ld a,(de)
    xor (hl)
    ld (hl),a
    inc de
    inc l
    ld a,(de)
    xor (hl)
    ld (hl),a
    inc de
    inc l
    ld a,(de)
    xor (hl)
    ld (hl),a
    inc de
    dec l
    dec l
    ld a,c                  ; line 0 drawn: the rest are above the screen
    or a
    ret z
    dec c
    dec h                   ; up a line: within the character row, or into
    ld a,h                  ; the one above (and maybe the third above)
    and 7
    cp 7
    jr nz,.next
    ld a,l
    sub 32
    ld l,a
    jr c,.next
    ld a,h
    add a,8
    ld h,a
.next:
    djnz .row
    ret

; jet_prepare: the image for his frame at his place on the screen (his world
; place less the view's) into jnew, shifted to his pixel, for jet_draw.
; Nothing (jready 0) if he is off the screen.
jet_prepare:
    xor a
    ld (jready),a
    ld hl,(jx)
    ld de,(view_x)
    or a
    sbc hl,de
    ld a,h
    and 7                   ; round the world (2048 pixels)
    ret nz
    ld a,l
    cp 256 - JET_W - 8
    ret nc                  ; (off the right: not drawn)
    ld (.sx + 1),a
    ld hl,(jy)
    ld de,(view_y)
    or a
    sbc hl,de
    ld a,h
    or a
    ret nz                  ; off the bottom (or above the top)
    ld a,l
    ld (.sy + 1),a
    call jet_frame          ; HL: the frame (its rows, then 2 bytes a row)
    ld de,(jnew)
.sx:
    ld a,0
    ld c,a
    rrca
    rrca
    rrca
    and 0x1F
    ld (de),a               ; its column
    inc de
.sy:
    ld a,0
    ld (de),a               ; its bottom line
    inc de
    ld b,(hl)               ; B: rows
    inc hl
    ld a,b
    ld (de),a
    inc de
    ld a,c
    and 7
    cp 5
    jr nc,.leftwards
    ld (.right + 1),a       ; 0 to 4: right that many bits
    ld a,.right_way - .way - 2
    jr .ways
.leftwards:
    neg
    add a,8
    ld (.left + 1),a        ; 5 to 7: a byte right, then left 8 less that
    ld a,.left_way - .way - 2
.ways:
    ld (.way + 1),a
.row:
    push bc
    ld b,(hl)               ; the row's left byte
    inc hl
    ld c,(hl)               ; and right
    inc hl
    push hl
.way:
    jr .right_way           ; (or .left_way)
.right_way:
    ld l,0                  ; the third byte
.right:
    ld a,0
    or a
    jr z,.store
.rbit:
    srl b
    rr c
    rr l
    dec a
    jr nz,.rbit
    jr .store
.left_way:
    ld l,c                  ; the row a byte right: 0, left, right
    ld c,b
    ld b,0
.left:
    ld a,0
.lbit:
    sla l
    rl c
    rl b
    dec a
    jr nz,.lbit
.store:
    ld a,b
    ld (de),a
    inc de
    ld a,c
    ld (de),a
    inc de
    ld a,l
    ld (de),a
    inc de
    pop hl
    pop bc
    djnz .row
    ld a,1
    ld (jready),a
    ret

; jet_frame: HL = his frame now (jet_frames' order: walking left, right,
; then flying left, right): walking, the step jwalk names of A B C B;
; flying, the exhaust the pass count's lowest bit picks.
jet_frame:
    ld a,(jstate)
    bit S_WALK,a
    jr z,.fly
    ld c,0
    bit S_RIGHT,a
    jr z,.walk
    ld c,3
.walk:
    ld a,(jwalk)
    and 3
    cp 3
    jr nz,.step
    ld a,1                  ; A B C B
.step:
    add a,c
    jr .look
.fly:
    ld c,6
    bit S_RIGHT,a
    jr z,.left
    ld c,8
.left:
    ld a,(jpass)
    and 1
    add a,c
.look:
    add a,a
    ld l,a
    ld h,0
    ld de,jet_frames
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ret

; ---------------------------------------------------------------------------
; A pass.

; jet_update: once the world has scrolled in, every other frame his
; controls and his move; every frame a move of the view after him and his
; image for the next.
jet_update:
    ld a,(jet_on)
    or a
    jr nz,.on
    ld hl,(view_y)          ; still scrolling in?
    ld de,VIEW_Y_START
    or a
    sbc hl,de
    ret c
    ld a,1                  ; there: he starts in the air at the middle,
    ld (jet_on),a           ; facing right
    ld hl,(view_x)
    ld de,JET_SX
    add hl,de
    ld (jx),hl
    ld hl,(view_y)
    ld de,JET_SY - 40
    add hl,de
    ld (jy),hl
    ld a,1 << S_RIGHT
    ld (jstate),a
    xor a
    ld (jvx),a
    ld (jvy),a
    jp jet_prepare
.on:
    ld hl,jhalf             ; his keys and speeds every other frame
    ld a,(hl)
    xor 1
    ld (hl),a
    jr z,.move
    ld hl,jpass
    inc (hl)
    call read_controls
    call jet_place
    ld a,(jstate)
    bit S_WALK,a
    jr z,.fly_speeds
    call walk_keys
    jr .move
.fly_speeds:
    call fly_speeds
.move:
    call jet_place          ; his move every frame
    ld a,(jstate)
    bit S_WALK,a
    jr z,.flying
    call walk_move
    jr .view
.flying:
    call fly_move
.view:
    call follow
    jp jet_prepare

; jet_place: jsx, jsy = his place on the screen now (the view not moved yet),
; and jrows his frame's rows.
jet_place:
    ld hl,(jx)
    ld de,(view_x)
    or a
    sbc hl,de
    ld a,l
    ld (jsx),a
    ld hl,(jy)
    ld de,(view_y)
    or a
    sbc hl,de
    ld a,l
    ld (jsy),a
    ld a,(jstate)
    bit S_WALK,a
    ld a,WALK_ROWS
    jr nz,.rows
    ld a,FLY_ROWS
.rows:
    ld (jrows),a
    ret

; read_controls: jcontrols from Lunar Jetman's keys (C_LEFT and so on).
read_controls:
    ld c,0
    ld a,0xFE               ; CAPS Z X C V
    in a,(0xFE)
    cpl
    ld b,a
    and 0x14                ; X, V: left
    jr z,.no_left
    set C_LEFT,c
.no_left:
    ld a,b
    and 0x08                ; C: right
    jr z,.no_right
    set C_RIGHT,c
.no_right:
    ld a,0x7F               ; SPACE SYM M N B
    in a,(0xFE)
    cpl
    ld b,a
    and 0x08                ; N: left
    jr z,.no_n
    set C_LEFT,c
.no_n:
    ld a,b
    and 0x14                ; M, B: right
    jr z,.no_mb
    set C_RIGHT,c
.no_mb:
    ld a,0xFB               ; Q W E R T and P O I U Y: thrust
    in a,(0xFE)
    ld b,a
    ld a,0xDF
    in a,(0xFE)
    and b
    cpl
    and 0x1F
    jr z,.no_thrust
    set C_THRUST,c
.no_thrust:
    ld a,0xF7               ; 1 2 3 4 5 and 0 9 8 7 6: hover
    in a,(0xFE)
    ld b,a
    ld a,0xEF
    in a,(0xFE)
    and b
    cpl
    and 0x1F
    jr z,.no_hover
    set C_HOVER,c
.no_hover:
    ld a,c
    ld (jcontrols),a
    ret

; step_of: the 2-pixel step his speed A (16ths of a pixel a pass) owes this
; frame, from the fraction at HL (32nds of a pixel, -63 to 63 between
; frames): the speed added (half a pass's worth, as the pass is two frames),
; and C = 1 or -1 when it reaches 2 pixels (64), the fraction then 2
; pixels less (and held within a step: 2 pixels a frame is the most), else
; C = 0.
step_of:
    bit 7,a                 ; no faster up than 2 lines a frame (which also
    jr z,.add               ; keeps the sum in a byte)
    cp -64 & 0xFF
    jr nc,.add
    ld a,-64
.add:
    add a,(hl)
    ld c,0
    cp 64
    jr c,.store             ; 0 to 63
    bit 7,a
    jr nz,.minus
    ld c,1                  ; 64 and up: a step on
    sub 64
    cp 64
    jr c,.store
    ld a,63
    jr .store
.minus:
    cp -63 & 0xFF
    jr nc,.store            ; -63 to -1
    ld c,-1                 ; -64 and below: a step back
    add a,64
    cp -63 & 0xFF
    jr nc,.store
    ld a,-63
.store:
    ld (hl),a
    ret

; ---------------------------------------------------------------------------
; Walking.

; walk_keys: on the frames his keys are read: thrust takes off (flying, up
; 2 lines, -16); else left, right or neither is his speed, -16, 16 or 0 --
; Lunar Jetman's pixel a pass -- and his stride goes on while he walks.
walk_keys:
    ld a,(jcontrols)
    bit C_THRUST,a
    jr z,.walk
    ld hl,jstate            ; take off
    res S_WALK,(hl)
    ld a,-16
    ld (jvy),a
    xor a
    ld (jvx),a
    ld (jfx),a
    ld (jfy),a
    ld a,FLY_ROWS           ; (the taller frame: room above for it is
    ld (jrows),a            ; looked at as he rises)
    call up_one
    ret nz
    jp up_one
.walk:
    ld c,0
    bit C_LEFT,a
    jr z,.not_left
    ld c,-16
    ld hl,jstate
    res S_RIGHT,(hl)
.not_left:
    bit C_RIGHT,a
    jr z,.not_right
    ld c,16
    ld hl,jstate
    set S_RIGHT,(hl)
.not_right:
    ld a,c
    ld (jvx),a
    or a
    jr nz,.striding
    ld (jfx),a              ; standing: no part step left over
    ret
.striding:
    ld hl,jwalk
    inc (hl)
    ret

; walk_move: every frame: his speed's 2-pixel step when it is due, a pixel
; at a time, each up a slope (walk_step) or down onto what is under him
; (walk_support); a wall stops him there.
walk_move:
    ld a,(jvx)
    ld hl,jfx
    call step_of
    ld a,c
    or a
    jp z,walk_support
    ld b,2
.pixel:
    push bc
    call walk_step
    pop bc
    jr nz,.wall
    push bc
    call walk_support
    pop bc
    ret nz                  ; off into the air
    djnz .pixel
    ret
.wall:
    xor a
    ld (jfx),a
    jp walk_support

; walk_support: down a pixel or two onto rock under him, or off into the
; air (flying, falling from still): NZ if he went off.
walk_support:
    call rock_below
    jr nz,.on
    ld a,(jsy)              ; a pixel or two down onto it?
    inc a
    ld (jsy),a
    call rock_below
    jr nz,.down1
    ld a,(jsy)
    inc a
    ld (jsy),a
    call rock_below
    jr nz,.down2
    ld a,(jsy)              ; off into the air: falling
    sub 2
    ld (jsy),a
    ld hl,jstate
    res S_WALK,(hl)
    xor a
    ld (jvy),a
    ld (jvx),a
    ld (jfx),a
    ld (jfy),a
    ld a,FLY_ROWS
    ld (jrows),a
    or 1                    ; NZ
    ret
.down2:
    ld hl,(jy)
    inc hl
    ld (jy),hl
.down1:
    ld hl,(jy)
    inc hl
    ld (jy),hl
.on:
    xor a                   ; Z
    ret

; walk_step: a pixel the way C says (1 or -1), up to 2 pixels up a slope:
; Z if he moved (jstep_up: how far up), NZ if a wall stopped him.
walk_step:
    xor a
    ld (jstep_up),a
.try:
    call side_rock          ; the column he steps into, his height
    jr z,.move
    ld a,(jstep_up)         ; up a pixel and try again, twice
    cp 2
    jr z,.blocked
    push bc
    call up_one
    pop bc
    jr nz,.blocked
    ld hl,jstep_up
    inc (hl)
    jr .try
.blocked:
    ld a,(jstep_up)         ; back down to where he was
    or a
    jr z,.wall
    ld b,a
.down:
    ld a,(jsy)
    inc a
    ld (jsy),a
    ld hl,(jy)
    inc hl
    ld (jy),hl
    djnz .down
.wall:
    or 1                    ; NZ
    ret
.move:
    call across_one
    xor a                   ; Z
    ret

; ---------------------------------------------------------------------------
; Flying.

; fly_speeds: on the frames his keys are read, his speeds from them, as
; Lunar Jetman's: across, built up 8 a pass to 64 or braked, drifting to 0
; with no key; down, gravity 8 a pass to 64, thrust -8 to -72, hover 0.
fly_speeds:
    ld a,(jcontrols)
    ld b,a
    ld a,(jvx)
    ld c,a                  ; C: his speed across
    bit C_LEFT,b
    jr z,.not_left
    bit C_RIGHT,b
    jr nz,.drift            ; both: as neither
    ld hl,jstate
    res S_RIGHT,(hl)
    ld a,c                  ; left
    or a
    jp m,.faster_left
    jr z,.faster_left
    cp 48                   ; braking: 16 from the top band, else 8
    ld a,c
    jr c,.brake8
    sub 8
.brake8:
    sub 8
    jr .across
.faster_left:
    sub 8
    cp -32 & 0xFF
    jr nc,.across           ; -32 and above (both negative here): as is
    ld a,-56
    jr .across
.not_left:
    bit C_RIGHT,b
    jr z,.drift
    ld hl,jstate
    set S_RIGHT,(hl)
    ld a,c                  ; right
    or a
    jp p,.faster_right
    cp -47 & 0xFF           ; braking: 24 from the top band, else 8
    ld a,c
    jr nc,.brake8r
    add a,16
.brake8r:
    add a,8
    jr .across
.faster_right:
    add a,8
    cp 41
    jr c,.across
    ld a,64
    jr .across
.drift:
    ld a,c                  ; no key: 2 a pass towards 0, past the bands
    or a
    jr z,.across            ; 48 to 63 and -48 to -33
    jp m,.drift_left
    sub 2
    cp 48
    jr c,.across
    cp 64
    jr nc,.across
    ld a,46
    jr .across
.drift_left:
    add a,2
    cp -48 & 0xFF
    jr c,.across
    cp -32 & 0xFF
    jr nc,.across
    ld a,-32
.across:
    ld (jvx),a
    ; Up and down.
    ld a,(jvy)
    bit C_THRUST,b
    jr z,.no_thrust
    sub 8                   ; thrust, to -72
    or a
    jp p,.vertical
    cp -72 & 0xFF
    jr nc,.vertical
    ld a,-72
    jr .vertical
.no_thrust:
    bit C_HOVER,b
    jr z,.gravity
    xor a                   ; hover
    jr .vertical
.gravity:
    add a,8                 ; gravity, to 64
    jp m,.vertical
    cp 65
    jr c,.vertical
    ld a,64
.vertical:
    ld (jvy),a
    ret

; fly_move: every frame: his speeds' 2-pixel steps when they are due, a
; pixel at a time: across, stopped by rock (speed 0); then up, stopped by
; rock above, or down, onto rock below, which lands him (walking).
fly_move:
    ld a,(jvx)
    ld hl,jfx
    call step_of
    ld a,c
    or a
    jr z,.vertical
    ld b,2
.across:
    push bc
    call side_rock
    pop bc
    jr nz,.wall
    push bc
    call across_one
    pop bc
    djnz .across
    jr .vertical
.wall:
    xor a
    ld (jvx),a
    ld (jfx),a
.vertical:
    ld a,(jvy)
    ld hl,jfy
    call step_of
    ld a,c
    or a
    ret z
    ld b,2
    bit 7,c
    jr z,.down
.up:
    push bc
    call up_one
    pop bc
    jr nz,.ceiling
    djnz .up
    ret
.ceiling:
    xor a
    ld (jvy),a
    ld (jfy),a
    ret
.down:
    push bc
    call rock_below
    pop bc
    jr nz,.land
    ld a,(jsy)
    inc a
    ld (jsy),a
    ld hl,(jy)
    inc hl
    ld (jy),hl
    djnz .down
    ret
.land:
    ld hl,jstate            ; landed: walking
    set S_WALK,(hl)
    xor a
    ld (jvy),a
    ld (jvx),a
    ld (jfx),a
    ld (jfy),a
    ld a,WALK_ROWS
    ld (jrows),a
    ret

; ---------------------------------------------------------------------------
; Moving a pixel, and looking at the rock round him.

; up_one: up a line if the line above his head is clear: Z if he moved, NZ
; if rock stopped him.
up_one:
    call rock_above
    ret nz
    ld a,(jsy)
    dec a
    ld (jsy),a
    ld hl,(jy)
    dec hl
    ld (jy),hl
    xor a
    ret

; across_one: a pixel the way C says (1 or -1).
across_one:
    ld a,(jsx)
    add a,c
    ld (jsx),a
    ld a,c
    ld e,a
    add a,a
    sbc a,a
    ld d,a                  ; DE: C as a word
    ld hl,(jx)
    add hl,de
    ld a,h
    and 7                   ; round the world
    ld h,a
    ld (jx),hl
    ret

; side_rock: NZ if there is rock in the column beside him the way C says,
; the height of his frame. C kept.
side_rock:
    ld a,(jsx)
    dec a                   ; left: the column before him
    bit 7,c
    jr nz,.col
    add a,JET_W + 1         ; right: the one after
.col:
    ld b,a
    ld a,(jrows)
    ld d,a
    ld a,(jsy)
    sub d
    inc a                   ; his top line
    ld e,a
    push bc
    call rock_column
    pop bc
    ret

; rock_below: NZ if there is rock on the line under his feet, across him.
rock_below:
    ld a,(jsy)
    inc a
    jr rock_across

; rock_above: NZ if there is rock on the line over his head, across him.
rock_above:
    ld a,(jrows)
    ld b,a
    ld a,(jsy)
    sub b
    ; fall into rock_across

; rock_across: NZ if any of the JET_W (16) pixels from jsx on screen line A
; are set, or the line is off what shows (rock): the three bytes they fall
; in, masked. C kept.
rock_across:
    cp LAST_SHOWN + 1
    jr nc,.rock
    push bc
    call line_at
    ld a,(jsx)
    ld c,a
    rrca
    rrca
    rrca
    and 0x1F
    add a,l
    ld l,a                  ; HL: the byte with his first pixel
    ld a,c
    and 7
    ld b,a                  ; B: his pixel in it
    ld a,0xFF
    jr z,.first
.mask:
    srl a                   ; 0xFF >> B: from his pixel on
    djnz .mask
.first:
    ld c,a
    and (hl)
    jr nz,.found
    inc l
    ld a,(hl)               ; the middle byte, whole
    or a
    jr nz,.found
    inc l
    ld a,c                  ; the third: what the first left out
    cpl
    and (hl)
    jr nz,.found
    pop bc
    xor a                   ; Z: clear
    ret
.found:
    pop bc
.rock:
    or 1                    ; NZ
    ret

; rock_column: NZ if any pixel in screen column B from line E down D lines
; is set, or a line is off what shows: the first line's address from the
; table, then down a line at a time as the blitters go up.
rock_column:
    ld a,e
    cp LAST_SHOWN + 1
    jr nc,.rock             ; (a line above the screen is too)
    add a,d
    dec a
    cp LAST_SHOWN + 1
    jr nc,.rock             ; its last line below what shows
    ld a,b
    and 7
    ld c,a
    ld a,0x80
    jr z,.mask
.shift:
    rrca
    dec c
    jr nz,.shift
.mask:
    ld c,a                  ; C: its bit
    ld a,e
    call line_at
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    add a,l
    ld l,a                  ; HL: its first line's byte
    ld b,d                  ; B: lines
.line:
    ld a,(hl)
    and c
    jr nz,.rock
    inc h                   ; down a line: within the character row, or into
    ld a,h                  ; the next (and maybe the next third)
    and 7
    jr nz,.next
    ld a,l
    add a,32
    ld l,a
    jr c,.next
    ld a,h
    sub 8
    ld h,a
.next:
    djnz .line
    xor a
    ret
.rock:
    or 1
    ret

; line_at: HL = screen line A's first byte. A must be 0 to 191.
line_at:
    inc a                   ; line_table_m1 starts at line -1
    ld l,a
    ld h,0
    add hl,hl
    push de
    ld de,line_table_m1
    add hl,de
    pop de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ret

; ---------------------------------------------------------------------------
; The view.

; follow: a move of the view after him: across, to keep him at screen x
; JET_SX (to the even pixel), and up or down, his feet to line JET_SY as
; far as the map goes -- both in a frame (a diagonal) when he is out both
; ways.
follow:
    ld hl,(jx)              ; across: where the view should be less where it
    ld de,JET_SX            ; is, round the world, -1024 to 1023
    or a
    sbc hl,de
    ld de,(view_x)
    or a
    sbc hl,de
    res 0,l
    ld a,h
    and 7
    bit 2,a
    jr z,.plus
    or 0xF8
.plus:
    ld h,a
    ld (.dx + 1),hl
    ld hl,(jy)              ; up or down: the same, the view kept in the map
    ld de,JET_SY
    or a
    sbc hl,de
    jr nc,.low
    ld hl,0
.low:
    ld de,VIEW_Y_MAX
    push hl
    or a
    sbc hl,de
    pop hl
    jr c,.high
    ex de,hl
.high:
    res 0,l
    ld de,(view_y)
    or a
    sbc hl,de
    ld (.dy + 1),hl
.dx:
    ld hl,0
    ld a,h
    or l
    jr z,.updown            ; nothing across
    bit 7,h
    jr nz,.go_right
    call left               ; the world 2 pixels left: the view 2 right
    ld hl,(view_x)
    inc hl
    inc hl
    jr .moved
.go_right:
    call right
    ld hl,(view_x)
    dec hl
    dec hl
.moved:
    ld a,h
    and 7
    ld h,a
    ld (view_x),hl
.updown:
.dy:
    ld hl,0
    ld a,h
    or l
    ret z
    bit 7,h
    jp z,up                 ; the view down the map: the world up
    jp down

; ---------------------------------------------------------------------------

jet_on:     db 0            ; 1 once the world has scrolled in
jx:         dw 0            ; his world x (his frame's left pixel), 0-2047
jy:         dw 0            ; his world line (his frame's bottom row)
jvx:        db 0            ; his speed across, 16ths of a pixel a pass
jvy:        db 0            ; and down
jstate:     db 0            ; S_WALK, S_RIGHT
jpass:      db 0            ; his moves, for the exhaust
jhalf:      db 0            ; 1 on the frames he moves
jwalk:      db 0            ; steps walked, for the stride
jcontrols:  db 0
jsx:        db 0            ; his place on the screen in a pass
jsy:        db 0
jrows:      db 0            ; his frame's rows
jstep_up:   db 0
jfx:        db 0            ; his move across owed, 32nds of a pixel (step_of)
jfy:        db 0            ; and down
view_x:     dw 0            ; the world x at the screen's left (fine and view_column)
jdrawn:     db 0            ; 1 while jold is on the screen
jready:     db 0            ; 1 when jnew is ready to draw
jold:       dw jet_image_a
jnew:       dw jet_image_b
jet_image_a: ds 3 + 3 * FLY_ROWS
jet_image_b: ds 3 + 3 * FLY_ROWS
