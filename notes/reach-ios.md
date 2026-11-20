# Reach on iOS (V4)

2026-11-20. Roadmap: notes/value-strategy.md > V4 "Reach". One word or one tap opens any tool, and SpeakUp reads photos and PDFs that come from other apps.

## Siri, Shortcuts, Action Button

All in `A11y/Launch/LaunchIntents.swift`. Every intent parks a `LaunchAction` on `LaunchActionRouter`. The main screen runs it.

| Intent | Opens app | App Shortcut phrases |
|---|---|---|
| ReadIntent | yes | "Read this with SpeakUp", "Read text with SpeakUp", "SpeakUp read" |
| StatusIntent | no | "SpeakUp status", "Is SpeakUp ready", "Check SpeakUp" |
| RepeatLastIntent | no | "SpeakUp repeat", "Repeat that with SpeakUp" |
| StartHandsFreeIntent | yes | "Start hands-free in SpeakUp", "Start SpeakUp hands-free", "SpeakUp hands-free" |
| OpenMailIntent | yes | "Read my mail with SpeakUp", "Read a letter with SpeakUp" |
| OpenLabelsIntent | yes | "Scan a label with SpeakUp", "Scan a barcode with SpeakUp", "Read the label with SpeakUp" |
| OpenLightIntent | yes | "Is the light on with SpeakUp", "What colour is this with SpeakUp", "What color is this with SpeakUp", "Check the light with SpeakUp" |
| OpenWatchIntent | yes | "Watch for text with SpeakUp", "SpeakUp watch" |
| OpenAskIntent | yes | "Ask about the text with SpeakUp", "SpeakUp ask" |
| OpenToolIntent (tool parameter) | yes | "Open (tool) in SpeakUp", "SpeakUp open (tool)" |
| ReadImportedIntent | yes | none (Shortcuts app only) |

- `ToolID` is an `AppEnum`, so Shortcuts shows a tool picker.
- That is 10 App Shortcuts, Apple's limit. ReadImportedIntent has no phrase because no slot is left.
- Tool intents open the app because every tool needs the camera.
- `OpenToolLaunch.park(tool, on:)` is the shared step. Siri says "Opening Mail reader."
- Action Button and Back Tap: pick any of these shortcuts in Settings.
- The build's App Intents metadata lists 11 intents and 10 App Shortcuts (checked in `Metadata.appintents`).
- Control Center (iOS 18 `ControlWidget`) needs a widget extension. Skipped. A small widget target could add one control per tool later.
- The main screen still runs `.openMail` and the other tools as Read text until ToolHub lands. That isn't wired in this change.

## Reading photos and PDFs

Code: `A11y/Import/` and `SpeakUpShared/ImportInbox.swift`.

Every way in ends at one inbox, a folder of files named `<ms>-<random>.<ext>`. `ImportedReading.readPending()` reads everything waiting and deletes it. Items older than 7 days are dropped unread.

Ways in:

1. **In the app.** `ImportButton` offers "Choose a photo" (PhotosPicker, no library permission) or "Choose a file" (document picker, PDF or image). It reads straight away.
2. **Open in / Copy to SpeakUp.** Both Info.plists declare `CFBundleDocumentTypes` for `com.adobe.pdf` and `public.image` (Viewer, Alternate). `LSSupportsOpeningDocumentsInPlace` is NO, so the app gets a copy. `.readsImports()` puts the file in the inbox and parks `.readImported`.
3. **Share sheet.** See below.
4. **`speakup://read-imported`** reads what is waiting. Shortcuts or tests can use it.

When the app comes to the front with something in the inbox, it parks `.readImported` itself.

How it reads:

