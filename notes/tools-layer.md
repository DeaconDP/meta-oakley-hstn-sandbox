# Tools layer (HstnBench, Android)

2026-11-06. The shared foundation for the five everyday tools in ROADMAP Phase 5: book, mail, watch, labels, light. Code is in `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/` (paths below are relative to that). **If you're building one tool, read this file first.** You should only need to edit:

- your package, `tools/<id>/` (ViewModel, screen, grammar, and any other files you add);
- your strings, `res/values/strings_<id>.xml`;
- your tests: `app/src/test/.../tools/<id>/` (JVM) and new files in `app/src/androidTest/...` (instrumented).

All five tools are already registered, have launcher entries, deep links, intent extras and camera-screen buttons, and are reachable by voice from every other tool. Each new tool is a stub that opens, connects, and says "<Tool> isn't ready yet."

## Map

| Piece | File | What it does |
|---|---|---|
| ToolHub | `tools/ToolHub.kt` | One per activity. Owns speech (ToolSpeaker), earcons, ToneSynth, mic (VoiceControl: glasses first, phone fallback), EchoGuard, the glasses/phone health watch, IdleNudge reminders, the reconnect loop, tool switching, RecentText and AskAboutText |
| ToolHost | `tools/ToolHost.kt` | The interface a tool's ViewModel implements. Every method has a default |
| ToolViewModel | `tools/ToolViewModel.kt` | Base class for new tools. Implements ToolHost with the usual behaviour and exposes `ui: StateFlow<ToolUiState>` |
| ToolTexts | `tools/ToolHost.kt` | The lines ToolHub speaks for your tool (connecting, ready, welcome, help...). `ToolTexts.generic(context, nameRes, helpRes)` fills them in |
| ToolScaffold, AttachTool | `tools/ToolScreen.kt` | The accessible screen frame (name, close, status, mic, last heard) and the effect that attaches your ViewModel |
| ToolRegistry, ToolSpec | `tools/ToolRegistry.kt` | The list of tools. Each `ToolSpec` lives in its own package (`tools/mail/MailTool.kt`, ...) |
| ToolId, ToolRequest, ToolLaunch | `tools/core/ToolId.kt` | Ids, "open this tool with mode/argument", and launch-intent parsing (pure) |
| GlobalGrammar | `tools/core/GlobalGrammar.kt` | Commands every tool understands, tool switching, questions (pure) |
| `<Id>Grammar` | `tools/<id>/<Id>Grammar.kt` | Your tool's "open me" phrases (`opens`) and its own commands (`parse`) (pure) |
| AskGrammar, AskProvider | `tools/ask/` | The "ask about the text" seam: question patterns, and which AskAboutText is used |
| RecentText, AskAboutText | `tools/core/RecentText.kt`, `tools/core/AskAboutText.kt` | Text each tool read, and the answering interface (pure) |
| Phrases, EchoGuard, IdleNudge, HealthMonitor | `tools/core/` | Normalising speech, ignoring our own voice, reminder timing, edge-triggered pitfalls (pure) |
| PageCamera | `tools/PageCamera.kt` | The camera seam: `capturePage()`, `frames(maxFps)`, `latestFrame()`, `frameSizes`, `isStreaming`, `link`, `connectAndStream` |
| FrameGrabber | `stream/FrameGrabber.kt` | Decoded stream frames (second HEVC decoder into an ImageReader), used by CameraViewModel |
| VoiceControl, VoiceInput, ToolSpeaker, Earcons, ToneSynth, GlassesWatch | `tools/` | Android glue moved out of `bookreader/` (ToolSpeaker was BookSpeaker, GlassesWatch was ReaderWatch) |

Pure files have no Android imports and are JVM-tested. ImageCheck (brightness checks for a page) stays in `book/`; import it from there if it helps.

## A minimal tool

The stubs are exactly this. `tools/mail/MailViewModel.kt`:

