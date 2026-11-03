# Book reader resolution experiment (synthetic)

2026-10-27. The "Experiment (do first)" from `notes/book-reader.md`, run as far as it goes without glasses. Question: what is the smallest capture setting that reads book body text at ≤ 2% CER, for a full page and for a half page? Answer and tables are in `results.md`.

There are no real photos yet. The pages are rendered from public-domain text, a simulated HSTN camera "photographs" them, and a desktop OCR engine stands in for ML Kit. Read the results as a first estimate that shows the shape of the problem. Real captures and ML Kit still need to confirm it.

## Pipeline

| Step | Script | Output (all under `out/` is gitignored) |
|---|---|---|
| 1. Lay out and render 17 page images (20 book pages) | `layout.py` | `out/pages/*.png`, `gt/` |
| 2. Simulate captures: 17 pages × 3 modes × 8 settings = 408, plus 17 flat "clean" renders | `capture.py` | `out/captures/<setting>/<page>__<mode>.jpg`, `out/captures/manifest.json` |
| 3. OCR (cached) and score CER/WER | `ocr_score.py` | `out/ocr/`, `out/scores.csv`, `results.md` |
| 4. Flat export for ML Kit on Android | `export_for_mlkit.py` | `out/mlkit_export/` |
| 5. ML Kit input-prep variants (crop / 2x / 3x / enhance), emulator run, scoring | `prep_for_mlkit.py`, `run_mlkit_prep.sh` | `out/mlkit_prep/`, `results_mlkit_prep.md` |

`passages.py` holds the text and `metrics.py` handles normalisation and Levenshtein distance (bit-parallel, no dependencies, self-test: `python metrics.py`).

## Rerun

```
cd experiments/book-reader-resolution
py -3 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python layout.py
.venv\Scripts\python capture.py          # ~15 min on a loaded 16-core box
.venv\Scripts\python ocr_score.py        # ~1-2 h first time (OCR is cached); --score-only to rescore
.venv\Scripts\python export_for_mlkit.py # -> out\mlkit_export
```

Python 3.14.3. `rapidocr` 3.10 and `onnxruntime` 1.31 install cleanly on 3.14. The old `rapidocr-onnxruntime` package only resolves to 1.2.3 on 3.14, so don't use it. On first run RapidOCR downloads its PP-OCRv5 models (a few MB) into the venv. Everything is seeded, so reruns produce the same images.

ML Kit round trip: push `out/mlkit_export/*.jpg` to the emulator, run Text Recognition v2 (Latin), and write one `results/<image>.json` per image with `{"boxes": [[[x,y]×4], ...], "txts": [...]}` from `Text.Line.cornerPoints` / `Text.Line.text`. Then run `python ocr_score.py --external out/mlkit_export/results --label mlkit` to get `results_mlkit.md`, scored the same way. Format details are in `out/mlkit_export/README.txt`.

## Dataset

| Type | Pages | Size (mm) | Font | Size / leading | Lines | Layout |
|---|---|---|---|---|---|---|
| paperback `pa-01..07` | 7 | 110×178 | Times New Roman | 11 / 12.4 pt | 34 | page number in the header outer corner, centred running header, narrow margins |
| hardback `ha-01..05` | 5 | 152×229 | Palatino Linotype | 12 / 14.5 pt | 36 | page number at the foot |
| spread `sp-01..02` | 2 images = 4 pages | 2 × 135×205 | Georgia | 10.5 / 13.5 pt | 2 × 34 | open book, gutter in the middle |
| textbook `te-01..03` | 3 | 210×270 | Cambria | 9 / 11 pt | 2 × 60 | two columns, headings inside columns |

- Text: Austen (Pride and Prejudice ch. 1), Melville (Moby-Dick ch. 1), Dickens (A Tale of Two Cities ch. 1, A Christmas Carol stave 1), Darwin (Origin, Introduction). It was typed from memory, so wording may differ slightly from any one edition. That doesn't matter, because the ground truth is what got rendered. Text flows from page to page, so a word can be hyphenated across a page break.
- Typography: justified, curly quotes, em dashes, first-line indents, chapter openers with a sunk heading and no running header. Line-end hyphenation uses a crude VC|CV rule (e.g. "surroun-ding") and also breaks at existing hyphens ("door-|nail"). The JSON records which kind each break is.
- Ground truth per page in `gt/`:
  - `<id>.body.txt`: body lines as printed, line-end hyphens kept. Chapter headings count as body.
  - `<id>.rejoined.txt`: one paragraph per line, with soft hyphens removed and hard ones kept.
  - `<id>.meta.txt`: running header and page number(s).
  - `<id>.json`: line boxes in mm, column index, page rects, gutter side, half-page region, x-height.

## Assumptions

Camera (`capture.py`, top of file):

- **Sensor:** 3024×4032 portrait (FULL 12 MP). Pinhole model with a **100° diagonal FOV** for the full 4:3 sensor. This is a guess for an ultra-wide glasses camera; Meta doesn't publish an HSTN FOV. It gives f = 2115 px, so the full sensor sees 71° × 87° (H×V).
- **Crops and scaling:** every setting is a centre crop of the sensor to its own aspect, then an area resample to its size:
  - 9:16 stream: 2268 px wide, 56° horizontal
  - 2:3 in-stream photo: 2688 px wide, 65°
  - 3:4 photo: full width, 71°

  We don't know whether the real stream is cropped, binned, or uses a different ISP path. With these crops, the linear pixel density relative to FULL is LOW / photo SMALL 0.16, MEDIUM 0.22, photo MEDIUM 0.24, HIGH 0.32, in-stream photo / LARGE 0.36.
