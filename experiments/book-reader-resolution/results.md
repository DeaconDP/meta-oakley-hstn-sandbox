# Book reader resolution experiment: results

Generated 2026-10-28 by `ocr_score.py`. Synthetic pages, simulated HSTN captures, desktop proxy OCR (RapidOCR PP-OCRv5 mobile, English). Not ML Kit, not real glasses. See README.md for every assumption.

CER/WER are pooled over pages (total edits / total reference chars or words), in %. Body text only: running headers and page numbers are excluded from the reference and from the OCR output. Reading order is an oracle, so this measures recognition only.

<!-- summary:start (hand-written, kept on rerun) -->
## Summary (2026-10-28 run)

- **Full page per capture: needs Experimental FULL (12 MP).** At 35 cm, FULL reads paperback (1.2% CER), hardback (0.0%) and a two-page spread (1.7%). It fails the 9 pt two-column textbook (45%). At 45 cm only single pages pass (paperback 1.8%, hardback 1.1%); the spread doesn't (9.1%).
- **No GA setting reads a full page at <= 2%.** The closest is the in-stream `capturePhoto` (960x1440) on a paperback at 35 cm: 2.7% CER, 11% WER. Hardback gets 9.8%, and spreads and textbooks fail outright. Experimental LARGE has the same pixel density as the in-stream photo and lands in the same place (2.1% paperback).
- **Half page, head at 25 cm: GA works for ordinary books.** The in-stream photo reads paperback at 0.5% and hardback at 0.1%. Stream HIGH just passes on hardback (1.9%) but not paperback (4.5%). The left page of a spread gets 4.3% (LARGE 2.2%). The textbook gets 14.5% at GA and needs FULL (0.1%).
- **Threshold:** with this proxy engine, book text reads reliably at ~5.5-6 px body x-height in the delivered image. At 3-5 px the result depends on font and blur: paperback at 3.9 px gets 2.7%, the textbook at 4.7 px gets 14.5%, and anything under ~3 px fails (see the x-height table). At 35 cm the 100°-lens guess gives a paperback x-height of 3.9 px for the in-stream photo and 11 px for FULL.
- **For the plan:** a GA-only book reader should read half a page per capture (head closer, two in-stream photos per page). Full page per capture needs FULL, so it's dev/beta builds only. Two-column textbooks need FULL either way. All of this needs confirming with ML Kit on the exported set and with real HSTN photos.

### ML Kit vs proxy, with and without prep (2026-10-28)

ML Kit Text Recognition v2 on the emulator, same captures and oracle scorer. Detail in `results_mlkit.md` (raw) and `results_mlkit_prep.md` (prepped). Pooled CER %, all page types / paperback / hardback / spread / textbook.

| Setting, mode | proxy (crop, 2x except FULL) | ML Kit raw | ML Kit crop | ML Kit crop + 2x |
|---|---|---|---|---|
| instream_photo half_25 | 6.9 / 0.5 / 0.1 / 4.3 / 14.5 | 37.9 / 25.9 / 11.1 / 22.9 / 61.1 | 33.3 / 1.8 / 11.1 / 30.4 / 62.8 | **1.2 / 1.6 / 0.1 / 0.5 / 1.7** |
| stream_HIGH half_25 | 27.4 / 4.5 / 1.9 / 13.2 / 55.7 | 55.6 / 50.3 / 27.6 / 41.7 / 75.4 | 46.1 / 6.6 / 27.2 / 43.9 / 78.3 | 11.0 / 6.5 / 0.7 / 3.6 / 20.2 |
| instream_photo full_35 | 47.9 / 2.7 / 9.8 / 51.0 / 91.0 | 79.0 / 63.6 / 59.2 / 78.4 / 97.6 | 51.1 / 12.7 / 5.9 / 79.4 / 83.8 | 25.8 / 9.5 / 3.4 / 9.7 / 52.3 (3x: 17.2 / 6.6 / 1.2 / 8.3 / 34.6) |
| photo_FULL full_35 | 19.1 / 1.2 / 0.0 / 1.7 / 45.4 | 39.0 / 29.1 / 16.2 / 23.0 / 62.3 | 1.9 / 0.8 / 0.1 / 0.7 / 3.8 | **1.2 / 0.9 / 0.2 / 0.7 / 2.0** |
| photo_FULL full_45 | 29.2 / 1.8 / 1.1 / 9.1 / 66.4 | 68.3 / 70.6 / 51.0 / 41.8 / 86.1 | 3.1 / 2.5 / 0.6 / 0.6 / 5.6 | **1.2 / 1.8 / 0.7 / 0.6 / 1.3** |

- Raw ML Kit's gap is almost all input preparation. Crop to the page, then 2x bicubic. With that, ML Kit matches or beats the proxy everywhere, and it does much better on spreads and the 9 pt textbook.
- Contrast/unsharp enhancement made it worse. Leave it out.
- Revised answer:
  - **Half page:** GA in-stream photo + crop + 2x reads every page type (1.2% pooled, textbook 1.7%).
  - **Full page:** still Experimental FULL, which needs crop + 2x to cover textbooks and 45 cm (1.2%). The only GA full-page pass is the hardback at 35 cm with 3x (1.2%).
