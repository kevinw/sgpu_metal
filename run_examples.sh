#!/bin/bash -e

pushd examples || exit 1
trap popd EXIT

# Set library path for slang
export DYLD_LIBRARY_PATH="../modules/slang/mac:${DYLD_LIBRARY_PATH}"

for example in 01_memory 02_compute; do
    echo "Running ${example}..."
    jai -quiet ${example}.jai && ./${example}
done
