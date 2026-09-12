#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="fold-like-Duo"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_PATH/Contents"
EXECUTABLE="$CONTENTS/MacOS/$APP_NAME"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

mkdir -p "$BUILD_ROOT/module-cache" "$DIST_DIR" "$CONTENTS/MacOS" "$CONTENTS/Resources"

SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ "$SDK_PATH" == *"MacOSX26.2.sdk" || "$SDK_PATH" == *"MacOSX.sdk" ]] \
   && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
fi

ARCH_SPEC="${ARCHS:-arm64 x86_64}"
ARCH_LIST=(${=ARCH_SPEC})
BINARIES=()
for ARCH in $ARCH_LIST; do
    ARCH_BINARY="$BUILD_ROOT/$APP_NAME-$ARCH"
    xcrun swiftc \
        -swift-version 5 \
        -strict-concurrency=complete \
        -O \
        -target "$ARCH-apple-macos14.0" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$BUILD_ROOT/module-cache-$ARCH" \
        "$ROOT_DIR"/Sources/*.swift \
        -o "$ARCH_BINARY" \
        -framework AppKit \
        -framework Carbon \
        -framework Combine \
        -framework CoreImage \
        -framework IOKit \
        -framework MetalKit \
        -framework ScreenCaptureKit \
        -framework ServiceManagement
    BINARIES+=("$ARCH_BINARY")
done

if (( ${#BINARIES[@]} == 1 )); then
    cp "${BINARIES[1]}" "$EXECUTABLE"
else
    lipo -create $BINARIES -output "$EXECUTABLE"
fi

cp "$ROOT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/Resources/fold-like-Duo.icns" "$CONTENTS/Resources/fold-like-Duo.icns"
cp "$ROOT_DIR/Resources/fold-like-Duo.metal" "$CONTENTS/Resources/fold-like-Duo.metal"
cp "$ROOT_DIR/NOTICE.md" "$CONTENTS/Resources/NOTICE.md"
mkdir -p "$CONTENTS/Resources/en.lproj" "$CONTENTS/Resources/zh-Hans.lproj"
cp "$ROOT_DIR/Resources/en.lproj/Localizable.strings" "$CONTENTS/Resources/en.lproj/Localizable.strings"
cp "$ROOT_DIR/Resources/en.lproj/InfoPlist.strings" "$CONTENTS/Resources/en.lproj/InfoPlist.strings"
cp "$ROOT_DIR/Resources/zh-Hans.lproj/Localizable.strings" "$CONTENTS/Resources/zh-Hans.lproj/Localizable.strings"
cp "$ROOT_DIR/Resources/zh-Hans.lproj/InfoPlist.strings" "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings"
chmod +x "$EXECUTABLE"

xattr -cr "$APP_PATH"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Built $APP_PATH"
