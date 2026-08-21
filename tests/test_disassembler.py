from zxspectrum.core.disassembler import annotate_symbols, disassemble_one, disassemble_range


def _mem(data: bytes, base: int = 0):
    buf = bytearray(0x10000)
    buf[base : base + len(data)] = data
    return lambda addr: buf[addr & 0xFFFF]


def _dis(data: bytes, addr: int = 0):
    return disassemble_one(_mem(data, base=addr), addr)


def test_basic_instructions():
    cases = [
        (bytes([0x00]), "NOP", 1),
        (bytes([0x76]), "HALT", 1),
        (bytes([0x3E, 0x42]), "LD A,0x42", 2),
        (bytes([0x47]), "LD B,A", 1),
        (bytes([0x21, 0x34, 0x12]), "LD HL,0x1234", 3),
        (bytes([0xC3, 0x00, 0x80]), "JP 0x8000", 3),
        (bytes([0xCD, 0x00, 0x80]), "CALL 0x8000", 3),
        (bytes([0xC9]), "RET", 1),
        (bytes([0xF3]), "DI", 1),
        (bytes([0xFB]), "EI", 1),
        (bytes([0xAF]), "XOR A", 1),
        (bytes([0x80]), "ADD A,B", 1),
        (bytes([0xFE, 0x10]), "CP 0x10", 2),
        (bytes([0xC5]), "PUSH BC", 1),
        (bytes([0xE1]), "POP HL", 1),
        (bytes([0x09]), "ADD HL,BC", 1),
        (bytes([0x23]), "INC HL", 1),
        (bytes([0x3C]), "INC A", 1),
        (bytes([0x2A, 0x00, 0x5C]), "LD HL,(0x5C00)", 3),
        (bytes([0x32, 0x00, 0x40]), "LD (0x4000),A", 3),
        (bytes([0xD3, 0xFE]), "OUT (0xFE),A", 2),
        (bytes([0xDB, 0xFE]), "IN A,(0xFE)", 2),
        (bytes([0xF7]), "RST 0x30", 1),
    ]
    for data, expected_text, expected_len in cases:
        inst = _dis(data)
        assert inst.text == expected_text, f"{data.hex()} -> {inst.text!r}, expected {expected_text!r}"
        assert inst.length == expected_len


def test_relative_jumps_compute_absolute_target():
    # JR +5 from address 0x8000: target = 0x8000 + 2 (instruction length) + 5
    inst = _dis(bytes([0x18, 0x05]), addr=0x8000)
    assert inst.text == "JR $0x8007"
    assert inst.length == 2

    # JR -3 (0xFD as signed = -3): target = addr + 2 - 3
    inst = _dis(bytes([0x18, 0xFD]), addr=0x8000)
    assert inst.text == "JR $0x7FFF"


def test_cb_prefixed():
    cases = [
        (bytes([0xCB, 0x00]), "RLC B", 2),
        (bytes([0xCB, 0x47]), "BIT 0,A", 2),
        (bytes([0xCB, 0x86]), "RES 0,(HL)", 2),
        (bytes([0xCB, 0xFF]), "SET 7,A", 2),
        (bytes([0xCB, 0x27]), "SLA A", 2),
    ]
    for data, expected_text, expected_len in cases:
        inst = _dis(data)
        assert inst.text == expected_text
        assert inst.length == expected_len


def test_ed_prefixed():
    cases = [
        (bytes([0xED, 0x44]), "NEG", 2),
        (bytes([0xED, 0x4D]), "RETI", 2),
        (bytes([0xED, 0x45]), "RETN", 2),
        (bytes([0xED, 0x46]), "IM 0", 2),
        (bytes([0xED, 0x56]), "IM 1", 2),
        (bytes([0xED, 0x5E]), "IM 2", 2),
        (bytes([0xED, 0xB0]), "LDIR", 2),
        (bytes([0xED, 0xA0]), "LDI", 2),
        (bytes([0xED, 0xB8]), "LDDR", 2),
        (bytes([0xED, 0x42]), "SBC HL,BC", 2),
        (bytes([0xED, 0x4A]), "ADC HL,BC", 2),
        (bytes([0xED, 0x43, 0x00, 0x80]), "LD (0x8000),BC", 4),
        (bytes([0xED, 0x47]), "LD I,A", 2),
        (bytes([0xED, 0x57]), "LD A,I", 2),
    ]
    for data, expected_text, expected_len in cases:
        inst = _dis(data)
        assert inst.text == expected_text
        assert inst.length == expected_len