```kotlin
class MailViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.MAIL) {

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.mail_name, R.string.mail_help)

  // After the welcome (tap/launch) or after ToolHub said "Mail reader." (switch).
  override fun onOpened(request: ToolRequest, reason: OpenReason) {
    say(str(R.string.tool_not_ready, str(R.string.mail_name)))
  }

  // Your grammar first; return false to let the global grammar have it.
  override fun onCommand(text: String): Boolean = MailGrammar.parse(Phrases.normalize(text)) != null

  class Factory(...) : ViewModelProvider.Factory { ... }
}
```

`tools/mail/MailTool.kt`:

```kotlin
val MailTool = ToolSpec(
    id = ToolId.MAIL,
    nameRes = R.string.mail_name, buttonRes = R.string.mail_button,
    buttonDescriptionRes = R.string.mail_button_description,
    icon = Icons.Filled.Email,
    content = { MailScreen(it) },
)

@Composable
fun MailScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: MailViewModel = viewModel(factory = MailViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)          // required: connects vm to ToolHub while showing
  val ui by vm.ui.collectAsStateWithLifecycle()
  ToolScaffold(ToolId.MAIL, stringResource(R.string.mail_name), ui, onClose = ctx.onClose) {
    // your big, labelled controls and large text here (ColumnScope)
  }
}
```

A real tool typically does this in `onOpened`: start a loop on `viewModelScope` that reads `hub.camera.frames(2f)` (or calls `hub.camera.capturePage()` on a command), runs ML Kit on `Dispatchers.Default`, and speaks with `hub.reply(...)` / `say(...)`, with `hub.earcons.play(Earcon.FOUND)` for hits. Stop the loop in `onLeaving()`.

### What a tool can call on `hub`

