# ML Kit with input preparation

2026-10-28. ML Kit Text Recognition v2 (Latin, bundled) on the Android emulator, over the same synthetic captures as `results.md`, after app-side prep. Question: how much of raw ML Kit's gap to the proxy (`results_mlkit.md`) is input preparation, and what is the smallest GA setting at <= 2% CER once the input is prepared.

Subset: stream_HIGH, instream_photo, photo_LARGE, photo_FULL; all 17 page images; all modes (some preps skip modes, see below). Scored with `ocr_score.score_image` (same oracle layout as `results.md` / `results_mlkit.md`): ML Kit line boxes are mapped back to capture pixels (box / scale + crop origin) first. Pooled CER %, body text only.

Pipeline: `prep_for_mlkit.py prep` -> `run_mlkit_prep.sh` (push, `MlKitFolderScore -e dumpLines true`, pull) -> `prep_for_mlkit.py score` (`out/mlkit_prep/scores.csv`). Images and results stay under `out/mlkit_prep/`.

## Preps

| prep | what | run on |
|---|---|---|
| raw | the capture as delivered (the `results_mlkit.md` run) | all |
| crop | oracle page crop (page bbox + 4%, `ocr_score.page_crop`), native pixels, PNG | all |
| crop_up2 | crop + 2x bicubic | HIGH / instream / LARGE all modes; FULL full_35 + full_45 |
| crop_up3 | crop + 3x bicubic | HIGH / instream / LARGE, full_35 + half_25 |
| crop_up2_enh | crop, grayscale, flatten lighting (divide by a heavy blur), 1-99% stretch, 2x, unsharp (σ 1.5, amount 1) | as crop_up3 |
| crop_max2000 | crop, then area-downscale to a 2000 px long side | FULL half_25 with crops over 2000 px (10 images; every other FULL crop is already under 2000) |

## CER (%) by setting, prep and mode

