# ios-native readiness (2026-10-22)

Read-only check. Nothing was installed, built, or reconfigured.

**Verdict: ready for the mock benchmark.** Nothing blocks it. A real-HSTN run is still blocked on pairing and Developer Mode (see TODO.md).

## macbook-pro (via Tailscale)
- SSH: works with key auth. The login user isn't `deaco`, so check the `macbook-pro` entry in `~/.ssh/config` if you get publickey denied.
- macOS 26.6.2 (25G83), arm64
- Xcode 27.1 (27A9275), at `/Applications/Xcode.app`
- iOS simulator runtimes: 18.2, 18.4, 18.5, 27.0. Devices exist only on 27.0: `T3 iPhone 17`, `Emily-iphone69` (iPhone 17 Pro Max), `Emily-ipad13`.
- Disk: 86 GiB free on the Data volume (91% used). Enough, but it's getting tight.
- Signing: 1 valid identity, an Apple Development identity. 73 provisioning profiles installed.
- `devicectl` sees **iPhone 13 Pro Max (iPhone14,3)**: paired over the local network, iOS 26.6.2, Developer Mode enabled. The tunnel was disconnected at check time, and the DDI was not mounted.

## epics-macbook-air-13006 (via Tailscale)
- Online (`tailscale ping` gets a pong). It has no SSH server, so I didn't check it. Not needed.

## CameraAccess sample (sdks/meta-wearables-dat-ios/samples/CameraAccess)
- iOS 17.2+ (`IPHONEOS_DEPLOYMENT_TARGET = 17.2`), Xcode 26.4+, Swift 6.0
- SPM: `https://github.com/facebook/meta-wearables-dat-ios`, exact version 1.0.1. Products used: MWDATCore, MWDATCamera, MWDATMockDevice, MWDATMockDeviceTestClient.
- Signing is Automatic with `DEVELOPMENT_TEAM = ""`. Before running on a device, set your development team and use your own bundle ID. Developer Mode needs no META_APP_ID or CLIENT_TOKEN.

## Mock Device Kit on iOS (DAT v1.0 docs)
- **Runs in the Simulator.** The docs describe running XCUITests "on CI simulators" through the MockDevice test server, and the display preview is Simulator-only.
- The Simulator has no camera, so the mock feed has to be a **video file** (h265; the iOS sample converts it automatically) plus `setCapturedImage(fileURL:)` for photos. The "phone camera as feed" option only works on a real iPhone.
- **The iPhone 13 Pro Max works too.** It meets iOS 17.2+, has Developer Mode on, and is already paired with Xcode. Use it for the live-camera mock feed and, later, the real HSTN through the Meta AI app.

## Caveats (not blockers)
- On the mock, TTS plays through the phone or Mac. Glasses-speaker (A2DP/HFP) routing can only be checked on a real HSTN. This is the same gap the Android track has.
- I didn't check whether the Mac can reach GitHub to resolve the SPM package.
- The iPhone DDI may need to mount and the network tunnel may need to connect the first time you run on the device.
