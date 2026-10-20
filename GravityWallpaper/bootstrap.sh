#!/bin/zsh
# Run once from the GravityWallpaper/ directory to generate the Xcode project and open it.
set -e

cd "$(dirname "$0")"

if ! command -v xcodegen &>/dev/null; then
    echo "Installing XcodeGen via Homebrew…"
    brew install xcodegen
fi

echo "Generating Xcode project…"
xcodegen generate

echo "Opening in Xcode…"
open GravityWallpaper.xcodeproj
