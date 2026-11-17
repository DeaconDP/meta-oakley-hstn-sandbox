"""SpeakUp brand asset generator. Usage: python -I gen.py <repo_root>"""
import math, sys, json, os
from pathlib import Path

ROOT = Path(sys.argv[1])
BRAND = ROOT / "design" / "brand"
RES = ROOT / "tracks/android-native/HstnBench/app/src/main/res"

NIGHT, DUSK, DUSKLINE = "#0B0B1A", "#1E1A3D", "#3A3470"
YELLOW, PAPER, CORAL, CYAN = "#FFD60A", "#FFF8E7", "#FF6B5B", "#3DD9EB"

def f(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s

# ---------------------------------------------------------------- mark geometry (512 grid)
# Pill-shaped speech bubble. Its right end is a semicircle; the three sound arcs are
# concentric with it, so the bubble itself reads as the first ripple.
CY = 252                      # vertical centre line of bubble
R = 94                        # bubble half height
BX0, BX1 = 16, 312            # bubble extent
LC = (BX0 + R, CY)            # left semicircle centre
RC = (BX1 - R, CY)            # right semicircle centre (arc centre)

def bubble():
    lx, ly = LC; rx, ry = RC
    top, bot = CY - R, CY + R
    # join point on left semicircle at 128 deg (bottom-left)
    a = math.radians(150)
    jx, jy = lx + R * math.cos(a), ly + R * math.sin(a)
    tip = (24, bot + 60)
    return (f"M{f(lx)} {f(top)}H{f(rx)}A{R} {R} 0 0 1 {f(rx)} {f(bot)}"
            f"H{f(lx + 40)}C{f(lx + 4)} {f(bot)} {f(tip[0] + 40)} {f(bot + 34)} {f(tip[0] + 10)} {f(tip[1] - 2)}"
            f"C{f(tip[0] + 2)} {f(tip[1] + 3)} {f(tip[0] - 6)} {f(tip[1] - 2)} {f(tip[0] - 3)} {f(tip[1] - 10)}"
            f"C{f(tip[0] + 6)} {f(bot + 26)} {f(jx - 2)} {f(jy + 24)} {f(jx)} {f(jy)}"
            f"A{R} {R} 0 0 1 {f(lx)} {f(top)}Z")

def lens(x0, y0, w, h, rt, rb):
    x1, y1 = x0 + w, y0 + h
    return (f"M{f(x0 + rt)} {f(y0)}H{f(x1 - rt)}A{rt} {rt} 0 0 1 {f(x1)} {f(y0 + rt)}"
            f"V{f(y1 - rb)}A{rb} {rb} 0 0 1 {f(x1 - rb)} {f(y1)}H{f(x0 + rb)}"
            f"A{rb} {rb} 0 0 1 {f(x0)} {f(y1 - rb)}V{f(y0 + rt)}A{rt} {rt} 0 0 1 {f(x0 + rt)} {f(y0)}Z")

LW, LH, BRIDGE = 96, 100, 36
lens_y = CY - LH / 2 - 4
inner = (BX1 - BX0)
lx0 = BX0 + (inner - 2 * LW - BRIDGE) / 2
LENSES = [lens(lx0, lens_y, LW, LH, 24, 40), lens(lx0 + LW + BRIDGE, lens_y, LW, LH, 24, 40)]

SW = 34           # arc stroke width
GAP = 26
def arc(rc, half_deg):
    cx, cy = RC; w = SW / 2
    a0, a1 = math.radians(-half_deg), math.radians(half_deg)
    P = lambda r, a: (cx + r * math.cos(a), cy + r * math.sin(a))
    o0, o1 = P(rc + w, a0), P(rc + w, a1)
    i1, i0 = P(rc - w, a1), P(rc - w, a0)
    ro, ri = rc + w, rc - w
    return (f"M{f(o0[0])} {f(o0[1])}A{f(ro)} {f(ro)} 0 0 1 {f(o1[0])} {f(o1[1])}"
            f"A{f(w)} {f(w)} 0 0 1 {f(i1[0])} {f(i1[1])}"
            f"A{f(ri)} {f(ri)} 0 0 0 {f(i0[0])} {f(i0[1])}"
            f"A{f(w)} {f(w)} 0 0 1 {f(o0[0])} {f(o0[1])}Z")

r1 = R + GAP + SW / 2
ARCS = [arc(r1, 46), arc(r1 + SW + GAP, 42), arc(r1 + 2 * (SW + GAP), 38)]

BODY = bubble() + "".join(LENSES)          # evenodd: lenses are holes
ARC_D = "".join(ARCS)
MARK_D = BODY + ARC_D                      # arcs don't overlap the body, evenodd safe
print("outer arc reach x =", RC[0] + r1 + 2 * (SW + GAP) + SW / 2)

# ---------------------------------------------------------------- wordmark outlines
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

def outline(text, ttf):
    blob = hb.Blob.from_file_path(str(ttf))
    face = hb.Face(blob); font = hb.Font(face)
    buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
    hb.shape(font, buf, {"kern": True, "liga": True})
    tt = TTFont(str(ttf)); gs = tt.getGlyphSet(); order = tt.getGlyphOrder()
    upm = tt["head"].unitsPerEm
    pen = SVGPathPen(gs, ntos=lambda v: f(v))
    bp = BoundsPen(gs)
    x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        name = order[info.codepoint]
        t = (1, 0, 0, -1, x + pos.x_offset, pos.y_offset)
        gs[name].draw(TransformPen(pen, t)); gs[name].draw(TransformPen(bp, t))
        x += pos.x_advance
    xmin, ymin, xmax, ymax = bp.bounds   # y already flipped
    cap = tt["OS/2"].sCapHeight
    return pen.getCommands(), (xmin, ymin, xmax, ymax), upm, cap, x

BOLD = BRAND / "fonts/AtkinsonHyperlegible-Bold.ttf"
WD, (wx0, wy0, wx1, wy1), UPM, CAP, ADV = outline("SpeakUp", BOLD)
print("wordmark bounds", wx0, wy0, wx1, wy1, "cap", CAP)

HDR = '<?xml version="1.0" encoding="UTF-8"?>\n'

def write(p, s):
    p.parent.mkdir(parents=True, exist_ok=True); p.write_text(s, encoding="utf-8", newline="\n"); print("wrote", p)

# mark: crop viewBox to content with even padding
MVB = "0 0 512 512"
write(BRAND / "speakup-mark.svg", HDR +
      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{MVB}" role="img" aria-labelledby="t">'
      f'<title id="t">SpeakUp</title>'
      f'<path fill="currentColor" fill-rule="evenodd" d="{MARK_D}"/></svg>\n')

pad = 8
wvb = f"{f(wx0 - pad)} {f(wy0 - pad)} {f(wx1 - wx0 + 2 * pad)} {f(wy1 - wy0 + 2 * pad)}"
write(BRAND / "speakup-wordmark.svg", HDR +
      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{wvb}" role="img" aria-labelledby="t">'
      f'<title id="t">SpeakUp</title><path fill="currentColor" d="{WD}"/></svg>\n')

# lockup: mark content box approx x 26..498, y ~70..430 ; wordmark cap height = 0.52 * mark height
mark_box = (20, 60, 500, 440)          # generous crop of the mark in 512 grid
mh = mark_box[3] - mark_box[1]
scale_w = (mh * 0.50) / CAP             # cap height = half the mark box height
gapx = 70
tx = mark_box[2] + gapx - wx0 * scale_w
ty = mark_box[1] + mh / 2 + (CAP * scale_w) / 2   # baseline so caps are centred on mark
lw = tx + wx1 * scale_w + 20
def lockup(mark_fill, word_fill):
    return (HDR + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{mark_box[0]} {mark_box[1]} {f(lw - mark_box[0])} {mh}" role="img" aria-labelledby="t">'
            f'<title id="t">SpeakUp</title>'
            f'<path fill="{mark_fill}" fill-rule="evenodd" d="{MARK_D}"/>'
            f'<path fill="{word_fill}" transform="translate({f(tx)} {f(ty)}) scale({scale_w:.5f})" d="{WD}"/></svg>\n')
write(BRAND / "speakup-lockup.svg", lockup(YELLOW, PAPER))
write(BRAND / "speakup-lockup-mono.svg", lockup("currentColor", "currentColor"))

# ---------------------------------------------------------------- app icon (1024)
# Mark centred optically on its bubble+arc mass; scale so it spans ~64% of the width.
mx0, mx1, my0, my1 = 16, 498, 70, 440
mcx, mcy = (mx0 + mx1) / 2, (my0 + my1) / 2
S_ICON = 1024 * 0.64 / (mx1 - mx0)
def icon_svg(size=1024):
    k = size / 1024
    return (HDR + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}">'
            f'<title>SpeakUp</title><defs>'
            f'<radialGradient id="g" cx=".5" cy=".44" r=".62">'
            f'<stop offset="0" stop-color="#2A2456"/><stop offset=".55" stop-color="#16132F"/><stop offset="1" stop-color="{NIGHT}"/></radialGradient>'
            f'<radialGradient id="h" cx=".5" cy=".5" r=".5">'
            f'<stop offset="0" stop-color="{YELLOW}" stop-opacity=".09"/><stop offset="1" stop-color="{YELLOW}" stop-opacity="0"/></radialGradient>'
            f'</defs><rect width="1024" height="1024" fill="url(#g)"/>'
            f'<circle cx="512" cy="512" r="400" fill="url(#h)"/>'
            f'<g transform="translate(512 512) scale({S_ICON:.5f}) translate({f(-mcx)} {f(-mcy)})">'
            f'<path fill="#000" fill-opacity=".35" fill-rule="evenodd" transform="translate(0 10)" d="{MARK_D}"/>'
            f'<path fill="{YELLOW}" fill-rule="evenodd" d="{MARK_D}"/></g></svg>\n')
