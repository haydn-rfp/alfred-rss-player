#!/bin/sh
# Build Alfred RSS Player and install it to ~/Applications.  Usage: ./build.sh
set -e
cd "$(dirname "$0")"
APP="build/Alfred RSS Player.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift -o "$APP/Contents/MacOS/AlfredRSSPlayer"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
mkdir -p "$HOME/Applications"
pkill -x AlfredRSSPlayer 2>/dev/null || true; pkill -x AlfredPlayer 2>/dev/null || true
rm -rf "$HOME/Applications/Alfred RSS Player.app" "$HOME/Applications/Alfred Player.app"
cp -R "$APP" "$HOME/Applications/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Alfred RSS Player.app"
echo "Installed ~/Applications/Alfred RSS Player.app"