- Photo: "Reading the photo." Vision OCR runs meanwhile. Empty: "Nothing to read in this picture."
- PDF: "PDF, 3 pages. Page 1.", then "Page 2." and so on. The next page is prepared while the current one is spoken.
- A PDF page with a text layer is read from the text layer, so the words are exact. A page without one is rendered (2600 px max) and OCR'd with `TextRecognizer`.
- Imports use a lower minimum text height (1/128) than the camera, because pages and screenshots have small text. `TextRecognizer.recognize` got an optional `minimumTextHeight` parameter. The default is unchanged.
- Transparent pictures are put on white first. Vision reads transparency as black, so black text on a clear PNG came back empty.
- The order and sentences come from `ReadingOrder`, `SentenceSplitter` and `ReadSpeech.render`, like the camera. Uncertain words get the same earcon. Doses and amounts are withheld the same way.
- Each page's text is added to `RecentText` under Read text, so Ask can answer questions about it.
- Locked PDF: "This PDF has a password..." Not a photo or PDF: "SpeakUp reads photos and PDFs..."
- Everything stays on the phone. Imports never use the cloud reader.

### Why ImportedReader is not TextReader

`TextReader` has no public way to be given a page. Its only trigger is the camera. So `ImportedReader` speaks the sentences the same way, through `Announcer`. Next, previous and repeat go to TextReader and don't move through imported text. Starting a camera read, Stop or Magic Tap cuts the import.

**Hook request:** a `TextReader.read(page: ReadPage)` entry would let imports share navigation. Not added, per the brief.

## Share extension "SpeakUp Share"

- Target `SpeakUp Share` (`com.deaco.speakup.share`) is embedded in the **SpeakUp** (store) app only. Code is in `SpeakUpShare/`. Info.plist and entitlements are in `Config/`.
- It accepts 1 to 10 images or PDFs, including screenshots from the markup editor (a UIImage turns into a PNG).
- iOS doesn't let a share extension open its app. Only Today and iMessage extensions may call openURL, and workarounds get rejected. So the extension copies the files into the App Group `group.com.deaco.speakup` and shows "Saved. Open SpeakUp to hear it." with a large Done button. VoiceOver announces it.
- The app reads them the next time it comes to the front.
- The Beta app (CameraAccess) has no App Group and no extension. Its inbox is in its own Application Support. An extension needs a bundle ID under its parent's ID, so the Beta would need its own extension target.
- Before a device build, register the App Group for the team, on both the app ID and the extension ID.

## Tests

`CameraAccessTests/ImportTests.swift`: 33 tests in 5 classes.

- ImportPDFTests: page count, text layer read exactly, reading order, scanned page goes to OCR, blank page, not a PDF, render size, fallback lines.
- ImportPhotoTests: OCR of a photo, text on a transparent background, blank picture, not an image, scaling down, the spoken lines.
- ImportInboxTests: order, kinds, removing, expiry, refusing other files, copying, file names.
- ImportURLTests: URL parsing, the read-imported link, other links left alone, an opened PDF, coming to the front.
- OpenToolIntentTests: tool to LaunchAction, one intent per tool, the parameter, openAppWhenRun, display names, at most 10 shortcuts.

Full CameraAccessTests run, skipping DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay, with `-parallel-testing-enabled NO`: **492 tests, 0 failures**. Both schemes build. `plutil -lint` passes on the project and all plists and entitlements.

## Checked end to end on the Simulator

On iOS 27.0 "SpeakUp Reach iPhone 17", SpeakUp build, cold boot:

- I put a 3-page text PDF in the App Group inbox (where the share extension puts it) and launched the app. The log showed `import pdf pages=3`, then `page=1/2/3 source=text_layer`. The inbox was empty afterwards.
- A PNG of a page: `import photo lines=1`. A blank PNG: `import photo empty`, which says "Nothing to read in this picture."
- The App Group container resolves on the Simulator.
- `simctl openurl speakup://read-imported` stops at iOS's "Open in SpeakUp?" prompt, which needs a tap. No iOS device driver was available, so the URL path is only covered by unit tests.
- One early run opened the PDF but said nothing more. That was before the cut-line logging was added. Three later runs, one from a cold boot, read every page. Watch for it.

## Not tried

- A real iPhone. Not tried: Siri phrases spoken aloud, the Action Button, the share sheet UI, Open in from Files, PhotosPicker, the document picker, and App Group provisioning.
- The share extension's UI was built but not driven.
- Large PDFs (100+ pages) and memory use in the share extension.