| Call | Use |
|---|---|
| `say(text)` (ToolViewModel) / `hub.say(text)` | Speak a note and put it on the status line |
| `hub.sayAside(text)` | Speak a note (status line unchanged). `onAsideDone()` runs when it finishes |
| `hub.reply(text)` | ACK earcon, cut off whatever is being said, speak. Use for answers to commands |
| `hub.warn(text)` | Error earcon, status line, interrupt and speak. Use for problems |
| `hub.speak(text, tag)` | Long content (a sentence of a letter). `onSpoken(tag)` runs when it finishes, not if cut off. Speak one sentence per call so "stop" and rate changes act quickly |
| `hub.hush()` | Stop speaking now and drop the queue |
| `hub.isSpeakingAside` | A note is being spoken |
| `hub.setRate(r)` | Set the speech rate (if your tool keeps its own; otherwise ToolHub's shared rate applies) |
| `hub.earcons.play(Earcon.X)` | ACK, ERROR, WORKING (soft tick while busy), READY, FOUND, SWITCH, plus the book's PAGE_* tones |
| `hub.tones.play(freqHz, ms, volume)` | A sine tone at any pitch (light probe, direction cues), accessibility stream |
| `hub.camera` | PageCamera: see "Frames" below |
| `hub.recentText` | Publish what you read (see "Ask about the text") |
| `hub.userActed()` | A button press: ACK earcon and restart the silence-reminder clock. Call it from every button handler |
| `hub.reconnectThen { ... }` | Not streaming but the user wants the camera: connect (narrated), then run the block. Returns false if voice isn't open |
| `hub.explainNoGlasses()` | Speak the most specific reason the glasses can't be reached |
| `hub.batteryReport()`, `hub.glassesNow`, `hub.phoneNow` | Battery, worn and Bluetooth readings |
| `hub.switchTo(request)`, `hub.closeByVoice()`, `hub.closeTool()` | Navigation (usually done for you) |
| `hub.recentSpeech()` | The last 50 things sent to speech. For tests |

### ToolHost callbacks (all optional; ToolViewModel provides the defaults in brackets)

`texts()` (required), `onAttached(request)` [stores `request`, clears `heard`], `onOpened(request, reason)`, `onRequest(request)` (asked for again while open, e.g. "watch for 43" while watching) [stores it], `onLeaving()` (closed or switching away: stop loops, save state), `onDetached()`, `speechRate()` [null = shared rate], `onAsideDone()`, `onSpoken(tag)`, `onEngineState(available)`, `onPartial(text)` [barge-in: hush on "stop"], `onHeard(text)` [shown on screen], `onCommand(text)`, `onGlobal(command)` [false], `onNotUnderstood(text)` ["Sorry, I didn't get that" unless `isBusy()`, ≤ 6 words, at most every 8 s], `isWaitingForUser()` [false: no reminders], `reminder(index, last)`, `onStatus(text)` [status line], `onHealthAlert(alert)` [tool-neutral lines for taken off / disconnected / worn again / too hot], `onStreamLost()` [true], `onStreamBack()`.

`OpenReason`: `TAPPED` (camera-screen button), `LAUNCHED` (launcher alias, deep link or extra: voice-first), `SWITCHED` (by voice from another tool; ToolHub already said the name and the previous tool's `onLeaving` ran).

### What ToolHub does for every tool

- **Connect and narrate.** On a voice-first launch it calls `connectAndStream` with no dialogs and says `texts().connecting`, then `texts().ready`, or the most specific reason it can't reach the glasses (Bluetooth off, not linked, update needed, camera refused, not worn, else "check they're on…"), and keeps waiting. Camera and mic permission requests are explained out loud before Meta AI opens.
- **Listening.** Glasses speech recognition when allowed, otherwise the phone's on-device recogniser, with the same fallbacks as the book reader (notes/book-reader-android.md > Voice control). "Listening through your glasses/the phone" is on screen. Voice runs while *any* tool is open, so switching tools doesn't restart the mic.
- **Echo guard.** Transcripts that are our own speech coming back are dropped before your tool sees them.
- **Every final transcript:** `onHeard` → your `onCommand` → `GlobalGrammar.parse` → your `onGlobal` → ToolHub's default → or `onNotUnderstood`.
- **Global defaults:** Pause = hush + "Paused."; Resume = say the welcome; Repeat = say the last thing again; Faster/Slower/SetRate change the shared rate ("1.25 times speed."); Help = `texts().help`; Battery = both batteries; Close = `onLeaving`, `texts().goodbye`, back to the camera screen; Open = switch tool (or `onRequest` if it's this tool); Ask = see below. Override any of them in `onGlobal`.
- **Pitfalls,** spoken once when they change, on the status line too: Bluetooth off/on, no glasses linked, disconnected/connected (then the camera comes back by itself), taken off/put on, update required, glasses and phone battery at 20/10/5 %, warm/too hot/cooled. `onHealthAlert` runs first, so you can pause or save. A dropped stream (fold, session end) calls `onStreamLost()`, starts a quiet reconnect every 4 s, says `texts().streamLost` if no alert explained it, and `texts().cameraBack` when it returns.
- **Silence reminders.** While `isWaitingForUser()` is true and ToolHub is idle, `reminder(i, last)` is spoken after 30 s, 60 s and 2 min of quiet. Anything the user says or presses restarts the clock.

## Opening a tool: registry and routing

| Id | Launcher label ("Hey Google, open …") | Alias | Deep link | Extra |
|---|---|---|---|---|
| `book` | Book Reader | `.BookReaderLauncher` | `hstnbench://book` | `--es tool book` (and the old `--ez book_reader true`) |
| `mail` | Mail Reader | `.MailReaderLauncher` | `hstnbench://mail` | `--es tool mail` |
| `watch` | Watch For Text | `.WatchForTextLauncher` | `hstnbench://watch?arg=42` | `--es tool watch --es tool_arg 42` |
| `labels` | Label Reader | `.LabelReaderLauncher` | `hstnbench://labels` | `--es tool labels` |
| `light` | Light Detector | `.LightDetectorLauncher` | `hstnbench://light?mode=colour` | `--es tool light --es tool_mode colour` |

For example: `adb shell am start -n com.deaco.hstnbench/com.meta.wearable.dat.externalsampleapps.cameraaccess.MainActivity --es tool watch --es tool_arg 42`, or `adb shell am start -a android.intent.action.VIEW -d "hstnbench://light?mode=colour"`.

`MainActivity` turns the intent into a `ToolRequest` (`ToolLaunch.parse`) and hands it to `CameraScreen`, which is the router: `ToolHub.activeTool` decides which tool screen covers the live preview (the stream keeps running underneath). The camera screen's bottom bar has a "Tools" heading, the full-width Book reader button (tag `book_reader_button`), and Mail/Watch/Labels/Light buttons (tags `tool_button_<id>`), enabled while streaming. A tool launched voice-first ends the session and moves the app to the background when it closes, as the book reader always has. Tool ViewModels are activity-scoped: they survive a switch away and back.

Known limit: if the app is already running, a launcher alias brings the existing task forward without delivering the new intent (standard launch mode), so "open Mail Reader" then shows whatever was open. Switching by voice works in that case.

## Global grammar

`GlobalGrammar.parse(transcript)` normalises (Phrases: lower case, punctuation out, fillers like "please/um/can you" dropped, an address like "glasses, …" dropped) and then tries, in order:

1. **Tool openers** (`GlobalGrammar.OPENERS`): `WatchGrammar.opens`, `MailGrammar.opens`, `LabelsGrammar.opens`, `LightGrammar.opens`, `GlobalGrammar.bookOpens`. Each returns a `ToolRequest` or null. **Add your synonyms to your own `opens`.** Current phrases:
   - mail: "read my mail", "check the post", "what is this letter (about)", "what does this letter say", "who is this letter from", "open the mail reader"
   - watch: "watch for X", "tell me when you see X", "let me know when you see X", "look out for X", "keep an eye out for X", "look for X" → `argument = X` (taken from the un-filtered text, so "watch for the right exit" gives "right exit"); "open watch for text" → no argument
   - labels: "scan this", "scan the barcode", "what's this product/tin/packet…", "read the label", "open the label reader"
   - light: "light detector", "is the light on", "are the lights on", "is it dark in here"; colour mode (`mode = ToolRequest.MODE_COLOUR`): "what colour/color is this", "what's the colour of this", "colour detector"
   - book: "open the book reader", "read a book", "back to my book", "book reader"
2. **Questions** (`AskGrammar.parse`): "what does X mean", "what's the meaning of X", "define X", "who is/was X", "what happened …", "why did …", "where did …", "what did X say/do", "how do you spell X" → `GlobalCommand.Ask(question, subject)`.
3. **Everyday commands:** Close ("close", "exit", "goodbye", "I'm done"), SetRate ("1.5 times", "double speed", "normal speed"), Faster/Slower (0.25, or 0.5 for "much"), Battery, Help, Repeat ("say that again", "pardon", "what did you say"), Pause ("stop", "hang on", "wait", "shush"), Resume ("carry on", "continue", "go on").

Room chatter ("turn right at the lights", "my mail came late") parses to nothing. `GlobalGrammarTest` pins the phrases above; run it after changing your `opens`.

**Your own commands** go in `<Id>Grammar.parse(normalized)` with a sealed `<Id>Command` type (the stubs have an empty one), in the style of `book/VoiceCommands.kt`: ordered regex rules, specific phrases before the short words inside them. ToolHub tries your grammar **before** the global one, so (1) you can give "read" or "stop" a tool-specific meaning, and (2) **don't** match another tool's opening phrases. The book reader's grammar wins inside the book reader ("read the book" = carry on, "where am I").

## Ask about the text (seam for the ask agent)

- **Publishing (tools):** `hub.recentText.addPassage(toolId, text, key)` for each passage read (a page, a letter; publishing the same `key` again replaces it), `setCurrent(toolId, sentence)` for the sentence being read, `setTitle(toolId, "Letter from …")`, `clear(toolId)` for a new letter. Memory only, this app session, at most 40 000 characters per tool (oldest passages dropped). **The book reader publishes** each page as it starts reading it (`key = "page-N"`) and the current sentence. **The mail tool should publish** the letter's full text once recognised, with `clear(ToolId.MAIL)` first for a new letter.
- **Asking:** a phrase matched by `AskGrammar` (in any tool, unless that tool's grammar claimed it) becomes `GlobalCommand.Ask`. ToolHub plays ACK, takes `recentText.forQuestion(currentTool)` (the open tool's text, or the most recent text from any tool), calls `askAboutText.answer(question, snapshot)` on the main dispatcher (make it suspend properly; do network on IO), and speaks the result with `reply()`: `Answer(text)` as is; `NotInText` → "The text doesn't say."; `NothingRead` → "I haven't read anything yet…"; `Unavailable` → "I can't answer questions yet."; `Failed` → "Sorry, I couldn't answer that just now."
- **Plugging in:** replace the body of `tools/ask/AskProvider.create(context)` with your implementation. Put widened question patterns in `tools/ask/AskGrammar.kt` and strings in `res/values/strings_ask.xml`. No other shared file needs to change. The book reader resumes the interrupted sentence after the answer.

## Frames for continuous tools

```kotlin
// Decoded stream frames while collected, at most maxFps a second. ARGB_8888, the stream's size.
fun frames(maxFps: Float = 2f): Flow<Bitmap>
// Newest frame if fresher than maxAgeMs, else decode until one arrives, else capturePage(). Null if not streaming.
suspend fun latestFrame(maxAgeMs: Long = 1_000L, timeoutMs: Long = 2_500L): Bitmap?
// The GA in-stream photo (960x1440 on the mock), ~1 s; restarts glasses speech afterwards.
suspend fun capturePage(): Bitmap?
```

- How, in order of preference (`CameraViewModel.frames`):
  1. **Preview copy.** A tool screen sits over the live preview, whose decoder already renders every frame to a Surface. `PixelCopy` copies the frame on screen into a Bitmap (a GPU copy) at the decoded picture's size, once per tick. No second decode. A single missed copy is retried for 1.5 s before falling back.
  2. **Decoder (no preview Surface: screen off, app in the background).** `FrameGrabber` runs a second `HevcDecoder`, the phone's hardware decoder if there is one (`c2.exynos.hevc.decoder` on the A26), with ByteBuffer output (`getOutputImage`, YUV converted to ARGB in Kotlin, ~11 ms per frame), only while someone collects. When keyframes come at least as often as frames are wanted (every 0.4 s on the mock), only keyframes are decoded. The last collector leaving stops it. Force this path in a test with `camera.previewCopyEnabled = false`.
  3. **Photos.** If neither gives a frame for 4 s while streaming, `capturePage()` at most once a second. Not exercised on the A26.
  Delivery is paced on average, so 2 fps means 2 frames a second.
- Frame size is the **video's** size: 480x864 for MockVideo feeds, 540x960 for plant.mp4. DAT's `VideoFrame.width/height` says 504x896 (the MEDIUM preset) for both, and an ImageReader sized from that crashed the hardware decoder (SIGSEGV), which is why the decoder path reads the codec's own output images. The real HSTN stream size is unverified.
- Collect on `Dispatchers.Default` and do your work there; each Bitmap is new and yours. Don't hold more than you need (about 2 MB each).
- Phone cost (Galaxy A26, mock HSTN streaming plant.mp4 at 30 fps, a light-tool screen over the preview; `FrameStreamTest#measuresTheCostOfDecodingFrames`; app process CPU time over 10 s windows, as % of one core, so it includes the preview decode):

  | | nothing collected | 2 fps | 5 fps | 10 fps |
  |---|---|---|---|---|
  | Preview copy (normal path) | 21 % | 30 % | 51 % | 92 % |
  | Decoder fallback (hardware HEVC) | | 41–77 % | 61–106 % | 61–110 % |
  | Decoder, earlier software-decoder build (ImageReader) | 22–26 % | 46–75 % | 55–84 % | 56–88 % |

  The measurement is noisy: in the same run the "nothing collected" baseline rose from 21 % at the start to 37 % at the end (CPU frequency scaling on an idle-ish phone, other processes), and repeated runs of one row differ by up to 30 points. The decoder rows are ranges over 2–3 runs. What holds across runs: preview copy at **2 fps costs about a tenth of a core over streaming**, 5 fps about a third. Ask for the lowest rate that works (watch for text: 1–2 fps; light probe: 2–5 fps on a small crop), and do your own work (OCR) on `Dispatchers.Default`. Per-frame conversion is 11–16 ms on the decoder path.

## How to test a tool on the mock

The Mock Device Kit runs inside the app, so instrumented tests drive "glasses" on the phone. Use `ToolTestKit` (`app/src/androidTest/.../ToolTestKit.kt`):

```kotlin
@RunWith(AndroidJUnit4::class) @LargeTest
class MailToolTest {
  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  @Before fun setup() = ToolTestKit.setUp()                 // grants permissions, clears prefs
  @After fun tearDown() = ToolTestKit.tearDown(scenario)    // closes, disables the mock

  @Test fun readsALetter() {
    val glasses = ToolTestKit.pairHstn()                    // HSTN on, worn, unfolded; camera + mic granted
    ToolTestKit.showImage(glasses, renderLetter())          // what capturePage() returns
    scenario = ToolTestKit.launch(ToolRequest(ToolId.MAIL)) // voice-first, no taps
    compose.waitUntil(30_000) { ToolTestKit.exists(compose, "tool_screen_mail") }
    compose.waitUntil(30_000) { ToolTestKit.text(compose, "tool_voice_mic") == ctx.getString(R.string.voice_mic_glasses) }
    ToolTestKit.say(glasses, "what is this letter")         // the glasses' recogniser "hears" it
    val hub = ToolTestKit.hub(scenario!!)
    compose.waitUntil(60_000) { hub.recentSpeech().any { it.contains("from") } }
  }
}
```

- **(a) A still image.** Render a Bitmap (see `BookPageRenderer` for text with real typography: serif, justified, hyphens; write your own for letters, labels, barcodes) and call `ToolTestKit.showImage(glasses, bitmap)`. It's saved as PNG and set with `setCapturedImage`; `capturePage()` then returns it at its own size. On the A26, ML Kit takes ~0.4 s on a 960x1440 page.
- **(b) A live video.** `ToolTestKit.playFrames(glasses, listOf(bitmapA, bitmapB), holdMs = 1000)` encodes the frames into an MP4 on the phone (`MockVideo`, ~1 s) and sets it with `setCameraFeed`; the mock loops it. Call it **before** launching (the mock takes the feed when the stream starts). Format the mock accepts: the mock reads the file with MediaExtractor and sends the compressed samples to the app unchanged. It accepts `video/hevc` and `video/avc`, but the app decodes HEVC only, so use **HEVC (Main) in MP4**, portrait, width and height multiples of 16 (MockVideo defaults to 480x864, 15 fps, a keyframe every 0.5 s), samples under 10 MB. `frames()` then delivers Bitmaps at the video's size; `FrameStreamTest` checks this. On the Mac, ffmpeg makes an equivalent file from PNGs: `/opt/homebrew/bin/ffmpeg -framerate 1 -i scene%02d.png -vf "fps=15,scale=480:864,format=yuv420p" -c:v libx265 -tag:v hvc1 -x265-params keyint=8 -an feed.mp4`; put it in `app/src/androidTest/assets/` and use `ToolTestKit.playAsset(glasses, "feed.mp4")`.
- **(c) Speech.** `ToolTestKit.say(glasses, "watch for 42")` calls `glasses.services.speech.simulateTranscription(text, true, 0.9f)`; it goes through the echo guard and both grammars exactly like real speech. It needs the mic permission (`pairHstn(micGranted = true)`, the default) and the glasses recogniser running, so wait for `tool_voice_mic` to say "Listening through your glasses" first. Pass `isFinal = false` for a partial (barge-in).
- **What to assert on.** The screen (tags `tool_screen_<id>`, `tool_status`, `tool_voice_heard`, plus your own), `hub.activeTool.value`, `hub.recentSpeech()` (what was sent to speech; tests can't hear), `hub.recentText.snapshot(id)`, `ToolTestKit.camera(scenario).frames(...)`. A test that reads or decodes for a long time should use the timeouts in `ToolsTest` (30 s for UI, 60 s for OCR).
- **Running.** From `tracks/android-native/HstnBench`: `export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools; ./gradlew assembleDebug assembleDebugAndroidTest testDebugUnitTest`. Take the phone lock (`until mkdir /tmp/hstn-phone.lock 2>/dev/null; do sleep 15; done`, `rmdir` after, also on failure; a lock older than 25 min is stale), `adb install -r -g` both APKs (`app/build/outputs/apk/debug/app-debug.apk`, `app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`), `adb shell input keyevent KEYCODE_WAKEUP`, then `adb shell am instrument -w -e class com.meta.wearable.dat.externalsampleapps.cameraaccess.MailToolTest com.deaco.hstnbench.test/androidx.test.runner.AndroidJUnitRunner`.
- Existing examples: `ToolsTest` (launch, switch by voice, ask, deep link, stubs), `FrameStreamTest` (video feed, frames, cost), `BookReaderTest` / `VoiceFirstLaunchTest` / `PitfallsTest` (book reader, pitfalls via `glasses.doff()/fold()/setBatteryLevel()/setThermalLevel()`).

## Results (2026-11-06, Galaxy A26 SM-A266B, Android 16, mock HSTN)

- **JVM:** `./gradlew testDebugUnitTest`: 101 tests, 0 failures. That's 87 before this work, plus `GlobalGrammarTest` (9: every tool-opening phrase above, the everyday commands, questions, room chatter, and the book grammar winning inside the book reader), `ToolCoreTest` (4: launcher aliases, extras and deep links, RecentText, Phrases), and `PageLayoutTest#misreadLineEndFragmentIsRepairedWhenRejoined`.
- **Instrumented, whole suite** (`am instrument`, no class filter): 37 tests. 35 pass, `MlKitFolderScore` skips (no data folder, by design), and 1 failed: `BookReaderTest#saysWhatToDoAtTheEndOfAPage`, "No compose hierarchies found". The logcat shows why: 90 s into the test, `com.android.shell` started another app (`io.worldbuild.pawnly`) on the shared phone and took the foreground. Another session was using adb without the phone lock. Run on its own straight after, `BookReaderTest` passes 4/4. So: no failures from this code.
- New instrumented tests, all passing: `ToolsTest` (3) runs a voice-first launch into the mail stub, then "open the book reader", reading a page by voice, the page appearing in RecentText, "what does Penang lawyer mean" answered "I can't answer questions yet.", "tell me when you see 42" (Watch with argument 42; bookmark kept), "what colour is this" (light, colour mode), "back to my book" (bookmark unchanged), with no stream drop through all the switches, then "close". It also covers the deep link `hstnbench://light?mode=colour`, and every stub opening, listening on the glasses and saying it isn't ready. `FrameStreamTest` (3): frames on the preview-copy path and on the decoder path are 480x864, alternate between the two scenes, and are paced (20 frames in ~4 s at 5 fps); plus the cost measurement above.
- **Before this work** on the same phone: `BookReaderTest#readsABookPageFromTheGlassesCamera` failed ("line-end hyphen not rejoined"; cause and fix in notes/book-reader-android.md > Tools layer), and `BookOcrPipelineTest` passed. The rest of the suite wasn't run on the phone before the change.
- Timings seen on the phone: session start to streaming ~2 s on the mock; ML Kit 160–320 ms per 960x1440 page (`metric=book_ocr`); encoding a 2-scene MockVideo ~1.2 s.

## Not done / not verified

- Nothing has run on real glasses: real stream size and keyframe interval (which decide the decoder path's cost), PixelCopy with the real stream, and glasses speech staying up across tool switches with a real recogniser.
- The capturePhoto fallback in `frames()` isn't exercised (decoding works on the A26).
- A launcher alias doesn't re-route an app that is already running (see "Opening a tool").
- The stubs have no tool grammar yet (`parse` returns null), and their help text says only what works now.
- The silence reminders still haven't fired in an instrumented test (they need 30 s of quiet).
- Frame cost numbers are noisy (see the table). A per-thread profile showed the extra CPU spread over codec IPC, dispatcher and GC threads, not one hot spot.
