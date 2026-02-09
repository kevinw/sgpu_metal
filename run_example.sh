name="$*"

# export MallocStackLogging=1
# export MallocStackLoggingNoCompact=1
# export NSZombieEnabled=YES
# export NSAutoreleaseFreedObjectCheckEnabled=YES
# export OBJC_DEBUG_MISSING_POOLS=YES
# export OBJC_DEBUG_POOL_DEPTH=10

export METAL_DEVICE_WRAPPER_TYPE=1
export MTL_LOG_TO_STDERR=1
export MTL_DEBUG_LAYER=1
export MTL_LOG_LEVEL=MTLLogLevelDebug
export MTL_LOG_BUFFER_SIZE=2048

cd examples &&  jai -quiet build.jai - $name && pushd bin && leaks --quiet --atExit -- ./$name
