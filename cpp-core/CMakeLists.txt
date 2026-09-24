cmake_minimum_required(VERSION 3.20)
project(zx_cpp_core CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Link-time optimisation for optimised builds. This is not a micro-tweak here:
# the emulator's hot loop crosses a translation-unit boundary on every single
# half-clock (Spectrum48K::clock -> Ula::clock -> Memory::read -> Z80::clock,
# each in its own .cpp), so without it none of them can inline and `pins` makes
# a memory round trip per call. Measured worth ~23% on bench_machine (41.5 ->
# 51.2 M half-clocks/s), for no source change.
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
  include(CheckIPOSupported)
  check_ipo_supported(RESULT ZX_IPO_OK OUTPUT ZX_IPO_WHY)
  if(ZX_IPO_OK)
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
  else()
    message(STATUS "Link-time optimisation unavailable: ${ZX_IPO_WHY}")
  endif()
endif()

# Every executable goes to the top of the build tree -- tests and tools
# included, although they are defined in tests/ -- because that is where
# scripts and docs run them from (build\RelWithDebInfo\bench_machine.exe,
# examples/filmation's z80_com_runner).
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

# Warnings-as-errors on our own code only -- vendored third_party/ targets are
# added with their own (looser) settings, since we don't control their source.
if(MSVC)
  add_compile_options(/utf-8)
  set(ZX_WARNINGS /W4 /WX)
else()
  set(ZX_WARNINGS -Wall -Wextra -Werror)
endif()

# ---- zx_core: the emulator itself (no server/protocol code) -----------------
add_library(zx_core STATIC
  src/alu.cpp
  src/ay.cpp
  src/beeper.cpp
  src/disassembler.cpp
  src/engine.cpp
  src/keyboard.cpp
  src/logpoint.cpp
  src/memory.cpp
  src/profile.cpp
  src/register_names.cpp
  src/snapshot.cpp
  src/spectrum.cpp
  src/tape.cpp
  src/tape_audio.cpp
  src/tracelog.cpp
  src/ula.cpp
  src/video_recorder.cpp
  src/z80.cpp
)
# Rewind: a history of the machine for stepping backwards -- see
# docs/rewind-design.md. On by default; configure with -DZX_REWIND=OFF (or
# build.ps1 -NoRewind) for a build with none of it compiled in. PUBLIC, so the
# servers and tests see the same value the core was built with.
option(ZX_REWIND "Keep a history of the machine for stepping backwards" ON)
if(ZX_REWIND)
  target_sources(zx_core PRIVATE src/rewind.cpp)
  target_compile_definitions(zx_core PUBLIC ZX_REWIND=1)
else()
  target_compile_definitions(zx_core PUBLIC ZX_REWIND=0)
endif()
find_package(Threads REQUIRED)
target_link_libraries(zx_core PUBLIC Threads::Threads zx_miniz)
target_include_directories(zx_core PUBLIC src)
# third_party as SYSTEM so miniz.h's own warnings cannot fail our /WX build.
target_include_directories(zx_core SYSTEM PRIVATE third_party)
target_compile_options(zx_core PRIVATE ${ZX_WARNINGS})

# ---- zx_miniz: inflate, and nothing else ------------------------------------
# .csw v2 and .tzx 0x18 store their pulse lists zlib-compressed, which is the
# only compression anywhere in the emulator. The defines below cut the
# amalgamation down to the tinfl decompressor -- no compressor, no .zip, no
# file I/O -- so what gets linked is a few kilobytes rather than all of miniz.
add_library(zx_miniz STATIC third_party/miniz/miniz.c)
target_include_directories(zx_miniz SYSTEM PUBLIC third_party)
target_compile_definitions(zx_miniz PUBLIC
  MINIZ_NO_DEFLATE_APIS
  MINIZ_NO_ARCHIVE_APIS
  MINIZ_NO_STDIO
  MINIZ_NO_TIME
)

# ---- zx_server: the protocol layer VS Code talks to --------------------------
# json.hpp and stb_image_write.h are header-only and vendored, so this is just
# our own sources plus the platform's socket library.
add_executable(zx_server
  src/audio_device.cpp
  src/audio_stream.cpp
  src/audio_wasapi.cpp
  src/base64.cpp
  src/dap.cpp
  src/http.cpp
  src/main.cpp
  src/mcp_server.cpp
  src/net.cpp
  src/profile_report.cpp
  src/rom_source.cpp
  src/screen_stream.cpp
  src/server_registry.cpp
)
target_link_libraries(zx_server PRIVATE zx_core)
target_compile_options(zx_server PRIVATE ${ZX_WARNINGS})
if(WIN32)
  target_link_libraries(zx_server PRIVATE ws2_32)
endif()
# json.hpp and stb_image_write.h trip /W4 warnings that aren't ours to fix, and
# /WX would fail the build on them -- included as SYSTEM so they're exempt.
target_include_directories(zx_server SYSTEM PRIVATE third_party)

# ---- tests and tools ------------------------------------------------------------
# Everything that is not the server -- the CTest suite, the benchmarks and the
# diagnostic tools -- is in tests/CMakeLists.txt. On by default, so a plain
# build and build.ps1 -Test have it all; -DZX_BUILD_TESTS=OFF configures a
# build that is only the server.
#
# Building just one part of an ON build is a matter of target, and needs no
# reconfigure: zx_server alone (what VS Code's launch builds, since relinking
# thirty-odd executables with link-time optimisation for every core change is
# what made launching slow), zx_tests for the suite, zx_tools for the rest.
option(ZX_BUILD_TESTS "Build the test suite, benchmarks and diagnostic tools" ON)
if(ZX_BUILD_TESTS)
  # Here rather than in tests/, so that ctest run from the top of the build
  # tree finds the tests defined down there.
  enable_testing()
  add_subdirectory(tests)
endif()
