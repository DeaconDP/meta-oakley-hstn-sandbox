# Mail reader (HstnBench, Android)

2026-11-06. The second everyday tool (ROADMAP Phase 5). A blind user holds up a letter or envelope and asks "what is this letter?". They hear who it's from, who it's for, what kind of letter it is, what it's about, and any amount due and deadline. "Read it all" then reads every word. Everything runs on the phone: ML Kit OCR and fixed rules, no cloud. Code is in `tools/mail/` under `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/`, with strings in `res/values/strings_mail.xml`. It's built on the tools layer (notes/tools-layer.md).

## What it does

| Say | What happens |
|---|---|
| "what is this letter", "read", "what's this", "what does it say" | Takes a photo (`capturePage`) and speaks a short summary |
| "read it all", "read every word", "read the whole letter" | Reads every paragraph one sentence at a time |
| "stop" / "carry on" / "back" / "skip" / "say that again" / "start again" | Controls reading by sentence |
| "who's it from", "who sent this" | Sender |
| "who's it for", "who is it addressed to" | Recipient name and address |
| "how much", "what do I owe" | Amount due (and any minimum payment), or a refusal (see the money rule) |
| "when is it due", "what's the deadline" | Pay-by date, reply-by date or appointment |
| "is it junk", "is it important" | Advert or not |
| "what kind of letter is this", "is this a bill" | The kind |
| "what's the date on it", "what's the reference number" | Letter date; references spelled one character at a time |
| "read the envelope" | Takes a photo and describes it as an envelope |
| "next page", "I've turned it over" | Adds a page; the summary updates ("2 pages. …") |
| "new letter", "next letter" | Forgets this letter and photographs a new one |
| "summary", "tell me again" | Repeats the summary without a new photo |

A question asked before any letter has been read ("how much?") photographs one first and then answers. "read my mail" while the tool is already open photographs whatever is held up. Example summary (from the A26 run):

> A bill from Northgate Energy, for Mrs Jane Patel. Dated 3 November 2026. About: Your electricity bill. Amount due: £84.17, by 24 November 2026. Say read it all to hear every word.

An envelope: "This is the outside of an envelope, addressed to Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB, from Northgate Energy. Open it and hold up the letter, then say read."

The phone screen has big yellow buttons (What is this letter?, Read it all / Pause / Carry on, Back a sentence, Next page, How much?). Below them are the facts found (kind, from, for, date, about, amount, due, pages) in large text, the sentence being read, and the full letter text. Each button calls `hub.userActed()`. Test tags are listed in `MailTool.kt`.

## Pipeline

`MailViewModel`: `capturePage` → `ImageCheck`, the book reader's instant check for a covered lens, dark room or nothing in view → `MailOcr` (ML Kit v2, like `MlKitOcr`, but it keeps each line's block plus every word's and character's confidence and box) → `FramingCheck` (no text, blurred, too small, cut off; for a cut-off letter it still summarises and then says which way to turn) → `LetterReader` → `LetterSpeech`. While working it plays a soft tick every 1.5 s and says "Still reading the letter" after 6 s. Every failure is spoken with the error earcon. The full text goes to `hub.recentText` (`clear(MAIL)` for a new letter, `addPassage(key = "letter")`, `setTitle("Letter from …")`, and `setCurrent` while reading) for the ask tool.

Pure, JVM-tested files: `LetterModel` (scan, words, characters, the missing-character check), `LetterText` (money, dates, postcodes, spelling out numbers), `LetterLayout`, `LetterReader`, `LetterSpeech`, `MailGrammar`.

## The rules

**Layout** (`LetterLayout`). It works on ML Kit's blocks, not on book layout:
1. Table rows. An amount alone on the right of a row is joined to the label on its left ("Standing charge £12.30"). So is a date after a deadline label ("First instalment due 1 December 2026") or any value after "Label:". A right-aligned letter date is never joined to the address line level with it.
2. Stacked blocks merge. **On the A26, ML Kit put every address line and every table label in a block of its own.** Blocks whose vertical gap is less than 0.9 of a line, that line up on the left (short lines may line up on the right instead), and whose text size is similar (the range is loose, because descenders make boxes taller) become one block.
3. Blocks are read top to bottom. Of two blocks side by side, the left one is read first.
4. A block of short lines (an address) is read as one sentence with commas. A block of long lines becomes a paragraph, with words hyphenated across line ends rejoined (`PageLayout.joinLine`). A short line ending in an amount or date gets a full stop, so each table row is its own sentence.

