# Glasses optional on iOS: the iPhone's camera (V0)

Written 2026-11-19. Roadmap item V0 in notes/value-strategy.md > 6. SpeakUp's iOS app now reads with the iPhone alone: the back camera, the phone mic, the speaker or headphones, and the screen. No Meta AI app, no registration and no glasses are needed. Glasses are an upgrade. It works in the touch toolbox and in hands-free mode (notes/hands-free-mode.md). Android has the same feature in notes/phone-camera.md; the setting, phrases and fallback line match.

## What was built

All new code is under `tracks/ios-native/HstnBench/CameraAccess/A11y/Read/`.

- `PhoneFrameSource.swift`: the phone camera as a `ReadFrameSource`. One `AVCaptureSession` with the back wide camera, preset `.photo`. `AVCaptureVideoDataOutput` keeps the latest frame as a pixel buffer and turns it into an image only when the reader asks. `AVCapturePhotoOutput` takes a full-resolution JPEG for small print and for the cloud path. Frames are rotated to portrait. Focus prefers near range. Nothing starts until the first read, so there is no camera prompt at launch. Going to the background stops it.
- `CameraSourceRouter.swift`: the `ReadFrameSource` that `TextReader` reads from. It forwards each call to the phone or the glasses and can switch while the app runs. Switching stops the camera that is no longer used, says which camera is in use, and plays an earcon. It imports nothing from the DAT SDK.
- `CameraSource.swift`: the setting, the pure rules (`CameraSourcePolicy`), the phone's problems (`PhoneCameraProblem`) and their spoken lines.
- `PhoneCameraViews.swift`: the camera card on the main screen.
- `ReadFrameSource` gained `cameraKind` and `stopReadingStream()`, with defaults, so guidance can fit the camera.

## The setting

`A11yPreferences.cameraSource`: `auto` (default), `phone` or `glasses`.

- **Auto** is the phone until glasses are linked through Meta AI. Once linked, it is the glasses. If they don't turn up within the main screen's usual wait (`waitForDeviceReport`, 2 s), it says "Glasses not connected. Using the phone camera." once and uses the phone. If the glasses turn up later, it says "Glasses connected. Using the glasses camera." and switches: at once when nothing is being read, otherwise at the next read. A read started before the wait ends doesn't wait for absent glasses.
- **Phone** always uses the phone.
- **Glasses** always uses the glasses. Without linked glasses, the main screen gives way to the connect screen (`HomeScreenView`), which also has "Use my iPhone's camera".
- A switch by voice or on screen is saved, so it holds on the next launch.

## Onboarding

The one setup screen now offers two choices. "Use my iPhone's camera" is the primary button: it sets the camera to phone, skips Meta AI and registration, and lands on the main screen with Read text working. "Connect glasses" is the second button and works as before. By voice: "phone" or "use the phone" picks the phone, "connect" connects. "Not now" also picks the phone. Glasses can be connected later from Settings ("Connect my glasses"), from the camera switch, or by saying "connect" on the main screen.

`NSCameraUsageDescription` now says, plainly, what the camera is for and when a page leaves the phone (only with the natural voice).

## Voice phrases

On the main screen, in both modes, and with "reader, …" while the app is speaking:

- "use the phone", "use the phone camera", "use my iPhone", "switch to the phone"
- "use the glasses", "use the glasses camera", "switch to the glasses"
- "which camera": "You're using the phone camera, chosen automatically."
- "torch on" / "torch off" (also "flashlight on", "turn on the torch")

On the setup screen, "phone" and "use the phone" pick the phone, and "use the glasses" connects. On the connect screen, "use the phone" goes back to the phone. Help lists "which camera", "use the phone" and "torch on". None of the new phrases clash with the old ones; tests check that every command's own phrase still means that command on every screen where it is offered.

## Phone pitfalls

With the phone as the camera, the glasses' connection, folded, removed and battery lines, and the firmware-update block, are skipped. The phone has its own:

- **Camera access off**: "Camera access is off for SpeakUp. To turn it on, open the Settings app, choose Apps, then SpeakUp, and turn on Camera." The card shows an Open Settings button.
- **Restricted** (Screen Time or a profile): says to ask whoever manages the phone.
- **No camera** (the Simulator): "No camera available on this device." It never asks for permission.
- **Taken by another app or split view**: "Another app is using the camera…", said in both modes, then "Phone camera back." when it returns.
- **Runtime error** or **setup failure**: says to read again.
- **Too dark**: the reader's existing framing check. For the phone the guidance is "Too dark to read. Say torch on, or move somewhere brighter, then read again."

All the framing guidance has phone wording: "Hold the phone flat, about 30 centimetres above the page", "Move the phone a little right", "Raise the phone a little". The glasses' wording is unchanged. The first time, iOS's camera prompt is introduced with "iPhone will ask to use the camera. Choose Allow."

