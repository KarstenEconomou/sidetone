#!/bin/bash

build_rnnoise() {
    local output="$1"
    local flags=(-O3 -DRNNOISE_BUILD -DDISABLE_DEBUG_FLOAT -IThirdParty/RNNoise/include -IThirdParty/RNNoise/src)
    if [[ "${SANITIZER:-}" != "" ]]; then
        flags+=(-fsanitize="$SANITIZER" -fno-omit-frame-pointer)
    fi
    mkdir -p "$output"
    local source
    local objects=()
    for source in ThirdParty/RNNoise/src/*.c; do
        local object="$output/$(basename "${source%.c}").o"
        xcrun clang "${flags[@]}" -c "$source" -o "$object"
        objects+=("$object")
    done
    xcrun ar rcs "$output/librnnoise.a" "${objects[@]}"
}
