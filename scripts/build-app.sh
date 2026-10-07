#!/bin/zsh
# Builds build/MacGlance.app from the Swift package.
#   --run      (re)start it from build/
#   --install  copy it to /Applications (Spotlight, Launchpad) and start it from there
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MacGlance.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacGlance "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# The widgets: an app extension inside the app, sandboxed, at the app's version.
WIDGETS="$APP/Contents/PlugIns/MacGlanceWidgets.appex"
mkdir -p "$WIDGETS/Contents/MacOS"
cp .build/release/MacGlanceWidgets "$WIDGETS/Contents/MacOS/"
cp Resources/Widgets-Info.plist "$WIDGETS/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$WIDGETS/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Widgets.entitlements "$WIDGETS"

codesign --force --sign - "$APP"   # ad-hoc signature, enough to run locally
echo "Built $APP"

case "${1:-}" in
    --run)
        pkill -x MacGlance || true
        while pgrep -x MacGlance >/dev/null; do sleep 0.2; done
        open "$APP"
        ;;
    --install)
        pkill -x MacGlance || true   # SIGTERM: the app saves its history and quits
        while pgrep -x MacGlance >/dev/null; do sleep 0.2; done
        rm -rf /Applications/MacGlance.app
        cp -R "$APP" /Applications/
        open /Applications/MacGlance.app
        echo "Installed /Applications/MacGlance.app"
        ;;
esac
