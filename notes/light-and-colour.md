# Light and colour (HstnBench, Android)

2026-11-06. The fifth everyday tool from ROADMAP Phase 5. Code is in `tools/light/` (under `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/`), strings in `res/values/strings_light.xml`. Built on the tools layer (notes/tools-layer.md). Everything runs on the phone; nothing leaves it.

## What it does

Two modes. Open it with "light detector", "is the light on", "Hey Google, open Light Detector", `hstnbench://light` or `--es tool light` (light probe), or "what colour is this", "colour detector", `hstnbench://light?mode=colour` or `--es tool light --es tool_mode colour` (colour).

**Light probe.** A continuous tone whose pitch rises with brightness. Turn your head: the pitch climbs towards a window or a lamp and drops when facing away, which answers "is the light on?", "are the curtains open?" and "where's the window?".

| Say | Does |
|---|---|
| "how bright is it", "is the light on", "is it dark in here", "are the curtains open" | Speaks a level: dark / dim / normal indoor light / bright / very bright, followed by "That's the camera's estimate, so it's only relative." |
| "where's the light / window", "which way is the window" | "Brighter to your left / right", "Brightest straight ahead", or "About even. Turn your head slowly and follow the tone up." |
| "is it blinking" | "It's blinking." or "Nothing's blinking that I can see. Hold still for a few seconds and ask again." It also says "It's blinking." by itself when blinking starts (at most once every 10 s). |
| "quiet", "pause", "stop", "tone off", "mute" | Tone off at once. Then "Tone off. Say carry on to hear it again." |
| "carry on", "tone on", "light mode" | Tone back on |
| "what colour is this", "colour mode" | Switch to colour mode |

The tone also stops immediately when the tool closes, when switching to another tool, when the stream drops (fold, session end), when the glasses come off, disconnect or get too hot, or when Bluetooth goes off. It also stops if no frame has arrived for 2 s, because a stale pitch would mislead. If the user hadn't paused it, it comes back by itself when the stream returns or the glasses are worn again.

**Colour.** Names the colour of whatever is in the middle of the view, e.g. "Navy blue.", "Probably teal, or maybe green.", "Mostly white, with blue.", "Hard to tell in this light. It might be red. The light looks yellowish, which shifts colours.", or "Too dark to tell. Turn a light on, or hold it nearer a window, and say again." Say "again" (or "check again", "what about this one") to measure again, and "light mode" to go back to the tone.

**Screen.** Mode; in light mode the tone's pitch in large text ("Tone 523 Hz" or "Tone off"), the level and "Blinking"; in colour mode a 180 dp swatch of the measured (white-balanced) colour with the spoken sentence under it in 28 sp. Both are polite live regions, and the swatch's TalkBack label is "Measured colour. <sentence>". Big yellow buttons: How bright? / Tone off–on / Colour mode, or What colour? / Light mode. Each plays the ACK earcon. Test tags are listed in `LightTool.kt`.

## Files

| File | Pure? | What |
|---|---|---|
| `ColourSpace.kt` | yes | sRGB ↔ linear, luma, luminance, OKLab |
| `ColourPalette.kt` | yes | The 39 everyday names, nearest match, light/dark modifier, runner-up from another family |
| `ColourReader.kt` | yes | Centre patch, white balance, two-colour split, hedging; `ColourSpeech` builds the sentence |
| `LightMeter.kt` | yes | Brightness, `PitchMap` (log-log), `PitchSmoother`, levels, brightest side |
| `FlickerDetector.kt` | yes | Blinking |
| `LightGrammar.kt` | yes | Opening phrases (unchanged) and the commands above |
| `ProbeTone.kt` | Android | A gliding continuous sine on a streaming AudioTrack |
| `LightViewModel.kt`, `LightTool.kt` | Android | The tool and screen |

## The light probe

