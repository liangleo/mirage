cmake_minimum_required(VERSION 3.5.0)
project(mirage_probe)

set(NATIVE_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVE_ROOT_PATH})

add_library(mirage_probe SHARED napi_init.cpp)

target_link_libraries(mirage_probe PUBLIC
    libace_napi.z.so
    libnative_media_vdec.so
    libnative_media_codecbase.so
    libnative_media_core.so)