#!/usr/bin/env bash

#
# Build script run by Xcode's "external build system" to compile our Jai executables.
#
# Note that we use PRODUCT_NAME, which is the name of the target, to assume the Jai file name.
#

# Set strict variable mode, fail on any error
set -euo pipefail

# Assume the Jai compiler lives in ~/jai if not specified via $JAI_COMPILER
JAI_COMPILER=${JAI_COMPILER:-~/jai/bin/jai-macos}

EXAMPLES_DIR=$SRCROOT/../examples

# Build the executable
cd $EXAMPLES_DIR && $JAI_COMPILER -very_debug -quiet $PRODUCT_NAME.jai
