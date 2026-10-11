#!/bin/zsh
# Builds the read-only flight recorder (never installs).
set -e
cd "$(dirname $0)"
clang -O2 -Wall -Wextra -Wno-deprecated-declarations \
  -framework IOKit -framework CoreFoundation -framework CoreGraphics -framework CoreMIDI -framework CoreAudio \
  mpc_watch.c -o mpc_watch
codesign -f -s - -i com.savilion.mpc-watch mpc_watch 2>/dev/null
