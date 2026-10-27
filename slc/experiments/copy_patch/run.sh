#!/usr/bin/env bash
# Run from the session workspace (slc/ inside the repository).
set -euo pipefail
mkdir -p build/copy_patch
clang -O2 -std=c11 -Wall -Wextra -Werror \
    -fno-pic -fno-pie -fno-stack-protector -fno-asynchronous-unwind-tables \
    -ffunction-sections -fcf-protection=none \
    -c experiments/copy_patch/handlers.c -o build/copy_patch/handlers.o
objdump -dr build/copy_patch/handlers.o > build/copy_patch/handlers.dis
python3 experiments/copy_patch/extract.py \
    build/copy_patch/handlers.o build/copy_patch/stencils.lua
luajit experiments/copy_patch/run.lua
luajit -joff experiments/copy_patch/run.lua
for name in affine-jumps affine-fallthrough sum-jumps sum-fallthrough; do
    objdump -D -b binary -m i386:x86-64 "build/copy_patch/$name.bin" \
        > "build/copy_patch/$name.dis"
done
