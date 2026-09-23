"""The standard ROM loading scheme: a tape the Spectrum's own LOAD "" reads.

A BASIC program autostarting at line 10 --

    CLEAR stack: POKE 23739,111: LOAD ""SCREEN$: LOAD ""CODE ...: RANDOMIZE USR entry

-- then the loading screen, then each block as CODE at its own address, all at
normal speed. POKE 23739,111 points the print channel at a RET, so the ROM's
"Bytes:" messages don't print over the picture as each block is found. CLEAR
puts RAMTOP, and the machine stack under it, at the design's 'stack', or just
below the lowest block when it has none; the program is entered on that stack.

The tape designer's tape_model.js builds the same bytes (romLoaderProgram,
romTap) to time the tape and makes the same checks (checkTape), and
vscode-extension/tests/tape_model_test.js holds the two to each other byte for
byte and word for word.

No third-party imports: a .tap is all this scheme needs to write.
"""

PROG = 0x5CCB        # where a 48K's BASIC program starts, with no microdrive
ROM_HEADROOM = 0x100  # room above it for the variables, workspace and machine stack
# How far below the CLEAR address a block must keep clear of the ROM's stack.
# Measured on the emulator: loading a block goes $11 below it (the GO SUB
# marker, the error return, the interpreter, LOAD, LD_BYTES -> LD_EDGE_2 ->
# LD_EDGE_1), and RANDOMIZE USR enters the program $17 below it. The rest is
# for the interrupts BASIC takes between loads, whose keyboard scan calls
# further down.
ROM_STACK = 0x40
SCREEN_MEMORY = (0x4000, 0x5B00)
SCREEN_BYTES = 6912

CLEAR, POKE, LOAD, SCREEN, CODE, RANDOMIZE, USR = 0xFD, 0xF4, 0xEF, 0xAA, 0xAF, 0xF9, 0xC0


def basic_number(value):
    """A number as BASIC stores it: the digits, then $0E and the five-byte
    small-integer form the interpreter evaluates."""
    return list(str(value).encode('ascii')) + [0x0E, 0x00, 0x00, value & 0xFF, (value >> 8) & 0xFF, 0x00]


def loader_program(design):
    """The BASIC loader's bytes, line number and length included."""
    body = []

    def statement(tokens):
        if body:
            body.append(0x3A)
        body.extend(tokens)

    clear = clear_address(design)
    if clear is not None:
        statement([CLEAR] + basic_number(clear))
    statement([POKE] + basic_number(23739) + [0x2C] + basic_number(111))
    if design['screen'] is not None:
        statement([LOAD, 0x22, 0x22, SCREEN])
    for _ in design['blocks']:
        statement([LOAD, 0x22, 0x22, CODE])
    if design['entry'] is not None:
        statement([RANDOMIZE, USR] + basic_number(design['entry']))
    body.append(0x0D)
    return [0x00, 10, len(body) & 0xFF, len(body) >> 8] + body


def tap_name(name):
    ascii_ = [ord(c) if ord(c) < 128 else 0x3F for c in str(name)]
    return (ascii_ + [0x20] * 10)[:10]


def tap_block(flag, payload):
    check = flag
    for byte in payload:
        check ^= byte
    length = len(payload) + 2
    return [length & 0xFF, length >> 8, flag] + list(payload) + [check]


def code_header(name, length, address):
    return [3] + tap_name(name) + [length & 0xFF, length >> 8, address & 0xFF, address >> 8, 0x00, 0x80]


def tap(design, program_name):
    """The whole .tap. `design` is build_tape.py's: 'screen' is None or
    {'data': 6912 bytes}, and each block has 'name', 'address' and 'data'."""
    program = loader_program(design)
    out = tap_block(0x00, [0] + tap_name(program_name) +
                    [len(program) & 0xFF, len(program) >> 8, 10, 0, len(program) & 0xFF, len(program) >> 8])
    out += tap_block(0xFF, program)
    if design['screen'] is not None:
        out += tap_block(0x00, code_header('screen', SCREEN_BYTES, 16384))
        out += tap_block(0xFF, design['screen']['data'])
    for block in design['blocks']:
        out += tap_block(0x00, code_header(block['name'], len(block['data']), block['address']))
        out += tap_block(0xFF, block['data'])
    return bytes(out)


