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

Meta's docs (build-integration-ios > Prerequisites, DAT v1.0): "since the SDK currently uses the ExternalAccessory framework, it will lead to App Store rejection due to Apple's MFi program and privacy manifest requirements." A store build must not link the SDK. Built on 2026-11-20.

There are now two app targets in `CameraAccess.xcodeproj`:

- **CameraAccess** (the Beta, glasses build): unchanged in behaviour. Links DAT, bundle id `com.deaco.hstnbench`.
- **SpeakUp** (the App Store build): bundle id `com.deaco.speakup`, scheme `SpeakUp`. Links no `MWDAT*` product, compiles with `SPEAKUP_NO_DAT`, and uses `Config/SpeakUp-Info.plist`. The built app has no `Frameworks` folder and no `MWDAT` symbols.

### What was built

- **Protocols** in `A11y/Glasses/GlassesLink.swift`, with no DAT types. `GlassesLink`: registration as an app enum (`GlassesRegistration`), connecting, notice, update required, connect, disconnect, updates, and `makeCamera()`. `GlassesCamera`: status line, phase, worn (`GlassesWear`), folded (`GlassesHinge`), battery, errors and the permission prompt. `CameraPhase`, `cameraBatteryWarningPercent`, `CameraErrorAction` and `coachSituation` moved here from DAT files.
- **DAT side** in `A11y/Glasses/DATGlassesLink.swift`: `WearablesViewModel` and `CameraViewModel` conform. Nothing else in them changed.
- **No-glasses side** in `A11y/Glasses/NoGlassesLink.swift`: `NoGlassesLink` and `NoGlassesCamera`. Asking to connect says "Meta glasses work in the SpeakUp Beta app. This version reads with your iPhone's camera."
- **Views** use the protocols: `MainAppView(link:)`, `OnboardingView(link:)`, `HomeScreenView(link:)`, `CameraView(link:)`, `CameraNarrator`, `CameraNarration`. `VoiceCoach` no longer imports DAT.
- **`#if !SPEAKUP_NO_DAT`** only in `CameraAccessApp` (DAT setup, mock kit, registration view; the store build passes `NoGlassesLink` and handles `speakup://handsfree` itself) and `VoiceControl.attachGlasses(session:wearables:)`.
- **Left out of the SpeakUp target**: the DAT view models, `RegistrationView`, the MockDeviceKit files, `DebugMenuView`, `VideoFrameDecoder` (they are explicit files, not added to it), and by membership exception in `A11y`: `DATGlassesLink`, `DATGlassesDisplay`, `GlassesSpeechListener`, `CameraViewModel+Status`, `CameraViewModel+Read`, `CameraProblem`, and the test fixtures in `Read/Fixtures`.

### What the store build does differently

- **Setup**: one button, "Start reading", straight to the main screen with the phone camera. The welcome line doesn't mention glasses. "continue", "yes" or "phone" by voice also start. "connect" says glasses need the Beta app.
- **Main screen**: no camera switch (only the caption), and no "Connect my glasses" or "Disconnect" in Settings. `CameraSourceRouter.preference` is always phone. "use the glasses", "connect" and "disconnect" say glasses need the Beta app.
- **Info.plist**: no `MWDAT` dictionary, no Bluetooth background modes or descriptions, no local network or Bonjour keys, no `hstnbench` URL scheme, no photo library line (nothing saves photos). Background modes: `audio` only. The microphone line no longer mentions the glasses. No entitlements file.

### How to build it

```sh
xcodebuild build -project CameraAccess.xcodeproj -scheme SpeakUp \
  -destination 'platform=iOS Simulator,name=<your simulator>'
```

Unit tests stay on the CameraAccess scheme. iPhone 17 Simulator, iOS 27.0, Xcode 27.2: 259 run with 1 failure before, and the same 259 with the same 1 failure after (the known `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`). The SpeakUp app was launched in the Simulator: the setup screen shows only Start reading, and the main screen shows Ready to read, the phone camera card and Read text.

### What's left

- **Signing and App Store Connect**: set the team, create the `com.deaco.speakup` app record, add a privacy manifest (`PrivacyInfo.xcprivacy`) and check the export compliance answer. Not tried.
- **Voice help still names the glasses** in the store build ("use the glasses", "connect" in help and hints). The commands answer honestly, but help could hide them when `GlassesSupport.isBuiltIn` is false.
- **No tests run against the SpeakUp target**. A small test target hosted in SpeakUp (onboarding without glasses, router stays on the phone) would catch a DAT import slipping into a shared file. Today a slip shows up as a SpeakUp build error, so build both schemes before merging.
- **New files in `A11y`** go into both targets by default. A tool that imports `MWDAT*` must be added to the SpeakUp exception set in the project.
- **App name and icon**: both builds show "SpeakUp". The Beta could get its own display name or icon so the two can sit side by side on one phone.

## Not tried on a real iPhone

The Simulator has no camera, so none of this has run with real frames: the session starting, the preview, frame size under the `.photo` preset, rotation, photo resolution, near focus, OCR quality at 30 cm, the torch, the permission prompt and its spoken lead-in, interruptions (split view, a call, another camera app), and the background stop. VoiceOver and Dynamic Type on the new card are unchecked, as are the onboarding buttons' order and wording with BLV testers.

## Open questions

1. Should a voice switch persist? iOS saves it as the setting. Android keeps it until the next switch or the next run. Pick one.
2. Is `.photo` the right preset? The reader's latest frame may be small with it; `.high` gives 1080p frames but may cap the still. **Reasoned answer (2026-11-20, notes/phone-reading-ios.md):** keep `.photo` for the full-resolution still and the 4:3 page shape. If real frames come in under about 1000 px on the short side, pick a 4:3 `activeFormat` with at least 1440x1080 video rather than switching to `.high`. Still to measure on a phone.
3. Should the phone source tell the user, before reading, that it's too dark (from the frame's EXIF brightness), instead of after OCR? Android has DarkWatch for this. **Answered (2026-11-20): yes.** `DarkWatch` checks the camera's exposure (EV from ISO, shutter and aperture) before OCR, with hysteresis (dark below EV 3, light above EV 4). It says "It's dark. Say torch on, or move somewhere brighter." and offers the torch once. The frame's brightness is the fallback. EV is used rather than frame brightness so that light text on black isn't flagged. See notes/phone-reading-ios.md.
4. ~~Haptics for framing and the big-text mirror aren't done.~~ Done 2026-11-20, notes/phone-reading-ios.md.
5. With a firmware update pending on linked glasses, the phone still reads. Is that right, or should the update block be shown?
