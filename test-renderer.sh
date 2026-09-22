#!/bin/zsh
set -euo pipefail

# Optional integration check: requires a logged-in macOS session and Metal GPU.
ROOT_DIR="${0:A:h}"
SOURCE_ROOT="${SOURCE_ROOT:-$ROOT_DIR}"
CHECK_APP="$ROOT_DIR/.build/renderer-check/fold-like-Duo-RendererCheck.app"
mkdir -p "$CHECK_APP/Contents/MacOS" "$CHECK_APP/Contents/Resources"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
fi
xcrun swiftc -swift-version 5 -strict-concurrency=complete -O \
    -sdk "$SDK_PATH" -module-cache-path "$ROOT_DIR/.build/module-cache-renderer" \
    "$SOURCE_ROOT/Sources/EffectModel.swift" \
    "$SOURCE_ROOT/Sources/EffectRenderer.swift" \
    "$SOURCE_ROOT/Sources/SampleArtwork.swift" \
    "$SOURCE_ROOT/Sources/L10n.swift" \
    "$ROOT_DIR/Tests/RendererChecks.swift" \
    -o "$CHECK_APP/Contents/MacOS/RendererCheck" \
    -framework AppKit -framework CoreImage -framework MetalKit
cp "$SOURCE_ROOT/Resources/fold-like-Duo.metal" "$CHECK_APP/Contents/Resources/"
"$CHECK_APP/Contents/MacOS/RendererCheck"