| Setting | prep | full_35: all / pb / hb / sp / tb | full_45: all / pb / hb / sp / tb | half_25: all / pb / hb / sp / tb | median ms |
|---|---|---|---|---|---|
| stream_HIGH | raw | 94.2 / 92.6 / 86.1 / 91.9 / 99.9 | 99.2 / 99.7 / 96.6 / 99.5 / 100.0 | 55.6 / 50.3 / 27.6 / 41.7 / 75.4 | 2018 |
| stream_HIGH | crop | 69.5 / 69.2 / 18.9 / 67.6 / 95.3 | 95.6 / 98.3 / 82.4 / 97.5 / 99.9 | 46.1 / 6.6 / 27.2 / 43.9 / 78.3 | 6184 |
| stream_HIGH | crop_up2 | 65.9 / 65.7 / 18.6 / 58.1 / 92.5 | 94.9 / 97.6 / 79.0 / 97.9 / 99.9 | 11.0 / 6.5 / 0.7 / 3.6 / 20.2 | 5339 |
| stream_HIGH | crop_up3 | 62.9 / 57.7 / 15.2 / 58.6 / 91.1 | - | 10.5 / 6.6 / 0.7 / 3.5 / 19.0 | 5445 |
| stream_HIGH | crop_up2_enh | 72.7 / 75.2 / 28.4 / 72.1 / 93.4 | - | 16.8 / 11.3 / 1.8 / 7.0 / 29.4 | 5537 |
| instream_photo | raw | 79.0 / 63.6 / 59.2 / 78.4 / 97.6 | 95.9 / 98.2 / 85.9 / 95.0 / 99.9 | 37.9 / 25.9 / 11.1 / 22.9 / 61.1 | 3286 |
| instream_photo | crop | 51.1 / 12.7 / 5.9 / 79.4 / 83.8 | 75.3 / 81.4 / 28.6 / 66.8 / 98.4 | 33.3 / 1.8 / 11.1 / 30.4 / 62.8 | 6613 |
| instream_photo | **crop_up2** | 25.8 / 9.5 / 3.4 / 9.7 / 52.3 | 69.3 / 76.0 / 20.3 / 61.9 / 92.6 | **1.2 / 1.6 / 0.1 / 0.5 / 1.7** | - |
| instream_photo | crop_up3 | 17.2 / 6.6 / 1.2 / 8.3 / 34.6 | - | 1.3 / 1.8 / 0.1 / 0.4 / 1.8 | 5861 |
| instream_photo | crop_up2_enh | 25.9 / 12.4 / 4.6 / 13.1 / 49.0 | - | 1.5 / 1.8 / 0.1 / 0.7 / 2.3 | 5796 |
| photo_LARGE | raw | 74.4 / 57.3 / 56.7 / 56.1 / 100.0 | 92.5 / 97.5 / 69.4 / 95.3 / 99.9 | 40.5 / 37.8 / 12.0 / 18.5 / 60.6 | 3471 |
| photo_LARGE | crop | 49.5 / 9.5 / 5.3 / 78.0 / 82.4 | 72.9 / 74.4 / 24.8 / 62.8 / 99.7 | 33.0 / 1.7 / 10.6 / 29.8 / 62.6 | 6860 |
| photo_LARGE | crop_up2 | 22.4 / 6.6 / 3.9 / 6.3 / 46.9 | 66.2 / 69.3 / 16.5 / 51.5 / 94.8 | 0.9 / 1.3 / 0.1 / 0.6 / 1.1 | - |
| photo_LARGE | crop_up3 | 12.6 / 4.6 / 0.8 / 4.5 / 26.1 | - | 0.8 / 1.2 / 0.1 / 0.4 / 1.1 | 6594 |
| photo_LARGE | crop_up2_enh | 21.2 / 9.6 / 3.9 / 8.5 / 41.2 | - | 1.1 / 1.4 / 0.1 / 0.6 / 1.4 | 5875 |
| photo_FULL | raw | 39.0 / 29.1 / 16.2 / 23.0 / 62.3 | 68.3 / 70.6 / 51.0 / 41.8 / 86.1 | 2.6 / 1.8 / 1.0 / 0.5 / 4.2 | 5749 |
| photo_FULL | crop | 1.9 / 0.8 / 0.1 / 0.7 / 3.8 | 3.1 / 2.5 / 0.6 / 0.6 / 5.6 | 0.3 / 0.5 / 0.0 / 0.5 / 0.3 | 7722 |
| photo_FULL | **crop_up2** | **1.2 / 0.9 / 0.2 / 0.7 / 2.0** | **1.2 / 1.8 / 0.7 / 0.6 / 1.3** | - | - |
| photo_FULL | crop_max2000 | - | - | 0.2 / - / 0.0 / 0.4 / 0.3 | 8339 |

Proxy for reference (`results.md`, crop + 2x, FULL crop native): instream half_25 6.9 / 0.5 / 0.1 / 4.3 / 14.5; FULL full_35 19.1 / 1.2 / 0.0 / 1.7 / 45.4; FULL full_45 29.2 / 1.8 / 1.1 / 9.1 / 66.4.

ms = median `ocr_ms` from the harness TSV (`recognize()` only, no decode), emulator, relative only. The raw run was an earlier, less loaded emulator session (2-3.5 s/image); the prep runs were all 5-8 s/image whatever the scale, so these numbers can't show what upscaling costs. crop_up2 for the GA settings has no timing (the emulator was shut down mid-run by another job, and the TSV only covers the rerun tail).

## Best recipe

1. **Crop to the page before OCR.** This is most of the gap for FULL: 12 MP raw 39% -> 1.9% at full_35, and 7 raw FULL images returned zero lines (6 of them at full_45). Page text that is small relative to the whole frame does badly, which fits ML Kit downscaling large inputs internally. The 2000 px cap on FULL half_25 crops neither helps nor hurts (0.3 -> 0.2).
2. **Then upscale 2x (bicubic)** when the body x-height in the crop is under ~11 px (all GA settings, FULL at full_45 or with small type). In-stream half page: crop alone 33% -> 1.2%. The hardback half page stays at 11% with crop alone and drops to 0.1% at 2x, so this is resolution, not framing. 3x only helps where the native x-height is ~4 px (full-page GA: instream full_35 hb 3.4 -> 1.2%) and never takes paperback or textbook under 2%. Rule of thumb: ML Kit wants ~11+ px body x-height after scaling, from at least ~5 px native.
3. **No enhancement.** Grayscale + lighting flatten + stretch + unsharp is worse than plain 2x everywhere (stream_HIGH half 11.0 -> 16.8%). Hand ML Kit the colour crop.

