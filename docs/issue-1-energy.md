# Issue #1: energy use while the lid is partially closed

Issue: https://github.com/Tongyun1/fold-like-Duo/issues/1

The report describes heat, particularly with the lid partially closed. It does
not include a hardware model, CPU/GPU measurements, or a temperature trace.
The following sustained-work paths were found in the code at `1f977a7`.

## Causes and changes

- An armed effect kept a 60 fps ScreenCaptureKit stream running indefinitely.
  Every new desktop frame uploads an image and rebuilds the blur pyramid. After
  0.75 seconds without meaningful lid movement, capture now requests at most
  5 fps. Motion restores 60 fps without restarting the stream. Content therefore
  remains live, with up to roughly 200 ms between updates while resting.
- The 60 Hz sensor loop assigned identical effect parameters and progress on
  every tick. Both setters unpaused the Metal view, undoing its existing pause
  after settling. Equal values now leave it paused, and the angle filter snaps
  to its target within 0.01 degrees. New content or changed parameters still draw.
- Sensor polling now uses 60 Hz during movement, 10 Hz at rest, and 1 Hz when
  automatic operation cannot run. Missing sensors retry every five seconds.
  Sleep/session suspension cancels polling and disconnects HID. Detecting motion
  from rest can take roughly 100 ms before fast polling resumes.
- Whole-degree status and unchanged messages are no longer published on every
  tick. This also avoids repeatedly updating the settings preview.
- Rendering is capped at 60 fps instead of 120 fps. Hidden overlays explicitly
  stop rendering and reject late images. Capture shutdown invalidates pending
  starts, frame-rate updates, and callbacks from old streams.
- Failure to obtain a drawable/command buffer now returns the acquired in-flight
  semaphore slot, preventing the renderer from exhausting its slots.

## Verification

`./test.sh` builds both arm64 and x86_64, runs behavior checks, and checks bundle
resources, signing, and English/Chinese localizations. Activity regressions cover
stationary input, small jitter, cumulative slow movement, reopening, and settling.

`./test-renderer.sh` uses an offscreen window and generated artwork with a real
Metal renderer; it does not read the screen or lid sensor. It checks that repeated
unchanged inputs stay paused, that angle/appearance/content changes redraw and
settle, and that stopping cancels rendering. It requires a logged-in macOS GUI
session with Metal and is separate from the headless CI checks.

On 2026-09-22, the same stationary-input scenario (120 equal parameter/progress
updates, approximately two seconds, after initial settling) submitted **93 extra
GPU frames** with the original renderer and **0** with the fixed renderer. The
original source was extracted from `1f977a7` for this comparison. This demonstrates
removal of redundant rendering, not a measured battery-life or temperature gain.

Physical-lid operation, ScreenCaptureKit's delivered live frame rate, sleep/wake,
and long-duration temperature/energy measurements still require manual testing.
For a useful comparison, keep hardware, brightness, background apps, desktop
content, lid angle, and test duration the same; compare open idle, moving lid,
stationary half-closed lid, and paused states. Check reopening and `⌘⇧Esc`, then
repeat sleep/wake and confirm capture stops and can resume after new lid motion.
