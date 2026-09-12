#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="fold-like-Duo"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

"$ROOT_DIR/build.sh"

STAGE_DIR=$(mktemp -d /private/tmp/fold-like-duo-package.XXXXXX)
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$DIST_DIR/$APP_NAME.app" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

echo "Packaged $DMG_PATH"