- **Frames:** `hub.camera.frames(4f)`, each scaled to 96 px wide (96x172) with `createScaledBitmap`, then read with `getPixels`.
- **Brightness:** mean relative luminance in linear light, centre-weighted (the middle half of the frame counts three times) so the tone follows where the head points.
- **Pitch:** logarithmic both ways. Perceived brightness is roughly log luminance, and perceived pitch is log frequency, so each doubling of light (one stop) raises the tone by the same interval: a third of an octave. Nine stops (luminance 1/512 to 1) cover three octaves, 220 to 1760 Hz. Anything darker than 1/512 gets the bottom note.
- **Smoothing:** an exponential average of the pitch position (alpha 0.4 per frame, settling in about a second at 4 fps) with a dead band of 0.004 (about 1/14 of a semitone), so compression noise doesn't warble. On top of that, `ProbeTone` glides frequency and volume with a 60 ms time constant, so there are no steps or clicks between updates.
- **Tone:** `hub.tones` (ToneSynth) only plays separate beeps, so `ProbeTone` keeps one streaming AudioTrack on the accessibility stream (the same usage as speech and earcons) and renders 20 ms chunks with a continuous phase. Volume is 0.35, below speech. `stop()` does pause + flush + stop, which silences it within a few ms. It doesn't duck while speaking; speech and tone mix.
- **Levels and the auto-exposure caveat:** levels come from the frame's mean luma: < 20 dark, < 60 dim, ≥ 200 or > 30 % blown-out pixels very bright, ≥ 150 bright, else normal. **They are relative.** The glasses' camera auto-exposes every frame towards mid-grey, and DAT 1.0.1's `VideoFrame` carries only buffer, width, height, timestamp and the compressed/codec-config flags. There is no exposure time, ISO or gain (checked in the DAT docs, `VideoFrame` reference), so absolute brightness (lux) can't be recovered. A dim room that the camera has brightened can read "normal", and the probe tone tells you about the *contrast* in view (a window vs the wall) better than about absolute light. The spoken level always ends "That's the camera's estimate, so it's only relative."
- **Blinking:** the 96x172 frame is cut into 12x20 cells; each keeps its brightest pixel (so a small LED still moves its cell) and its mean. Over the last 20 frames (5 s), a cell is blinking if its brightest value swings by ≥ 60 between two levels (top ≥ 110), sits near one of the two at least 80 % of the time, and crosses between them at least 3 times. Movement resets the history: more than 30 % of cell *means* changing by > 25 in mixed directions. If ≥ 90 % change the same way, the room light itself went on or off, so a flashing room light still counts. At 4 fps this sees blinks up to ~1.5 Hz. Mains flicker (100/120 Hz) is far beyond any frame rate the stream offers and isn't detected.

## The colour method

1. **Frame:** `latestFrame()` scaled to 160 px wide (160x288).
2. **Centre patch:** a square 20 % of the frame's width (32x32 at 160 px, ~96 px on the 480-wide stream). On the glasses' wide camera that's about the size of a mug or a folded sleeve held 30–40 cm in front of the face, so it covers the object and not the room behind. This is unverified on real glasses (see below).
3. **White balance**, estimated from the *surround*: the frame outside its middle 60 % of width and 50 % of height, so an object bigger than the patch doesn't leak in. (In an earlier version the surround began just outside the patch; a large light-blue object then read as a strong "cool light" cast.) It averages two estimates in log space, in linear light, ignoring clipped and near-black pixels:
   - grey-world (the room averages to grey);
   - white-patch (the brightest 3 % are white).

   Gains are clamped to ½–2× and applied at 75 % strength, because the glasses' ISP already balances white and grey-world is fooled by a coloured wall. The raw estimate's max/min gain is the **cast**, and blue-gain/red-gain is the **warmth** (> 1 means warm light).
4. **Two colours:** the balanced patch pixels go to OKLab and are split with k-means (k = 2, farthest-point start, ≤ 10 rounds).
   - Two groups with the same name, or closer than 0.12, are merged back into one.
   - A second group with ≥ 22 % of the patch is named: "mostly A, with B" if the main group has ≥ 60 %, else "A and B".
   - A smaller second group (a speck, an edge, a pinstripe) is left out of the main colour but not named.
5. **Naming:** nearest palette entry in OKLab, with lightness weighted 0.75 (lighting moves lightness most). The runner-up is the nearest entry from a *different* family.

**Why OKLab:** it's perceptually uniform enough for nearest-neighbour naming, has separate lightness, chroma and hue axes, and doesn't have CIELAB's blue→purple hue bend (which matters for navy vs purple). Check: sRGB red → (0.628, 0.225, 0.126), matching Ottosson's reference (in `ColourReaderTest`).

**Palette** (39 names, each with a typical sRGB value and a family):
- neutral: black, dark grey, grey, light grey, white;
- yellow: cream, yellow, pale yellow, mustard;
- red: red, dark red, burgundy;
- pink: pink, light pink, hot pink;
- purple: purple, dark purple, lilac;
- orange: coral, orange, peach, rust;
- brown: beige, brown, dark brown, tan, khaki;
- green: olive green, lime green, green, dark green, light green, mint green;
- teal: teal, turquoise;
- blue: light blue, blue, navy blue, grey-blue.

