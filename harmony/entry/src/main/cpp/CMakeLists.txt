cmake_minimum_required(VERSION 3.5.0)
project(mirage)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${CMAKE_CURRENT_SOURCE_DIR})

add_library(mirage SHARED bridge.cpp video_decoder.cpp usb_transport.cpp udp_receiver.cpp)

target_link_libraries(mirage PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_media_vdec.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libohcrypto.so)