**Fields** (`LetterReader`).
- Header: the lines above "Dear …" or the "Re:" line. If neither exists, the top 36 % of the page.
- Recipient: an address block in the header whose first line has a title (Mr/Mrs/Ms/Miss/Mx/Dr/The Occupier…), or one with a postcode on the left half of the page. An untitled address on the right is the sender's own (the top right of a personal letter). "Private and confidential" and mailsort codes are skipped.
- Sender, in this order: a "From:" line; on an envelope, "If undelivered return to …"; the letterhead (the largest text in the top quarter, at least 1.3 times the body text height); the name under "Yours sincerely" / "Lots of love"; the first line of the other address block, if it isn't a house number.
- Date: the first date that isn't a deadline. Formats: "24 November 2026", "Nov 24, 2026", "24/11/2026" (UK order, day first), "2026-11-24".
- Subject: a "Re:/Subject:" line. Otherwise a heading (text at least 1.15 times the body height, below the letterhead). Otherwise "It starts: " plus the first sentence of the body, up to 25 words.
- Amount due: money on a line saying "amount due / total due / balance due / amount payable / total to pay / please pay / you owe / we will collect / new balance…". If there is none, a "total" line. Lines saying previous / paid / received / credit / excluding VAT / subtotal / saving don't count, and neither does "CR". A "minimum payment" is reported separately and doesn't count as a conflict.
- Deadline: a date on a line saying due / pay by / deadline / no later than / collected on, or "by"/"before" directly in front of the date. Failing that, the date at the start of the next line in the same block, or "within 14 days". Priority: pay > appointment (with its time) > reply by > other.
- References: account / customer / reference / policy / NHS / invoice / council tax reference / sort code / account ending… with at least 3 digits. They are spoken one character at a time with a pause between groups ("8 8 4 2, 1 9 3 7, 5 5"). "Read it all" also spells out phone numbers beginning with 0 and any run of 5 or more digits.
- Kind: keyword scores for bill, bank, official, medical, personal and advert. Extra points: an amount due adds to bill; up to 3 "!" add to advert; "Dear <one first name>" adds to personal. Official, medical or bank wins at a score of 5 or more if it is within 3 of the top score, so a council tax bill counts as official, and the amount is still said. Advert wins only at 5 or more and only if it beats every other kind. A top score under 3 gives "a letter".
- Envelope: no "Dear", no sign-off, at most one long line, under 60 words, and either an address block or postal markings (Royal Mail, postage paid, if undelivered…). Never an advert: a flyer addressed to "The Occupier" is junk, not an envelope.

