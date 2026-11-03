"""OCR every capture with a desktop proxy engine, score CER/WER, write results.md.

Engine: RapidOCR 3.x (onnxruntime), PP-OCRv5 mobile detector + English PP-OCRv5
mobile recogniser. Stand-in for ML Kit Text Recognition v2, not a substitute.

Variants per image:
  up2     2x bicubic upscale first (app-side preprocessing). Main result for every
          setting except FULL and clean, which are scored native.
  native  the capture as delivered. Also run on the paperback pages for every
          setting, to show what the upscale buys.

Before OCR the image is cropped to the page's bounding box plus a margin (oracle
page detection: an app would find the page quad itself). This keeps desktop OCR
time sane; it does not change pixel density.

Layout is an oracle: each OCR box is mapped back onto the printed page through the
known capture geometry and slotted into the ground-truth line it lands on. So the
score measures recognition only, not reading order, header removal or hyphen rejoin.

Usage:
  python ocr_score.py               run missing OCR (cached in out/ocr/), score, write results.md
  python ocr_score.py --score-only  rescore from cache
  python ocr_score.py --workers 3
  python ocr_score.py --external out/mlkit_export/results --label mlkit
                                    score another engine's output (see export_for_mlkit.py),
                                    writes results_mlkit.md
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from collections import defaultdict
from multiprocessing import Pool
from pathlib import Path

import cv2
import numpy as np

from capture import MODES, SETTINGS, curl_map
from metrics import cer_wer

HERE = Path(__file__).resolve().parent
CAP = HERE / "out" / "captures"
OCR = HERE / "out" / "ocr"
GT = HERE / "gt"
THRESH = 0.02

SETTING_ORDER = [s[0] for s in SETTINGS]
GA = {"stream_LOW", "stream_MEDIUM", "stream_HIGH", "instream_photo"}
KINDS = ["paperback", "hardback", "spread", "textbook"]

_engine = None


def engine():
    global _engine
    if _engine is None:
        from rapidocr import LangDet, LangRec, ModelType, OCRVersion, RapidOCR
        threads = int(os.environ.get("OCR_THREADS", "4"))
        _engine = RapidOCR(params={
            "Global.max_side_len": 4100, "Global.log_level": "warning", "Global.use_cls": False,
            "EngineConfig.onnxruntime.intra_op_num_threads": threads,
            "Det.ocr_version": OCRVersion.PPOCRV5, "Det.model_type": ModelType.MOBILE, "Det.lang_type": LangDet.CH,
            "Rec.ocr_version": OCRVersion.PPOCRV5, "Rec.model_type": ModelType.MOBILE, "Rec.lang_type": LangRec.EN,
            "Rec.rec_batch_num": 1,  # much faster than batched on this onnxruntime build
        })
    return _engine


def variants_for(rel: str) -> list[tuple[str, float]]:
    setting, fn = rel.split("/")
    if setting in ("photo_FULL", "clean"):
        return [("native", 1.0)]
    if fn.startswith("pa-"):
        return [("up2", 2.0), ("native", 1.0)]
    return [("up2", 2.0)]


MAIN_VARIANT = {s: ("native" if s in ("photo_FULL", "clean") else "up2") for s in [x[0] for x in SETTINGS] + ["clean"]}


def cache_path(rel: str, variant: str) -> Path:
    return OCR / variant / (rel.replace(".jpg", ".json"))


def page_crop(entry: dict, info: dict) -> list[int]:
    """Bounding box of the page in the image plus a margin: [x0, y0, x1, y1]."""
    w, h = entry["size"]
    if entry["mode"] == "clean":
        return [0, 0, w, h]
    W, Hh = info["image_mm"]
    H = np.array(entry["H_page_to_img"])
    pts = np.array([[0, 0, 1], [W, 0, 1], [W, Hh, 1], [0, Hh, 1]], float) @ H.T
    pts = pts[:, :2] / pts[:, 2:3]
    mx, my = 0.04 * (pts[:, 0].max() - pts[:, 0].min()), 0.04 * (pts[:, 1].max() - pts[:, 1].min())
    x0, y0 = max(0, int(pts[:, 0].min() - mx)), max(0, int(pts[:, 1].min() - my))
    x1, y1 = min(w, int(pts[:, 0].max() + mx) + 1), min(h, int(pts[:, 1].max() + my) + 1)
    return [x0, y0, x1, y1]


def run_one(job):
    rel, variant, scale, crop = job
    out = cache_path(rel, variant)
    if out.exists():
        return rel, variant, "cached"
    img = cv2.imread(str(CAP / rel))
    img = img[crop[1]:crop[3], crop[0]:crop[2]]
    if scale != 1.0:
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    t = time.time()
    r = engine()(img)
    secs = time.time() - t
    boxes = [] if r.boxes is None else (np.asarray(r.boxes) / scale + np.array(crop[:2])).round(2).tolist()
    data = {"file": rel, "variant": variant, "scale": scale, "crop": crop, "secs": round(secs, 2),
            "boxes": boxes, "txts": list(r.txts or []), "scores": [round(float(s), 3) for s in (r.scores or [])]}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data), encoding="utf-8")
    return rel, variant, f"{secs:.1f}s {len(boxes)} boxes"


# ---------------------------------------------------------------- scoring
def inside(pt, rect):
    return rect[0] <= pt[0] <= rect[2] and rect[1] <= pt[1] <= rect[3]


def score_image(entry: dict, info: dict, ocr: dict) -> dict:
    H = np.array(entry["H_page_to_img"])
    Hinv = np.linalg.inv(H)
    region = entry["params"].get("region_mm") or [0, 0, *info["image_mm"]]
    lead = info["leading_pt"] * 25.4 / 72
    lines = info["lines"]
    body_idx = [i for i, ln in enumerate(lines) if inside(((ln["x0"] + ln["x1"]) / 2, (ln["y0"] + ln["y1"]) / 2), region)]
    body_set = set(body_idx)
    targets = [("body", i, ln) for i, ln in enumerate(lines)] + [("meta", i, m) for i, m in enumerate(info["meta"])]

    slots: dict[int, list] = defaultdict(list)
    extra: list = []
    meta_hits = 0
    for box, txt in zip(ocr["boxes"], ocr["txts"]):
        b = np.asarray(box)
        c = b.mean(axis=0)
        ph = Hinv @ np.array([c[0], c[1], 1.0])
        sx, sy = ph[0] / ph[2], ph[1] / ph[2]
        if entry["mode"] != "clean":
            sx, sy = curl_map(sx, sy, info)
            sx, sy = float(sx), float(sy)
        best, bd = None, 1e9
        for kind, i, t in targets:
            x0, y0, x1, y1 = (t["x0"], t["y0"], t["x1"], t["y1"]) if kind == "body" else t["box"]
            dx = max(0.0, x0 - sx, sx - x1)
            dy = abs(sy - (y0 + y1) / 2)
            d = dy + 2 * dx
            if d < bd:
                best, bd = (kind, i), d
        if best is None or bd > 0.9 * lead:
            if inside((sx, sy), region) and 0 <= sx <= info["image_mm"][0] and 0 <= sy <= info["image_mm"][1]:
                extra.append(txt)  # unexplained text on the page: counts as insertions
            continue
        kind, i = best
        if kind == "meta":
            meta_hits += 1
            continue
        if i in body_set:
            slots[i].append((sx, txt))
        # else: a body line outside the half-page target region; the app reads it next capture
    order = sorted(body_idx, key=lambda i: (lines[i]["col"], lines[i]["y0"]))
    ref = " ".join(lines[i]["text"] for i in order)
    hyp = " ".join(" ".join(t for _, t in sorted(slots[i])) for i in order if slots[i])
    if extra:
        hyp += " " + " ".join(extra)
    r = cer_wer(hyp, ref)
    r["lines_ref"] = len(order)
    r["lines_hit"] = sum(1 for i in order if slots[i])
    r["meta_boxes"] = meta_hits
    return r


def pooled(rows):
    ce = sum(r["char_edits"] for r in rows)
    rc = sum(r["ref_chars"] for r in rows)
    we = sum(r["word_edits"] for r in rows)
    rw = sum(r["ref_words"] for r in rows)
    return ce / max(1, rc), we / max(1, rw)


def fmt(v):
    return f"{100 * v:.1f}"


SUMMARY_START = "<!-- summary:start (hand-written, kept on rerun) -->"
SUMMARY_END = "<!-- summary:end -->"
ENGINE_DESC ="desktop proxy OCR (RapidOCR PP-OCRv5 mobile, English). Not ML Kit"


def write_results(rows: list[dict], chosen: dict = MAIN_VARIANT, out_name: str = "results.md",
                  engine_desc: str = ENGINE_DESC):
    by_sv = defaultdict(list)
    for r in rows:
        by_sv[(r["setting"], r["variant"])].append(r)
    main = [r for r in rows if chosen.get(r["setting"]) == r["variant"]]

    cell = defaultdict(list)
    for r in main:
        cell[(r["kind"], r["setting"], r["mode"])].append(r)
        cell[("all", r["setting"], r["mode"])].append(r)
    xh = defaultdict(list)
    for r in main:
        xh[(r["kind"], r["setting"], r["mode"])].append(r["x_height_px"])
        xh[("all", r["setting"], r["mode"])].append(r["x_height_px"])
    modes = list(MODES)

    L = []
    L.append("# Book reader resolution experiment: results")
    L.append("")
    L.append(f"Generated {time.strftime('%Y-%m-%d')} by `ocr_score.py`. Synthetic pages, simulated HSTN captures, "
             f"{engine_desc}, not real glasses. "
             "See README.md for every assumption.")
    L.append("")
    L.append("CER/WER are pooled over pages (total edits / total reference chars or words), in %. "
             "Body text only: running headers and page numbers are excluded from the reference and from the OCR output. "
             "Reading order is an oracle, so this measures recognition only.")
    L.append("")
    # keep the hand-written summary across reruns
    out_path = HERE / out_name
    old = out_path.read_text(encoding="utf-8") if out_path.exists() else ""
    if SUMMARY_START in old and SUMMARY_END in old:
        L.append(old[old.index(SUMMARY_START):old.index(SUMMARY_END) + len(SUMMARY_END)])
        L.append("")
    L.append("## Caveats")
    L.append("")
    L.extend([
        "- Synthetic pages and a simulated camera. The FOV (100° diagonal guess), crops, blur, noise and compression "
        "are assumptions (README.md > Assumptions). Pixel density per mm of page drives everything. A narrower real "
        "lens would shift every row toward better, so read across with the x-height table.",
        "- Proxy OCR, not ML Kit Text Recognition v2. The two will break down at different x-heights. Score the "
        "same images with ML Kit via `export_for_mlkit.py` before deciding.",
        "- Everything except FULL is upscaled 2x before OCR, and every image is cropped to the page first (oracle "
        "page detection). Layout is an oracle too, so real reading order, spread splitting and header removal "
        "will only add errors.",
        "- Stream HEVC is approximated by JPEG. Real streams over Bluetooth may also drop a resolution step "
        "(bandwidth ladder).",
        "- 17 page images, one pose per page and mode. Per-cell numbers rest on 2-7 pages, so treat differences "
        "of a point or two as noise.",
    ])
    L.append("")

    # ---- answer
    L.append("## Answer")
    L.append("")
    L.append(f"Smallest capture setting (by pixel count) with pooled body-text CER <= {THRESH:.0%}.")
    L.append("")
    by_px = sorted(SETTING_ORDER, key=lambda s: dict((n, w * h) for n, (w, h), _, _ in SETTINGS)[s])
    L.append("| Page type | " + " | ".join(modes) + " |")
    L.append("|---|" + "---|" * len(modes))
    answers = {}
    for kind in ["all"] + KINDS:
        cells = []
        for m in modes:
            ok = [s for s in by_px if cell.get((kind, s, m)) and pooled(cell[(kind, s, m)])[0] <= THRESH]
            if ok:
                s = ok[0]
                tag = "GA" if s in GA else "Exp."
                cells.append(f"{s} ({tag}, {fmt(pooled(cell[(kind, s, m)])[0])}%)")
            else:
                cells.append("none")
            answers[(kind, m)] = ok[0] if ok else None
        L.append(f"| {kind} | " + " | ".join(cells) + " |")
    L.append("")
    L.append("Modes: `full_35` / `full_45` = whole page (or spread) in frame, camera 35 / 45 cm from the page centre. "
             "`half_25` = head closer (25 cm), aimed at the top half of the page (left page of a spread); "
             "only lines in that half are scored.")
    L.append("")

    # ---- CER table
    for metric, idx in (("CER", 0), ("WER", 1)):
        L.append(f"## {metric} (%) by page type, setting and mode")
        L.append("")
        hdr = "| Setting | GA? | prep | " + " | ".join(f"{k} {m}" for m in modes for k in ["all"] + KINDS) + " |"
        L.append("| Setting | GA? | prep | " + " | ".join(
            f"{m}: all / pb / hb / sp / tb" for m in modes) + " |")
        L.append("|---|---|---|" + "---|" * len(modes))
        for s in SETTING_ORDER:
            parts = []
            for m in modes:
                vals = []
                for k in ["all"] + KINDS:
                    rr = cell.get((k, s, m))
                    vals.append(fmt(pooled(rr)[idx]) if rr else "-")
                parts.append(" / ".join(vals))
            L.append(f"| {s} | {'GA' if s in GA else 'Exp.'} | {chosen.get(s, '-')} | " + " | ".join(parts) + " |")
        cl = defaultdict(list)
        for r in main:
            if r["setting"] == "clean":
                cl[r["kind"]].append(r)
                cl["all"].append(r)
        if cl:
            vals = " / ".join(fmt(pooled(cl[k])[idx]) if cl.get(k) else "-" for k in ["all"] + KINDS)
            L.append(f"| clean flat render, 8 px/mm (engine ceiling) | - | native | {vals} | | |")
        L.append("")
        del hdr

    # ---- x-height table
    L.append("## Body x-height in the delivered image (px, median over pages)")
    L.append("")
    L.append("| Setting | " + " | ".join(f"{m}: pb / hb / sp / tb" for m in modes) + " |")
    L.append("|---|" + "---|" * len(modes))
    for s in SETTING_ORDER:
        parts = []
        for m in modes:
            parts.append(" / ".join(f"{np.median(xh[(k, s, m)]):.1f}" if xh.get((k, s, m)) else "-" for k in KINDS))
        L.append(f"| {s} | " + " | ".join(parts) + " |")
    L.append("")

    # ---- preprocessing comparison
    L.append("## Native vs 2x upscale before OCR (pooled CER %, paperback pages only)")
    L.append("")
    L.append("| Setting | " + " | ".join(f"{m} native / up2" for m in modes) + " |")
    L.append("|---|" + "---|" * len(modes))
    for s in SETTING_ORDER:
        parts = []
        for m in modes:
            a = [r for r in by_sv.get((s, "native"), []) if r["mode"] == m and r["kind"] == "paperback"]
            b = [r for r in by_sv.get((s, "up2"), []) if r["mode"] == m and r["kind"] == "paperback"]
            parts.append(f"{fmt(pooled(a)[0]) if a else '-'} / {fmt(pooled(b)[0]) if b else '-'}")
        L.append(f"| {s} | " + " | ".join(parts) + " |")
    L.append("")

    # ---- per-page spread at the answer settings
    L.append("## Pages over 2% CER at each mode's answer setting (all page types)")
    L.append("")
    for m in modes:
        s = answers.get(("all", m))
        if not s:
            L.append(f"- {m}: no setting reaches 2% pooled.")
            continue
        bad = sorted((r["cer"], r["page"]) for r in cell[("all", s, m)] if r["cer"] > THRESH)
        n = len(cell[("all", s, m)])
        L.append(f"- {m} @ {s}: {len(bad)}/{n} pages over 2%" + (": " + ", ".join(f"{p} {fmt(c)}%" for c, p in bad) if bad else ""))
    L.append("")
    (HERE / out_name).write_text("\n".join(L) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--score-only", action="store_true")
    ap.add_argument("--external", default="", help="dir of <flat image name>.json from another engine")
    ap.add_argument("--label", default="external")
    args = ap.parse_args()
    if args.external:
        return score_external(Path(args.external), args.label)
    manifest = json.loads((CAP / "manifest.json").read_text())
    infos = {}
    for e in manifest.values():
        if e["page"] not in infos:
            infos[e["page"]] = json.loads((GT / f"{e['page']}.json").read_text(encoding="utf-8"))
    jobs = [(rel, v, sc, page_crop(manifest[rel], infos[manifest[rel]["page"]]))
            for rel in sorted(manifest) for v, sc in variants_for(rel)]
    if not args.score_only:
        todo = [j for j in jobs if not cache_path(j[0], j[1]).exists()]
        print(f"OCR: {len(todo)} to run, {len(jobs) - len(todo)} cached")
        os.environ.setdefault("OCR_THREADS", str(max(1, (os.cpu_count() or 4) // args.workers)))
        with Pool(args.workers) as pool:
            for k, (rel, v, msg) in enumerate(pool.imap_unordered(run_one, todo), 1):
                print(f"[{k}/{len(todo)}] {rel} {v} {msg}", flush=True)

    rows = []
    for rel, v, _, _ in jobs:
        cp = cache_path(rel, v)
        if not cp.exists():
            continue
        e = manifest[rel]
        ocr = json.loads(cp.read_text(encoding="utf-8"))
        r = score_image(e, infos[e["page"]], ocr)
        r.update({"file": rel, "page": e["page"], "kind": e["kind"], "mode": e["mode"], "setting": e["setting"],
                  "variant": v, "x_height_px": e["x_height_px"], "ocr_secs": ocr["secs"]})
        rows.append(r)
    cols = ["file", "page", "kind", "mode", "setting", "variant", "x_height_px", "cer", "wer", "char_edits",
            "ref_chars", "word_edits", "ref_words", "lines_ref", "lines_hit", "meta_boxes", "ocr_secs"]
    with open(HERE / "out" / "scores.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({**r, "cer": round(r["cer"], 4), "wer": round(r["wer"], 4)})
    write_results(rows)
    print(f"scored {len(rows)} OCR results -> results.md, out/scores.csv")


def score_external(res_dir: Path, label: str):
    exp = res_dir.parent
    entries = json.loads((exp / "manifest.json").read_text(encoding="utf-8"))
    manifest = json.loads((CAP / "manifest.json").read_text())
    infos, rows, missing = {}, [], 0
    for row in entries:
        rp = res_dir / (row["image"] + ".json")
        if not rp.exists():
            missing += 1
            continue
        e = manifest[row["source"]]
        if e["page"] not in infos:
            infos[e["page"]] = json.loads((GT / f"{e['page']}.json").read_text(encoding="utf-8"))
        ocr = json.loads(rp.read_text(encoding="utf-8"))
        r = score_image(e, infos[e["page"]], ocr)
        r.update({"file": row["source"], "page": e["page"], "kind": e["kind"], "mode": e["mode"],
                  "setting": e["setting"], "variant": label, "x_height_px": e["x_height_px"],
                  "ocr_secs": ocr.get("secs", 0)})
        rows.append(r)
    chosen = {s: label for s in SETTING_ORDER + ["clean"]}
    write_results(rows, chosen, f"results_{label}.md", f"{label} OCR via export_for_mlkit.py")
    print(f"scored {len(rows)} images ({missing} without results) -> results_{label}.md")


if __name__ == "__main__":
    main()
