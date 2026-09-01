# Project layout

Part of the [zx-spectrum-emulator README](../README.md).

```
zx-spectrum-emulator/
  vendor/chips/z80.h          # vendored floooh/chips Z80 core -- the tests'
                              #   reference only, not the emulator (zlib license)
  cpp-core/                   # THE emulator
    build.ps1                 # configure + build + test (finds MSVC itself)
    src/
      z80.cpp                 # the Z80: cycle-stepped, pin-level
      alu.cpp                  # flags and arithmetic
      memory.cpp                # 48K map (16K ROM + 48K RAM)
      ula.cpp                    # screen decode, border, frame interrupt
      keyboard.cpp                # 8x5 matrix, port 0xFE
      beeper.cpp                   # port 0xFE bits 4/3 -> samples
      tape.cpp                      # .tap/.tzx, pulse level + fast-load trap
      snapshot.cpp                   # .sna loader + writer
      disassembler.cpp                # full documented Z80 disassembler
      tracelog.cpp                     # cycle-by-cycle bus capture
      rom_source.cpp                    # SLD parser (source-level debug)
      spectrum.cpp                       # Spectrum48K: wires it all together
      engine.cpp                # the shared live instance + command queue
      dap.cpp                    # DAP TCP server
      mcp_server.cpp              # MCP tools (streamable HTTP)
      screen_stream.cpp            # screen-frame TCP stream
      audio_stream.cpp              # audio TCP stream
      audio_wasapi.cpp               # native playback (Windows)
      main.cpp                        # entrypoint: engine + every server
    tests/                    # CTest executables, benchmarks, diagnostics
  scripts/                    # Python helpers -- still current
    build_rom_source.py         # builds rom_disassembly/ (see vscode-debugging.md)
    make_test_tape.py             # generates tapes/
  examples/
    hello_rom_call/              # tiny original demo, committed
  tools/
    trace_viewer.html          # standalone viewer for cycle-by-cycle bus traces
  vscode-extension/            # debugger type registration + screen/trace/tape panels
  roms/                        # gitignored; drop your 48K ROM here
  rom_disassembly/             # gitignored; scripts/build_rom_source.py output
  game-disassemblies/          # submodule: github.com/jonsole/zx-spectrum-disassemblies
  game_disassembly/            # gitignored; left over from before that split
  tapes/                       # scripts/make_test_tape.py output, committed
  snapshots/                   # the Z80 exercisers, committed; games gitignored

  # deprecated, kept for history -- see the note in the README
  zxspectrum/ + tests/*.py     # the original Python core and its pytest suite
  rust-core/                   # the from-scratch Rust Z80 core
```
