#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

git clone --depth 1 --branch swift-5.10.1-RELEASE-CustomDevelopments https://github.com/yusufozgul/swift swift

cd "swift"

./utils/update-checkout --tag swift-5.10.1-RELEASE --clone