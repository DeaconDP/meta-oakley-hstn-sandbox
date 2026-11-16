# ios-native

Swift app using the DAT Swift Package. Needs Xcode, so build on macbook-pro (100.111.251.47) over Tailscale.
See READINESS.md (2026-10-22).

`HstnBench/` is the SpeakUp iOS app. It started as a copy of `sdks/meta-wearables-dat-ios/samples/CameraAccess` (mwdat 1.0.1).

After setup there is one screen: what the glasses are doing, a big **Read text** button, the reading card while something is being read, and Settings (voice, Replay setup, Disconnect). There are no camera steps to take by hand. Read starts the session and the stream itself, and going to the background ends them. Magic Tap reads or stops reading, and voice commands, Siri ("Read", "Status", "Repeat") and VoiceOver actions do the same things. The sample's photo capture, video recording and session/preview controls were removed on 2026-11-16.

The step-2 benchmark mirrors the android-native track:

- `CameraAccess/Bench/BenchClock.swift` logs timings to the unified log (subsystem `com.deaco.hstnbench`, category `HstnBench`) as `metric=<name> ms=<n>`, the same layout as Android.
- The hooks are in `CameraAccess/ViewModels/CameraViewModel.swift` (session, first frame, read photo) and `CameraAccess/A11y/Read/TextReader.swift` (trigger to first word, OCR, frame age).
- Bundle ID is `com.deaco.hstnbench` and the callback scheme is `hstnbench`, so it installs alongside the upstream sample.

Copy `bench.sh` and `HstnBench/` to the Mac, then run `./bench.sh [runs]` there. It creates and uses its own simulator ("HstnBench iPhone 17", the newest iOS runtime) and runs the `ReadAloudUITests/testReadAloud` UI test to drive the mock flow. Results go in `notes/bench-ios-native.md`. Earlier results there time the photo flow, which no longer exists.

```sh
tar cf - bench.sh HstnBench | ssh <user>@macbook-pro 'mkdir -p ~/hstn-bench && cd ~/hstn-bench && tar xf - && ./bench.sh 5'
```

Signing stays Automatic with an empty team, which is fine for the Simulator. Set your team before running on the iPhone.
