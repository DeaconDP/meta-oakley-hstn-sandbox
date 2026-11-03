"""Copy the simulated captures into one flat folder for scoring with ML Kit on Android.

Output (default out/mlkit_export/):
  <setting>__<page>__<mode>.jpg   the capture, byte-identical to out/captures/
  ref__<page>__<mode>.txt         reference body text for that image: only the lines that
                                  are scored (all body lines, or the top half for half_25),
                                  in reading order, one printed line per line
  gt__<page>.json                 full layout ground truth (line boxes in mm, headers, page numbers)
  manifest.json / manifest.csv    image -> page, kind, setting, mode, size, GA flag, ref file,
                                  gt file, H_page_to_img (page mm -> image px)
  results/                        empty; put ML Kit output here (format below)

Expected ML Kit output, one file per image: results/<image filename>.json
  {"boxes": [[[x, y], [x, y], [x, y], [x, y]], ...],   # Text.Line.cornerPoints, image px
   "txts":  ["line text", ...]}                         # Text.Line.text, same order
Use lines, not blocks or elements. Then score on the desktop with the same oracle
layout as the proxy run:
  python ocr_score.py --external out/mlkit_export/results --label mlkit
which writes results_mlkit.md.

Usage: python export_for_mlkit.py [--out DIR] [--settings stream_HIGH,photo_FULL] [--no-clean]
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAP = HERE / "out" / "captures"
GT = HERE / "gt"
GA = {"stream_LOW", "stream_MEDIUM", "stream_HIGH", "instream_photo"}


def flat_name(rel: str) -> str:
    setting, fn = rel.split("/")
    stem = fn[:-4]
    if setting == "clean":
        return f"clean__{stem}__clean.jpg"
    page, mode = stem.split("__")
    return f"{setting}__{page}__{mode}.jpg"


def ref_lines(info: dict, region: list[float]) -> list[str]:
    def inside(ln):
        cx, cy = (ln["x0"] + ln["x1"]) / 2, (ln["y0"] + ln["y1"]) / 2
        return region[0] <= cx <= region[2] and region[1] <= cy <= region[3]
    lines = [ln for ln in info["lines"] if inside(ln)]
    return [ln["text"] for ln in sorted(lines, key=lambda ln: (ln["col"], ln["y0"]))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "out" / "mlkit_export"))
    ap.add_argument("--settings", default="")
    ap.add_argument("--no-clean", action="store_true")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "results").mkdir(exist_ok=True)
    manifest = json.loads((CAP / "manifest.json").read_text())
    want = set(filter(None, args.settings.split(",")))

    rows = []
    infos = {}
    for rel in sorted(manifest):
        e = manifest[rel]
        if want and e["setting"] not in want:
            continue
        if args.no_clean and e["setting"] == "clean":
            continue
        pid = e["page"]
        if pid not in infos:
            infos[pid] = json.loads((GT / f"{pid}.json").read_text(encoding="utf-8"))
            shutil.copyfile(GT / f"{pid}.json", out / f"gt__{pid}.json")
        info = infos[pid]
        region = e["params"].get("region_mm") or [0, 0, *info["image_mm"]]
        ref_name = f"ref__{pid}__{e['mode']}.txt"
        if not (out / ref_name).exists():
            (out / ref_name).write_text("\n".join(ref_lines(info, region)) + "\n", encoding="utf-8")
        img = flat_name(rel)
        shutil.copyfile(CAP / rel, out / img)
        rows.append({
            "image": img, "source": rel, "page": pid, "kind": e["kind"], "setting": e["setting"],
            "mode": e["mode"], "width": e["size"][0], "height": e["size"][1],
            "ga": e["setting"] in GA, "x_height_px": e["x_height_px"], "ref": ref_name,
            "gt": f"gt__{pid}.json", "region_mm": region, "H_page_to_img": e["H_page_to_img"],
        })
    (out / "manifest.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")
    with open(out / "manifest.csv", "w", newline="", encoding="utf-8") as f:
        cols = ["image", "page", "kind", "setting", "mode", "width", "height", "ga", "x_height_px", "ref", "gt"]
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    (out / "README.txt").write_text(__doc__, encoding="utf-8")
    print(f"{len(rows)} images -> {out}")


if __name__ == "__main__":
    main()