The plain names (red, pink, purple, orange, yellow, brown, green, blue) take "light"/"dark" when the measured lightness is 0.12 or more above/below the palette value and no named shade is nearer (e.g. "light brown", "dark blue").

## Hedging rules

| Outcome | When | Said |
|---|---|---|
| Abstain (no colour) | Frame's 95th-percentile luma < 45 or mean < 15 | "Too dark to tell. Turn a light on, or hold it nearer a window, and say again." |
| Abstain | > 50 % of the patch blown to white (every channel ≥ 250) | "Too much glare to tell. Tilt it away from the light and say again." |
| Unsure | Frame mean luma < 35; or cast > 3; or cast > 1.5 and chroma < 0.10 (a muted colour under tinted light) | "Hard to tell in this light. It might be X." + reason |
| Probable | Frame mean < 60 (dim); cast > 1.3; a chromatic name with chroma < 0.05 (muted); runner-up from another family within 1.2× the distance (+0.006); a dark (patch luma < 30), low-chroma (< 0.1) chromatic colour; spread inside the main group > 0.12 (busy pattern) | "Probably X." or "Probably X, or maybe Y." + reason |
| Confident | None of the above | "X." |

The reason is the first that applies:
- "The light is dim."
- "The light looks yellowish / bluish, which shifts colours." or "The light looks tinted."
- "It's a muted colour."
- "It's very dark."
- "It looks patterned."

A black object in good light is "Black.", not "too dark": darkness is judged from the whole frame, not the object. In the JVM tests:
- No palette colour under either warm light is ever confident.
- Red under warm light stays in the red family (red / dark red / burgundy) and is hedged, never "orange" or "coral".
- With moderate warm light, white balance brings red back to exactly "red" ("Probably red. The light looks yellowish, which shifts colours.").

## CPU cost (Galaxy A26, mock HSTN streaming plant.mp4, light tool screen over the preview)

`LightToolTest#measuresTheProbeCost`: app process CPU time over 10 s windows, as % of one core. It includes the preview decode and everything else the app does while streaming. Run 2026-11-06 16:53–16:54.

| | App CPU | Frames in 10 s | Analysis per frame (scale + measure + blink) |
|---|---|---|---|
| Colour mode, stream only (baseline) | 69.2 % (66.6 % at the end) | – | – |
| Probe 2 fps | 71.1 % | 23 | 15.5 ms |
| **Probe 4 fps (default)** | **83.9 %, 82.3 % (two runs)** | 46 | 14.8 / 14.5 ms |
| Probe 5 fps | 89.4 % | 58 | 14.0 ms |

Over the stream-only baseline, the probe costs about +2 points of a core at 2 fps, **+14 at 4 fps** and +20 at 5 fps. That cost is the preview copy (PixelCopy) plus our ~15 ms of analysis per frame on `Dispatchers.Default`. The baseline on this run was higher than in notes/tools-layer.md (21–37 %): the phone is shared and other sessions were active, and these numbers are noisy in the same way.

**Chosen rate: 4 fps.**
- At 2 fps the tone lags a head turn noticeably: a change takes ~1 s to show plus smoothing.
- 5 fps costs 40 % more than 4 fps for little gain once the 60 ms glide smooths the steps.
- 4 fps still catches blinks up to ~1.5 Hz.

Colour mode costs nothing between questions. One measurement is a single `latestFrame()` plus 75–285 ms of analysis on the phone (`colour in … ms` in the log). The first is slowest.

## Tests

**JVM** (`./gradlew testDebugUnitTest`): 131 tests, 0 failures. That's 101 before this work plus the 30 below.

- `ColourReaderTest` (15):
  - OKLab against reference values;
  - 23 known sRGB patches in neutral light, each with its expected name and confident;
  - light/dark modifiers;
  - "Probably orange, or maybe …" between families;
  - red under warm and very warm light is never confident or orange;
  - no palette colour is confident under a strong cast, and white under very warm light is "hard to tell";
  - white balance measures the cast and its direction;
  - a dark or badly underexposed frame is too dark to tell;
  - dim light is hedged;
  - black in good light is "Black.";
  - glare abstains;
  - a muted cream is hedged;
  - stripes: 70/30 → "Mostly white, with blue.", 50/50 → "White and navy blue.", a 10 % pinstripe is ignored;
  - a bright green room around a small red object is still red;
  - the swatch is the balanced colour.
