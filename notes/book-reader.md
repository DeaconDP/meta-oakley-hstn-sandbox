# Book reader: read a printed book aloud, page by page

Idea logged 2026-10-22. Not built yet. This is a continuous-paging extension of the "Read it aloud" demo (ROADMAP step 5). Builds on `notes/hstn-capabilities.md`, `notes/a11y-perception-stack.md` and `notes/a11y-prior-art.md`.

## Why it fits

- **It fills a gap users report.** Meta AI summarises text unless asked to read "every single word". Seeing AI and Lookout read documents, but only with the phone held up (`notes/a11y-prior-art.md` > 1a, > Implications: "verbatim, complete reading").
- **Latency matters less.** A short pause per page is fine for a book, so the photo + OCR path (Tier 2 in `notes/a11y-perception-stack.md`) works here without the 1.5 s trigger-to-first-word budget.
- **Hands stay free.** They hold the book and turn pages, which a phone app can't offer.
- **No display needed.** HSTN has no display, and this app is audio only.
- **Other users** beyond BLV readers: dyslexia, low vision and tired eyes, children following along, and language learners (read, then translate the sentence).

## Loop

```
stream LOW/7 fps (warm) ─► detect page turn: hand/motion in frame, then a still frame with a new text block
   ─► framing check (text cut off? blur? dark?) ─► spoken hint, or capture
   ─► capture: in-stream capturePhoto (GA), or standalone photo LARGE/FULL (dev builds) ─► on-device OCR
   ─► layout: split spread, reading order, drop running header/page number, rejoin hyphenation
   ─► compare with last page (skip if same) ─► clause-chunked TTS
   ─► while speaking page N, the user is already on N+1: capture + OCR it during playback
```

## Hard parts

| # | Problem | Approach |
|---|---|---|
| 1 | **Resolution vs. shipping.** Book print is small. The GA options are the stream (max 720x1280) and in-stream `stream.capturePhoto()` (960x1440 bitmap on the mock, ~3.9 s). Standalone `Camera.photo` FULL 12 MP is Experimental, so dev/beta builds only (`notes/a11y-sdk-mapping.md` > In-stream photo; `notes/hstn-capabilities.md` > Capabilities) | Measure first (see Experiment). If in-stream photo isn't enough, the shippable version reads a half-page at a time with the head closer to the book |
| 2 | **Framing.** The camera is on the left, so the right side of a page gets cut off (`notes/a11y-prior-art.md` > 1a). Pages curve into the gutter | Cheap on-device text-box check before capture: "page cut off on the right, turn your head right", "tilt down". Dewarp or ignore low-confidence lines near the gutter |
| 3 | **Page-turn detection** | Motion or hand in frame, then N stable frames with a text block that differs from the last page. Spoken or earcon confirmation. Manual "next page" as fallback |
| 4 | **Two-page spreads and reading order** | Split on the gutter. Drop or announce headers, page numbers and footnotes (verbosity setting). Rejoin words hyphenated across lines and pages. Use a cloud VLM only for layout-heavy pages (columns, textbooks), never by default |
| 5 | **Gaps between pages** | Pipeline: capture and OCR page N+1 while page N is spoken |
| 6 | **Controls** | GA: phone buttons and screen-reader actions. Experimental: captouch tap = pause/resume, swipe = back a sentence / change speed, voice "go back a paragraph". User-set speech rate (experts run 2–3×) |
| 7 | **Long sessions** | Streaming for a whole chapter: watch `thermalLevel` and battery, drop to LOW between pages. Folding the hinges ends the session, so treat it as a bookmark: save the last sentence and resume from it |
| 8 | **Privacy and copyright** | On-device OCR by default; nothing uploaded or stored unless the user opts into the cloud layout path. Personal-use read-aloud, same as existing accessibility readers |

## Experiment (do first)

Resolution check. Photograph ~20 book pages (paperback, hardback, a two-column textbook). Feed each through the Mock Device Kit (`setCameraFeed` / `setCapturedImage`) at stream LOW / MEDIUM / HIGH, in-stream `capturePhoto` (GA), and standalone photo LARGE / FULL (Experimental). Run ML Kit Text Recognition v2 and score CER/WER against a hand transcription. Output: the smallest capture setting that reads body text at ≤ 2% CER, for a full page and for a half page. This decides whether a GA-only book reader can read a full page per capture.

## Open questions

- Does real-HSTN HIGH stream over Bluetooth hold 720x1280 while reading, or does the bandwidth ladder drop it (`notes/hstn-capabilities.md` > Stream bandwidth ladder)?
- Comfortable head-to-book distance that keeps a full page in frame at a readable resolution.
- Does the page-turn detector cope with the reader's own hand resting on the page?
