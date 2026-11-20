# Mail reader (iOS, phone first)

2026-11-20. A port of the Android mail reader (notes/mail-reader.md) to the iOS app. You hold up a letter or envelope and ask "what is this letter?". The app says who it's from, who it's for, what kind of letter it is, what it's about, any amount due and deadline, and any scam signs. "Read it all" then reads every word. It runs on the phone. It uses Apple Vision OCR and fixed rules, and makes no cloud calls on any path. Update: reminders, the letters log and "explain this letter" were added later the same day (notes/letters-ios.md). The only cloud call is the AI explanation, and only when the user asks for it.

Code is in `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Mail/`. Tests are in `CameraAccessTests/MailReaderTests.swift`.

## Files

| File | What it does |
|---|---|
| `MailTool.swift` | `MailTool`, the `SpeakUpTool`: picture, OCR, framing check, rules, speech, reading by sentence. Also `MailPages` (same-page check). |
| `MailPanel.swift` | The SwiftUI panel from `makePanel()` |
| `MailGrammar.swift` | Voice commands inside the tool |
| `LetterReader.swift` | Sender, recipient, kind, date, subject, amount, deadline, references; the money rule; `LetterSentences` |
| `LetterLayout.swift` | Reading order: table rows, stacked blocks, columns, paragraphs |
| `LetterText.swift` | Money, dates, postcodes, spelling out numbers |
| `LetterModel.swift` | Lines, words, confidences; conversion from Vision's `ReadPage` |
| `LetterSpeech.swift` | Everything it says |
| `ScamSigns.swift` | Scam-sign hints (new on iOS) |
| `MailRegex.swift` | A small NSRegularExpression wrapper |

## Wiring it in

`MailTool` conforms to `SpeakUpTool` (A11y/Tools/SpeakUpTool.swift, unchanged).

- `init(recognize: @escaping @Sendable (UIImage) throws -> RecognizedFrame = { try TextRecognizer.recognize($0) })`. Call `MailTool()` in the app. Tests pass a fake OCR.
- `start(source:)` keeps the source weakly (as `TextReader` does), asks it to start streaming, and says how to hold the letter.
- `stop()` cancels a look in progress and pauses reading.
- `handle(transcript:)` returns true for a mail command.
- `perform(_ command: MailCommand)` and `toggleReading()` are what the panel's buttons call.
- Observable state for other UI: `phase`, `letter`, `summary`, `sentences`, `sentenceIndex`, `currentSentence`, `notice`.

## Voice

Matching works like `VoiceCommandParser`: the same normalising (so "what's" is "whats"), whole phrase only, filler peeled off the ends ("could you read it all for me please").

| Say | What happens |
|---|---|
| "what is this letter", "read", "what does it say" | Takes a picture and says the summary |
| "read it all", "read every word" | Reads every sentence |
| "back", "skip", "start again", "repeat", "carry on reading" | Moves through the sentences |
| "who is it from", "who is it for" | Sender, recipient |
| "how much" | Amount due, or a refusal (the money rule) |
| "when is it due" | Pay-by date, reply-by date or appointment |
| "is it a scam", "is it genuine" | Scam signs, or "I found no scam signs, but I can't tell if a letter is genuine" |
| "is it junk", "what kind of letter", "what's the date", "what's the reference" | As on Android |
| "read the envelope", "next page", "new letter", "summary" | As on Android |

The global "stop" pauses: the Announcer cut ends the sentence early, and the tool marks itself paused. Bare "carry on", "continue", "say that again" and "close" are left to the global grammar. "repeat" is in the tool's grammar as asked, but the global `repeatLast` matches it first unless the router hands it to the tool.

A question asked before any letter takes a picture first. "how much" on an unsure amount takes a fresh picture of the same page.

## Pipeline

1. `ReadFrameSource.prepareStreamForReading()` until ready (30 s limit). The phone camera by default, the glasses when linked.
2. The still photo (`captureStillForReading`), since letters have small print and money is at stake. The latest stream frame if the photo fails.
3. `TextRecognizer.recognize` (Vision `.accurate`, shared with Read text), off the main actor.
4. `FramingAdvisor.assess`. No text, dark, blurry or too small: the Read text guidance is spoken (`SpokenMessage.readGuidance`, phone or glasses wording) and nothing is summarised. Cut off: it summarises, then says which side.
5. `LetterScan(page:)`, then `LetterReader.read`.
6. The second look (below), only when the amount is sure.
7. The summary is spoken with the done earcon (uncertain earcon if the amount is unsure).

The working tick plays while it looks. Failures use the error or attention earcon.

## Differences from Android