## The main screen

A "Camera" card sits under the status. It has a labelled Automatic / Phone / Glasses switch (a menu at accessibility text sizes), a caption saying which camera is in use, the phone's live preview (one VoiceOver element, "Phone camera view", On or "Off until you read"), and a Torch switch when the phone has one. A phone problem replaces the preview with the problem and its fix. The status card and the spoken status line follow the phone. Spoken tips have two new situations: ready with the phone ("Hold the phone flat… say read. In a dark room, say torch on.") and camera blocked.

UI tests keep the old glasses-only screens unless launched with `--phone-camera`.

## Tests

`CameraAccessTests/PhoneCameraTests.swift` (30 tests): the policy table, the setting's default and persistence, the router with a fake phone and fake glasses (fallback said once, coming back, not switching mid-read, early fallback on read, switching and stopping the other camera, "use the glasses" without linked glasses, torch, "which camera", status line), the new phrases and their non-conflict, help, the pitfall wording, phone guidance, and the no-camera path: `PhoneFrameSource` with no device, the Simulator's real default, and a full `TextReader` read that ends in "No camera available on this device." Existing tests were updated for the new welcome and tips wording.

Unit tests on the iPhone 17 Simulator (iOS 27.0, Xcode 27.2): 229 run with 1 failure before, 259 run with 1 failure after. The failure is the known `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay` ("The display didn't start").

## App Store build without the DAT SDK

Meta's docs (build-integration-ios > Prerequisites, DAT v1.0): "since the SDK currently uses the ExternalAccessory framework, it will lead to App Store rejection due to Apple's MFi program and privacy manifest requirements." A store build must not link the SDK. **Not built in this change**: it isn't contained enough.

What it would take:

- **18 app files import `MWDAT*`**, and 5 more use `CameraViewModel` or `WearablesViewModel` without importing it (`CameraNarration`, `CameraViewModel+Read`, `LaunchIntents`, two MockDeviceKit views). Tests: 3 files import it.
- **Leave out of the store target (10 files)**: `ViewModels/CameraViewModel.swift`, `ViewModels/WearablesViewModel.swift`, `Views/RegistrationView.swift`, the 5 MockDeviceKit files, `A11y/HandsFree/DATGlassesDisplay.swift`, `A11y/Voice/GlassesSpeechListener.swift`. Plus `CameraViewModel+Read/+Status`, `CameraProblem` and the `CameraViewModel` extension in `VoiceCoach`.
- **Rework behind a protocol (about 8 files)**: `CameraView` (574 lines, typed on both view models throughout), `OnboardingView`, `HomeScreenView`, `MainAppView`, `CameraAccessApp` (`Wearables.configure`, the mock test server), `CameraNarrator`/`CameraNarration`, `VoiceControl` (`attachGlasses(session:wearables:)`). The clean way is a `GlassesLink` protocol (registration state as an app enum, connect, disconnect, notice, update required) and a `GlassesCamera` protocol (status line, phase, don/hinge/battery), with DAT implementations and a "no glasses" stub, and `#if !SPEAKUP_NO_DAT` only at the seams.
- **Project**: a second app target (`SpeakUp`) sharing the synchronized `A11y` group with membership exceptions, no `MWDAT*` package products, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = SPEAKUP_NO_DAT`, its own scheme, and its own Info.plist without the `MWDAT` dictionary, the `bluetooth-central`/`bluetooth-peripheral` background modes, the Bluetooth descriptions, and the local network and Bonjour keys (if those are only for DAT). `UISupportedExternalAccessoryProtocols` isn't in the current plist. A test plan run against both targets.
- **Estimate**: 2 to 3 days, most of it in `CameraView` and the onboarding and voice seams. It touches every main-screen path, so it should be its own change. This change makes it smaller: the router, the phone source and the phone UI don't import DAT.

## Not tried on a real iPhone

The Simulator has no camera, so none of this has run with real frames: the session starting, the preview, frame size under the `.photo` preset, rotation, photo resolution, near focus, OCR quality at 30 cm, the torch, the permission prompt and its spoken lead-in, interruptions (split view, a call, another camera app), and the background stop. VoiceOver and Dynamic Type on the new card are unchecked, as are the onboarding buttons' order and wording with BLV testers.

## Open questions

1. Should a voice switch persist? iOS saves it as the setting. Android keeps it until the next switch or the next run. Pick one.
2. Is `.photo` the right preset? The reader's latest frame may be small with it; `.high` gives 1080p frames but may cap the still. Measure on a phone.
3. Should the phone source tell the user, before reading, that it's too dark (from the frame's EXIF brightness), instead of after OCR? Android has DarkWatch for this.
4. Haptics for framing and the big-text mirror (value-strategy V0, "Phone-specific UX") aren't done.
5. With a firmware update pending on linked glasses, the phone still reads. Is that right, or should the update block be shown?