- `LightProbeTest` (15):
  - pitch rises monotonically over every grey level 0–255, with the endpoints at 220 and 1760 Hz;
  - a doubling of light is a third of an octave at any level;
  - the smoother settles without overshoot, at least halves noise, and has a dead band;
  - levels from dark to very bright, including a blown-out window;
  - centre weighting;
  - brightest side;
  - blinking: an LED at 1 Hz (detected within 5–10 frames), an LED blinking every frame, steady (no), switched on once (no), a textured scene panning back and forth (no), a flashing room light (yes), a slow fade (no);
  - grammar: every command phrase, everyday words left to the global grammar, room chatter ignored.

**Instrumented** (`LightToolTest`, mock HSTN on the A26): 3 tests, all passing. Each ran on its own class/method run, holding the phone lock.
- `probeToneRisesWithBrightnessThenFalls`:
  - **Clip:** the mock streams solid grey 20 → 230 → 20, 2.5 s each, looping. Sampled tone: `336 … 632, 924, 1160, 1330, 1443, 806, 568, 460 … 341` Hz, then up again on the next loop.
  - **Assertions:**
    - range > 600 Hz, rising then falling;
    - "quiet" drops the tone to 0 within 2 s, and it stays off;
    - "carry on" brings it back;
    - "read my mail" switches tools and the tone stops.
  - **Results:**
    - First run: failed at "carry on". The test spoke it while "Tone off. Say carry on to hear it again." was still playing, and the echo guard correctly dropped it as our own voice (`voice echo ignored: "carry on"`). The test now waits for the line to end, like a user would.
    - Re-run: passed.
- `namesANavyPatchOpenedInColourModeByDeepLink`: a navy (20, 30, 95) square on a grey room, through HEVC encode/decode, opened with `hstnbench://light?mode=colour`.
  - Spoken and shown: "Navy blue." (CONFIDENT, cast 1.00, swatch #141e5f).
  - "again" by voice measured again: "Navy blue."
  - Passed.
- `measuresTheProbeCost`: the table above. Passed.
- In the cost test, the default plant.mp4 clip named its centre "Light grey.", "Probably dark brown. It's a muted colour.", "Probably black, or maybe dark brown." and "Probably dark grey, or maybe burgundy." as the video moved. Those are hedged answers on a moving natural scene, not checked against ground truth.

`ToolsTest` (edited, see below) re-run on the phone after the change: 3/3 pass. That covers the deep link into colour mode and "what colour is this" from the book reader, which now measures a colour instead of saying "isn't ready". `FrameStreamTest` (a one-line change to the mode it opens with) was not re-run.

## Shared files touched

- `app/src/androidTest/.../ToolsTest.kt`: removed the `ToolId.LIGHT to "is the light on"` line from `everyStubOpensConnectsAndSaysItIsNotReady`, since the light tool is no longer a stub.
- `app/src/androidTest/.../FrameStreamTest.kt`: its tests open the light tool as "a quiet way to bring the stream up". They now open it in colour mode (`mode = ToolRequest.MODE_COLOUR`), because the light probe collects frames continuously and would skew the frame-cost baseline.

## Not verified / limits

- **Nothing has run on real glasses.** Not tested there:
  - the real stream's colour rendering, ISP white balance and auto-exposure behaviour;
  - the centre patch size against real objects at arm's length (20 % of width is a guess from the camera's field of view);
  - the probe tone through the glasses' open-ear speakers over A2DP, and how it mixes with speech.
- Colour on the mock went through HEVC encode/decode of a synthetic frame. Real lighting (mixed sources, shadows, specular highlights on shiny objects) isn't exercised. The thresholds come from synthetic frames.
- Levels are relative (auto-exposure; no exposure metadata in DAT 1.0.1).
- White balance assumes the surround averages to grey or has something white in it. A strongly coloured room produces a false cast. That makes the tool hedge ("probably…"), not name the wrong colour confidently, but it may hedge more often than needed.
- Colour words are built in English in pure Kotlin (`ColourSpeech`, palette names), not string resources, so they aren't localisable yet.
- Blinking faster than ~1.5 Hz aliases at 4 fps; mains flicker isn't detectable.
- The tone doesn't duck under speech.
