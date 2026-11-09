cmake_minimum_required(VERSION 3.20)
project(FaceUnlockProvider CXX)

set(CMAKE_CXX_STANDARD 17)
add_library(FaceUnlockProvider SHARED FaceUnlockProvider.cpp FaceUnlockProvider.def)
target_compile_definitions(FaceUnlockProvider PRIVATE UNICODE _UNICODE WIN32_WINNT=0x0A00 _WIN32_WINNT=0x0A00)
target_link_libraries(FaceUnlockProvider PRIVATE advapi32 secur32 ole32 shlwapi gdi32 user32)

if(MSVC)
  target_compile_options(FaceUnlockProvider PRIVATE /utf-8 /W4 /permissive-)
  # LogonUI 에 별도 런타임 DLL 의존성이 생기지 않도록 정적 CRT
  set_property(TARGET FaceUnlockProvider PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
else()
  target_compile_options(FaceUnlockProvider PRIVATE -Wall -Wextra)
  target_link_options(FaceUnlockProvider PRIVATE -static -static-libgcc -static-libstdc++)
endif()
