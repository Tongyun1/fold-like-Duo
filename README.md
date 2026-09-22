<p align="center">
  <img src="Resources/fold-like-Duo-AppIcon-Source.png" width="128" alt="fold-like-Duo icon">
</p>

# fold-like-Duo

[简体中文](README.zh-CN.md) | English

A native macOS menu-bar app that makes the desktop follow a MacBook lid as it
closes. The real lid-angle sensor drives a Metal-rendered perspective, blur,
frost, and shadow effect.

English and Simplified Chinese are included. No third-party dependencies are
required.

<p align="center">
  <img src="docs/fold-like-Duo-preview.gif" width="640" alt="Animated preview of the fold-like-Duo effect">
</p>

## Features

- Reads the real MacBook lid angle through IOKit HID.
- Captures the local desktop with ScreenCaptureKit and excludes its own overlay.
- Keeps the effect at the current angle while the lid is still.
- Reduces live capture from up to 60 fps to 5 fps after the lid rests for
  0.75 seconds; unchanged frames and effect parameters leave rendering paused.
- Clears safely after reopening, sensor loss, sleep, or display changes.
- Includes a permission-free sample preview and an emergency `⌘⇧Esc` pause.
- Builds as a Universal 2 app for Apple silicon and Intel.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel processor; the release is a Universal 2 app
- Automatic folding requires a MacBook whose Apple lid-angle sensor is
  accessible; the current implementation detects `VID 0x05AC`, `PID 0x8104`
  at runtime
- Some M1/M2 Touch Bar models may not expose an angle through this HID
  interface; the sample preview remains available on unsupported hardware
- The effect applies only to the built-in MacBook display, not external displays
- A Metal-capable GPU
- Screen Recording permission for the live effect
- Xcode 15 or matching Xcode Command Line Tools when building from source

## Install and open for the first time

1. Download and open the DMG, then drag `fold-like-Duo.app` into Applications.
2. Open fold-like-Duo from Applications.
3. The current public build is not Apple-notarized. If macOS says it cannot
   verify the developer or blocks the app, open **System Settings → Privacy &
   Security**, scroll down to **Security**, and click **Open Anyway** next to
   the fold-like-Duo message.
4. Authenticate with Touch ID or your login password, then click **Open** in
   the final confirmation dialog.

This is normally required only once. Only open builds downloaded from this
project's official GitHub Releases page.

## Build

```sh
./test.sh       # build and run checks
./test-renderer.sh # optional Metal regression checks in a logged-in macOS session
./package.sh    # create dist/fold-like-Duo-1.0.1.dmg
```

The default build is ad-hoc signed. For distribution with a Developer ID:

```sh
SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' ./package.sh
```

Developer ID releases must also be notarized with the distributor's Apple
Developer credentials.

## Privacy

fold-like-Duo needs Screen Recording permission only to render the live desktop as
the folding surface. Frames stay in memory and are never saved or uploaded.
Audio and the pointer are not captured, and the app has no network feature.

On first launch, the app asks macOS to show the Screen Recording permission
prompt automatically. If access was previously denied, use the Privacy Settings
button because macOS does not show the system prompt a second time.

Launch at Login is optional. Reading the built-in lid sensor and registering the
emergency shortcut do not require additional privacy permissions.

## Project layout

```text
Sources/       Swift, AppKit, SwiftUI, ScreenCaptureKit, and Metal integration
Resources/     Metal shader, icon, and localizations
build.sh       Universal app builder
package.sh     Drag-to-Applications DMG builder
test.sh        Bundle, localization, signature, and behavior checks
```

## License

MIT. See [NOTICE.md](NOTICE.md) for acknowledgements of the open-source projects
studied while designing fold-like-Duo. fold-like-Duo is not affiliated with Apple.
