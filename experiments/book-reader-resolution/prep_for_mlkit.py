"""Input preparation for ML Kit: crop / upscale / enhance variants, and their scoring.

Raw ML Kit (results_mlkit.md) got the uncropped capture; the proxy got an oracle page crop
and a 2x upscale. This script makes the same subset in several preps so ML Kit can be
compared like for like, and scores the results with ocr_score.score_image (same oracle layout).

Subset: stream_HIGH, instream_photo, photo_LARGE, photo_FULL; all pages.

Variants (out/mlkit_prep/<variant>/):
  crop          page crop (ocr_score.page_crop: page bbox + 4%), native pixels. All 4 settings, all modes.
  crop_up2      crop + 2x bicubic. HIGH / instream / LARGE all modes; FULL full_35 + full_45.
  crop_up3      crop + 3x bicubic. HIGH / instream / LARGE, full_35 + half_25.
  crop_up2_enh  crop, grayscale, flatten lighting (divide by a heavy blur), 1-99% stretch,
                2x bicubic, unsharp (sigma 1.5, amount 1). Same subset as crop_up3.
  crop_max2000  FULL half_25 only: crop, then area-downscale so the long side is <= 2000 px
                (only crops above 2000 px are written; the rest equal `crop`).
  raw           not written; out/mlkit_export/results scored on the same subset.

Each folder: <setting>__<page>__<mode>.png, ref__<page>__<mode>.txt, manifest.tsv
(image<TAB>ref, what MlKitFolderScore reads) and prep.json (image -> source, crop, scale).
ML Kit output goes to <variant>/results/<image>.json (pulled mlkit-lines) and the harness TSV
to <variant>/book-ocr-results.tsv. Scoring maps each box back to the original capture
(box / scale + crop origin) before score_image, so numbers are comparable to results.md.

Usage:
  python prep_for_mlkit.py prep [--variants crop,crop_up2]
  python prep_for_mlkit.py score            -> out/mlkit_prep/scores.csv + table on stdout
  (run_mlkit_prep.sh pushes each folder to the emulator, runs ML Kit, pulls results)
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import statistics
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np

from ocr_score import CAP, GT, HERE, page_crop, pooled, score_image

OUT = HERE / "out" / "mlkit_prep"
EXPORT = HERE / "out" / "mlkit_export"
SETTINGS = ["stream_HIGH", "instream_photo", "photo_LARGE", "photo_FULL"]
SMALL = {"stream_HIGH", "instream_photo", "photo_LARGE"}
MODES = ["full_35", "full_45", "half_25"]
VARIANTS = ["crop", "crop_up2", "crop_up3", "crop_up2_enh", "crop_max2000"]
KINDS = ["paperback", "hardback", "spread", "textbook"]


def wanted(variant: str, setting: str, mode: str) -> bool:
    if variant == "crop":
        return True
    if variant == "crop_up2":
        return setting in SMALL or mode != "half_25"
    if variant in ("crop_up3", "crop_up2_enh"):
        return setting in SMALL and mode != "full_45"
    if variant == "crop_max2000":
        return setting == "photo_FULL" and mode == "half_25"
    return False


def enhance(img: np.ndarray) -> np.ndarray:
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    bg = cv2.GaussianBlur(g, (0, 0), max(g.shape) / 30)
    flat = g / np.maximum(bg, 1)
    lo, hi = np.percentile(flat, [1, 99])
    return np.clip((flat - lo) / max(hi - lo, 1e-6) * 255, 0, 255).astype(np.uint8)


def unsharp(img: np.ndarray, sigma: float = 1.5, amount: float = 1.0) -> np.ndarray:
    blur = cv2.GaussianBlur(img, (0, 0), sigma)
    return cv2.addWeighted(img, 1 + amount, blur, -amount, 0)


def prepare(img: np.ndarray, variant: str, crop: list[int]) -> tuple[np.ndarray, float] | None:
    img = img[crop[1]:crop[3], crop[0]:crop[2]]
    if variant == "crop":
        return img, 1.0
    if variant in ("crop_up2", "crop_up3"):
        s = 2.0 if variant == "crop_up2" else 3.0
        return cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC), s
    if variant == "crop_up2_enh":
        e = cv2.resize(enhance(img), None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
        return unsharp(e), 2.0
    if variant == "crop_max2000":
        long = max(img.shape[:2])
        if long <= 2000:
            return None
        s = 2000 / long
        return cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA), s
    raise ValueError(variant)


def flat_name(rel: str) -> str:
    setting, fn = rel.split("/")
    page, mode = fn[:-4].split("__")
    return f"{setting}__{page}__{mode}"


def load():
    manifest = json.loads((CAP / "manifest.json").read_text())
    infos = {}
    subset = {}
    for rel in sorted(manifest):
        e = manifest[rel]
        if e["setting"] not in SETTINGS:
            continue
        if e["page"] not in infos:
            infos[e["page"]] = json.loads((GT / f"{e['page']}.json").read_text(encoding="utf-8"))
        subset[rel] = e
    return subset, infos


def cmd_prep(variants: list[str]):
    subset, infos = load()
    for v in variants:
        d = OUT / v
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
        rows, prep = [], {}
        for rel, e in subset.items():
            if not wanted(v, e["setting"], e["mode"]):
                continue
            crop = page_crop(e, infos[e["page"]])
            got = prepare(cv2.imread(str(CAP / rel)), v, crop)
            if got is None:
                continue
            img, scale = got
            name = flat_name(rel) + ".png"
            cv2.imwrite(str(d / name), img)
            ref = f"ref__{e['page']}__{e['mode']}.txt"
            if not (d / ref).exists():
                shutil.copyfile(EXPORT / ref, d / ref)
            rows.append(f"{name}\t{ref}")
            prep[name] = {"source": rel, "crop": crop, "scale": scale, "size": [img.shape[1], img.shape[0]]}
        (d / "manifest.tsv").write_text("image\tref\n" + "\n".join(rows) + "\n", encoding="utf-8")
        (d / "prep.json").write_text(json.dumps(prep, indent=1), encoding="utf-8")
        print(f"{v}: {len(rows)} images -> {d}")


def read_ms(tsv: Path) -> dict[str, int]:
    if not tsv.exists():
        return {}
    with open(tsv, encoding="utf-8") as f:
        return {r["image"]: int(r["ocr_ms"]) for r in csv.DictReader(f, delimiter="\t")}


def cmd_score():
    subset, infos = load()
    rows = []
    # raw: the original export, boxes already in capture coordinates
    ms = read_ms(EXPORT / "book-ocr-results.tsv")
    for rel, e in subset.items():
        name = flat_name(rel) + ".jpg"
        rp = EXPORT / "results" / (name + ".json")
        if rp.exists():
            rows.append(score_row(e, infos, json.loads(rp.read_text(encoding="utf-8")), rel, "raw", ms.get(name)))
    for v in VARIANTS:
        d = OUT / v
        if not (d / "prep.json").exists():
            continue
        prep = json.loads((d / "prep.json").read_text(encoding="utf-8"))
        ms = read_ms(d / "book-ocr-results.tsv")
        for name, p in prep.items():
            rp = d / "results" / (name + ".json")
            if not rp.exists():
                continue
            ocr = json.loads(rp.read_text(encoding="utf-8"))
            off = np.array(p["crop"][:2], float)
            ocr["boxes"] = [(np.asarray(b, float) / p["scale"] + off).tolist() for b in ocr["boxes"]]
            rows.append(score_row(subset[p["source"]], infos, ocr, p["source"], v, ms.get(name)))
    cols = ["file", "page", "kind", "mode", "setting", "variant", "x_height_px", "cer", "wer", "char_edits",
            "ref_chars", "word_edits", "ref_words", "lines_ref", "lines_hit", "n_boxes", "ocr_ms"]
    with open(OUT / "scores.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({**r, "cer": round(r["cer"], 4), "wer": round(r["wer"], 4)})
    print(f"scored {len(rows)} -> {OUT / 'scores.csv'}")
    print(table(rows))


def score_row(e, infos, ocr, rel, variant, ms):
    r = score_image(e, infos[e["page"]], ocr)
    r.update({"file": rel, "page": e["page"], "kind": e["kind"], "mode": e["mode"], "setting": e["setting"],
              "variant": variant, "x_height_px": e["x_height_px"], "n_boxes": len(ocr["boxes"]), "ocr_ms": ms})
    return r


def table(rows) -> str:
    cell = defaultdict(list)
    for r in rows:
        for k in ("all", r["kind"]):
            cell[(r["setting"], r["variant"], r["mode"], k)].append(r)
    L = ["| Setting | prep | " + " | ".join(f"{m}: all / pb / hb / sp / tb" for m in MODES) + " | median ms |",
         "|---|---|" + "---|" * len(MODES) + "---|"]
    for s in SETTINGS:
        for v in ["raw"] + VARIANTS:
            if not any(cell.get((s, v, m, "all")) for m in MODES):
                continue
            parts = []
            for m in MODES:
                parts.append(" / ".join(f"{100 * pooled(cell[(s, v, m, k)])[0]:.1f}" if cell.get((s, v, m, k)) else "-"
                                        for k in ["all"] + KINDS))
            mss = [r["ocr_ms"] for m in MODES for r in cell.get((s, v, m, "all"), []) if r["ocr_ms"]]
            L.append(f"| {s} | {v} | " + " | ".join(parts) + f" | {int(statistics.median(mss)) if mss else '-'} |")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["prep", "score"])
    ap.add_argument("--variants", default=",".join(VARIANTS))
    a = ap.parse_args()
    if a.cmd == "prep":
        cmd_prep([v for v in a.variants.split(",") if v])
    else:
        cmd_score()


if __name__ == "__main__":
    main()
