#!/bin/bash -e

pushd examples || exit 1
trap popd EXIT
for example in 01_memory 02_compute; do
    echo "Running ${example}..."
    jai -quiet ${example}.jai && ./${example}
done
