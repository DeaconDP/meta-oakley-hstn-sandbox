# Labels and barcodes (HstnBench, Android)

2026-11-06. The label reader from ROADMAP Phase 5 > Everyday tools. Built on the tools layer (notes/tools-layer.md). Code: `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/tools/labels/`, strings in `res/values/strings_labels.xml`.

## What it does

The user holds up a packet, tin or box and says "what's this?", "scan this", "what's this product" or "read the label" from any tool, or opens "Label Reader" from the launcher (`hstnbench://labels`).

1. **Barcode first, on the phone.** The tool starts looking straight away: ML Kit barcode scanning (bundled model `com.google.mlkit:barcode-scanning:17.3.0`, no Play Services download) on stream frames at 2 fps (`camera.frames(2f)`).
   - **Geiger ticks.** On frames that don't decode, `BarcodeHint` looks for a barcode-like patch. It looks for many dark/light changes along a row that the rows a few percent lower repeat almost exactly (bars are vertical; text isn't). It then plays 1–4 short sine ticks before the next frame, faster and higher (500 → 1400 Hz) as the patch gets bigger and more central. It reads 48 full-width rows per frame. With no patch, it plays a soft WORKING tick every 2 s, so the search is never silent.
   - **Spoken guidance.** After 5 s with nothing barcode-like: "Turn it slowly. Barcodes are usually on the back or bottom." After 4 frames that show bars but don't decode: "I can see a barcode. Bring it a little closer…" or "…Hold it steady." After 15 s: "I couldn't find a barcode. I'll read the label instead.", and it reads the label.
   - **Decoded.** The FOUND earcon plays, then "Found a barcode. Say look it up to get the product name, or read the label." EAN/UPC check digits are verified before a code counts as a product code. A QR code gets "This is a QR code. It links to example.com. I won't open links." For a QR code it reads the domain only, the network name for Wi-Fi (never the password), and the text for anything else; it never opens a link. Other 1D codes: "Found a barcode, but it isn't a product barcode. It reads 1 2 3…".
2. **Product lookup only on request.** "Look it up" sends the barcode number, and nothing else, to `https://world.openfoodfacts.org/api/v2/product/<code>.json` (with `?fields=` set to the ten fields it speaks; no key; User-Agent `HstnBench-LabelReader/0.1 (Android; accessibility app for blind users; barcode lookups only)`). It says the name, brand and quantity ("Snickers, by Mars Wrigley Confectionery UK Limited, 50 grams."), then "Say allergens or ingredients for more, or read the label." Every failure is spoken, with the error earcon:
   - not in Open Food Facts: "Open Food Facts doesn't know this product. Say read the label…";
   - no network: "I can't reach the internet, so I can't look it up…";
   - other errors: "The product lookup didn't work just now…".
   Products found are cached on the phone (`filesDir/labels_products/<code>.json`), so asking again works offline.
3. **Reading the label word for word.** "Read the label" takes the in-stream photo (`capturePage()`). It then runs the same pipeline as the book reader:
   - `book/ImageCheck`: covered, dark, nothing in view, glare or a hand in the way is said before OCR, in label wording;
   - `bookreader/MlKitOcr` on the phone;
   - `book/FramingCheck`: "I can't read any writing. Hold it about a hand's length…", or "too small".
   The text is then read one sentence per utterance (OCR blocks in reading order), so "stop" cuts it off at once. It ends with "That's all I can see. You can ask when does it expire, ingredients, allergens or cooking instructions."
