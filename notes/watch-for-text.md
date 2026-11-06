# Watch for text (HstnBench, Android)

2026-11-06. "Tell me when you see 42", "watch for exit", "look out for platform 3", "find Boots". The tool keeps reading the glasses' stream with on-device OCR and says when the target appears and which side it's on, with no repeated prompting. It's for bus numbers, platforms, rooms, gates, shop signs and street signs. It's orientation help, not a mobility aid.

Code: `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/tools/watch/`. It's built on the tools layer (notes/tools-layer.md).

| File | What it does | Android? |
|---|---|---|
| `WatchTarget.kt` | Turns what the user said into tokens: numbers, codes ("12B"), words. Handles spoken numbers and drops bus noise words | pure |
| `TextMatcher.kt` | Tokenises each OCR line, matches the target, works out the position in the frame, finds near misses | pure |
| `SightingTracker.kt` | The sighting state machine (confirm, announce, gone, reappear, near-miss throttle, "where is it"), left/ahead/right and close/far, `ViewIssueWatch` (covered or dark), `PaceWatch` (OCR too slow) | pure |
| `WatchGrammar.kt` | Opening phrases (now also "find X") and the commands inside the tool | pure |
| `WatchViewModel.kt` | Frame loop: `hub.camera.frames(2f)`, then ImageCheck, then ML Kit, then TextMatcher and the tracker, then earcon and speech. Also the tick, watchdogs and commands | Android |
| `WatchTool.kt` | Registry entry and the accessible screen | Android |

It reuses `bookreader/MlKitOcr.kt`, `book/ImageCheck.kt` and `book/TextDistance.kt`, unchanged.

## What the user hears

- **Opening.** From a voice phrase in any tool ("watch for 42", "tell me when you see exit", "find Boots"), from the deep link `hstnbench://watch?arg=42`, from `--es tool watch --es tool_arg 42`, or from the launcher or the camera-screen button. With no target it asks: "What should I watch for? Say a word or a number, like 42, or exit." The next short answer (4 words at most) becomes the target. "Exit" is accepted as an answer even though it's also the global "close".
- **Start.** The first time in a session: "I'll tell you when I see 42. Keep using your cane or dog as usual." After that: "Watching for 73."
- **Sighting.** The FOUND earcon plays, current speech is cut off, then it says "42, on your right." ("ahead", "on your left"), with ", close" or ", far off" when the text is very large or very small in the frame.
- **Gone.** "42, gone." is said once the target has been out of view for 4 s. If it comes back, it's announced again.
- **Near miss** (single-number targets only). "I see 24, not 42." Needs 2 frames that agree, at most once every 20 s, the same near miss at most once a minute, and never while the target is in view or while something else is being said.
- **Commands.**
  - "where is it" / "which side": "42, on your right." or "I last saw 42 on your left, 12 seconds ago." or "I haven't seen 42 yet. I'm still watching."
  - "what are you watching for"
  - "watch for something else, 73" / "change it to exit" / a fresh "watch for 73". Without a target, it asks.
  - "stop watching" / "never mind" stops but keeps the target. "carry on watching" restarts it.
  - "ticks off" / "ticks on" / "tick every 20 seconds".
  - Global "stop"/"pause" pauses watching and says "Paused. Say carry on to keep watching for 42." "Carry on" resumes. Help, repeat, rate, battery and close are the usual global ones.
- **Alive tick.** The WORKING earcon every 10 s while watching (10/20/30 s or off; saved in the `tools` prefs as `watch_tick_seconds`). It ticks only while frames are actually arriving and the view is fine, so the tick never covers for a failure.
- **Never silent about failing.**
  - Lens covered or too dark (ImageCheck's COVERED and TOO_DARK only; a street isn't a page, so "nothing in view", glare and "partly blocked" are ignored): said after 2 frames in a row, repeated every 45 s while it lasts, and "I can see again. Still watching for 42." when it clears. OCR is skipped on those frames.
  - Streaming but no frames for 10 s: "I'm not getting pictures from your glasses camera."
  - ML Kit failing 3 frames in a row: "Text recognition isn't working right now."
  - OCR slower than one look every 3 s (average over 4 frames): "Reading is slow on this phone. I can only look about every N seconds."
  - Glasses off, disconnected, folded, stream lost, battery and heat are ToolHub's spoken pitfalls. When the stream comes back, the sighting history is reset, so it doesn't say "gone" for something seen before the gap.
