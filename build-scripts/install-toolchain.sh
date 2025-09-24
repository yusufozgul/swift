#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

WORK_DIR="$HOME/Documents/swift-build"
PACKAGE_DIR="$WORK_DIR/../swift-swift-5.10.1-RELEASE"
USER_TOOLCHAIN_DIR="$HOME/Library/Developer/Toolchains"
DATE_FORMATTED=$(date '+%Y-%m-%d')

TOOLCHAIN_PACKAGE=$(find "$PACKAGE_DIR" -name "swift-LOCAL-*-osx.tar.gz" -type f | sort -r | head -n1)

rm -rf "$USER_TOOLCHAIN_DIR"/swift-LOCAL*
tar -xzf "$TOOLCHAIN_PACKAGE" -C "$USER_TOOLCHAIN_DIR/"

EXTRACTED_TOOLCHAIN=$(find "$USER_TOOLCHAIN_DIR" -name "swift-LOCAL-*-a.xctoolchain" -type d | head -n1)
TOOLCHAIN_NAME=$(basename "$EXTRACTED_TOOLCHAIN")
FINAL_TOOLCHAIN_PATH="$USER_TOOLCHAIN_DIR/$TOOLCHAIN_NAME"

mv "$EXTRACTED_TOOLCHAIN" "$FINAL_TOOLCHAIN_PATH" 2>/dev/null || true

cp /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/15.0.0/lib/darwin/libclang_rt.profile_iossim.a "$FINAL_TOOLCHAIN_PATH/usr/lib/clang/15.0.0/lib/darwin/libclang_rt.profile_iossim.a" 2>/dev/null || true