So the app should: find the page quad, crop it (with a margin), scale so the body x-height is ~11-17 px (2x for GA captures; 1x-2x for FULL depending on distance), and then run ML Kit. Real page detection replaces the oracle crop. A perspective warp to the page quad would also do the scaling, but it wasn't tested here.

## Answer (ML Kit + best prep, smallest setting <= 2% pooled CER)

| Page type | full_35 | full_45 | half_25 |
|---|---|---|---|
| all | photo_FULL crop_up2 (Exp., 1.2%) | photo_FULL crop_up2 (Exp., 1.2%) | **instream_photo crop_up2 (GA, 1.2%)** |
| paperback | photo_FULL crop (Exp., 0.8%) | photo_FULL crop_up2 (Exp., 1.8%) | instream_photo crop_up2 (GA, 1.6%) |
| hardback | instream_photo crop_up3 (GA, 1.2%) | photo_FULL crop (Exp., 0.6%) | stream_HIGH crop_up2/up3 (GA, 0.7%) |
| spread | photo_FULL crop_up2 (Exp., 0.7%) | photo_FULL crop (Exp., 0.6%) | instream_photo crop_up3 (GA, 0.4%; up2 0.5%) |
| textbook | photo_FULL crop_up2 (Exp., 2.0%) | photo_FULL crop_up2 (Exp., 1.3%) | instream_photo crop_up2 (GA, 1.7%) |

- **Half page: GA in-stream photo (960x1440) + crop + 2x reads every page type, the 9 pt two-column textbook included (1.2% pooled, 1.7% textbook).** 3/17 pages are over 2% (pa-02 2.9%, te-03 2.3%, pa-07 2.1%). stream_HIGH is enough only for hardback (0.7%); paperback stays at 6.5% and textbook at 20%.
- **Full page: still Experimental FULL.** With crop + 2x it reads every page type at both 35 and 45 cm (1.2% pooled; textbook 2.0% at 35 cm is borderline). The only GA full-page pass is the hardback at 35 cm with 3x (1.2%). Paperback best is 6.6%.
- Only these 4 settings were prepped. stream_LOW/MEDIUM and photo_SMALL/MEDIUM have smaller x-heights than stream_HIGH, so they're unlikely to pass, but that is untested with ML Kit + prep.

## Odd things

- **Raw ML Kit drops and garbles fragments on clearly legible text.** In FULL full_35 ha-01 raw, "hope, it was the winter of despair, we had everything before" came back as "Spat, we" plus "all ooing direct to", even though the crop is crisp at 11 px x-height. On the page crop the same lines read perfectly. This is an input-size effect, not image quality.
- **Line splitting with overlapping fragments.** At native GA resolution ML Kit often splits a printed line into two Lines that overlap: "per | er-", "taking | king", "grindst | dstone". The oracle scorer joins both fragments in x order, so the overlap counts as insertions. A real layout pass would have to de-duplicate overlapping fragments on the same line. These fragments mostly go away after 2x. A fragment can also land a line off ("know how many yean" slotted into the next line) when its box centre mis-maps.
- **Upscaling also fixes line-level failures, not just characters.** In hardback half_25 every line was hit with crop alone, but 10-20% of them were garbled. At 2x they read cleanly.
- Residual errors at the answer settings are mostly punctuation (dropped closing quotes and question marks, `;` -> `:`) and e/c confusions ("marricd", "ycar").
- `MlKitOcr` returns axis-aligned `boundingBox` rectangles, not the rotated `cornerPoints` the README describes. The scorer only uses the box centre, so this doesn't matter here.
- Housekeeping: the emulator was shut down mid-run by another job. 148/187 crop_up2 results had survived on the device, one was truncated to 0 bytes, and the rest (40 images) were rerun. All 809 scored results are complete.