- Room chatter while watching (at a bus stop, say) gets no "Sorry, I didn't get that" (`isBusy()`). Silence reminders run only while it's asking or stopped.

Wording stays with orientation ("on your right", "ahead"). It never says anything like "safe to cross".

## Matching rules

OCR lines are split into tokens: whole numbers, decimals (`4.2`, `10:30`, `4,2`), codes (letters and digits mixed) and words.

- **Numbers are exact.** `42` matches the token 42 anywhere in a line: "42", "42 Victoria", "via Town Centre 42 Victoria", "No. 42", "No.42", "Bus 42,", "(42)". It also matches a sign word stuck to the number ("No42", "Platform3"). It never matches 421, 142, 24, 4.2, 42.5, 4,2, 42A, "4 2" or 10:42. Leading zeros don't count ("Gate 04" = 4). Inside a number, OCR's letter-for-digit slips are undone first: "4O" reads as 40 and "1l" as 11.
- **Codes** ("12B") are exact, ignoring case. A code split by OCR ("12 B") still matches, and slips at the digit positions are undone ("I2B").
- **Words are loose.** Case, punctuation and apostrophes are ignored ("SAINSBURY'S" = sainsburys). The allowed edit distance (Levenshtein, `TextDistance`) depends on the target's length: 0 for up to 3 letters, 1 for 4 to 7, 2 for 8 or more. Digits read for letters are undone ("B00TS" = boots). A long word split in two by OCR ("BO OTS") still matches.
- **Several words** ("platform 3", "way out") must be next to each other, in order, on one line. Each token follows its own rule, so "Platform 13" doesn't match "platform 3". They can also run together in one OCR token ("PLATFORM3"), with the digits still exact.
- **Spoken targets.** Number words become digits when the whole target is a number ("forty two", "four two", "one oh one", "one hundred and one") or when they follow a sign word such as platform, gate, room, stop or exit ("platform three" becomes "platform 3"). Elsewhere they stay words ("one way"). When the target has a number, "bus", "number", "no", "route" and "the" are dropped ("the 73 bus" becomes "73"). "12 b" becomes the code "12B".
- **Position.** The horizontal centre of the matched characters, taken as their share of the line's box. So "42" at the start of a wide "42 VICTORIA" line is placed left of the line's centre. Straight ahead is taken as x = 0.53, not 0.5, because the camera sits at the front left of the glasses, so things straight ahead appear a little right of the picture's centre. Ahead is 0.53 ± 0.16 (the portrait frame is narrow). Text at least 10 % of the frame height is "close". Text at most 2.5 % is "far off". With several sightings in one frame, the tallest wins.
- **Confidence.** A target is announced only when it's found in at least 2 of the last 4 frames, and frames older than 8 s don't count. After "gone" the history is cleared, so a single new frame can't combine with old hits.

Known looseness: a 4-letter word with one letter changed also matches ("edit" for "exit"). The two-frame rule reduces this but doesn't remove it.

## Measured on the phone (Galaxy A26 SM-A266B, Android 16, mock HSTN)

Rendered street video (480x864, the MockVideo size), `frames(2f)` on the preview-copy path, `WatchForTextTest#measuresOcrTimeAndCpu`. App process CPU time is shown as % of one core, so it includes the preview decode and the Compose screen.

| | Run 1 | Run 2 |
|---|---|---|
| ML Kit per frame (480x864, whole frame) | 61 ms | 64 ms |
| Frames read per second | 2.0 | 2.0 |
| CPU, streaming, nothing watched (15 s) | 55 % | 45 % |
| CPU, watching at 2 fps (30 s) | 84 % | 82 % |

