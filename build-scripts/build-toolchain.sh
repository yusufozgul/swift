#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

START_TIME=$(date +%s)
WORK_DIR="$HOME/Documents/swift-build"
SWIFT_SOURCE_DIR="$WORK_DIR/swift"
INSTALL_DIR="$WORK_DIR/../swift-nightly-install"
PACKAGE_DIR="$WORK_DIR/../swift-swift-6.1.2-RELEASE"

sccache --start-server || true

mkdir -p "$WORK_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$WORK_DIR/symbols"
cd "$SWIFT_SOURCE_DIR"

./utils/build-script \
    --sccache \
    --preset="buildbot_osx_package,no_test,ios_simulator_only" \
    install_destdir="$INSTALL_DIR" \
    install_prefix="swift-LOCAL-a.xctoolchain/usr" \
    install_symroot="$WORK_DIR/symbols" \
    symbols_package="$PACKAGE_DIR/swift-LOCAL-a-osx-symbols.tar.gz" \
    installable_package="$PACKAGE_DIR/swift-LOCAL-a-osx.tar.gz" \
    install_toolchain_dir="swift-LOCAL-a.xctoolchain" \
    darwin_toolchain_bundle_identifier="com.yusufozgul.local" \
    darwin_toolchain_display_name="Local Swift Development Snapshot" \
    darwin_toolchain_display_name_short="Local Swift Development Snapshot" \
    darwin_toolchain_xctoolchain_name="swift-LOCAL-a" \
    darwin_toolchain_version="6.1.2.custom" \
    darwin_toolchain_alias="Local"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
HOURS=$((DURATION / 3600))
MINUTES=$(((DURATION % 3600) / 60))
SECONDS=$((DURATION % 60))

echo "Swift 6.1.2 Toolchain Build completed: $(date)"
echo "Total time: ${HOURS}s ${MINUTES}d ${SECONDS}s"
echo ""
echo "📦 Toolchain location:"
echo "   • Documents: swift-LOCAL-a.xctoolchain"

# cp /Users/yusuf/Documents/swift-build/build/buildbot_osx/swift-macosx-arm64/lib/swift/iphonesimulator/libswiftCore.dylib /Users/yusuf/Desktop/VirtualBuddyShared/SwiftBuild/libswiftCore.dylib