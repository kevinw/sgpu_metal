name="$*"
# export MallocStackLogging=1
# export MallocStackLoggingNoCompact=1
# export NSZombieEnabled=YES
# export NSAutoreleaseFreedObjectCheckEnabled=YES
# export OBJC_DEBUG_MISSING_POOLS=YES
# export OBJC_DEBUG_POOL_DEPTH=10
cd examples && MTL_DEBUG_LAYER=1 jai -quiet $name.jai && leaks --quiet --atExit -- ./$name