- **In-stream photo:** 960×1440, taken from the mock (`notes/bench-android-native.md`). Real glasses may return a different size.
- **Photo sizes:** SMALL/MEDIUM/LARGE are taken as 480×640, 720×960 and 1080×1440 (3:4). The docs only say "~480p/~720p/~1080p".
- **Compression:** streams are HEVC on the wire, approximated by JPEG q50 (LOW, MEDIUM) and q55 (HIGH). This gives blocking rather than HEVC smear, at a guessed bitrate-equivalent quality. In-stream photo JPEG q80. Photos JPEG q85 (PhotoQuality MEDIUM, guessed).
- **Optics and sensor:**
  - Gaussian lens softness σ 1.1 px at sensor resolution.
  - Fixed focus, sharp at ≥ 45 cm. Defocus grows to σ ≈ 1.9 px at 25 cm (a guess).
  - Head-motion blur: a line kernel 0–5 sensor px long at a random angle.
  - Shot + read noise (σ ≈ 4/255 on paper).
  - Mild unsharp mask after resampling, standing in for ISP sharpening.
  - No denoise and no HDR.
- **Pose and framing:**
  - Distance is from the camera to the aimed point.
  - Pitch 8–18° (top of page farther away), yaw ±6°, roll ±4°.
  - The page sits 2–7% right of centre, because the camera is on the left temple.
  - The aimed region is always kept fully inside the narrowest (9:16) crop. So this tests resolution, not the cut-off-on-the-right framing problem (hard part #2).
- **Modes:**
  - `full_35` / `full_45`: whole page (or spread) at 35 / 45 cm.
  - `half_25`: head closer, at 25 cm, aimed at the top half of the page (the left page of a spread). Only lines in that half are scored.

  With a 100° lens a whole paperback still fits in frame at 25 cm. "Half page" here means going closer and scoring half, not cropping.
- **Page:**
  - Curls into the gutter over the 22% of the page width nearest it: content squeezes toward the gutter, lines bow by ~3%, and a gutter shadow up to −35%.
  - Off-white paper with mottling, ink density 0.88.
  - Brown desk background.
  - Lamp gradient −15 to −35% across the frame, lens vignetting −35% at the corners, exposure 0.85–0.95.
- **FOV sensitivity:** pixel density scales with focal length over distance. If the real lens is narrower, e.g. 80° diagonal (f × 1.42), then `full_45` here approximates ~63 cm and `half_25` approximates ~35 cm. Use the x-height table in `results.md` to transfer results: CER tracks body x-height in delivered pixels far more than anything else.

OCR and scoring (`ocr_score.py`):

- **Proxy engine:** RapidOCR 3.10, with the PP-OCRv5 mobile detector and the English PP-OCRv5 mobile recogniser on onnxruntime CPU. The angle classifier is off. This is a mobile-class model like ML Kit, but it is not ML Kit, and the two will fail at different x-heights.
- **Preprocessing (both oracle steps would be done by the app in practice):**
  - Crop to the page's bounding box plus a 4% margin (oracle page detection). This keeps OCR time manageable. The PP-OCR detector scales its input so the short side is at least 736 px, so a small page crop also gets upscaled for detection. Recognition still sees the original pixels.
  - Upscale 2× bicubic before OCR, for every setting except FULL. The PP-OCR detector misses small text at native size: in-stream photo at 35 cm went from 4 boxes to 30 on the same page. The paperback pages are also scored without the upscale, to show the difference.
- **Oracle layout:** each OCR line box is mapped back to page coordinates through the known homography and gutter curl, then assigned to the nearest ground-truth line.
  - Headers and page numbers are dropped.
  - In `half_25`, lines outside the target half are dropped.
  - Text on the page that matches no line is kept, so it counts as insertions.
  - The text is then joined in true reading order.

  So the score is recognition only. It excludes column order, spread splitting, header removal and hyphen rejoining, which are layout work for later.
- **Metrics:** both sides are normalised with NFKC, ASCII quotes and dashes, and whitespace collapsed. Case and punctuation count.
  - CER = Levenshtein(chars) / reference chars.
  - WER = Levenshtein(words) / reference words.
  - Tables pool edits over pages. "≤ 2%" means pooled CER for that page type, setting and mode.
- **Ceiling:** the "clean" row is OCR of the flat page at 8 px/mm (~200 dpi), with no camera at all. It is the engine's own floor on this typography.

## Not done / didn't work

- No real HSTN photos, and no Mock Device Kit run. The mock's `setCameraFeed` / `setCapturedImage` path, ML Kit and real ISP/HEVC are all still open. `export_for_mlkit.py` prepares the ML Kit half.
- `rapidocr-onnxruntime` (the package named in the plan) is stuck at an old 1.2.3 build on Python 3.14. Use `rapidocr` 3.x instead. EasyOCR wasn't tried.
- The OCR ran on a machine already saturated by Unity and an Android emulator. On this onnxruntime build, batched recognition was very slow (~1 s/line), so `Rec.rec_batch_num` is 1. Timings in `out/scores.csv` are therefore not meaningful as latency.
