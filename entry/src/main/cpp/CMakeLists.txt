cmake_minimum_required(VERSION 3.16)
project(lumine_napi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CORE_SOURCES
    ccore/lmini_json.cpp
    ccore/ltypes.cpp
    ccore/lmatcher.cpp
    ccore/lnet.cpp
    ccore/lroute.cpp
    ccore/ltunnel.cpp
    ccore/lsocks5.cpp
    ccore/lhttp.cpp
    ccore/lcore.cpp
)

add_library(lumine_napi SHARED napi_init.cpp ${CORE_SOURCES})
target_include_directories(lumine_napi PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/ccore"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_compile_definitions(lumine_napi PRIVATE LUMINE_OHOS)

find_library(ACE_NAPI_LIB libace_napi.z.so HINTS "${OHOS_SDK_NATIVE}/sysroot/usr/lib/${OHOS_ARCH}")
find_library(HILOG_LIB libhilog_ndk.z.so HINTS "${OHOS_SDK_NATIVE}/sysroot/usr/lib/${OHOS_ARCH}")

target_link_libraries(lumine_napi PRIVATE "${ACE_NAPI_LIB}" "${HILOG_LIB}")

# The core uses std::thread/std::atomic; link pthread on musl targets.
if(NOT OHOS_ARCH STREQUAL "arm64-v8a")
    # x86_64 emulator shared runtime already pulls in pthread; leave default.
endif()
if(UNIX AND NOT APPLE)
    target_link_libraries(lumine_napi PRIVATE pthread)
endif()