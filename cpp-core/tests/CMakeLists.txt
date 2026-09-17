# The test suite, the benchmarks and the diagnostic tools: everything in
# cpp-core that is not the server. Included by the top-level CMakeLists.txt
# when ZX_BUILD_TESTS is on (the default).
#
# Paths here are spelled from the project root rather than from this
# directory, since the sources the tools share with the server live in src/,
# and ZX_PROJECT_ROOT has to name the repository whichever file defines it.
set(ZX_SRC ${PROJECT_SOURCE_DIR}/src)
set(ZX_THIRD_PARTY ${PROJECT_SOURCE_DIR}/third_party)
set(ZX_ROOT_DEFINE ZX_PROJECT_ROOT="${PROJECT_SOURCE_DIR}/..")

# Two groups, so either can be built without the other or the server:
#   zx_tests   everything CTest runs, the slow exercisers included
#   zx_tools   the benchmarks and diagnostics, which nothing runs for you
add_custom_target(zx_tests)
add_custom_target(zx_tools)

# ---- tests ------------------------------------------------------------------
# Hand-rolled assertions (see test_main.h) rather than a framework -- these are
# plain executables run by CTest, and the emulator's own test needs (diff two
# cores, run ZEXALL to completion) don't benefit from one.
#
# Every test runs from the top of the build tree, as it did when they were
# defined there: a test that writes a scratch file writes it where it always
# has.

