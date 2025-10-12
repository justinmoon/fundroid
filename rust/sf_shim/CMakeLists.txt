cmake_minimum_required(VERSION 3.16)
project(sf_shim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(sf_shim SHARED src/sf_shim.cpp)
target_include_directories(sf_shim PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

set(ADDITIONAL_LIB_DIR "$ENV{ANDROID_PLATFORM_LIB_DIR}")
if(ADDITIONAL_LIB_DIR)
  link_directories(${ADDITIONAL_LIB_DIR})
endif()

find_library(log_lib log)
find_library(android_lib android)
find_library(gui_lib gui)
find_library(ui_lib ui)
find_library(binder_lib binder)
find_library(utils_lib utils)

set(REQUIRED_LIBS
  "log;${log_lib}"
  "android;${android_lib}"
  "gui;${gui_lib}"
  "ui;${ui_lib}"
  "binder;${binder_lib}"
  "utils;${utils_lib}"
)

foreach(entry IN LISTS REQUIRED_LIBS)
  list(GET entry 0 pretty_name)
  list(GET entry 1 path_value)
  if(NOT path_value OR path_value MATCHES "-NOTFOUND$")
    message(FATAL_ERROR "Failed to locate lib${pretty_name}.so; set ANDROID_PLATFORM_LIB_DIR to a directory containing the required system libraries.")
  endif()
endforeach()

target_link_libraries(
  sf_shim
  PRIVATE
    ${android_lib}
    ${log_lib}
    ${gui_lib}
    ${ui_lib}
    ${binder_lib}
    ${utils_lib}
)