<!-- summary:end -->

## Caveats

- Synthetic pages and a simulated camera. The FOV (100° diagonal guess), crops, blur, noise and compression are assumptions (README.md > Assumptions). Pixel density per mm of page drives everything. A narrower real lens would shift every row toward better, so read across with the x-height table.
- Proxy OCR, not ML Kit Text Recognition v2. The two will break down at different x-heights. Score the same images with ML Kit via `export_for_mlkit.py` before deciding.
- Everything except FULL is upscaled 2x before OCR, and every image is cropped to the page first (oracle page detection). Layout is an oracle too, so real reading order, spread splitting and header removal will only add errors.
- Stream HEVC is approximated by JPEG. Real streams over Bluetooth may also drop a resolution step (bandwidth ladder).
- 17 page images, one pose per page and mode. Per-cell numbers rest on 2-7 pages, so treat differences of a point or two as noise.

## Answer

Smallest capture setting (by pixel count) with pooled body-text CER <= 2%.

| Page type | full_35 | full_45 | half_25 |
|---|---|---|---|
| all | none | none | photo_FULL (Exp., 0.1%) |
| paperback | photo_FULL (Exp., 1.2%) | photo_FULL (Exp., 1.8%) | instream_photo (GA, 0.5%) |
| hardback | photo_FULL (Exp., 0.0%) | photo_FULL (Exp., 1.1%) | stream_HIGH (GA, 1.9%) |
| spread | photo_FULL (Exp., 1.7%) | none | photo_FULL (Exp., 0.1%) |
| textbook | none | none | photo_FULL (Exp., 0.1%) |

Modes: `full_35` / `full_45` = whole page (or spread) in frame, camera 35 / 45 cm from the page centre. `half_25` = head closer (25 cm), aimed at the top half of the page (left page of a spread); only lines in that half are scored.

## CER (%) by page type, setting and mode

| Setting | GA? | prep | full_35: all / pb / hb / sp / tb | full_45: all / pb / hb / sp / tb | half_25: all / pb / hb / sp / tb |
|---|---|---|---|---|---|
| stream_LOW | GA | up2 | 99.9 / 100.0 / 99.9 / 99.9 / 100.0 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 98.6 / 99.0 / 96.0 / 98.4 / 99.8 |
| stream_MEDIUM | GA | up2 | 98.5 / 99.2 / 95.7 / 98.1 / 99.8 | 99.9 / 99.9 / 99.7 / 99.8 / 100.0 | 70.8 / 52.3 / 31.8 / 88.4 / 98.0 |
| stream_HIGH | GA | up2 | 71.6 / 46.2 / 28.5 / 96.4 / 97.2 | 95.4 / 98.2 / 82.8 / 97.3 / 99.3 | 27.4 / 4.5 / 1.9 / 13.2 / 55.7 |
| instream_photo | GA | up2 | 47.9 / 2.7 / 9.8 / 51.0 / 91.0 | 68.1 / 45.6 / 18.0 / 93.2 / 95.5 | 6.9 / 0.5 / 0.1 / 4.3 / 14.5 |
| photo_SMALL | Exp. | up2 | 99.1 / 99.8 / 96.5 / 99.6 / 99.9 | 99.9 / 99.9 / 99.7 / 99.8 / 100.0 | 73.7 / 66.0 / 37.4 / 92.7 / 93.3 |
| photo_MEDIUM | Exp. | up2 | 72.4 / 56.5 / 23.7 / 96.8 / 95.7 | 94.8 / 99.8 / 75.7 / 99.0 / 99.8 | 44.5 / 3.0 / 7.9 / 41.5 / 87.1 |
| photo_LARGE | Exp. | up2 | 46.0 / 2.1 / 8.1 / 45.9 / 89.3 | 63.7 / 35.3 / 12.7 / 91.3 / 93.7 | 6.6 / 0.7 / 0.0 / 2.2 / 14.0 |
| photo_FULL | Exp. | native | 19.1 / 1.2 / 0.0 / 1.7 / 45.4 | 29.2 / 1.8 / 1.1 / 9.1 / 66.4 | 0.1 / 0.1 / 0.0 / 0.1 / 0.1 |
| clean flat render, 8 px/mm (engine ceiling) | - | native | 0.1 / 0.2 / 0.0 / 0.0 / 0.0 | | |

## WER (%) by page type, setting and mode

