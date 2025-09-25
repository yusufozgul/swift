#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

mkdir -p "$HOME/Documents/swift-build" || true
cd "$HOME/Documents/swift-build"

git clone --depth 1 --branch swift-6.1.2-RELEASE-CustomDevelopments https://github.com/yusufozgul/swift swift

cd "swift"

./utils/update-checkout --tag swift-6.1.2-RELEASE --clone
git checkout swift-6.1.2-RELEASE-CustomDevelopments