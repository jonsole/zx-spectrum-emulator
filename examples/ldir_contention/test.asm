    DEVICE ZXSPECTRUM48
    ORG 0x8000
Start:
    DI
    LD SP,0xFF00     ; safe, uncontended stack
    LD A,0x82
    LD I,A          ; IM2 vector page -- vector address becomes 0x82FF
    IM 2
    EI
LdirTest:
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    HALT
    JP LdirTest      ; repeat forever

    ORG 0x8400
Isr:
    LD HL, 596
Delay:
    DEC HL
    LD A,H
    OR L
    JP NZ,Delay
    LD HL,SourceData ; LDIR source -- uncontended
    LD DE,0x4000     ; LDIR dest -- contended (screen)
    LD BC,256
    LDI
;Copy:
;    LD A,(HL)
;    LD (DE),A
;    INC HL
;    INC DE
;    DJNZ Copy
    EI
    RET

    ORG 0x82FF
    DEFW Isr          ; IM2 vector table entry for I=0x82

    ORG 0x8100
SourceData:
    DS 256,0xAA       ; 256 recognizable, non-zero bytes

    SAVESNA "test.sna", Start
