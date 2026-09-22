# Project layout

Part of the [zx-spectrum-emulator README](../README.md).

```
zx-spectrum-emulator/
  vendor/chips/z80.h          # vendored floooh/chips Z80 core -- the tests'
                              #   reference only, not the emulator (zlib license)
  cpp-core/                   # THE emulator
    build.ps1                 # configure + build + test (finds MSVC itself)
    CMakeLists.txt            # the core (zx_core) and the server (zx_server)
    src/
      z80.cpp                 # the Z80: cycle-stepped, pin-level
      alu.cpp                  # flags and arithmetic
      memory.cpp                # 48K map (16K ROM + 48K RAM), and the 128K's paging over 8 banks
      ay.cpp                    # the 128K's AY-3-8912 sound chip
      ula.cpp                    # screen decode, border, frame interrupt
      keyboard.cpp                # 8x5 matrix, port 0xFE
      beeper.cpp                   # port 0xFE bits 4/3 -> samples
      tape.cpp                      # .tap/.tzx, pulse level + fast-load trap
      snapshot.cpp                   # .sna (48K/128K) and .z80 loader + writer
      disassembler.cpp                # full documented Z80 disassembler
      tracelog.cpp                     # cycle-by-cycle bus capture
      profile.cpp                      # execution profile: time per address, call tree, periods
      rewind.cpp                       # history for stepping backwards: checkpoints, input log, replay
      video_recorder.cpp               # frames -> ffmpeg pipe (MCP start_video)
      rom_source.cpp                    # SLD parser (source-level debug)
      profile_report.cpp                # a profile folded into source lines, routines, call tree
      spectrum.cpp                       # Spectrum: wires it all together
      engine.cpp                # the shared live instance + command queue
      dap.cpp                    # DAP TCP server
      mcp_server.cpp              # MCP tools (streamable HTTP)
      screen_stream.cpp            # screen-frame TCP stream
      audio_stream.cpp              # audio TCP stream
      audio_wasapi.cpp               # native playback (Windows)
      main.cpp                        # entrypoint: engine + every server
    tests/                    # CTest executables, benchmarks, diagnostics --
                              #   their own CMakeLists.txt, behind ZX_BUILD_TESTS
  scripts/                    # Python helpers -- still current
    build_rom_source.py         # builds rom_disassembly/ (see vscode-debugging.md)
    make_test_tape.py             # generates tapes/
    make_toolbar_icons.py          # the extension's coloured debug-toolbar icons
    room_designer.py                # serves the room designer outside VS Code
  examples/
    hello_rom_call/              # tiny original demo, committed
    filmation/                    # isometric masked-sprite engine; multi-file,
                                  #   assembled by its own build.py
      graphics.py                 #   what each game's graphic numbers are called,
                                  #   off its sprite sheet: the one rule both
                                  #   rooms.py and rooms_source.py name them by
    zx-tape-loader/               # submodule: github.com/jonsole/zx-tape-loader --
                                  #   a fast custom tape loader, and the Python that
                                  #   renders its tapes to WAV
  tools/
    trace_viewer.html          # standalone viewer for cycle-by-cycle bus traces
  vscode-extension/            # debugger type registration + screen/trace/graphics/tape panels
    room_view.html                     # the Filmation room designer's page, shared by
    room_view.js                       #   its two hosts: the custom editor on rooms.json
    room_model.js                      #   ...what a castle is (no vscode API, tested)
    room_render.js                     #   ...and what it looks like (ditto)
    extension.js                 #   the panels, and activation of everything below
    profile_view.js              #   execution profile: heat map on the source, hot spots
    profile_tree.js              #   ...its call tree and worst frames in the debug sidebar
    profile_model.js             #   ...the report turned into both (no vscode API, tested)
    rewind_view.js               #   stepping backwards: toolbar, menus, "before live" status
    rewind_model.js              #   ...its status text (no vscode API, tested)
    watchpoint_view.js           #   watchpoints: the Watch Address command and the sidebar list
    watchpoint_model.js          #   ...how one reads, and what was typed (no vscode API, tested)
    screen_scaling.js            #   the screen panel's size and filter (no vscode API, tested)
    graphics_view.html           #   the graphics panel's page
    graphics_model.js            #   ...its decoding and sprite sheet export (no vscode API, tested)
    server_view.js               #   starting the emulator: debug adapter factory, status bar
    server_launch.js             #   ...where zx_server is and its command line (no vscode API, tested)
    program_view.js              #   opening .sna/.z80/.tap/.tzx: the Run/Debug page, stopOnEntry
    program_info.js              #   ...what a snapshot or tape is (no vscode API, tested)
    asm_language.js              #   Z80 assembly: definition, references, rename, hierarchy
    asm_index.js                 #   ...the symbol index behind it (no vscode API, tested)
    syntaxes/z80-asm.tmLanguage.json  # sjasmplus syntax colouring
    media/toolbar/               #   the debug toolbar's icons (scripts/make_toolbar_icons.py)
    tests/                       #   plain-Node tests for the model files
  roms/                        # gitignored; drop your 48K ROM (and the 128K pair) here
  rom_disassembly/             # gitignored; scripts/build_rom_source.py output
  game-disassemblies/          # submodule: github.com/jonsole/zx-spectrum-disassemblies
  game_disassembly/            # gitignored; left over from before that split
  tapes/                       # scripts/make_test_tape.py output, committed
  snapshots/                   # the Z80 exercisers, committed; games gitignored

  # deprecated, kept for history -- see the note in the README
  zxspectrum/ + tests/*.py     # the original Python core and its pytest suite
```
