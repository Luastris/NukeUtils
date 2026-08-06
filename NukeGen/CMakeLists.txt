# NukeGen — the native reflection generator. Zero dependencies beyond the C++ standard
# library and a STATIC CRT, so the single exe runs on any machine (the SDK ships it, and a
# game-module build must not require a Python install).
cmake_minimum_required(VERSION 3.20)
project(NukeGen CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
cmake_policy(SET CMP0091 NEW)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")   # static: standalone exe

add_executable(NukeGen nukegen.cpp)
if(MSVC)
    target_compile_options(NukeGen PRIVATE /utf-8)   # the generated header line carries UTF-8
endif()

# One stable, config-independent home: build scripts, module CMakeLists and the game-module
# scaffold all reference NukeUtils/bin/NukeGen.exe. Debug and Release produce identical
# behavior, so last-built wins harmlessly.
add_custom_command(TARGET NukeGen POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:NukeGen>" "${CMAKE_CURRENT_SOURCE_DIR}/../bin/NukeGen.exe"
    COMMENT "Deploying NukeGen.exe to NukeUtils/bin/")
