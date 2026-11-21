# Reel (Android)

Local-only video player and library. Plays everything libmpv plays (MKV, MP4, HEVC, AVI, ...), hardware decoding, smooth scrubbing on 1080p/4K.

## Get it built
1. Create a GitHub repo (e.g. `reel-android`), upload everything in this folder (keep `.github/workflows/build.yml`).
2. The Actions tab runs "Build Android APK" on every push. When it finishes, install `Reel.apk` from the new release (arm64, fits the OnePlus 11R).
3. If an update refuses to install, uninstall the old Reel first (each CI run signs with a fresh debug key).

## First run
Library tab -> Add folder (allow "all files access" when asked) -> pick where your videos live.

## Gestures
Tap = controls, double-tap sides = skip, double-tap middle = pause, swipe sideways = scrub, swipe left edge = brightness, swipe right edge = volume (to 130%), hold = 2x.

## Known limits
- Subtitles are text-based (SRT/ASS/VTT, plain styling). Picture subtitles (PGS/VobSub) are not drawn.
- No online posters/metadata, no network shares, no Picture-in-Picture, no "open with" from other apps.
