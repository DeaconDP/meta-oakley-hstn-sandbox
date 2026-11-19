# Phone camera: glasses optional (Android)

2026-11-19. ROADMAP > Everyday value, notes/value-strategy.md > 6 (V0). Every SpeakUp tool now runs on the phone alone: the phone's back camera, mic, speaker and screen. No Meta AI app, no registration, no glasses and no Bluetooth permission. Glasses are an upgrade. It works in both modes (toolbox and hands-free, notes/hands-free-mode.md).

Code is in `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/` (paths below are relative to that).

## What was built

| Piece | File | What it does |
|---|---|---|
| PageCamera | `tools/PageCamera.kt` | The camera seam, now with no DAT types: `isStreaming`, `link`, `motion`, `capturePage()`, `frames(maxFps)`, `latestFrame()`, and an optional `lockExposure(locked)` |
| GlassesLink | `tools/GlassesLink.kt` | The glasses-only half: `deviceSession`, `frameSizes`, `connectAndStream(requestPermission)`, `endSession()`. CameraViewModel implements both |
| PhoneCamera | `tools/PhoneCamera.kt` | CameraX on the back camera: Preview (when the camera screen shows), ImageAnalysis (about 960x720, YUV) and ImageCapture (aim 1920x1440 or more). Bound to its own lifecycle: running only while wanted and the activity is started |
| CameraSourceSelector | `tools/CameraSourceSelector.kt` | The PageCamera the tools see (`hub.camera`). Forwards to the camera in use; flows follow a switch, so a tool collecting frames keeps going |
| CameraSource rules and wording | `tools/core/CameraSource.kt` | Pure: AUTO/PHONE/GLASSES rules, the link-timeout fallback, when setup shows, when Bluetooth is asked for, what the phone camera says (`PhoneCameraWording`), and the "torch on" hint (`DarkWatch`) |
| FrameDifferenceMotion | `book/FrameDifferenceMotion.kt` | Pure: the phone's page-turn motion score from 32x24 luma grids |
| Camera switch | `ui/CameraSourceControls.kt` | "Camera: Phone / Glasses" on the home panels; "Camera source: Automatic / Phone / Glasses" in settings |

Tools didn't change, except the light tool, which asks for `lockExposure(true)` while it's open.

## The setting

`HandsFreeStore.settings.cameraSource`, saved next to hands-free (preferences file "mode", key `camera_source`):

- **AUTO** (default). The phone when the app isn't registered with Meta AI. The glasses when it is. If the glasses don't stream within the usual link wait (20 s), the app says once "Glasses not connected. Using the phone camera." and uses the phone until the next switch or the next run. It doesn't keep watching for the glasses: say "use the glasses" to go back.
- **PHONE.** Always the phone. Setup is skipped.
- **GLASSES.** Always the glasses. No fallback: the app says why it can't reach them, as before.

A voice switch ("use the phone", "use the glasses") or the screen's camera switch changes the camera **for this run only**. The settings menu saves the choice. "Use the glasses" before the glasses are set up says so: "Your glasses aren't set up with SpeakUp yet. Say connect my glasses to set them up, or keep using the phone."

`phone_chosen` (same file) records "Use my phone's camera" on the setup screen.

## First run

The setup screen offers two big buttons: **Use my phone's camera** (first, primary) and **Connect my glasses**. In hands-free mode it says: "Welcome to SpeakUp. It reads with your phone's camera, or with Meta glasses. Say use my phone to start now, or connect my glasses to set up your glasses, or say help." It hears "use my phone", "phone", "phone camera", "I don't have glasses", "no glasses" (SetupGrammar).

- A launch asks only for the microphone (spoken first in hands-free mode, as before).
- **Phone:** the tools open straight away. The camera permission is asked the first time the camera starts, with the spoken sentence first in hands-free mode: "Android will ask to use the camera, so I can see for you. Choose Allow." No Bluetooth dialog, no Meta AI, and the DAT SDK isn't started.
- **Glasses:** Nearby devices (Bluetooth) is asked for on the tap or "connect", then Meta AI opens, as before.
- Glasses stay reachable later: "connect my glasses" by voice, or the **Connect my glasses** button in the toolbox (shown until registered).

## Voice phrases (GlobalGrammar, every screen)

| Say | Does |
|---|---|
| "use the phone", "use my phone", "use the phone camera", "switch to the phone", "phone camera" | Switch to the phone camera (earcon, "Using the phone camera.", camera on) |
| "use the glasses", "use my glasses", "switch back to the glasses" | Switch to the glasses (earcon, "Using the glasses.", connect narrated) |
| "which camera", "what camera are you using", "is it the phone or the glasses" | "Using the phone camera. It's on." (or off, or the glasses) |
| "torch on", "turn on the torch", "flashlight on" / "torch off" | The phone's light (CameraX torch). "This phone has no torch." if there isn't one |
| "connect", "disconnect" on the phone | Turn the phone camera on or off. "Connect" with the phone camera already on and no glasses set up opens Meta AI |