4. **Quick jumps.** Each one takes a fresh photo, because the user may have turned the pack. It then searches every side read for this product, newest first. If the photo fails but something was read before, it answers from that.
   - **"When does it expire" / "best before" / "use by" / "is it out of date"** (`LabelDates`) reads the date as a date and says whether it has passed. Examples:
     - "Best before 12 March 2027."
     - "Use by 1 November. That date has already passed."
     - "Expiry date the end of June 2028."
     Formats read:
     - `BB 12/03/27`, `12.03.2027`, `12-03-27`, `12 03 2027`
     - `2027-03-12`, `EXP 2027-03`
     - `12 MAR`, `12MAR27`, `12th March 2027`, `March 12, 2027`
     - `best before end: 03 2027`, `BBE 03/27`, `MAR 27`, `EXP JUN 2028`
     - a date on the line after the keyword
     Numbers are read day first unless that's impossible. A date with no year gets the nearest year, and the year isn't spoken. A month-only date counts as passed only once the month is over. If the label says "see top of pack", it says "The label says the date is on the top…". If it finds a keyword but can't read the date: "I can see best before, but I can't make out the date…". It also reports a full date with no keyword next to it ("There's a date: …"). Nothing found: "I can't find a date on this side. Dates are often on the top, the bottom or the back…".
   - **"Ingredients"**, **"cooking instructions"** (`LabelText.section`): the text after the heading, up to the next heading. A heading is a heading word at the start of a line with a colon, or alone, or in capitals; "see ingredients in bold" isn't one. Cooking keeps its oven and microwave sub-headings. If the label has no ingredients, it uses the looked-up product's ingredients, and says they come from Open Food Facts.
   - **"Allergens"** reads the label's allergy advice plus Open Food Facts' allergen and trace lists.
   - **"Does it contain nuts" / "is it gluten free"** (`LabelText.allergenAnswer`) checks a list of words for each allergen, e.g. nuts → almond, hazelnut… and peanut; milk → whey, casein, butter… It ignores look-alikes such as cocoa butter, coconut milk and nutmeg. It looks in the label text and the product data:
     - "Yes. The label mentions almonds."
     - "It may contain milk. The label says: May contain milk."
     - "The label says: Gluten free oat bars."
     - Otherwise: "I couldn't find sesame on the part of the label I read. That doesn't mean it's free from sesame. Check the whole label, or ask someone to check."
     **It never answers "no" because it didn't find something.**
   - **"What is it"**: the product name, or "The biggest writing says: …".
5. **Medicine rule.** See below.
6. **Ask about the text.** Food label text (each side read) and the product summary go to `hub.recentText`, so "what does … mean" works on them. QR text goes there too. Medicine text never does.

Commands (`LabelsGrammar.parse`, tried before the global grammar):
- scan / what's this / try again / next one
- look it up
- read the label / read it
- read it all
- when does it expire (and synonyms)
- cooking instructions / how do I cook it
- ingredients / what's in it
- allergens / does it contain X / is it X free
- what is it
- stop scanning / cancel
- dose questions

"Read the label" means "read it now" inside the tool. Nothing in the grammar claims another tool's opening phrase; `LabelsGrammarTest` checks this. "Stop" (global Pause) also stops the search and the reading.

The screen mirrors the state for TalkBack and sighted helpers:
- phase (a polite live region), barcode, product, label text (scrollable), and a medicine banner;
- five large buttons that do exactly what the voice commands do: Scan, Look it up, Read label, Date, Allergens.

Test tags are `labels_*` (see `LabelsTool.kt`).

## Medicine rule

From the ROADMAP: medicine gives the name only, never doses.

- **Detection** (`MedicineCheck.looksLikeMedicine`) leans towards "medicine":
  - one strong sign is enough: tablets, capsules, caplets, lozenges, dosage or dose, pharmacy, pharmacist, prescription, "patient information leaflet", "active ingredient", "each tablet contains", "do not exceed", oral suspension, inhaler, "medicine", common drug names (paracetamol, ibuprofen, aspirin, codeine…), or an Open Food Facts category containing medicine, drug, pharma or dietary/food supplements;
  - otherwise it takes two different weak signs: a strength in mg or mcg, "take 2", "take" (not "take care"), "every 4 hours" or "twice a day", "daily" (not "daily value"), or "children under 12".
  - A food nutrition panel ("sodium 400mg", "% Daily Value") stays food.
  - It is checked after every OCR and after a lookup.
