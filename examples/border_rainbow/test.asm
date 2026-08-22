    DEVICE ZXSPECTRUM48
    ORG 0x8000
Start:
    XOR A               ; A = 0
Loop:
    OUT (0xFE), A        ; border = A & 7
    INC A
    AND 7
    JR Loop
    SAVESNA "test.sna", Start