write(BRAND / "app-icon.svg", icon_svg())

# ---------------------------------------------------------------- Android vectors
# Adaptive canvas 108dp; 66dp safe circle (r=33). Fit the mark's farthest point inside r=30.
pts_r = []
def farthest():
    # sample critical extremities of the mark relative to (mcx, mcy)
    cands = [(BX0, CY), (24, CY + R + 60)]
    rr = r1 + 2 * (SW + GAP) + SW / 2
    for d in range(-38, 39, 2):
        a = math.radians(d); cands.append((RC[0] + rr * math.cos(a), RC[1] + rr * math.sin(a)))
    return max(math.hypot(x - mcx, y - mcy) for x, y in cands)
FR = farthest()
S_AD = 30.5 / FR
print("farthest", FR, "adaptive scale", S_AD, "-> mark width dp", (mx1 - mx0) * S_AD)
AX = 54 - mcx * S_AD; AY = 54 - mcy * S_AD
ANS = 'xmlns:android="http://schemas.android.com/apk/res/android"'

def vec_group(fill):
    return (f'    <group android:translateX="{AX:.3f}" android:translateY="{AY:.3f}"\n'
            f'        android:scaleX="{S_AD:.5f}" android:scaleY="{S_AD:.5f}">\n'
            f'        <path android:fillColor="{fill}" android:fillType="evenOdd"\n'
            f'            android:pathData="{MARK_D}" />\n    </group>\n')

