#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

export SDL_DEBUG=true
export PULSE_LOG=4
export LIBASOUND_DEBUG=2

LD_LIBRARY_PATH="lib32:." lib32/ld-linux.so.2 ./lc2e $@