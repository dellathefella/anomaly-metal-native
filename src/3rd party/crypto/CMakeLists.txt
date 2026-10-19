# Anomaly's crypto wrapper (DSA sign/verify + SHA) for stats submission.
# On Windows it statically embeds a vendored OpenSSL 1.0; on macOS we link
# brew's OpenSSL 3 (DSA_* APIs are deprecated there but still functional).

if(APPLE AND NOT OPENSSL_ROOT_DIR)
    set(OPENSSL_ROOT_DIR "/opt/homebrew/opt/openssl@3")
endif()
find_package(OpenSSL REQUIRED)

add_library(xrcrypto crypto.cpp xr_dsa.cpp xr_sha.cpp)

target_include_directories(xrcrypto
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    PRIVATE
    "${XRAY_SOURCE_DIR}/src"
)

target_link_libraries(xrcrypto PUBLIC OpenSSL::Crypto xrCore)

if(NOT MSVC)
    target_compile_definitions(xrcrypto PRIVATE _MT)
    target_compile_options(xrcrypto PRIVATE -w)
endif()

set_target_properties(xrcrypto PROPERTIES PREFIX "")