write(RES / "drawable/ic_launcher_foreground_speakup.xml", HDR.replace("UTF-8", "utf-8") +
      '<!-- SpeakUp "speaking lens" mark in Signal Yellow. 108dp adaptive canvas, kept inside the 66dp safe zone.\n'
      '     Generated from design/brand (see design/brand/README.md). -->\n'
      f'<vector {ANS}\n    android:width="108dp" android:height="108dp"\n    android:viewportWidth="108" android:viewportHeight="108">\n'
      + vec_group("#FFFFD60A") + '</vector>\n')
write(RES / "drawable/ic_launcher_monochrome_speakup.xml", HDR.replace("UTF-8", "utf-8") +
      '<!-- Themed-icon (Android 13+) layer: same mark, single colour; the launcher tints it. -->\n'
      f'<vector {ANS}\n    android:width="108dp" android:height="108dp"\n    android:viewportWidth="108" android:viewportHeight="108">\n'
      + vec_group("#FFFFFFFF") + '</vector>\n')
write(RES / "drawable/ic_launcher_background_speakup.xml", HDR.replace("UTF-8", "utf-8") +
      '<!-- Night background with a soft violet radial glow behind the mark. -->\n'
      f'<vector {ANS}\n    xmlns:aapt="http://schemas.android.com/aapt"\n'
      '    android:width="108dp" android:height="108dp"\n    android:viewportWidth="108" android:viewportHeight="108">\n'
      '    <path android:pathData="M0,0h108v108h-108z" android:fillColor="#FF0B0B1A" />\n'
      '    <path android:pathData="M0,0h108v108h-108z">\n        <aapt:attr name="android:fillColor">\n'
      '            <gradient android:type="radial" android:centerX="54" android:centerY="50" android:gradientRadius="58">\n'
      '                <item android:offset="0" android:color="#FF2A2456" />\n'
      '                <item android:offset="0.55" android:color="#FF16132F" />\n'
      '                <item android:offset="1" android:color="#FF0B0B1A" />\n'
      '            </gradient>\n        </aapt:attr>\n    </path>\n</vector>\n')
