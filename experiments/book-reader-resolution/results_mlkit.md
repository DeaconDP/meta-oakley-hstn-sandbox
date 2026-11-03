# Book reader resolution experiment: results

Generated 2026-10-28 by `ocr_score.py`. Synthetic pages, simulated HSTN captures, mlkit OCR via export_for_mlkit.py, not real glasses. See README.md for every assumption.

CER/WER are pooled over pages (total edits / total reference chars or words), in %. Body text only: running headers and page numbers are excluded from the reference and from the OCR output. Reading order is an oracle, so this measures recognition only.

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
| all | none | none | none |
| paperback | none | none | photo_FULL (Exp., 1.8%) |
| hardback | none | none | photo_FULL (Exp., 1.0%) |
| spread | none | none | photo_FULL (Exp., 0.5%) |
| textbook | none | none | none |

Modes: `full_35` / `full_45` = whole page (or spread) in frame, camera 35 / 45 cm from the page centre. `half_25` = head closer (25 cm), aimed at the top half of the page (left page of a spread); only lines in that half are scored.

## CER (%) by page type, setting and mode

| Setting | GA? | prep | full_35: all / pb / hb / sp / tb | full_45: all / pb / hb / sp / tb | half_25: all / pb / hb / sp / tb |
|---|---|---|---|---|---|
| stream_LOW | GA | mlkit | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 98.3 / 99.7 / 93.9 / 98.0 / 100.0 |
| stream_MEDIUM | GA | mlkit | 99.9 / 100.0 / 99.7 / 99.8 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 93.2 / 95.9 / 79.8 / 85.3 / 99.9 |
| stream_HIGH | GA | mlkit | 94.2 / 92.6 / 86.1 / 91.9 / 99.9 | 99.2 / 99.7 / 96.6 / 99.5 / 100.0 | 55.6 / 50.3 / 27.6 / 41.7 / 75.4 |
| instream_photo | GA | mlkit | 79.0 / 63.6 / 59.2 / 78.4 / 97.6 | 95.9 / 98.2 / 85.9 / 95.0 / 99.9 | 37.9 / 25.9 / 11.1 / 22.9 / 61.1 |
| photo_SMALL | Exp. | mlkit | 99.9 / 100.0 / 99.6 / 99.8 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 87.7 / 95.1 / 55.1 / 90.7 / 99.8 |
| photo_MEDIUM | Exp. | mlkit | 99.3 / 99.7 / 96.8 / 99.8 / 100.0 | 100.0 / 100.0 / 99.9 / 99.9 / 100.0 | 81.0 / 65.9 / 69.5 / 54.4 / 100.0 |
| photo_LARGE | Exp. | mlkit | 74.4 / 57.3 / 56.7 / 56.1 / 100.0 | 92.5 / 97.5 / 69.4 / 95.3 / 99.9 | 40.5 / 37.8 / 12.0 / 18.5 / 60.6 |
| photo_FULL | Exp. | mlkit | 39.0 / 29.1 / 16.2 / 23.0 / 62.3 | 68.3 / 70.6 / 51.0 / 41.8 / 86.1 | 2.6 / 1.8 / 1.0 / 0.5 / 4.2 |
| clean flat render, 8 px/mm (engine ceiling) | - | native | 0.1 / 0.4 / 0.0 / 0.1 / 0.1 | | |

## WER (%) by page type, setting and mode

| Setting | GA? | prep | full_35: all / pb / hb / sp / tb | full_45: all / pb / hb / sp / tb | half_25: all / pb / hb / sp / tb |
|---|---|---|---|---|---|
| stream_LOW | GA | mlkit | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 99.7 / 99.9 / 99.1 / 99.4 / 100.0 |
| stream_MEDIUM | GA | mlkit | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 97.0 / 98.9 / 89.6 / 96.1 / 100.0 |
| stream_HIGH | GA | mlkit | 97.8 / 98.1 / 93.1 / 97.6 / 100.0 | 99.7 / 99.9 / 98.9 / 99.9 / 100.0 | 68.5 / 64.7 / 36.4 / 57.4 / 89.4 |
| instream_photo | GA | mlkit | 86.5 / 78.3 / 69.4 / 88.1 / 99.2 | 98.3 / 99.4 / 92.8 / 98.9 / 100.0 | 46.4 / 36.7 / 16.1 / 35.2 / 69.8 |
| photo_SMALL | Exp. | mlkit | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 | 95.3 / 99.2 / 81.7 / 96.1 / 100.0 |
| photo_MEDIUM | Exp. | mlkit | 99.8 / 100.0 / 98.9 / 99.9 / 100.0 | 100.0 / 100.0 / 99.9 / 100.0 / 100.0 | 86.7 / 79.2 / 74.3 / 72.3 / 100.0 |
| photo_LARGE | Exp. | mlkit | 82.7 / 73.2 / 67.1 / 72.8 / 100.0 | 96.0 / 99.2 / 81.8 / 98.6 / 100.0 | 47.6 / 45.4 / 16.5 / 28.4 / 68.5 |
| photo_FULL | Exp. | mlkit | 48.6 / 40.2 / 25.3 / 33.7 / 71.0 | 74.8 / 77.8 / 57.8 / 52.7 / 90.4 | 5.8 / 5.7 / 1.4 / 2.6 / 8.7 |
| clean flat render, 8 px/mm (engine ceiling) | - | native | 0.9 / 2.4 / 0.2 / 0.6 / 0.4 | | |

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
| stream_LOW | - / - | - / - | - / - |
| stream_MEDIUM | - / - | - / - | - / - |
| stream_HIGH | - / - | - / - | - / - |
| instream_photo | - / - | - / - | - / - |
| photo_SMALL | - / - | - / - | - / - |
| photo_MEDIUM | - / - | - / - | - / - |
| photo_LARGE | - / - | - / - | - / - |
| photo_FULL | - / - | - / - | - / - |

## Pages over 2% CER at each mode's answer setting (all page types)

- full_35: no setting reaches 2% pooled.
- full_45: no setting reaches 2% pooled.
- half_25: no setting reaches 2% pooled.

