# Joysticks

Part of the [zx-spectrum-emulator README](../README.md).

The machine has two joystick ports. Each one is plugged into one of the
interfaces Spectrum games were written for, or into nothing:

| Mode | Name | Read as | Right | Left | Down | Up | Fire |
|---|---|---|---|---|---|---|---|
| Kempston | `kempston` | its own port, any with A5 low (`0x1F`) | bit 0 | bit 1 | bit 2 | bit 3 | bit 4 |
| Interface II, port 1 | `sinclair1` | keys | 7 | 6 | 8 | 9 | 0 |
| Interface II, port 2 | `sinclair2` | keys | 2 | 1 | 3 | 4 | 5 |
| Cursor | `cursor` | keys | 8 | 5 | 6 | 7 | 0 |
| Nothing | `none` | — | | | | | |

At start the left port is Kempston and the right is Sinclair 1, which covers
most games without touching anything. retro-spectrum's board uses the same
modes, numbers and power-on setting (its `docs/spec/joystick.md`) and follows
this emulator wherever the two could differ.

What is plugged in is hardware, not machine state. A reset keeps it, and so
does loading a snapshot or a tape.

## How each one reads

**Kempston.** The original interface decodes A5 alone. Every port read with A5
low gets `000FUDLR`, with 1 meaning pressed and bits 7–5 always 0. Those three
bits read 0 because the interface drives them: D5 through the sixth gate of its
74LS366, and D6 and D7 through diodes, according to Kio's notes on his issue 4
board (zxsp's `KempstonJoy.cpp`). The interface's own manual relies on this
when it tells you to write `IF IN 31 = 2`. One fire button. If both ports are
in Kempston mode, the two sticks are ORed.

When no port is in Kempston mode the interface is not there at all. Its ports
then read what they read on a bare machine: an odd one gets the floating bus,
and an even one gets the ULA.

**Interface II and cursor.** These are only keys held down, so they are read
through port `0xFE` on their half-rows like any key. They are ORed with the
keyboard, so a key and the stick holding the same key read as one press. The
cursor mode holds only the digits, not CAPS SHIFT, because a cursor interface
never pressed it. That is also why games offering "cursor" read the digits
alone.

None of this changes an I/O cycle's timing. Contention follows the port's
address as before; only the byte read differs.

## A port both answer

An even port with A5 low (`0x1E`, `0x5E`, ...) is decoded by the ULA and by a
Kempston at once. The emulator gives **the Kempston's byte, all eight bits**,
and the ULA's keys and EAR bit are lost.

Nobody has published a measurement of this. The choice rests on how the two
reach the bus:
- The Kempston interface drives the CPU's data bus directly, from the edge
  connector.
- The ULA reaches the CPU's bus only through the 470 Ω resistors that isolate
  its own bus. The floating bus is those same resistors seen from the other
  side.
- A 74LS output overpowers a signal coming through 470 Ω in either direction.
  A low sinks far more than the resistor can carry. A high is still a valid
  high with the resistor pulling against it.

The weakest point is D6 and D7, which the interface holds low through diodes
rather than gates. If the ULA drove D6 high there, the pin would sit near 0.8 V,
the Z80's limit for a low, so a marginal machine might read either way.

Fuse has no rule here. Whichever device comes first in its port list wins, and
that order is not fixed. A real machine would settle it:
1. Plug in a Kempston and hold a key on some half-row.
2. Push the stick so its bit is that key's bit.
3. Run `IN A,($1E)` with that half-row's address byte in A.

If the result is the Kempston's byte, the choice here is right. If the key
shows through, the ULA wins on a clash and both this emulator and the board
need changing.

## Moving the sticks and changing the ports

**From the screen panel.**
- The numeric keypad is the left port's stick: 8 4 6 2 for up, left, right
  and down, 7 9 1 3 for the diagonals, and 0 or 5 to fire.
- Game controllers work too: the first is the left port, the second the right.
  The left stick or the d-pad moves, and any of the four face buttons fires.
- **ZX Spectrum: Joystick Ports...** picks what each port is plugged into.

**From MCP.**

```jsonc
joystick       { "left": "kempston", "right": "sinclair1" }  // either or both; {} just reports
joystick_press { "port": "left", "directions": "UF" }        // up and fire, until the next press
joystick_press { "port": "left", "directions": "" }          // let go
```

`joystick` has the same name and arguments as retro-spectrum's bridge, so one
script drives either machine. `joystick_press` takes the stick's whole
position as letters, U D L R F, in any order and either case.

**From DAP.** The `joystick` and `joystickPress` custom requests take the same
arguments. These are what the panel sends.

**From the command line.** `--joystick-left` and `--joystick-right`, each taking
a mode's name.

**Linking the core.** `Spectrum::joystick` is a plain struct:
- `mode[port]` is a `JoystickMode`.
- `stick[port]` is `JOY_*` bits.
- `JOY_LEFT_PORT` is 0 and `JOY_RIGHT_PORT` is 1.

A bench driving the machine directly sets these between frames, the way it
calls `keyboard.key_down`. `modes_byte()` and `set_modes_byte()` are the
board's JOY byte: bits 2–0 are the left port's mode and bits 5–3 the right's.

## Rewind

A stick moved or a port replugged is an input like a key. It is recorded in
the history, undone by stepping back past it, and replayed at the same instant
by running forward again. Moving a stick while in the past starts a new
timeline, as a key does.

## Not done

- A `.z80` snapshot's joystick byte is neither read nor written. Loading one
  keeps the ports as they were.
- There is no launch.json setting for the ports. Use the command, or the
  `joystick` tool.
- Only one fire button. Bits 5–7 are 0, never a second or third button.
- The 128K has the same ports, and nothing about them differs from the 48K.
