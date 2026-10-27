# ios-native

Swift app using the DAT Swift Package. Needs Xcode, so build on macbook-pro (100.111.251.47) over Tailscale.
See READINESS.md (2026-10-22).

`HstnBench/` is a copy of `sdks/meta-wearables-dat-ios/samples/CameraAccess` (mwdat 1.0.1) with the step-2 benchmark added, mirroring the android-native track:

- `CameraAccess/Bench/BenchClock.swift` logs timings to the unified log (subsystem `com.deaco.hstnbench`, category `HstnBench`) as `metric=<name> ms=<n>`, the same layout as Android.
- `CameraAccess/Bench/TtsReply.swift` speaks "Photo captured." after each photo with AVSpeechSynthesizer on a playback audio session, so it goes to the glasses over A2DP when they're connected. It logs `route=a2dp|hfp|phone`.
- The hooks are in `CameraAccess/ViewModels/CameraViewModel.swift` (search for `benchClock`).
- Bundle ID is `com.deaco.hstnbench` and the callback scheme is `hstnbench`, so it installs alongside the upstream sample.

Copy `bench.sh` and `HstnBench/` to the Mac, then run `./bench.sh [runs]` there. It creates and uses its own simulator ("HstnBench iPhone 17", the newest iOS runtime) and reuses the upstream `testPhotoCaptureAndDismiss` UI test to drive the mock flow. Results go in `notes/bench-ios-native.md`.

```sh
tar cf - bench.sh HstnBench | ssh <user>@macbook-pro 'mkdir -p ~/hstn-bench && cd ~/hstn-bench && tar xf - && ./bench.sh 5'
```

Signing stays Automatic with an empty team, which is fine for the Simulator. Set your team before running on the iPhone.
