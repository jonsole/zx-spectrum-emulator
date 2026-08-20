    DEVICE ZXSPECTRUM48
    ORG 0x8000
Start:
    LD A, 'X'
PrintIt:
    CALL 0x0010        ; ROM: print the character in A
    HALT
    SAVESNA "test.sna", Start
