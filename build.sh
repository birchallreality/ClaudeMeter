#!/bin/sh
# Build ClaudeMeter.app. Pass --install to copy it to ~/Applications and launch it.
set -e
cd "$(dirname "$0")"

APP=ClaudeMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -parse-as-library ClaudeMeter.swift -o "$APP/Contents/MacOS/ClaudeMeter"
codesign --force -s - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -x ClaudeMeter 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$APP"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"$APP"
  echo "Installed to ~/Applications/$APP"
fi
