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

## Features

- Reads the real MacBook lid angle through IOKit HID.
- Captures the local desktop with ScreenCaptureKit and excludes its own overlay.
- Keeps the effect at the current angle while the lid is still.
- Clears safely after reopening, sensor loss, sleep, or display changes.
- Includes a permission-free sample preview and an emergency `⌘⇧Esc` pause.
- Builds as a Universal 2 app for Apple silicon and Intel.

## Requirements

- macOS 14 Sonoma or later
- A MacBook exposing Apple's lid-angle sensor (`VID 0x05AC`, `PID 0x8104`)
- Screen Recording permission for the live effect
- Xcode Command Line Tools when building from source

## Build

```sh
./test.sh       # build and run checks
./package.sh    # create dist/fold-like-Duo-1.0.0.dmg
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
