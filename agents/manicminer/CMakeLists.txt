# The Manic Miner player (README.md): added from cpp-core/tests/CMakeLists.txt,
# so it builds with the other tools and lands at the top of the build tree.

set(MM_DIR ${CMAKE_CURRENT_SOURCE_DIR})

add_library(mm_game STATIC ${MM_DIR}/mm_game.cpp)
target_link_libraries(mm_game PUBLIC zx_core)
target_include_directories(mm_game PUBLIC ${MM_DIR} ${ZX_SRC})
target_compile_options(mm_game PRIVATE ${ZX_WARNINGS})
target_compile_definitions(mm_game PRIVATE ${ZX_ROOT_DEFINE})

foreach(tool mm_lab mm_explore)
  add_executable(${tool} ${MM_DIR}/${tool}.cpp)
  target_link_libraries(${tool} PRIVATE mm_game Threads::Threads)
  target_compile_options(${tool} PRIVATE ${ZX_WARNINGS})
  add_dependencies(zx_tools ${tool})
endforeach()

# Skips (77) without roms/48.rom and the game: neither is committed.
add_executable(mm_tests ${MM_DIR}/mm_tests.cpp)
target_link_libraries(mm_tests PRIVATE mm_game)
target_include_directories(mm_tests PRIVATE ${PROJECT_SOURCE_DIR}/tests)
target_compile_options(mm_tests PRIVATE ${ZX_WARNINGS})
add_test(NAME mm_tests COMMAND mm_tests WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(mm_tests PROPERTIES SKIP_RETURN_CODE 77)
add_dependencies(zx_tests mm_tests)
