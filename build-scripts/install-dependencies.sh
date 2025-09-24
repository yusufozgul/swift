#!/usr/bin/env zsh

set -e
set -u
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

mkdir ~/Downloads/CMake
curl --location --retry 3 "https://github.com/Kitware/CMake/releases/download/v3.30.9/cmake-3.30.9-macos-universal.dmg" --output ~/Downloads/CMake/cmake-macos.dmg
yes | PAGER=cat hdiutil attach -quiet -mountpoint /Volumes/cmake-macos ~/Downloads/CMake/cmake-macos.dmg
cp -R /Volumes/cmake-macos/CMake.app /Applications/
hdiutil detach /Volumes/cmake-macos
sudo "/Applications/CMake.app/Contents/bin/cmake-gui" --install=/usr/local/bin
cmake --version

brew install ninja sccache distcc python3 git lld
mkdir -p ~/.distcc
echo "localhost,cpp,lzo" > ~/.distcc/hosts