# USES_REFERENCE marks a test that #includes the vendored vendor/chips/z80.h
# (with CHIPS_IMPL) to diff against the real reference core. Those get the
# vendor include path and relaxed warnings, since z80.h's own warnings aren't
# ours to fix and /WX would fail the build on them.
function(zx_add_test name)
  cmake_parse_arguments(ARG "USES_REFERENCE" "" "" ${ARGN})
  add_executable(${name} ${name}.cpp)
  target_link_libraries(${name} PRIVATE zx_core)
  target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  if(ARG_USES_REFERENCE)
    # vendor/, not vendor/chips/, so the reference is included as
    # "chips/z80.h" and cannot be confused with our own src/z80.h.
    target_include_directories(${name} PRIVATE ${PROJECT_SOURCE_DIR}/../vendor)
    if(MSVC)
      target_compile_options(${name} PRIVATE /W3 /wd4244)
    else()
      target_compile_options(${name} PRIVATE -Wall)
    endif()
  else()
    target_compile_options(${name} PRIVATE ${ZX_WARNINGS})
  endif()
  add_test(NAME ${name} COMMAND ${name} WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
  add_dependencies(zx_tests ${name})
endfunction()

zx_add_test(memory_tests)
zx_add_test(register_names_tests)
zx_add_test(beeper_tests)
zx_add_test(alu_tests USES_REFERENCE)
zx_add_test(pin_level)
zx_add_test(int_timing)
zx_add_test(differential USES_REFERENCE)
zx_add_test(spectrum_tests)
zx_add_test(spectrum128_tests)
zx_add_test(ay_tests)
zx_add_test(floating_bus)
zx_add_test(call_stack)
zx_add_test(graphics_view)
zx_add_test(tape_tests)
zx_add_test(tape_audio_tests)
zx_add_test(tracelog_tests)
zx_add_test(video_recorder_tests)
zx_add_test(frame_capture_tests)
zx_add_test(profile_tests)
zx_add_test(watchpoint_tests)
if(ZX_REWIND)
  zx_add_test(rewind_tests)
  target_compile_definitions(rewind_tests PRIVATE ${ZX_ROOT_DEFINE})
endif()

# Not a zx_add_test: the symbol/address-expression parsing it covers lives in
# rom_source.cpp, which belongs to zx_server rather than zx_core (debug data is
# file-based tooling, not machine state), so it is compiled in directly.
add_executable(symbol_tests symbol_tests.cpp ${ZX_SRC}/rom_source.cpp)
target_link_libraries(symbol_tests PRIVATE zx_core)
target_include_directories(symbol_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(symbol_tests PRIVATE ${ZX_WARNINGS})
add_test(NAME symbol_tests COMMAND symbol_tests WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
add_dependencies(zx_tests symbol_tests)
# The same arrangement for the profile report: it folds addresses through the
# SLD data, which is zx_server's, and emits JSON through the vendored header.
add_executable(profile_report_tests profile_report_tests.cpp ${ZX_SRC}/profile_report.cpp
                                    ${ZX_SRC}/rom_source.cpp)
target_link_libraries(profile_report_tests PRIVATE zx_core)
target_include_directories(profile_report_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(profile_report_tests SYSTEM PRIVATE ${ZX_THIRD_PARTY})
target_compile_options(profile_report_tests PRIVATE ${ZX_WARNINGS})
add_test(NAME profile_report_tests COMMAND profile_report_tests
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
add_dependencies(zx_tests profile_report_tests)
# Diffs against tests/data/visualz80_reference.txt, found relative to the
# project root rather than the build tree.
target_compile_definitions(tracelog_tests
  PRIVATE ${ZX_ROOT_DEFINE})
# Needs the real ROM, which is copyrighted and gitignored -- the test skips
# gracefully if it is absent.
target_compile_definitions(spectrum_tests
  PRIVATE ${ZX_ROOT_DEFINE})
# The same for the 128K's ROM pair (roms/128.rom).
target_compile_definitions(spectrum128_tests
  PRIVATE ${ZX_ROOT_DEFINE})
# The fast-load trap and the auto-typed LOAD "" only mean anything against the
# real ROM; those tests skip gracefully without it, the parser ones do not need
# it at all.
target_compile_definitions(tape_tests
  PRIVATE ${ZX_ROOT_DEFINE})
# Same again: the round-trip tests drive the real ROM's loader off decoded
# audio, and skip gracefully when the ROM is absent.
target_compile_definitions(tape_audio_tests
  PRIVATE ${ZX_ROOT_DEFINE})

# ---- throughput benchmark ---------------------------------------------------
# Not a test (nothing to assert -- it reports numbers). Build and run manually;
# only meaningful in an optimised build.
add_executable(bench bench.cpp)
target_link_libraries(bench PRIVATE zx_core)
target_compile_options(bench PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools bench)

# Companion to bench: measures the machine and Engine layers rather than the
# bare CPU, i.e. what a connected client actually experiences.
add_executable(bench_machine bench_machine.cpp)
target_link_libraries(bench_machine PRIVATE zx_core)
target_compile_options(bench_machine PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools bench_machine)
target_compile_definitions(bench_machine
  PRIVATE ${ZX_ROOT_DEFINE})

# Diagnostic, not a test: runs a snapshot until it derails and dumps the
# instruction history that led there.
add_executable(trace trace.cpp)
target_link_libraries(trace PRIVATE zx_core)
target_compile_options(trace PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools trace)
target_compile_definitions(trace
  PRIVATE ${ZX_ROOT_DEFINE})

# Diagnostic, not a test: drives the audio path end to end and writes a WAV.
# Needs a few of zx_server's sources (the stream server and its sockets) as
# well as zx_core, so that `beep serve` can stand the real servers up without
# main.cpp -- which is the only way to hear this without starting the whole
# debug server.
add_executable(beep beep.cpp ${ZX_SRC}/audio_device.cpp ${ZX_SRC}/audio_stream.cpp
                    ${ZX_SRC}/audio_wasapi.cpp ${ZX_SRC}/net.cpp)
target_link_libraries(beep PRIVATE zx_core)
target_compile_options(beep PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools beep)
target_compile_definitions(beep
  PRIVATE ${ZX_ROOT_DEFINE})
if(WIN32)
  target_link_libraries(beep PRIVATE ws2_32)
endif()

# Diagnostic, not a test: dumps the rendered canvas for eyeballing.
add_executable(screenshot screenshot.cpp)
target_link_libraries(screenshot PRIVATE zx_core)
target_compile_options(screenshot PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools screenshot)
target_compile_definitions(screenshot
  PRIVATE ${ZX_ROOT_DEFINE})

# Not a test on its own: runs a Z80 .com, exiting with A, for the unit tests
# the examples write in Z80 -- see examples/filmation/engine/tests/run_tests.py.
add_executable(z80_com_runner z80_com_runner.cpp)
target_link_libraries(z80_com_runner PRIVATE zx_core)
target_compile_options(z80_com_runner PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tools z80_com_runner)

# ---- ZEXALL / ZEXDOC --------------------------------------------------------
# One executable, run twice with different arguments. Labelled "slow" and
# excluded from the default ctest run (build.ps1 -Test): a full pass is well
# over a billion emulated instructions and takes many minutes even optimised.
# Run with build.ps1 -Slow.
add_executable(zexall_runner zexall.cpp)
target_link_libraries(zexall_runner PRIVATE zx_core)
target_compile_options(zexall_runner PRIVATE ${ZX_WARNINGS})
add_dependencies(zx_tests zexall_runner)
# The .com images live outside the build tree; baked in rather than found by
# walking relative paths, which break depending on where ctest is invoked.
target_compile_definitions(zexall_runner
  PRIVATE ${ZX_ROOT_DEFINE})

foreach(suite zexdoc zexall)
  add_test(NAME ${suite} COMMAND zexall_runner ${suite} WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
  set_tests_properties(${suite} PROPERTIES LABELS "slow" TIMEOUT 7200)
endforeach()