"Status", "where am I" and "settings" mention the phone camera. None of the new phrases clash with the tool grammars or the old phrases (GlobalGrammarTest).

## What changes on the phone

- **No glasses health.** Bluetooth, worn, glasses battery, heat and update alerts aren't spoken. The phone battery still is.
- **No connect narration and no reconnect loop.** The phone opens in about a second. If the app goes to the background, Android closes the camera and CameraX reopens it on return; that isn't a "lost stream".
- **Voice.** No session, so the mic is the phone's ("I'll listen through the phone's microphone" isn't said: it's obvious).
- **Screen.** The background is the phone preview. The DAT session and stream chips become one line ("Camera: phone, on"). The SDK capture row, Start session, the glasses display switch and the "On the glasses" card are hidden.
- **Tools.** A tool opening on the phone starts the camera if it's off. Tool buttons are enabled without a stream.
- **Ready line.** A voice-first launch says "Phone camera on. Hold the phone about 30 centimetres above the page. Say help at any time." for the book and mail readers, without the distance for the others.

## Pitfalls on the phone (PhoneCameraWording)

| When | Says |
|---|---|
| Camera permission refused | "Camera access wasn't allowed, so I can't see anything. Say use the phone to be asked again." |
| Refused for good (Android won't ask) | "Camera access is off for SpeakUp, and Android won't ask again. Open Android Settings, Apps, SpeakUp, Permissions, Camera, and choose Allow." It isn't asked again |
| Another app has the camera | "Another app is using the camera. Close it, then say use the phone." |
| No usable camera | "I can't find a camera I can use on this phone." |
| It stopped | "The phone camera stopped. Say use the phone to start it again." Then "The camera is back." when CameraX reopens it |
| Very dark for 3 s (mean brightness under 18 of 255) | "It's very dark. Say torch on to use the phone's light." Once, until it's bright again. Not in the light tool (it measures the light), and not on phones without a torch |

The existing framing checks (book/ImageCheck) still run on phone stills. No thresholds were changed: no test showed they're wrong for phone frames.

## Motion for page turns

The glasses score motion from HEVC frame sizes (FrameSizeMotion). The phone has no compressed stream, so every analysed frame is averaged into a 32x24 brightness grid and compared with the last one: mean absolute cell difference, minus the change in overall brightness (so an exposure step isn't motion), minus a noise floor of 2.5 levels, divided by 20, clamped to 0..1. Both feed the same PageTurnDetector through `PageCamera.motion`. In the JVM tests a still page with sensor noise scores 0, an exposure step of 30 levels scores under 0.1, a page sliding 3 or more cells scores over 0.35, and a whole turn ends in a capture.

## Measured

No trustworthy timings yet. On 2026-11-19 the HSTN_Mock_API34 emulator (virtual back camera, LIMITED) was badly overloaded: six Unity editors were running, and their adb kept killing Gradle's adb server. `PhoneCameraTest` got this far:

- The app opened on the camera screen with no glasses and no Meta AI. CameraX bound Preview, ImageAnalysis and ImageCapture together (`bound: preview=true capture=true torch=false`), and the voice used the phone mic.
- Analysis frames were 1280x960 with rotation 90 (so the frames are upright portrait after rotation). The first frame took 142 s; on a working phone it should take about a second.
- Then the emulator's camera service died, and its whole system restarted (DeadSystemException), so the test never finished. Capture and frame timings are still to measure.

Since then a still that never comes back gives up after 8 s (`CAPTURE_TIMEOUT_MS`), so a dead camera service can't hang a tool.

## Tests

- JVM: `CameraSourceTest` (rules, selector with fake cameras, fallback, wording, DarkWatch), `FrameDifferenceMotionTest`, new cases in `GlobalGrammarTest`, `SetupGrammarTest`, `SetupFlowTest`.
- Instrumented: `PhoneCameraTest` launches with cameraSource=PHONE and no glasses: the camera streams, `capturePage()` returns a still, `frames()` gives upright frames, `motion` emits, "which camera" and "torch on" answer, and the light tool runs on the phone. `ToolTestKit.setUp` resets the camera source to AUTO.

## Not tested yet

- A real phone (only the emulator's virtual camera). Capture timing, OCR quality at 30 cm, and the dark threshold need a real phone and real pages.
- The AUTO fallback end to end (glasses registered but off). The rule and the selector are JVM-tested; the spoken path isn't instrumented.
- Switching cameras mid-tool with real glasses (the mock can't be unregistered cleanly mid-run).
- Exposure lock on a real phone (the emulator ignores it).
- TalkBack on the new controls (labels and roles are set; not walked through on a device).

## Open questions

- Should a voice switch be saved? Now it lasts for the run; the settings menu saves. A user whose glasses died might prefer "use the phone" to stick.
- Should AUTO keep watching for the glasses after falling back (switch back when they connect)? Not done: it would need the DAT session polling in the background.
- Haptics for framing and a big-text mirror of what's read (value-strategy V0 phone UX) aren't built.
- A store build without the DAT SDK (iOS needs a separate target; Android could use a product flavour) isn't done.