def test_dd_ix_prefixed():
    cases = [
        (bytes([0xDD, 0x21, 0x00, 0x80]), "LD IX,0x8000", 4),
        (bytes([0xDD, 0x7E, 0x05]), "LD A,(IX+5)", 3),
        (bytes([0xDD, 0x77, 0xFB]), "LD (IX-5),A", 3),
        (bytes([0xDD, 0x23]), "INC IX", 2),
        (bytes([0xDD, 0xE1]), "POP IX", 2),
        (bytes([0xDD, 0xE5]), "PUSH IX", 2),
        (bytes([0xDD, 0x64]), "LD IXH,IXH", 2),
        (bytes([0xFD, 0x21, 0x00, 0x80]), "LD IY,0x8000", 4),
        (bytes([0xFD, 0x6E, 0x02]), "LD L,(IY+2)", 3),
    ]
    for data, expected_text, expected_len in cases:
        inst = _dis(data)
        assert inst.text == expected_text
        assert inst.length == expected_len


def test_dd_cb_displacement_bit_ops():
    # DD CB d op: RLC (IX+3)
    inst = _dis(bytes([0xDD, 0xCB, 0x03, 0x06]))
    assert inst.text == "RLC (IX+3)"
    assert inst.length == 4

    # BIT 5,(IX+3) -- never has an undocumented copy-to-register suffix
    inst = _dis(bytes([0xDD, 0xCB, 0x03, 0x6E]))
    assert inst.text == "BIT 5,(IX+3)"

    # SET 0,(IY-2) with the undocumented copy into B
    inst = _dis(bytes([0xFD, 0xCB, 0xFE, 0xC0]))
    assert inst.text == "SET 0,(IY-2),B"


def test_disassemble_range_walks_variable_length_instructions():
    program = bytes([0x00, 0x3E, 0x42, 0xC3, 0x00, 0x80])  # NOP; LD A,n; JP nn
    instructions = disassemble_range(_mem(program), 0, 3)
    assert [i.text for i in instructions] == ["NOP", "LD A,0x42", "JP 0x8000"]
    assert [i.addr for i in instructions] == [0, 1, 3]


def test_annotate_symbols_appends_exact_match_with_no_offset():
    resolve = {0x8000: ("MY_ROUTINE", 0)}.get
    assert annotate_symbols("CALL 0x8000", resolve) == "CALL 0x8000 (MY_ROUTINE)"


def test_annotate_symbols_appends_offset_when_not_exactly_on_the_symbol():
    resolve = {0x4567: ("MY_TABLE", 4)}.get
    assert annotate_symbols("LD HL,0x4567", resolve) == "LD HL,0x4567 (MY_TABLE+4)"


def test_annotate_symbols_leaves_text_unchanged_when_unresolved():
    assert annotate_symbols("CALL 0x8000", lambda addr: None) == "CALL 0x8000"


def test_annotate_symbols_ignores_2_digit_operands():
    # 8-bit immediates/ports/RST vectors are never wide enough to look
    # like a 4-hex-digit address, so a resolver that would match anything
    # must never be consulted for them.
    resolve = lambda addr: ("SHOULD_NOT_MATCH", 0)  # noqa: E731
    assert annotate_symbols("OUT (0xFE),A", resolve) == "OUT (0xFE),A"
    assert annotate_symbols("RST 0x30", resolve) == "RST 0x30"


def test_annotate_symbols_handles_multiple_addresses_in_one_instruction():
    resolve = {0x8000: ("SRC", 0), 0x9000: ("DST", 0)}.get
    assert annotate_symbols("LD (0x9000),0x8000", resolve) == "LD (0x9000) (DST),0x8000 (SRC)"


def test_annotate_symbols_labels_memory_indirect_operand_after_the_closing_paren():
    # "(0x5C0E)" -- a memory-indirect operand -- should annotate as
    # "(0x5C0E) (TVDATA)", not the more confusing "(0x5C0E (TVDATA))".
    resolve = {0x5C0E: ("TVDATA", 0)}.get
    assert annotate_symbols("LD HL,(0x5C0E)", resolve) == "LD HL,(0x5C0E) (TVDATA)"


def test_real_rom_reset_vector_matches_known_disassembly():
    # The first bytes of every genuine Sinclair 48K ROM: DI; XOR A; LD DE,0xFFFF; JP 0x11CB
    rom_start = bytes([0xF3, 0xAF, 0x11, 0xFF, 0xFF, 0xC3, 0xCB, 0x11])
    instructions = disassemble_range(_mem(rom_start), 0, 4)
    assert [i.text for i in instructions] == ["DI", "XOR A", "LD DE,0xFFFF", "JP 0x11CB"]