**The money rule** (ROADMAP: refuse on money it can't verify). The amount due is `Unsure` and no figure is spoken if:
- a character where a digit should be isn't one ("£8O.17", "£l2.50"); or
- **any character** of the amount (digits, point and currency sign) has ML Kit character confidence under 0.5. With no character scores, the cut-off is a word or line confidence under 0.6; or
- the character boxes show a character went missing: a digit box more than 1.6 times the typical digit width, a point or comma wider than 0.6 of a digit, or a gap of more than 0.9 of a digit between characters.

Two different amounts that are both "due" and both sure give `Conflict`, and again no figure is spoken. The same amount printed twice is fine. In "read it all", any amount that isn't sure is read as "an amount I can't read for sure". On an unsure amount, "how much" takes a fresh photo of the same page (replacing that page) before answering, so "hold it closer and say how much" works. An unsure deadline gives "The due date isn't clear".

Why the money rule checks every character and the boxes: **the first run on the A26 said a wrong figure.** With the 4 of "£84.17" pixelated, ML Kit returned "£8.17" and every remaining digit had high confidence (0.89–0.92). The low score (0.28) was on the "." whose box had stretched over the smudge. A digit-only confidence check passed it, and the tool said "The amount due is £8.17". Counting every character, plus the box check, now refuses it. The first version of the gap check also refused a clean "£84.17", because a narrow "1" leaves 8 px gaps next to 12 px digits. The gap limit was loosened to 0.9 of a digit. The clean amounts' lowest character scores on the A26 were 0.55–0.79 (always the "£"), close to the 0.5 limit.

## Test results (2026-11-06, Galaxy A26 SM-A266B, Android 16, mock HSTN)

- **JVM** (`./gradlew testDebugUnitTest`): 124 tests, 0 failures. That's the 101 from before plus 23 new ones:
  - `LetterReaderTest` (18): a utility bill, a bank letter, a council tax bill, a personal letter, a flyer, a window envelope, a hospital appointment, a 2-page bill, and the money rule (a low-confidence digit, a smudged "£" or ".", O for 0, conflicting amounts, the same amount twice, line confidence only, minimum payment, an unsure charge replaced in "read it all", and the missing-character box check, including the A26's real boxes).
  - `MailGrammarTest` (5): every phrase above; other tools' openers and the global commands are left alone; money, date and number patterns.
  - The fixtures are in `LetterFixtures.kt`: hand-built OCR geometry with word and character confidences.
- **Instrumented** (`MailToolTest`, 3/3 pass): a rendered bill (`LetterRenderer`, sans-serif, letterhead, window address, right-aligned account number and date, a table of charges with right-aligned amounts) as the mock's photo, a voice-first launch, then voice only.
  - `summarisesALetterThenReadsItAll`: "what is this letter" gives the exact summary above, and the screen shows "From: Northgate Energy" and the amount. The text reaches `recentText`. "who's it from" and "when is it due" are answered without a new photo. "double speed", then "read it all" reads all 15 sentences in order. Table rows come out as rows ("Standing charge £12.30." … "Amount due £84.17."), the account number and phone number are spelled out, and it ends with "That's the end of the letter…".
  - `refusesConflictingAmounts`: a second "Total to pay £48.17" gives the conflict line with no figure.
  - `neverSaysAFigureThatIsNotOnTheLetter`: the 4 smudged; "how much" (no letter yet, so it photographs first) refuses. The test fails if any figure other than £84.17 is spoken.
- `ToolsTest` (shared, edited) 3/3 pass on the A26.
- Speed: from "what is this letter" heard to the summary ready, about 0.5 s on the A26 (ML Kit plus the rules, on a 960x1440 render).

## Shared files touched

- `app/src/androidTest/.../ToolsTest.kt`: two assertions expected the mail stub to say "Mail reader isn't ready yet". They now expect `mail_welcome` for the mail tool. Nothing else changed.
- Reused without changing: `book/FramingCheck`, `ImageCheck`, `SpeechChunker`, `TextDistance`, `PageLayout.joinLine` (internal, same module), `OcrModel.Box`.

## Not done / not verified

- **Nothing has run on real glasses or real paper.** Everything above uses rendered letters on the mock. Real photos are the open question: blur, curved paper, shadows and lower resolution. The confidence limits (0.5 per character, 0.6 per word) and the box check are tuned on one font on one phone. The clean "£" scored as low as 0.55, so real photos may refuse often (the safe direction). How often the box check fires on real print is unknown.
- The geometry check needs ML Kit character boxes. A smudge that ML Kit reads as a different digit, at high confidence and with normal boxes, would still get through. No check can catch that, and only a second photo would help. One idea not built yet: read the amount on two photos and refuse if they differ.
- Classification is keyword rules in English with UK wording (council tax, HMRC, NHS, postcodes, dd/mm dates). Only the eight fixture letters and one rendered bill have been tested. US dates (mm/dd) would be misread as day first.
- Summaries and answers are English text in `LetterSpeech.kt`, not string resources (like the book's FramingCheck hints). Screen and status strings are in `strings_mail.xml`.
- On a real two-column letterhead or a dense table, ML Kit may group blocks differently from what was seen here. Only one real ML Kit layout has been seen (the rendered bill).
- An advert's "sender" is its biggest headline ("MEGA SOFA SALE!").
- Handwritten letters: ML Kit's Latin model isn't made for handwriting. Not tested.
- Multi-page and envelope behaviour are JVM-tested only, not on the phone.
- Verbosity levels (short/normal/detailed) aren't implemented. The summary is always the same length.
