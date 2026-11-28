cmake_minimum_required(VERSION 3.5.0)
project(arkclash)

# Built by scripts/core/build.sh.
set(CORE_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libclash.so)
if(NOT EXISTS ${CORE_LIB})
    message(FATAL_ERROR "${CORE_LIB} not found, run scripts/core/build.sh first")
endif()

add_library(arkclash SHARED napi_init.cpp)
target_include_directories(arkclash PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../core)
target_link_libraries(arkclash PUBLIC libace_napi.z.so ${CORE_LIB})

add_library(arkstore SHARED backup_init.cpp)
target_compile_features(arkstore PRIVATE cxx_std_14)
target_link_libraries(arkstore PRIVATE libace_napi.z.so libhilog_ndk.z.so dl)