- **What is said for medicine:**
  - The name, with every number and unit stripped, e.g. "Paracetamol 500 mg Tablets" → "Paracetamol Tablets": "This looks like medicine: PARACETAMOL."
  - The expiry date is still given, **only if it was read clearly**, and always with a reminder (decided 2026-11-07): "Expiry date the end of June 2028. Please have a pharmacist or a trusted person check the date before you take it." If the OCR confidence of any line the date came from is below 0.8, or the engine gave none, no date is said: "I can see a date on this medicine, but I can't read it for sure. Please ask a pharmacist or a trusted person to check it." (`MedicineCheck.expiry`, `MedicineExpiryTest`). Food dates are unchanged.
  - "Read it all", ingredients, cooking and allergens all get the name, then "For medicine I only tell you the name and the date. I won't read medicine doses. Please check with a pharmacist or a trusted person."
  - Any dose question ("how many should I take", "what's the dose", "how often", "directions for use", "can I take another") gets "I won't read medicine doses. Please check with a pharmacist or a trusted person." This happens on any label, food or not.
- **Nothing from a medicine label leaves the speech path.**
  - Its text is not shown on screen, so TalkBack can't read a dose either.
  - It is not published to RecentText, so "ask about the text" can't send a dose to a model. Only the name is set as the title.
  - The only place the OCR text appears is the debug logcat line `label view N: …`, which the instrumented test uses.

## Privacy

- **Only the barcode number leaves the phone, and only when the user says "look it up"** (or presses the Look it up button). There is no image, no label text and no location. It goes over HTTPS to Open Food Facts, and no account or key is used. The lookup happens nowhere else in the tool.
- Barcode decoding, OCR, date parsing, allergen search and medicine detection all run on the phone.
- Frames and photos are only held in memory while being processed. Product replies are cached on the phone: public data, keyed by barcode.

## Tests (2026-11-06)

### JVM

From `tracks/android-native/HstnBench`: `./gradlew assembleDebug assembleDebugAndroidTest testDebugUnitTest` builds, and runs **149 tests with 0 failures**. That's the 101 from before plus 48 new ones in `app/src/test/.../tools/labels/`:

- `LabelDatesTest` (13): every format above; day-first versus impossible day-first; no year → nearest year, not spoken; best-before-end and month-only dates; next-line dates; past, today, and a month not yet over; two kinds of date; unlabelled dates; "see top"; keyword without a date; nutrition numbers, BBC and "expert" not mistaken for dates; impossible dates.
- `OpenFoodFactsTest` (10): MiniJson basics and errors; recorded replies. The four fixtures were recorded from world.openfoodfacts.org on 2026-11-06:
  - Snickers 5000159461122, full reply (117 KB);
  - a dietary supplement under 5012345678900, full reply, category `en:dietary-supplements` → medicine;
  - Nutella with the app's `fields=`;
  - "no code or invalid code".
  The tests check name, brands, quantity ("400 g e" → "400 grams"), allergens and traces, a missing name, and the URL holding only the code. `OpenFoodFactsSource` is tested with a fake fetch: it caches found products, answers from the cache when offline, reports Offline for an unknown code with no network, treats 404/status 0 as NotFound (not cached), and treats 503 as Failed.
- `LabelTextTest` (12): sections end at the next heading; the "see ingredients in bold" mention isn't a heading; cooking keeps sub-headings; the name is the biggest print; allergen yes, may contain, free-from, never "no", look-alikes, peanuts for nuts, product data, summary; medicine detection on medicine, supplements, food panels and "take care"; strength stripping.
- `LabelsGrammarTest` (7): every command and its synonyms. Dose questions always win. Other tools' phrases and global commands parse to nothing here and still reach the global grammar. The opening phrases still open the tool.
- `BarcodeHintTest` (6): a drawn EAN-13 is found at the right place, and smaller or off-centre is less "close"; text rows and plain paper aren't barcodes; a barcode below text is found; check digits (EAN-13, EAN-8, UPC-A padded, UPC-E); QR descriptions (domain only, Wi-Fi without the password, tel, long text cut).

### Instrumented

Galaxy A26, Android 16, mock HSTN, run with the phone lock. `am instrument -e class …LabelsToolTest`: **2 tests, both pass** (8.9 s).

