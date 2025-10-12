cmake_minimum_required(VERSION 3.10)
project(sf_shim)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add include directory
include_directories(include)

# Create the shared library
add_library(sf_shim SHARED
    src/sf_shim.cpp
)

# Link against Android libraries
target_link_libraries(sf_shim
    gui
    ui
    android
    log
    binder
    utils
)

# Set output directory
set_target_properties(sf_shim PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)
