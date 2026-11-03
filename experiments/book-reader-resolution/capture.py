"""Simulate HSTN head-worn captures of the rendered pages.

For each page and each viewing mode, build one 12 MP "sensor" image (page curved
toward the gutter, perspective, uneven light, blur, noise), then crop and resample
it to every DAT capture setting and JPEG-compress it.

Output:
  out/captures/<setting>/<page>__<mode>.jpg
  out/captures/clean/<page>.jpg          flat, undistorted render (OCR ceiling)
  out/captures/manifest.json             per image: geometry for scoring, all sim params

Every assumption here is listed in README.md > Assumptions.
Usage: python capture.py [--pages pa-01,te-02] [--modes full_35]
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
PAGES = HERE / "out" / "pages"
GT = HERE / "gt"
OUT = HERE / "out" / "captures"

# --- camera model (assumptions) ---------------------------------------------
SENSOR_W, SENSOR_H = 3024, 4032  # portrait, native 12 MP (FULL)
DIAG_FOV_DEG = 100.0  # ultra-wide guess for the full 4:3 sensor
FOCAL_PX = math.hypot(SENSOR_W, SENSOR_H) / 2 / math.tan(math.radians(DIAG_FOV_DEG / 2))

# name, output (w, h), JPEG quality, notes. All are centre crops of the sensor to
# the output aspect, then resampled (INTER_AREA).
SETTINGS = [
    ("stream_LOW", (360, 640), 50, "GA stream, 9:16, HEVC approximated by JPEG q50"),
    ("stream_MEDIUM", (504, 896), 50, "GA stream default"),
    ("stream_HIGH", (720, 1280), 55, "GA stream max"),
    ("instream_photo", (960, 1440), 80, "GA stream.capturePhoto(), size from the mock"),
    ("photo_SMALL", (480, 640), 85, "Experimental Camera.photo SMALL ~480p"),
    ("photo_MEDIUM", (720, 960), 85, "Experimental MEDIUM ~720p"),
    ("photo_LARGE", (1080, 1440), 85, "Experimental LARGE ~1080p"),
    ("photo_FULL", (3024, 4032), 85, "Experimental FULL 4032x3024"),
]

# mode: distance (mm, camera to aimed point), aim region
MODES = {
    "full_35": (350.0, "page"),
    "full_45": (450.0, "page"),
    "half_25": (250.0, "half"),
}

PAPER_RGB = np.array([226, 236, 243], np.float32) / 255.0  # BGR, off-white
TABLE_BGR = np.array([45, 62, 88], np.float32) / 255.0  # brown wood/desk
INK_DENSITY = 0.88


def rot(pitch, yaw, roll):
    p, y, r = map(math.radians, (pitch, yaw, roll))
    rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    ry = np.array([[math.cos(y), 0, math.sin(y)], [0, 1, 0], [-math.sin(y), 0, math.cos(y)]])
    rz = np.array([[math.cos(r), -math.sin(r), 0], [math.sin(r), math.cos(r), 0], [0, 0, 1]])
    return rz @ ry @ rx


def crop_box(w, h):
    """Centre crop of the sensor with the output aspect ratio: (x0, y0, cw, ch)."""
    if SENSOR_H * w / h <= SENSOR_W:
        ch, cw = SENSOR_H, SENSOR_H * w / h
    else:
        cw, ch = SENSOR_W, SENSOR_W * h / w
    return (SENSOR_W - cw) / 2, (SENSOR_H - ch) / 2, cw, ch


def homography(R, T, aim_mm):
    K = np.array([[FOCAL_PX, 0, SENSOR_W / 2], [0, FOCAL_PX, SENSOR_H / 2], [0, 0, 1]])
    t = T - R @ np.array([aim_mm[0], aim_mm[1], 0.0])
    return K @ np.column_stack([R[:, 0], R[:, 1], t])


def project(H, pts):
    pts = np.asarray(pts, np.float64)
    ph = np.c_[pts, np.ones(len(pts))] @ H.T
    return ph[:, :2] / ph[:, 2:3]


def local_scale(H, pt):
    """Isotropic px per mm of H at page point pt."""
    e = 0.5
    p = project(H, [pt, (pt[0] + e, pt[1]), (pt[0], pt[1] + e)])
    j = np.c_[(p[1] - p[0]) / e, (p[2] - p[0]) / e]
    return math.sqrt(abs(np.linalg.det(j)))


# --- page curvature toward the gutter ----------------------------------------
# Defined as a map from the *seen* (warped) page coords to the *printed* page coords,
# so cv2.remap can use it directly and scoring can map OCR boxes back with it.
CURL_BAND_FRAC = 0.22  # of page width
CURL_SQUEEZE = 0.12  # of band width hidden into the gutter
CURL_Y = 0.03  # vertical shrink at the gutter (makes lines bow)
CURL_LIFT = 0.008  # of page height, upward shift at the gutter


def curl_map(x, y, info):
    """Seen (x, y) in mm -> printed (x, y) in mm. Works on numpy arrays."""
    xs, ys = np.array(x, np.float64), np.array(y, np.float64)
    out_x, out_y = xs.copy(), ys.copy()
    H = info["image_mm"][1]
    for pg in info["pages"]:
        x0, _, x1, _ = pg["rect"]
        band = CURL_BAND_FRAC * (x1 - x0)
        gx, sgn = (x0, 1.0) if pg["gutter"] == "left" else (x1, -1.0)
        g = (xs - gx) * sgn
        inside = (xs >= x0) & (xs <= x1) & (g < band)
        t = np.where(inside, np.clip(1 - g / band, 0, 1) ** 2, 0.0)
        out_x = np.where(inside, gx + sgn * (g + CURL_SQUEEZE * band * t), out_x)
        out_y = np.where(inside, H / 2 + (ys - H / 2) * (1 + CURL_Y * t) + CURL_LIFT * H * t, out_y)
    return out_x, out_y


def gutter_shade(x, info, depth=0.35):
    shade = np.ones_like(x)
    for pg in info["pages"]:
        x0, _, x1, _ = pg["rect"]
        band = CURL_BAND_FRAC * (x1 - x0)
        gx, sgn = (x0, 1.0) if pg["gutter"] == "left" else (x1, -1.0)
        g = (x - gx) * sgn
        inside = (x >= x0) & (x <= x1) & (g < band)
        shade = np.where(inside, shade * (1 - depth * np.clip(1 - g / band, 0, 1) ** 3), shade)
    return shade


def make_seen_page(ink, info, scale_px_mm, rng):
    """Reflectance of the curved page at scale_px_mm (float32, 0..1)."""
    W_mm, H_mm = info["image_mm"]
    src_ppm = info["px_per_mm"]
    w, h = int(W_mm * scale_px_mm), int(H_mm * scale_px_mm)
    # anti-alias the 12 px/mm render down to the working scale first
    small = cv2.resize(ink, (w, h), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    xs = (np.arange(w, dtype=np.float32) + 0.5) / scale_px_mm
    ys = (np.arange(h, dtype=np.float32) + 0.5) / scale_px_mm
    X, Y = np.meshgrid(xs, ys)
    sx, sy = curl_map(X, Y, info)
    mapx = (sx * scale_px_mm - 0.5).astype(np.float32)
    mapy = (sy * scale_px_mm - 0.5).astype(np.float32)
    seen = cv2.remap(small, mapx, mapy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=1.0)
    # paper texture: low-frequency mottling + fibre noise
    mott = cv2.resize(rng.normal(0, 1, (max(2, h // 80), max(2, w // 80))).astype(np.float32), (w, h),
                      interpolation=cv2.INTER_CUBIC)
    paper = 1.0 + 0.015 * mott + 0.01 * rng.normal(0, 1, (h, w)).astype(np.float32)
    refl = paper * (1 - INK_DENSITY * (1 - seen)) * gutter_shade(X, info).astype(np.float32)
    return refl.astype(np.float32), src_ppm


def motion_kernel(length, angle_deg):
    n = max(3, int(math.ceil(length)) | 1)
    k = np.zeros((n, n), np.float32)
    c = n // 2
    dx, dy = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
    for s in np.linspace(-length / 2, length / 2, 4 * n):
        k[int(round(c + s * dy)), int(round(c + s * dx))] += 1
    return k / k.sum()


def unsharp(img, sigma=1.0, amount=0.35):
    blur = cv2.GaussianBlur(img, (0, 0), sigma)
    return cv2.addWeighted(img, 1 + amount, blur, -amount, 0)


def simulate(pid, mode, info, ink, rng):
    dist, aim_kind = MODES[mode]
    W_mm, H_mm = info["image_mm"]
    if aim_kind == "page":
        region = [0.0, 0.0, W_mm, H_mm]
    else:
        region = info["half_region"]
    aim = ((region[0] + region[2]) / 2, (region[1] + region[3]) / 2)

    pitch = -rng.uniform(8, 18)  # negative = top of page farther away (looking down at a book)
    yaw = rng.uniform(-6, 6)
    roll = rng.uniform(-4, 4)
    R = rot(pitch, yaw, roll)
    # camera sits on the left temple, so the book shows up right of centre
    sx0, sy0, scw, sch = crop_box(*SETTINGS[0][1])  # narrowest crop (9:16 stream)
    off_x = rng.uniform(0.02, 0.07) * scw
    off_y = rng.uniform(-0.04, 0.04) * sch
    fit = None
    for shrink in (1.0, 0.6, 0.3, 0.0):
        T = np.array([off_x * shrink / FOCAL_PX * dist, off_y * shrink / FOCAL_PX * dist, dist])
        Hs = homography(R, T, aim)
        corners = project(Hs, [(region[0], region[1]), (region[2], region[1]), (region[2], region[3]),
                               (region[0], region[3])])
        m = 0.02 * scw
        if (corners[:, 0].min() > sx0 + m and corners[:, 0].max() < sx0 + scw - m
                and corners[:, 1].min() > sy0 + m and corners[:, 1].max() < sy0 + sch - m):
            fit = shrink
            break
    if fit is None:
        print(f"  WARNING {pid} {mode}: aim region not fully inside the 9:16 stream crop")
        fit = 0.0

    # render the curved page at ~1.3x the finest sensor sampling, then warp to the sensor
    all_c = project(Hs, [(0, 0), (W_mm, 0), (W_mm, H_mm), (0, H_mm)])
    ppm_max = max(local_scale(Hs, p) for p in [(0, 0), (W_mm, 0), (W_mm, H_mm), (0, H_mm)])
    work_ppm = min(info["px_per_mm"], 1.3 * ppm_max)
    refl, _ = make_seen_page(ink, info, work_ppm, rng)
    S = np.diag([1 / work_ppm, 1 / work_ppm, 1.0])
    S[0, 2] = S[1, 2] = 0.5 / work_ppm
    Hw = Hs @ S
    page = cv2.warpPerspective(refl, Hw, (SENSOR_W, SENSOR_H), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    mask = cv2.warpPerspective(np.ones_like(refl), Hw, (SENSOR_W, SENSOR_H), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    paper_tint = PAPER_RGB * rng.uniform(0.97, 1.03, 3).astype(np.float32)
    img = page[..., None] * paper_tint[None, None, :]
    table = TABLE_BGR[None, None, :] * (1 + 0.08 * cv2.resize(
        rng.normal(0, 1, (40, 30)).astype(np.float32), (SENSOR_W, SENSOR_H))[..., None])
    img = img * mask[..., None] + table * (1 - mask[..., None])

    # uneven light: lamp gradient + lens vignetting
    yy, xx = np.mgrid[0:SENSOR_H, 0:SENSOR_W].astype(np.float32)
    xn, yn = (xx - SENSOR_W / 2) / (SENSOR_W / 2), (yy - SENSOR_H / 2) / (SENSOR_H / 2)
    ang = rng.uniform(0, 2 * math.pi)
    grad_strength = rng.uniform(0.15, 0.35)
    lamp = 1 - grad_strength * (0.5 + 0.5 * (xn * math.cos(ang) + yn * math.sin(ang)) / math.sqrt(2))
    r2 = (xn ** 2 + yn ** 2) / 2
    vign = 1 - 0.35 * r2
    exposure = rng.uniform(0.85, 0.95)
    img = img * (lamp * vign * exposure)[..., None]
    del xx, yy, xn, yn, lamp, vign, r2

    # optics: lens softness + defocus (fixed focus, sharper further out) + head motion
    defocus = max(0.0, (450 - dist) / 100) * 0.75
    sigma = math.hypot(1.1, defocus)
    img = cv2.GaussianBlur(img, (0, 0), sigma)
    mlen = rng.uniform(0, 5)
    mang = rng.uniform(0, 180)
    if mlen >= 1:
        img = cv2.filter2D(img, -1, motion_kernel(mlen, mang))
    # sensor noise (shot + read), at native resolution
    img = np.clip(img, 0, 1)
    noise_sigma = np.sqrt(0.0003 * img + 0.00005)
    img = img + noise_sigma * rng.normal(0, 1, img.shape).astype(np.float32)
    img = np.clip(img, 0, 1)

    params = {
        "distance_mm": dist, "aim": aim_kind, "aim_mm": list(aim), "region_mm": region,
        "pitch_deg": round(pitch, 2), "yaw_deg": round(yaw, 2), "roll_deg": round(roll, 2),
        "offset_px_sensor": [round(off_x * fit, 1), round(off_y * fit, 1)],
        "blur_sigma_px_sensor": round(sigma, 2), "motion_px_sensor": round(mlen, 2),
        "motion_angle_deg": round(mang, 1), "light_gradient": round(grad_strength, 3),
        "exposure": round(exposure, 3), "page_corners_sensor": all_c.round(1).tolist(),
    }
    return img, Hs, params


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", default="")
    ap.add_argument("--modes", default=",".join(MODES))
    ap.add_argument("--seed", type=int, default=20261027)
    args = ap.parse_args()
    pids = [p for p in (GT / "index.txt").read_text().split() if not args.pages or p in args.pages.split(",")]
    modes = args.modes.split(",")
    OUT.mkdir(parents=True, exist_ok=True)
    man_path = OUT / "manifest.json"
    manifest = json.loads(man_path.read_text()) if man_path.exists() else {}

    for pid in pids:
        info = json.loads((GT / f"{pid}.json").read_text(encoding="utf-8"))
        ink = cv2.imread(str(PAGES / f"{pid}.png"), cv2.IMREAD_GRAYSCALE)
        # clean baseline: flat page at 8 px/mm (~200 dpi), no distortion
        cppm = 8.0
        W_mm, H_mm = info["image_mm"]
        flat = cv2.resize(ink, (int(W_mm * cppm), int(H_mm * cppm)), interpolation=cv2.INTER_AREA)
        flat = (PAPER_RGB[None, None, :] * (1 - INK_DENSITY * (1 - flat[..., None] / 255.0)) * 255).astype(np.uint8)
        (OUT / "clean").mkdir(exist_ok=True)
        cv2.imwrite(str(OUT / "clean" / f"{pid}.jpg"), flat, [cv2.IMWRITE_JPEG_QUALITY, 95])
        Hc = np.diag([cppm, cppm, 1.0])
        manifest[f"clean/{pid}.jpg"] = {
            "page": pid, "kind": info["kind"], "mode": "clean", "setting": "clean", "size": [flat.shape[1], flat.shape[0]],
            "H_page_to_img": Hc.tolist(), "x_height_px": round(info["x_height_mm"] * cppm, 2), "params": {}}

        for mode in modes:
            rng = np.random.default_rng([args.seed, sum(map(ord, pid)), list(MODES).index(mode)])
            img, Hs, params = simulate(pid, mode, info, ink, rng)
            xh_sensor = info["x_height_mm"] * local_scale(Hs, params["aim_mm"])
            for name, (w, h), q, _ in SETTINGS:
                x0, y0, cw, ch = crop_box(w, h)
                crop = img[int(round(y0)):int(round(y0 + ch)), int(round(x0)):int(round(x0 + cw))]
                out = cv2.resize(crop, (w, h), interpolation=cv2.INTER_AREA) if (w, h) != crop.shape[1::-1] else crop
                out = np.clip(unsharp(out), 0, 1)
                out8 = (out * 255 + 0.5).astype(np.uint8)
                d = OUT / name
                d.mkdir(exist_ok=True)
                fn = f"{pid}__{mode}.jpg"
                cv2.imwrite(str(d / fn), out8, [cv2.IMWRITE_JPEG_QUALITY, q])
                s = w / cw
                A = np.array([[s, 0, -x0 * s], [0, s, -y0 * s], [0, 0, 1]])
                manifest[f"{name}/{fn}"] = {
                    "page": pid, "kind": info["kind"], "mode": mode, "setting": name, "size": [w, h],
                    "jpeg_quality": q, "H_page_to_img": (A @ Hs).tolist(),
                    "x_height_px": round(xh_sensor * s, 2), "params": params}
            print(f"{pid} {mode}: x-height {xh_sensor:.1f} px at FULL, blur {params['blur_sigma_px_sensor']}, "
                  f"motion {params['motion_px_sensor']}")
            del img
        man_path.write_text(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
