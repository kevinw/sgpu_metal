cd examples

# Set library path for slang
export DYLD_LIBRARY_PATH="../modules/slang/mac:${DYLD_LIBRARY_PATH}"

for example in 01_memory 02_compute; do
    echo "Running ${example}..."
    jai -quiet ${example}.jai && ./${example} || exit 1
done

# Run hello_square with -singleframe for automated testing
echo "Running 03_hello_square..."
jai -quiet 03_hello_square.jai && ./03_hello_square -singleframe || exit 1

# run metal + sdl example
cd ../modules/Metal/examples && jai -quiet sdl_metal.jai +Autorun -singleframe || exit 1
