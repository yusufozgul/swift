#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

WORK_DIR="$HOME/Documents/swift-build"

rm -rf "$WORK_DIR"

sccache --stop-server || true
rm -rf $HOME/.cache/sccache || true
sccache --start-server || true

rm -rf $HOME/Library/Developer/Xcode/DerivedData/* || true