So watching costs about 30 to 40 points of one core over streaming alone, and OCR uses about an eighth of each 500 ms slot. No downscaling or cropping was needed at this size. The baseline is noisy, as notes/tools-layer.md also found (21 to 37 % there, 45 to 55 % here, with the watch screen showing). The per-frame log line is `metric=watch_ocr ms=… size=… lines=… hit=… near=…` (tag `WatchForText`).

## Tests

- **JVM** (`./gradlew testDebugUnitTest`): 132 tests, 0 failures. That's the 101 from before plus 31 new:
  - `WatchMatchingTest` (11): target parsing and number words; 42 against 421, 142, 4.2, 42.5, 42A, "No. 42", "No42", "4O", "10:42"; leading zeros; codes; loose words; multi-word targets; position inside a wide line; the tallest sighting winning; near misses; tokenising decimals.
  - `WatchTrackerTest` (14): one frame never enough; two of four announce once; appear → gone → reappear; "gone" timing; a brief dropout; a single frame after "gone" with slow OCR; ageing out; near-miss agreement and throttling; no near miss while in view; "where is it"; sides with the camera offset; close/far; the view-issue watcher; the pace watcher.
  - `WatchGrammarTest` (6): stop and carry on; what and where (and "where am I" / "where did he go" left alone); new targets; ticks; global commands and other tools' openers left alone; "find Boots" through GlobalGrammar.
- **Instrumented** (`WatchForTextTest`, 3 tests, all passing on the A26). The video loops 3 s of empty street, 4 s of a "42" sign on the right, 6 s empty, 5 s of "421", then 5 s of "24":
  - `announcesFortyTwoOnTheRightThenGoneAndIgnoresFourTwentyOne`: launched with argument 42. It checks the start line (with the cane/dog line), "42, on your right." exactly once, "42, gone.", no "42, …" announcement while the screen shows OCR reading 421, "I see 24, not 42.", and 42 announced again when the video loops.
  - `opensByVoiceFromAnotherToolAndTakesCommands`: in the mail tool, "watch for 42" switches to Watch. Then by voice: "what are you watching for", the sighting, "where is it", "watch for something else, 73", "stop watching" (screen shows Stopped), and "close".
  - `measuresOcrTimeAndCpu`: opened with no target, so it asks. It measures the baseline, then the answer "forty two" starts watching, and it measures again (the numbers above). It asserts reading keeps up with at least 1 frame a second.
- **Shared test changed:** `ToolsTest#everyStubOpensConnectsAndSaysItIsNotReady` expected the watch stub to say "isn't ready yet". It now skips that one check for Watch (one line), and still launches into Watch and waits for the glasses mic. `ToolsTest` passes 3/3 on the A26, including the voice switch "tell me when you see 42" into the working tool.

## Not done / not verified

- **Nothing has run on real glasses.** Not tried yet:
  - the real stream size (OCR time scales with it);
  - the camera's real field of view and angle, which decide whether 0.53 ± 0.16 is the right "ahead" band;
  - the real camera offset;
  - text height thresholds for close/far;
  - signs in daylight, motion blur while walking, and LED bus destination displays (dot-matrix digits may OCR poorly);
  - ImageCheck's dark threshold outdoors at night.
- Only rendered, high-contrast, upright signs were tested. Real signage, angles, small distant text and cluttered scenes are unmeasured, so the false-alarm and miss rates are unknown.
- No downscaling or cropping is done. If the real stream is much larger than 480x864, re-measure and consider a crop.
- Near misses cover numbers only (swaps, or one digit off for numbers with 3+ digits). Words have none.
- The ask-for-target answer is any short utterance (4 words at most) that isn't a global command, so a short bit of room chatter while it's asking could become the target. It's said back ("I'll tell you when I see …"), so the user hears what was taken.
- The screen-off / background path (decoder fallback) wasn't measured for this tool.
- Movement of the target while in view (left to right) isn't announced. "Where is it" gives the latest side.
