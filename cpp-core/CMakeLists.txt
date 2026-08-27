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
  src/disassembler.cpp
  src/engine.cpp
  src/keyboard.cpp
  src/memory.cpp
  src/snapshot.cpp
  src/spectrum.cpp
  src/tracelog.cpp
  src/ula.cpp
  src/z80.cpp
)
find_package(Threads REQUIRED)
target_link_libraries(zx_core PUBLIC Threads::Threads)
target_include_directories(zx_core PUBLIC src)
target_compile_options(zx_core PRIVATE ${ZX_WARNINGS})

# ---- zx_server: the protocol layer VS Code talks to --------------------------
# json.hpp and stb_image_write.h are header-only and vendored, so this is just
# our own sources plus the platform's socket library.
add_executable(zx_server
  src/base64.cpp
  src/dap.cpp
  src/http.cpp
  src/main.cpp
  src/mcp_server.cpp
  src/net.cpp
  src/rom_source.cpp
  src/screen_stream.cpp
)
target_link_libraries(zx_server PRIVATE zx_core)
target_compile_options(zx_server PRIVATE ${ZX_WARNINGS})
if(WIN32)
  target_link_libraries(zx_server PRIVATE ws2_32)
endif()
# json.hpp and stb_image_write.h trip /W4 warnings that aren't ours to fix, and
# /WX would fail the build on them -- included as SYSTEM so they're exempt.
target_include_directories(zx_server SYSTEM PRIVATE third_party)

# ---- tests ------------------------------------------------------------------
# Hand-rolled assertions (see tests/test_main.h) rather than a framework --
# these are plain executables run by CTest, and the emulator's own test needs
# (diff two cores, run ZEXALL to completion) don't benefit from one.
enable_testing()

# USES_REFERENCE marks a test that #includes the vendored vendor/chips/z80.h
# (with CHIPS_IMPL) to diff against the real reference core. Those get the
# vendor include path and relaxed warnings, since z80.h's own warnings aren't
# ours to fix and /WX would fail the build on them.
function(zx_add_test name)
  cmake_parse_arguments(ARG "USES_REFERENCE" "" "" ${ARGN})
  add_executable(${name} tests/${name}.cpp)
  target_link_libraries(${name} PRIVATE zx_core)
  target_include_directories(${name} PRIVATE tests)
  if(ARG_USES_REFERENCE)
    # vendor/, not vendor/chips/, so the reference is included as
    # "chips/z80.h" and cannot be confused with our own src/z80.h.
    target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../vendor)
    if(MSVC)
      target_compile_options(${name} PRIVATE /W3 /wd4244)
    else()
      target_compile_options(${name} PRIVATE -Wall)
    endif()
  else()
    target_compile_options(${name} PRIVATE ${ZX_WARNINGS})
  endif()
  add_test(NAME ${name} COMMAND ${name})
endfunction()

zx_add_test(memory_tests)
zx_add_test(alu_tests USES_REFERENCE)
zx_add_test(pin_level)
zx_add_test(int_timing)
zx_add_test(differential USES_REFERENCE)
zx_add_test(spectrum_tests)
zx_add_test(tracelog_tests)
# Diffs against tests/data/visualz80_reference.txt, found relative to the
# project root rather than the build tree.
target_compile_definitions(tracelog_tests
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")
# Needs the real ROM, which is copyrighted and gitignored -- the test skips
# gracefully if it is absent.
target_compile_definitions(spectrum_tests
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# ---- throughput benchmark ---------------------------------------------------
# Not a test (nothing to assert -- it reports numbers). Build and run manually;
# only meaningful in an optimised build.
add_executable(bench tests/bench.cpp)
target_link_libraries(bench PRIVATE zx_core)
target_compile_options(bench PRIVATE ${ZX_WARNINGS})

# Companion to bench: measures the machine and Engine layers rather than the
# bare CPU, i.e. what a connected client actually experiences.
add_executable(bench_machine tests/bench_machine.cpp)
target_link_libraries(bench_machine PRIVATE zx_core)
target_compile_options(bench_machine PRIVATE ${ZX_WARNINGS})
target_compile_definitions(bench_machine
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# Diagnostic, not a test: runs a snapshot until it derails and dumps the
# instruction history that led there.
add_executable(trace tests/trace.cpp)
target_link_libraries(trace PRIVATE zx_core)
target_compile_options(trace PRIVATE ${ZX_WARNINGS})
target_compile_definitions(trace
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# Diagnostic, not a test: dumps the rendered canvas for eyeballing.
add_executable(screenshot tests/screenshot.cpp)
target_link_libraries(screenshot PRIVATE zx_core)
target_compile_options(screenshot PRIVATE ${ZX_WARNINGS})
target_compile_definitions(screenshot
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# ---- ZEXALL / ZEXDOC --------------------------------------------------------
# One executable, run twice with different arguments. Labelled "slow" and
# excluded from the default ctest run (build.ps1 -Test): a full pass is well
# over a billion emulated instructions and takes many minutes even optimised.
# Run with build.ps1 -Slow.
add_executable(zexall_runner tests/zexall.cpp)
target_link_libraries(zexall_runner PRIVATE zx_core)
target_compile_options(zexall_runner PRIVATE ${ZX_WARNINGS})
# The .com images live outside the build tree; baked in rather than found by
# walking relative paths, which break depending on where ctest is invoked.
target_compile_definitions(zexall_runner
  PRIVATE ZX_PROJECT_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

foreach(suite zexdoc zexall)
  add_test(NAME ${suite} COMMAND zexall_runner ${suite})
  set_tests_properties(${suite} PROPERTIES LABELS "slow" TIMEOUT 7200)
endforeach()