- **Confidence comes from Vision's candidates, not ML Kit's characters.** ML Kit gives a score and a box for every character. Vision gives one score per line and up to three candidate readings. `WordConfidence` (Read text's code) turns that into a score per word: a word the runner-ups disagree on drops to 0.45 of the line's score, and numbers and money count any disagreement. So "£8.17" with a runner-up "£84.17" is unsure. The bar for money is `ReadSpeech.sensitiveNumberBelow` (0.8), the same as Read text's. Android uses 0.6 for word scores and 0.5 for character scores.
- **The missing-digit box check doesn't run on iOS today.** It needs a box per character, and `TextRecognizer` doesn't give them. The code and its tests are ported, so a Vision pass using `VNRecognizedText.boundingBox(for:)` could feed it later. Instead, iOS has two other checks: the runner-up disagreement above, and the second look.
- **The second look is new.** When the amount reads as sure on the photo, the latest stream frame (under 1 s old) is read too. If it reads a different sure amount, no figure is said, and every printing of that amount is masked (`LetterReader.crossChecked`). A frame that can't read the amount doesn't count against it. Android's notes listed this as an idea.
- **Scam signs are new.** Fixed phrases: payment by gift card, crypto or money transfer; asking for a PIN, password or card details; a prize or a release fee; urgency; threats of arrest; secrecy. One strong sign, or two different weak ones, gives a hint: "It has signs of a scam: it asks for payment by gift card... Check with someone you trust before you pay or reply." One weak sign alone (a council's "final notice") says nothing. It never says a letter is genuine.
- **Blocks.** ML Kit gives blocks; Vision gives lines. Every Vision line starts as its own block. `LetterLayout.mergeStacked` joins them, the same step Android needed because ML Kit did the same on the A26.
- **Hyphen repair.** Android's fix for ML Kit's "0C-" fragment misread isn't ported. Vision's language correction covers that case.
- **Same page.** Android uses character error rate. iOS checks shared words: 70 % of the shorter page's words also on the other page means it's the same page.
- **Ask about the text.** There is no iOS ask seam yet. The panel shows `Letter.safeText` (unsure amounts masked), so VoiceOver can't read a guessed figure. Any future seam should get `safeText` too.
- **Images.** Android's `ImageCheck` (covered lens, dark, nothing in view) is covered by `FramingAdvisor`'s brightness and sharpness checks.
- Answers during "read it all" cut in, then reading carries on from the same sentence.

## Panel

Large text in the brand font at Dynamic Type sizes, theme colours (dark mode and Increase Contrast follow). A yellow "What is this letter?" button, then Read it all / Pause / Carry on, Back a sentence, How much?, When is it due?, Who is it from?, Is it a scam?, Next page. Buttons are at least 60 pt, two per row, one per row at accessibility sizes. Below them: what was found (kind, from, for, date, about, amount, due, pages, scam hint) with one VoiceOver element per fact ("From, Northgate Energy"), the sentence being read, and the letter's text. An unsure amount shows as "Can't read it for sure". Identifiers start with `mail_`.

## Tests

On the Mac, iOS 27.0 simulator (iPhone 17), with signing on and parallel testing off:

- `MailReaderTests`: 35 tests, all pass. They include the 23 Android JVM tests (18 from `LetterReaderTest`, 5 from `MailGrammarTest`), with the same fixtures and the same expected sentences. The iOS additions cover Vision candidates (a clean reading is sure, a runner-up with another digit is refused, 0.5 is refused, a weak runner-up isn't doubt), the second look (a different figure is refused and masked, an agreeing or unreadable one is kept), scam signs (a hint, never "genuine", one weak sign isn't enough), the same-page check and reading by sentence.
- `MailToolTests`: 4 tests, all pass. They cover the tool seam, plus `MailTool` end to end with a fake camera and fake OCR: summary then read it all, a stream frame with another figure means no figure, and next page on the same page.
- Full `CameraAccessTests`: 297 tests, 0 failures. The known failing `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay` was skipped, because on this run it hung for more than 10 minutes instead of failing.

Note for the build: building with `CODE_SIGNING_ALLOWED=NO` makes the app host crash in `Wearables.configure()`, and parallel test clones crash the same way. Build signed (the default) and pass `-parallel-testing-enabled NO`, as `bench.sh` does.

## Not tried yet

- **Not tried on a real iPhone**, and not on real paper. All tests use hand-built fixtures and fake OCR. How often Vision scores clean lines at 0.5 (which refuses money) is unknown. If it's often, amounts will be refused often. That is the safe direction, but it may be annoying.
- The second look's value on real frames is unknown. Stream frames are lower resolution, so they may often fail to read the amount, and then they don't count.
- The scam phrases are a first list, in English with UK wording. Only fixtures have been tested.
- No UI test drives the panel yet.
- The classification rules are English and UK-specific, as on Android (dd/mm dates, council tax, NHS).
