#!/bin/bash

set -euo pipefail

topdir=$(dirname $(readlink -f "$0"))
cd "$topdir"

export SDL_DEBUG=true
export PULSE_LOG=4
export LIBASOUND_DEBUG=2

export LD_LIBRARY_PATH="lib32:."
if ! ldd ./lc2e > /dev/null; then
	echo "$0: ldd failed, using bundled dynamic loader and glibc" >&2
	LD_LIBRARY_PATH="lib32_glibc:$LD_LIBRARY_PATH" lib32_glibc/ld-linux.so.2 ./lc2e
elif ldd ./lc2e | grep "not found" > /dev/null; then
	echo "$0: ldd didn't find all needed libraries, using bundled dynamic loader and glibc" >&2
	LD_LIBRARY_PATH="lib32_glibc:$LD_LIBRARY_PATH" lib32_glibc/ld-linux.so.2 ./lc2e
else
	echo "$0: ldd found all needed libraries, using system dynamic loader and glibc" >&2
	./lc2e
fi
