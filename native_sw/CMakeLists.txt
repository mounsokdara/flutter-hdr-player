cmake_minimum_required(VERSION 3.18)
project(swdecode C CXX)

set(FF ${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg)

add_library(avcodec STATIC IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION ${FF}/lib/libavcodec.a)
add_library(avutil STATIC IMPORTED)
set_target_properties(avutil PROPERTIES IMPORTED_LOCATION ${FF}/lib/libavutil.a)

add_library(swdecode SHARED swdecode.cpp)
target_include_directories(swdecode PRIVATE ${FF}/include)
target_compile_options(swdecode PRIVATE -O3 -fvisibility=hidden)
target_link_libraries(swdecode avcodec avutil android log m)
target_link_options(swdecode PRIVATE -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=16384)
