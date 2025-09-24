#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

WORK_DIR="/Users/yusuf/Documents/swift-build"
SWIFT_SOURCE_DIR="$WORK_DIR/swift"
INSTALL_DIR="$WORK_DIR/swift-nightly-install"
PACKAGE_DIR="$WORK_DIR/swift-swift-5.10.1-RELEASE"
TOOLCHAIN_DIR="$WORK_DIR/toolchains"

rm -rf "$WORK_DIR"
rm -rf "/Library/Developer/Toolchains/swift-LOCAL-"*".xctoolchain"

sccache --stop-server || true
rm -rf ~/.cache/sccache || true
sccache --start-server || true

rm -rf ~/Library/Developer/Xcode/DerivedData/* || true