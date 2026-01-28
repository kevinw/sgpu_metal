# Project description
- We're reimplementing sgpu, a minimal Jai gpu abstraction library, in Metal for macOS. The original Vulkan implementation is at ../sgpu, but we should not make changes there.
- Jai's standard library can be found at ~/jai/modules but we should not make changes there.

# Bash commands
- run-examples.sh: Build and run the examples

# Code style
- For Jai casts: prefer the cast(s32)foo syntax instead of foo.(s32)

# Workflow
- Ensure examples run when you're done making a series of code changes.
