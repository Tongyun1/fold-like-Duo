#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP="$ROOT_DIR/dist/fold-like-Duo.app"

"$ROOT_DIR/build.sh"
plutil -lint "$APP/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist") == "fold-like-Duo.icns" ]]
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/fold-like-Duo" --self-test
test -f "$APP/Contents/Resources/fold-like-Duo.metal"
test -f "$APP/Contents/Resources/fold-like-Duo.icns"
test -f "$APP/Contents/Resources/NOTICE.md"
plutil -lint "$APP/Contents/Resources/en.lproj/Localizable.strings"
plutil -lint "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
plutil -lint "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
plutil -lint "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

EN_PROBE=$("$APP/Contents/MacOS/fold-like-Duo" -AppleLanguages '(en)' --localization-probe)
ZH_PROBE=$("$APP/Contents/MacOS/fold-like-Duo" -AppleLanguages '(zh-Hans)' --localization-probe)
[[ "$EN_PROBE" == $'Settings…\nLid angle: 42°' ]]
[[ "$ZH_PROBE" == $'设置…\n屏幕角度：42°' ]]
echo "fold-like-Duo bundle checks passed"
