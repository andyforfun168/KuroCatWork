cmake_minimum_required(VERSION 3.20)
project(KuroCatWork LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(KuroCatWork WIN32
    src/main.cpp
    resource.rc
    app.manifest
)

target_compile_definitions(KuroCatWork PRIVATE UNICODE _UNICODE NOMINMAX _WIN32_WINNT=0x0601 WINVER=0x0601)
if(MSVC)
    target_compile_options(KuroCatWork PRIVATE /O2 /utf-8 /EHsc /W3 /MT)
    target_link_options(KuroCatWork PRIVATE /SUBSYSTEM:WINDOWS,6.01)
else()
    target_compile_options(KuroCatWork PRIVATE -O2 -municode)
endif()

target_link_libraries(KuroCatWork PRIVATE user32 gdi32 gdiplus shell32 advapi32 winhttp wtsapi32 ole32 winmm comctl32)
