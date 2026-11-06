cmake_minimum_required(VERSION 3.5.0)
project(arkclash)

# Built by scripts/build-core.sh.
set(CORE_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libclash.so)
if(NOT EXISTS ${CORE_LIB})
    message(FATAL_ERROR "${CORE_LIB} not found, run scripts/build-core.sh first")
endif()

add_library(arkclash SHARED napi_init.cpp)
target_include_directories(arkclash PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../core)
target_link_libraries(arkclash PUBLIC libace_napi.z.so ${CORE_LIB})
