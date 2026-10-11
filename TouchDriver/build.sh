#!/bin/zsh
# Builds mpc_touchd v3 here (never installs). Ad-hoc signed as com.savilion.mpc-touchd.
set -e
cd "$(dirname $0)"
clang -x objective-c -O2 -Wall -Wextra -Wno-deprecated-declarations \
  -framework IOKit -framework CoreFoundation -framework CoreGraphics -framework CoreMIDI -framework ApplicationServices -framework AppKit \
  mpc_touchd.c -o mpc_touchd
codesign -f -s - -i com.savilion.mpc-touchd mpc_touchd
shasum -a 256 mpc_touchd
