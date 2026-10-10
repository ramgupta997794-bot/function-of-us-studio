# Function of Us Studio

Cinematic math-story graph video generator — dark, neon, 1080x1920 (9:16),
Shorts/Reels style. Type equations, get a story-driven animated graph video.

## Files
- `main.dart` — the whole app (single file, as requested).
- `pubspec.yaml` — dependencies.

## Run
```
flutter create function_of_us_studio
# replace lib/main.dart and pubspec.yaml with the ones here
flutter pub get
flutter run
```

## Platforms
`ffmpeg-kit` (used for MP4 encoding) works on **Android / iOS only** — it will
not build for web/desktop. Use a physical device or emulator.

## Required permissions

**Android** — `android/app/src/main/AndroidManifest.xml`
```xml
<uses-permission android:name="android.permission.INTERNET"/>            <!-- google_fonts -->
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>    <!-- save to gallery -->
```

**iOS** — `ios/Runner/Info.plist`
```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Save your exported video to Photos.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Save your exported video to Photos.</string>
```

## How it works
- **Equation engine** — `math_expressions` parses `y=...` inputs. `cbrt(x)` is
  rewritten as `u/(u*u)^(1/3)` since the library has no cube root (correct for
  negatives; NaN at 0 is dropped by the sampler).
- **Cinematic animation** — a 12s `AnimationController` drives a `CustomPainter`:
  left-to-right draw-in with additive neon bloom + a bright trailing head, a
  camera that eases from a wide `[-9,9]` establishing shot into a slow push-in
  near the origin (keyframed), floating labels pinned to each curve head, a
  dashed low-opacity `y=x` reference line, and an adaptive moving grid.
- **Story mode** — four curves on a timeline: The Stranger (0s) → The Friend
  (4s) → The Lover (8s) → The Ex diverges (11s), with fading captions.
- **Export** — drives the controller frame-by-frame through a `RepaintBoundary`
  at 1080x1920, writes PNG frames, encodes H.264 MP4 with ffmpeg, saves to the
  gallery (`gal`) and offers a share sheet (`share_plus`).

## Tweaking the story
Edit `defaultCurves()` (labels, equations, colors) and the `appear`/`duration`
fractions. Camera moves live in `kCameraKeys`. Export length is `kTimelineSeconds`.
