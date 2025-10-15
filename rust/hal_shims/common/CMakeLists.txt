cmake_minimum_required(VERSION 3.16)
project(binder_ndk_shim LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_library(binder_ndk_shim STATIC binder_ndk_shim.c)
target_include_directories(binder_ndk_shim PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

find_library(binder_ndk_lib NAMES binder_ndk REQUIRED)
target_link_libraries(binder_ndk_shim PUBLIC ${binder_ndk_lib})

set(OUTPUT_DIR "${CMAKE_BINARY_DIR}")
set_target_properties(
	binder_ndk_shim
	PROPERTIES
		ARCHIVE_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
		LIBRARY_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
)
