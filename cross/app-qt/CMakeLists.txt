cmake_minimum_required(VERSION 3.21)
project(OpenTaskManagerQt VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Widgets Test)

# The warnings counterpart of the Rust side's `clippy -D warnings`.
if(MSVC)
    add_compile_options(/W4 /WX)
else()
    add_compile_options(-Wall -Wextra -Wpedantic -Wshadow -Werror)
endif()

# Plain C++ with no Qt: sampling (Linux /proc) and the display rules.
add_library(otm_core STATIC src/core/sampler.cpp src/core/rules.cpp)
target_include_directories(otm_core PUBLIC src/core)

add_executable(opentaskmanager-qt
    src/main.cpp
    src/ui/controller.cpp
    src/ui/graph_widget.cpp
    src/ui/main_window.cpp
    src/ui/process_model.cpp)
target_include_directories(opentaskmanager-qt PRIVATE src/ui)
target_link_libraries(opentaskmanager-qt PRIVATE otm_core Qt6::Widgets)
if(CMAKE_BUILD_TYPE STREQUAL "Release" AND NOT MSVC)
    target_link_options(opentaskmanager-qt PRIVATE -s)
endif()

enable_testing()
add_executable(otm-qt-tests tests/tests.cpp)
target_link_libraries(otm-qt-tests PRIVATE otm_core Qt6::Test)
add_test(NAME otm-qt-tests COMMAND otm-qt-tests)