| Setting | GA? | prep | full_35: all / pb / hb / sp / tb | full_45: all / pb / hb / sp / tb | half_25: all / pb / hb / sp / tb |
|---|---|---|---|---|---|
| stream_LOW | GA | up2 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 99.7 / 99.7 / 99.2 / 99.0 / 100.0 |
| stream_MEDIUM | GA | up2 | 99.5 / 99.7 / 98.4 / 99.6 / 100.0 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 83.3 / 79.3 / 51.9 / 97.4 / 99.5 |
| stream_HIGH | GA | up2 | 83.9 / 75.6 / 51.1 / 99.0 / 98.9 | 98.6 / 99.9 / 94.4 / 99.2 / 99.8 | 39.4 / 13.0 / 4.3 / 22.6 / 76.0 |
| instream_photo | GA | up2 | 54.6 / 11.1 / 15.2 / 67.0 / 94.7 | 79.4 / 70.6 / 36.8 / 97.6 / 98.3 | 11.5 / 2.6 / 0.3 / 7.7 / 23.2 |
| photo_SMALL | Exp. | up2 | 99.8 / 100.0 / 99.0 / 100.0 / 100.0 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 86.2 / 87.4 / 59.0 / 97.1 / 97.8 |
| photo_MEDIUM | Exp. | up2 | 84.0 / 80.8 / 46.5 / 99.1 / 98.4 | 98.2 / 100.0 / 91.6 / 99.5 / 100.0 | 51.6 / 11.3 / 13.3 / 60.3 / 93.2 |
| photo_LARGE | Exp. | up2 | 51.9 / 8.0 / 12.4 / 61.7 / 93.3 | 75.1 / 59.5 / 29.8 / 97.0 / 97.8 | 10.4 / 3.1 / 0.0 / 6.1 / 20.8 |
| photo_FULL | Exp. | native | 21.9 / 2.9 / 0.2 / 3.8 / 51.1 | 35.0 / 5.2 / 2.4 / 15.4 / 76.4 | 0.5 / 0.5 / 0.0 / 0.6 / 0.7 |
| clean flat render, 8 px/mm (engine ceiling) | - | native | 0.3 / 0.8 / 0.1 / 0.1 / 0.1 | | |

## Body x-height in the delivered image (px, median over pages)

| Setting | full_35: pb / hb / sp / tb | full_45: pb / hb / sp / tb | half_25: pb / hb / sp / tb |
|---|---|---|---|
| stream_LOW | 1.7 / 1.9 / 1.7 / 1.5 | 1.4 / 1.5 / 1.3 / 1.2 | 2.4 / 2.6 / 2.4 / 2.1 |
| stream_MEDIUM | 2.4 / 2.7 / 2.4 / 2.1 | 1.9 / 2.1 / 1.9 / 1.6 | 3.4 / 3.7 / 3.4 / 3.0 |
| stream_HIGH | 3.5 / 3.8 / 3.5 / 3.0 | 2.7 / 3.0 / 2.7 / 2.3 | 4.8 / 5.3 / 4.9 / 4.2 |
| instream_photo | 3.9 / 4.3 / 3.9 / 3.4 | 3.0 / 3.3 / 3.0 / 2.6 | 5.5 / 6.0 / 5.5 / 4.7 |
| photo_SMALL | 1.7 / 1.9 / 1.7 / 1.5 | 1.4 / 1.5 / 1.3 / 1.2 | 2.4 / 2.6 / 2.4 / 2.1 |
| photo_MEDIUM | 2.6 / 2.9 / 2.6 / 2.2 | 2.0 / 2.2 / 2.0 / 1.7 | 3.6 / 4.0 / 3.6 / 3.2 |
| photo_LARGE | 3.9 / 4.3 / 3.9 / 3.4 | 3.0 / 3.3 / 3.0 / 2.6 | 5.5 / 6.0 / 5.5 / 4.7 |
| photo_FULL | 11.0 / 12.0 / 11.0 / 9.4 | 8.5 / 9.3 / 8.5 / 7.3 | 15.3 / 16.7 / 15.3 / 13.3 |

## Native vs 2x upscale before OCR (pooled CER %, paperback pages only)

| Setting | full_35 native / up2 | full_45 native / up2 | half_25 native / up2 |
|---|---|---|---|
| stream_LOW | 100.0 / 100.0 | 100.0 / 100.0 | 99.5 / 99.0 |
| stream_MEDIUM | 99.3 / 99.2 | 99.8 / 99.9 | 46.9 / 52.3 |
| stream_HIGH | 43.9 / 46.2 | 99.2 / 98.2 | 4.8 / 4.5 |
| instream_photo | 2.9 / 2.7 | 51.0 / 45.6 | 2.1 / 0.5 |
| photo_SMALL | 99.9 / 99.8 | 100.0 / 99.9 | 78.4 / 66.0 |
| photo_MEDIUM | 72.7 / 56.5 | 99.8 / 99.8 | 1.9 / 3.0 |
| photo_LARGE | 2.4 / 2.1 | 43.3 / 35.3 | 1.3 / 0.7 |
| photo_FULL | 1.2 / - | 1.8 / - | 0.1 / - |

## Pages over 2% CER at each mode's answer setting (all page types)

- full_35: no setting reaches 2% pooled.
- full_45: no setting reaches 2% pooled.
- half_25 @ photo_FULL: 0/17 pages over 2%