write(RES / "drawable/speakup_mark.xml", HDR.replace("UTF-8", "utf-8") +
      '<!-- SpeakUp mark for in-app use. White fill so the caller can tint it\n'
      '     (Compose Icon tint / ImageView app:tint). Use Signal Yellow #FFD60A on Night by default. -->\n'
      f'<vector {ANS}\n    android:width="24dp" android:height="24dp"\n    android:viewportWidth="512" android:viewportHeight="512">\n'
      f'    <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd"\n        android:pathData="{MARK_D}" />\n</vector>\n')
write(RES / "mipmap-anydpi-v26/ic_launcher.xml", HDR.replace("UTF-8", "utf-8") +
      f'<adaptive-icon {ANS}>\n'
      '    <background android:drawable="@drawable/ic_launcher_background_speakup" />\n'
      '    <foreground android:drawable="@drawable/ic_launcher_foreground_speakup" />\n'
      '    <monochrome android:drawable="@drawable/ic_launcher_monochrome_speakup" />\n'
      '</adaptive-icon>\n')

# ---------------------------------------------------------------- renders
import resvg_py
from PIL import Image
import io
def render(svg_text, out, size):
    png = resvg_py.svg_to_bytes(svg_string=svg_text, width=size, height=size)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_bytes(bytes(png)); print("rendered", out)
render(icon_svg(), BRAND / "app-icon-1024.png", 1024)
# legacy launcher: rounded-square variant (only used if adaptive icons unavailable; minSdk 31 always uses adaptive)
render(icon_svg(), RES / "mipmap-xxxhdpi/ic_launcher.png", 192)

# ---------------------------------------------------------------- contrast
def lum(h):
    h = h.lstrip("#"); c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def cr(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True); return (la + 0.05) / (lb + 0.05)
pairs = {
    "Paper on Night": (PAPER, NIGHT), "Paper on Dusk": (PAPER, DUSK),
    "Signal Yellow on Night": (YELLOW, NIGHT), "Signal Yellow on Dusk": (YELLOW, DUSK),
    "Night on Signal Yellow": (NIGHT, YELLOW), "Listen Cyan on Night": (CYAN, NIGHT),
    "Listen Cyan on Dusk": (CYAN, DUSK), "Voice Coral on Night": (CORAL, NIGHT),
    "Voice Coral on Dusk": (CORAL, DUSK), "Night on Voice Coral": (NIGHT, CORAL),
    "Night on Listen Cyan": (NIGHT, CYAN), "Night on Paper (light mode)": (NIGHT, PAPER),
    "Dusk on Paper (light mode)": (DUSK, PAPER), "Dusk Line on Night (outline)": (DUSKLINE, NIGHT),
    "Dusk Line on Dusk (outline)": (DUSKLINE, DUSK), "Dusk on Night (card edge)": (DUSK, NIGHT),
    "Paper on Dusk Line": (PAPER, DUSKLINE),
    "Signal Yellow on Paper (never)": (YELLOW, PAPER), "Voice Coral on Paper (never for text)": (CORAL, PAPER),
    "Listen Cyan on Paper (never for text)": (CYAN, PAPER),
}
res = {k: round(cr(*v), 2) for k, v in pairs.items()}
for k, v in res.items(): print(f"{v:6.2f}  {k}")
Path(sys.argv[0]).with_name("contrast.json").write_text(json.dumps(res, indent=1))
Path(sys.argv[0]).with_name("paths.json").write_text(json.dumps({"mark": MARK_D, "body": BODY, "arcs": ARCS, "word": WD,
    "wvb": wvb, "lockup": lockup("var(--mark)", "var(--word)")}, indent=1))
