# Contributing to ShareScreen

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs

Open an [issue](../../issues/new/choose) using the **Bug report** form. Include your Mac and phone models, how they're connected (USB, Wi‑Fi or hotspot), and screenshots of any alerts.

## Development setup

**Mac app** (`mac/`): Swift Package, macOS 13 or newer, Xcode Command Line Tools.
```bash
cd mac
bash ./build.sh          # builds ShareScreen.app
open ShareScreen.app
```

**Android app** (`android/`): Kotlin, JDK 17, Android SDK (Android Studio works).
```bash
cd android
./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
```

**Testing over USB**
```bash
adb reverse tcp:8780 tcp:8780 && adb reverse tcp:8781 tcp:8781 && adb reverse tcp:8783 tcp:8783
```

## Project layout

| Path | What's there |
|---|---|
| `mac/Sources/MacScreen/VirtualDisplay.swift` | Creates the extra monitor |
| `mac/Sources/MacScreen/Capturer.swift` | ScreenCaptureKit capture |
| `mac/Sources/MacScreen/H264Encoder.swift` | Low‑latency hardware H.264 |
| `mac/Sources/MacScreen/VideoServer.swift` | TCP video stream for the app |
| `mac/Sources/MacScreen/StreamServer.swift` | HTTP + WebSocket browser viewer |
| `mac/Sources/MacScreen/Discovery.swift` | UDP auto‑discovery |
| `android/.../VideoPlayer.kt` | MediaCodec decoder and SurfaceView |
| `android/.../MainActivity.kt` | Finding the computer and the status screen |
| `host/` | Windows and Linux host |
| `linux/` | Ubuntu `.deb` packaging |

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep changes focused: one fix or feature per PR.
3. Make sure both apps still build. CI checks this automatically.
4. Describe how you tested it, ideally on a real phone.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
