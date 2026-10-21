# Meta Oakley HSTN Sandbox

A sandbox for trying the different ways to build for **Oakley Meta HSTN** glasses. Each approach is a separate sub-project. The plan is to prototype the same small feature in each one and keep whichever works best.

## The hardware reality

- HSTN has **no display**. The glasses provide a camera (12 MP ultra-wide), a 5-mic array, open-ear speakers, and (as of DAT 1.0) motion/IMU data.
- Apps **do not run on the glasses**. Your app runs on a **phone**, which connects to the glasses through the Meta AI app via the **Wearables Device Access Toolkit (DAT)**.
- DAT has official SDKs for **Android** and **iOS** only. Meta does not ship a Unity SDK. Unity and Flutter both work by wrapping the native SDK.

## Layout

```
sdks/                          upstream, git submodules (don't edit; pull to update)
  meta-wearables-dat-android/  official Android SDK + samples (CameraAccess, DisplayAccess, BirdSpotter)
  meta-wearables-dat-ios/      official iOS SDK + samples (same three)
tracks/                        our own experiments, one per approach
  android-native/              Kotlin + mwdat-* from Maven Central
  ios-native/                  Swift + SPM (needs a Mac: macbook-pro over Tailscale)
  unity-bridge/                Unity app + Android Kotlin plugin wrapping DAT (Photon Fusion sample shows the pattern)
  flutter/                     Flutter + community wrapper (flutter_meta_wearables_dat)
notes/
  sdk-comparison.md            scorecard; fill it in as each track is tried
```

## Getting started

```sh
git clone --recurse-submodules https://github.com/DeaconDP/meta-oakley-hstn-sandbox
# or, after a plain clone:
git submodule update --init
```

1. Pair the HSTN with the Meta AI app on your phone, then turn on **Developer Mode** in that app.
2. Create an app in the **Wearables Developer Center** to get an application ID.
3. Build `sdks/meta-wearables-dat-android/samples/CameraAccess` (or the iOS one) to get a baseline. The Mock Device Kit lets you test without the glasses.

## Docs for AI tools

`.mcp.json` registers Meta's public docs MCP server (`https://mcp.developer.meta.com/wearables`, no auth needed). Static docs are at https://wearables.developer.meta.com/llms.txt?full=true

## Links

- https://developers.meta.com/wearables/faq/
- https://github.com/facebook/meta-wearables-dat-android
- https://github.com/facebook/meta-wearables-dat-ios
- https://doc.photonengine.com/fusion/v2/industries-samples/fusion-meta-wearables-camera-streaming (Unity bridge reference)

## Security

This sandbox has no services and no secrets. Report a problem by opening a GitHub issue.

Created by deac.online @ worldbuild.io
