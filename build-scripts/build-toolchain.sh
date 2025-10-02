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

TEMP_PRESET_FILE="$WORK_DIR/temp-single-arch-presets.ini"
if ! sed '/^infer-cross-compile-hosts-on-darwin$/d' utils/build-presets.ini > "$TEMP_PRESET_FILE"; then
    echo "❌ failed to create preset file!"
    exit 1
fi

# Add custom preset for iOS-only build (much faster)
cat >> "$TEMP_PRESET_FILE" << 'EOF'

# Custom preset: iOS-only build for faster compilation
[preset: custom_ios_only_package]
mixin-preset=mixin_buildbot_install_components_with_clang

# ONLY macOS and iOS - no tvOS, watchOS, xrOS
ios

# Build all the necessary tools
lldb
llbuild
swiftpm
swift-driver
swiftsyntax
swift-testing
swift-testing-macros
swiftformat
playgroundsupport
indexstore-db
sourcekit-lsp
swiftdocc

# Build configuration
release-debuginfo
compiler-vendor=apple

# Assertions (lightweight)
assertions
swift-enable-ast-verifier=0
no-swift-stdlib-assertions

lldb-use-system-debugserver
lldb-build-type=Release
build-ninja
build-swift-stdlib-unittest-extra

# Disable embedded stdlib to avoid armv6 serialization crash
build-embedded-stdlib=0

# Don't build the benchmarks
skip-build-benchmarks

# CMake options
extra-cmake-options=
   -DLLDB_FRAMEWORK_COPY_SWIFT_RESOURCES=0
   -DCMAKE_C_FLAGS="-gline-tables-only"
   -DCMAKE_CXX_FLAGS="-gline-tables-only"

extra-dsymutil-args="--verify-dwarf=none"

# Install components
install-llvm
install-static-linux-config
install-swift
install-lldb
install-llbuild
install-swiftpm
install-swift-driver
install-swiftsyntax
install-swift-testing
install-swift-testing-macros
install-playgroundsupport
install-sourcekit-lsp
install-swiftformat
install-swiftdocc

install-destdir=%(install_destdir)s
darwin-install-extract-symbols
install-symroot=%(install_symroot)s
install-prefix=%(install_toolchain_dir)s/usr

test-installable-package
toolchain-benchmarks
reconfigure

installable-package=%(installable_package)s
symbols-package=%(symbols_package)s

darwin-toolchain-bundle-identifier=%(darwin_toolchain_bundle_identifier)s
darwin-toolchain-display-name=%(darwin_toolchain_display_name)s
darwin-toolchain-display-name-short=%(darwin_toolchain_display_name_short)s
darwin-toolchain-name=%(darwin_toolchain_xctoolchain_name)s
darwin-toolchain-version=%(darwin_toolchain_version)s
darwin-toolchain-alias=%(darwin_toolchain_alias)s
darwin-toolchain-require-use-os-runtime=0

build-subdir=buildbot_osx

# Skip all tests (including LLDB - rdar://67923799)
skip-test-swift
skip-test-swiftpm
skip-test-swift-driver
skip-test-llbuild
skip-test-lldb
skip-test-cmark
skip-test-playgroundsupport
skip-test-swiftsyntax
skip-test-swiftformat
skip-test-skstresstester
skip-test-swiftdocc
skip-test-sourcekit-lsp
skip-test-indexstore-db

# Don't configure LLDB tests to avoid building libcxx (rdar://109774179)
lldb-configure-tests=0
EOF

./utils/build-script \
    --sccache \
    --preset-file=$TEMP_PRESET_FILE \
    --preset="custom_ios_only_package" \
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

rm -f "$TEMP_PRESET_FILE" || true

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
