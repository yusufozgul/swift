#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

START_TIME=$(date +%s)
WORK_DIR="~/Documents/swift-build"
SWIFT_SOURCE_DIR="$WORK_DIR/swift"
INSTALL_DIR="$WORK_DIR/../swift-nightly-install"
PACKAGE_DIR="$WORK_DIR/../swift-swift-5.10.1-RELEASE"
TOOLCHAIN_DIR="$WORK_DIR/../toolchains"
DATE_FORMATTED=$(date '+%Y-%m-%d')
DATE_COMPACT=$(date '+%Y%m%d')

sccache --start-server || true

mkdir -p "$WORK_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$TOOLCHAIN_DIR"
mkdir -p "$WORK_DIR/symbols"
cd "$SWIFT_SOURCE_DIR"

TEMP_PRESET_FILE="$WORK_DIR/temp-single-arch-presets.ini"
if ! sed '/^infer-cross-compile-hosts-on-darwin$/d' utils/build-presets.ini > "$TEMP_PRESET_FILE"; then
    echo "❌ failed to create preset file!"
    exit 1
fi

./utils/build-script \
    --sccache \
    --preset-file=$TEMP_PRESET_FILE \
    --preset="buildbot_osx_package,no_test" \
    install_destdir="$INSTALL_DIR" \
    install_prefix="$TOOLCHAIN_DIR/swift-LOCAL-$DATE_FORMATTED-a.xctoolchain/usr" \
    install_symroot="$WORK_DIR/symbols" \
    symbols_package="$PACKAGE_DIR/swift-LOCAL-$DATE_FORMATTED-a-osx-symbols.tar.gz" \
    installable_package="$PACKAGE_DIR/swift-LOCAL-$DATE_FORMATTED-a-osx.tar.gz" \
    install_toolchain_dir="$TOOLCHAIN_DIR/swift-LOCAL-$DATE_FORMATTED-a.xctoolchain" \
    darwin_toolchain_bundle_identifier="com.yusuf.$DATE_COMPACT" \
    darwin_toolchain_display_name="Local Swift Development Snapshot $DATE_FORMATTED" \
    darwin_toolchain_display_name_short="Local Swift Development Snapshot" \
    darwin_toolchain_xctoolchain_name="swift-LOCAL-$DATE_FORMATTED-a" \
    darwin_toolchain_version="5.10.$DATE_COMPACT" \
    darwin_toolchain_alias="Local"

rm -f "$TEMP_PRESET_FILE" || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
HOURS=$((DURATION / 3600))
MINUTES=$(((DURATION % 3600) / 60))
SECONDS=$((DURATION % 60))

echo "Swift 5.10.1 Toolchain Build completed: $(date)"
echo "Total time: ${HOURS}s ${MINUTES}d ${SECONDS}s"
echo ""
echo "📦 Toolchain location:"
echo "   • Documents: $TOOLCHAIN_DIR/swift-LOCAL-$DATE_FORMATTED-a.xctoolchain"