def seconds(tap_bytes):
    """How long a .tap takes at the ROM's own speed: std_block()'s leader, sync
    and bits (a 1 is 1710+1718 T-states, a 0 855+855), with a second's silence
    between blocks -- tape_model.js's romTapeSeconds."""
    tstates = 0
    at = 0
    first = True
    while at + 2 <= len(tap_bytes):
        length = tap_bytes[at] | (tap_bytes[at + 1] << 8)
        block = tap_bytes[at + 2:at + 2 + length]
        if not first:
            tstates += 1000000
        first = False
        tstates += (3184 if block[0] else 4096) * 2168 + 667 + 735
        for byte in block:
            for bit in range(7, -1, -1):
                tstates += 1710 + 1718 if (byte >> bit) & 1 else 1710
        at += 2 + length
    return tstates / 3500000


def tzx(tap_bytes):
    """The same blocks as a .tzx: standard-speed data blocks (ID $10), each
    followed by a second of silence, which is what a real tape has between
    files and a .tap has no way to say."""
    out = bytearray(b'ZXTape!\x1a' + bytes([1, 20]))
    at = 0
    while at + 2 <= len(tap_bytes):
        length = tap_bytes[at] | (tap_bytes[at + 1] << 8)
        out += bytes([0x10, 1000 & 0xFF, 1000 >> 8, length & 0xFF, length >> 8])
        out += tap_bytes[at + 2:at + 2 + length]
        at += 2 + length
    return bytes(out)


def clear_address(design):
    """The loader's CLEAR: the design's 'stack', or just below the lowest
    block, or None for no CLEAR at all."""
    if design.get('stack') is not None:
        return design['stack']
    if design['blocks']:
        return min(b['address'] for b in design['blocks']) - 1
    return None


def rom_stack(stack):
    """The [start, end) the ROM's stack takes while it loads, under a CLEAR
    at `stack`."""
    return stack - ROM_STACK, stack + 1


def lowest_address(design):
    """The first address a block can load at: above the BASIC loader, its
    variables and the stack CLEAR puts below the lowest block."""
    return PROG + len(loader_program(design)) + ROM_HEADROOM


def _overlaps(a_start, a_end, b_start, b_end):
    return a_start < b_end and b_start < a_end


def check_blocks(design, vital, errors, warnings):
    """What every scheme checks of a block and of the entry -- tape_model.js's
    checkBlocks, and zx-tape-loader's check_design, word for word."""
    for i, block in enumerate(design['blocks']):
        start, end = block['address'], block['address'] + len(block['data'])
        name = f'block "{block["name"]}" (${start:04X}-${end - 1:04X})'
        if not block['data']:
            errors.append(f"{name} is empty")
            continue
        if start < 0x4000:
            errors.append(f"{name} starts in the ROM")
        if end > 0x10000:
            errors.append(f"{name} runs past $FFFF")
        vital(block, start, end, name)
        if design['screen'] is not None and _overlaps(start, end, *SCREEN_MEMORY):
            warnings.append(f"{name} loads over the loading screen")
        for other in design['blocks'][:i]:
            if _overlaps(start, end, other['address'], other['address'] + len(other['data'])):
                warnings.append(f'{name} loads over part of block "{other["name"]}"')
    if design['entry'] is None:
        errors.append("there is no entry address to jump to once the tape has loaded")
    elif not any(b['address'] <= design['entry'] < b['address'] + len(b['data']) for b in design['blocks']):
        warnings.append(f"the entry address ${design['entry']:04X} is not in any block this tape loads")


def check(design):
    """What would stop a standard ROM tape loading, and what is only worth
    knowing, as (errors, warnings)."""
    errors, warnings = [], []
    lowest = lowest_address(design)
    stack = design.get('stack')
    if stack is not None and stack < lowest - 1:
        errors.append(f"the stack at ${stack:04X} must be at ${lowest - 1:04X} or above: any lower "
                      "and CLEAR would put it in the BASIC loader's own workspace")
        stack = None

    def vital(block, start, end, name):
        if 0x4000 <= start < lowest:
            errors.append(f"{name} starts below ${lowest:04X}, which the BASIC loader and its stack need")
        elif stack is not None and _overlaps(start, end, *rom_stack(stack)):
            span = rom_stack(stack)
            errors.append(f"{name} would load over the stack (${span[0]:04X}-${span[1] - 1:04X})")

    check_blocks(design, vital, errors, warnings)
    return errors, warnings