- `decodesTheBarcodeLooksItUpAndReadsTheDate`:
  - `LabelRenderer` draws a cereal label with a real EAN-13 (4006381333931, bars drawn from the L/G/R tables) and "Best before: 12/03/27". The label is the stream (`playFrames`, 480x864 HEVC) and the photo (`showImage`, 960x1440).
  - A voice-first launch starts the search, which decoded the barcode from the stream about 1.7 s after the feed was set.
  - The test asserts that no lookup happened before it was asked for.
  - "look it up" goes to a fake injected source (`LabelsLookup.source`), which received exactly `["4006381333931"]` and returned "Oat Crunch, by Test Mills, 500 grams.", on screen too.
  - "when does it expire" → "Best before 12 March 2027." (OCR 149 ms).
  - "does it contain nuts" → "Yes. The label mentions almonds."
  - The label text is in RecentText.
- `medicineGivesTheNameOnlyAndNeverADose`:
  - The paracetamol label reads "500 mg Tablets / Dosage: adults take 2 tablets every 4 hours. Do not exceed 8 tablets in 24 hours. / EXP 2028-06".
  - "read the label" → "This looks like medicine: PARACETAMOL. For medicine I only tell you the name and the date. I won't read medicine doses…"
  - "how many should I take" and "read it all" are declined.
  - "when does it expire" → "Expiry date the end of June 2028. Please have a pharmacist or a trusted person check the date before you take it."
  - None of these were ever sent to speech: "500", "2 tablets", "4 hours", "every", "Do not exceed", "24 hours", "Dosage".
  - There is no label text on screen and no "tablets" in RecentText.

`ToolsTest` (3) passes with the labels stub check removed. **Shared file touched:** `ToolsTest.kt` lost one line, `ToolId.LABELS to "scan this"`, from `everyStubOpensConnectsAndSaysItIsNotReady`, because the label reader is no longer a stub.

### Live Open Food Facts check (manual, from the phone)

`LabelsLiveLookupCheck`, which only runs with `-e live_off true`. It used the app's own `OpenFoodFactsSource` on the A26 over Wi-Fi:

- Nutella 3017620422003 → Found in 1049 ms;
- "Nutella, by Ferrero, 400 grams.", allergens milk, nuts and soya;
- a second lookup was served from the phone's cache.

## Not done / not verified

- **Real glasses:**
  - nothing has run on real HSTN;
  - barcode decoding on the real stream (size, blur, keyframe rate) and from real packaging (curved tins, shiny film, small barcodes) is untested;
  - the mock barcode was large and flat, 360 px wide in a 480 px frame.
- **On the phone, not just in JVM tests:**
  - the geiger ticks and the "I can see a barcode…" hint: `BarcodeHint` itself is only JVM-tested;
  - the 5 s turn hint and the 15 s fall-back to reading;
  - the silence reminders.
- The geiger heuristic's thresholds (18 transitions, 85 % row agreement) were tuned on synthetic patterns only. Real photos of text with strong vertical strokes (condensed capitals) may tick falsely.
- **Medicine detection** is keyword-based and English-only. A medicine whose label OCR misses every keyword, with no lookup, would be read in full. Detection leans towards medicine, but it isn't proof. Supplements count as medicine, which is deliberate and conservative. The expiry date is given for medicine (see above).
- **Allergen answers** rely on OCR seeing the words. Bold-only allergen marking can't be detected, and a side not yet shown isn't searched; the answer says "on the part of the label I read".
- **Dates:** US month-first dates are only read as such when day-first is impossible. Some formats aren't handled: Julian-day codes, `2027 MAR 12`, and non-English month names.
- **Open Food Facts data is crowd-sourced and sometimes wrong** (the recorded Nutella reply lists its ingredients as "sugar, palm oil"). The tool says where an answer came from, but doesn't judge its quality.
- UPC-E codes are sent as 8 digits, without expanding them to UPC-A, so Open Food Facts may not find them.
- Speech-rate changes don't apply to sentences already queued while reading a label. Utterances are queued with QUEUE_ADD; "stop" still drops them all.
