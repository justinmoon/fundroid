cmake_minimum_required(VERSION 3.16)
project(vibrator_shim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(AIDL_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/aidl)

add_library(
	vibrator_shim
	STATIC
	vibrator_shim.cpp
	${AIDL_SRC_DIR}/android/hardware/vibrator/IVibrator.cpp
)

target_include_directories(
	vibrator_shim
	PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR}
	PRIVATE
		${AIDL_SRC_DIR}
		${AIDL_SRC_DIR}/aidl
)

find_library(binder_ndk_lib NAMES binder_ndk REQUIRED)
target_link_libraries(vibrator_shim PUBLIC ${binder_ndk_lib})

set(OUTPUT_DIR "${CMAKE_BINARY_DIR}")
set_target_properties(
	vibrator_shim
	PROPERTIES
		ARCHIVE_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
		LIBRARY_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
)
