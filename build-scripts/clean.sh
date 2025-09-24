#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

WORK_DIR="~/Documents/swift-build"

rm -rf "$WORK_DIR"

sccache --stop-server || true
rm -rf ~/.cache/sccache || true
sccache --start-server || true

rm -rf ~/Library/Developer/Xcode/DerivedData/* || true