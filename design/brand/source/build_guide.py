import json, sys, re
from pathlib import Path
here = Path(sys.argv[0]).parent
B = Path(sys.argv[1]) / "design/brand"
P = json.loads((here / "paths.json").read_text())
tpl = (here / "guide.tpl.html").read_text(encoding="utf-8")

def lum(h):
    h = h.lstrip("#"); c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def cr(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True); return (la + 0.05) / (lb + 0.05)

MUTED = "#D4CEEC"
print("muted on night", round(cr(MUTED, "#0B0B1A"), 2), "on dusk", round(cr(MUTED, "#1E1A3D"), 2))

def mark(px, label=None):
    a = f'role="img" aria-label="{label}"' if label else 'aria-hidden="true" focusable="false"'
    return (f'<svg {a} width="{px}" height="{px}" viewBox="0 0 512 512" style="display:block">'
            f'<path fill="currentColor" fill-rule="evenodd" d="{P["mark"]}"/></svg>')

lock = P["lockup"].split("\n", 1)[1]  # drop xml header
lock = re.sub(r'<title id="t">SpeakUp</title>', "", lock)
def lockup(mark_fill, word_fill, label=True, extra=""):
    s = lock.replace("var(--mark)", mark_fill).replace("var(--word)", word_fill)
    s = s.replace('role="img" aria-labelledby="t"',
                  ('role="img" aria-label="SpeakUp"' if label else 'aria-hidden="true"') + f' class="lock" style="width:100%;height:auto;max-width:520px{extra}"')
    return s

icon = (B / "app-icon.svg").read_text(encoding="utf-8").split("\n", 1)[1]
def icon_at(px, rad, idn):
    s = icon.replace('width="1024" height="1024"', f'width="{px}" height="{px}" role="img" aria-label="SpeakUp app icon" style="border-radius:{rad}px"', 1)
    s = s.replace("<title>SpeakUp</title>", "")
    return s.replace('id="g"', f'id="g{idn}"').replace('url(#g)', f'url(#g{idn})').replace('id="h"', f'id="h{idn}"').replace('url(#h)', f'url(#h{idn})')

rows = [
    ("Paper", "Night", "#FFF8E7", "#0B0B1A", "Body text, dark mode"),
    ("Paper", "Dusk", "#FFF8E7", "#1E1A3D", "Body text on cards"),
    ("Muted " + MUTED, "Night", MUTED, "#0B0B1A", "Secondary text"),
    ("Muted " + MUTED, "Dusk", MUTED, "#1E1A3D", "Secondary text on cards"),
    ("Night", "Paper", "#0B0B1A", "#FFF8E7", "Body text, light mode"),
    ("Signal Yellow", "Night", "#FFD60A", "#0B0B1A", "Mark, links, focus ring"),
    ("Signal Yellow", "Dusk", "#FFD60A", "#1E1A3D", "Links on cards"),
    ("Night", "Signal Yellow", "#0B0B1A", "#FFD60A", "Primary button label"),
    ("Listen Cyan", "Night", "#3DD9EB", "#0B0B1A", "Listening label"),
    ("Listen Cyan", "Dusk", "#3DD9EB", "#1E1A3D", "Listening label on cards"),
    ("Night", "Listen Cyan", "#0B0B1A", "#3DD9EB", "Text on cyan fill"),
    ("Voice Coral", "Night", "#FF6B5B", "#0B0B1A", "Speaking and warning label"),
    ("Voice Coral", "Dusk", "#FF6B5B", "#1E1A3D", "Large text and icons only"),
    ("Night", "Voice Coral", "#0B0B1A", "#FF6B5B", "Text on coral fill"),
    ("Paper", "Dusk Line", "#FFF8E7", "#3A3470", "Text on selected rows"),
    ("Paper outline", "Night", "#FFF8E7", "#0B0B1A", "Control edge (needs 3:1)"),
    ("Dusk Line", "Night", "#3A3470", "#0B0B1A", "Decorative dividers only"),
    ("Dusk", "Night", "#1E1A3D", "#0B0B1A", "Card fill, not a boundary"),
    ("Signal Yellow", "Paper", "#FFD60A", "#FFF8E7", "Never"),
    ("Voice Coral", "Paper", "#FF6B5B", "#FFF8E7", "Never as text"),
    ("Listen Cyan", "Paper", "#3DD9EB", "#FFF8E7", "Never as text"),
]
out = []
results = {}
for fg_n, bg_n, fg, bg, use in rows:
    r = cr(fg, bg); results[f"{fg_n} on {bg_n}"] = round(r, 2)
    if r >= 7: pill = '<span class="pill aaa">AAA</span>'
    elif r >= 4.5: pill = '<span class="pill aa">AA</span>'
    elif r >= 3: pill = '<span class="pill ui">Large text or UI</span>'
    else: pill = '<span class="pill fail">Below 3:1</span>'
    # sample: show legible label regardless; swatch shows fg on bg
    if r < 4.5 and "outline" not in fg_n and fg_n not in ("Dusk Line", "Dusk"):
        sample = (f'<span class="sample" role="img" aria-label="Swatch: {fg_n} bar on {bg_n}" style="background:{bg};border:1px solid #3A3470;display:inline-flex;align-items:center;height:40px">'
                  f'<span style="display:block;width:100%;height:12px;border-radius:6px;background:{fg}"></span></span>')
    elif "outline" in fg_n or fg_n in ("Dusk Line", "Dusk"):
        sample = f'<span class="sample" style="background:{bg};color:#FFF8E7;border:3px solid {fg}">Edge</span>'
    else:
        sample = f'<span class="sample" style="background:{bg};color:{fg};border:1px solid #3A3470">Aa Bus 42</span>'
    out.append(f'<tr><td>{sample}</td><td>{fg_n} on {bg_n}</td><td class="n">{r:.2f}:1</td><td>{pill} {use}</td></tr>')

rep = {
    "{{MUTED}}": MUTED, "{{CONTRAST_ROWS}}": "\n".join(out),
    "{{LOCKUP_HERO}}": lockup("#FFD60A", "#FFF8E7"),
    "{{LOCKUP_DARK}}": lockup("#FFD60A", "#FFF8E7", label=False),
    "{{LOCKUP_MONO}}": lockup("currentColor", "currentColor", label=False),
    "{{MARK_LG}}": mark(200), "{{MARK_24}}": mark(24), "{{MARK_32}}": mark(32), "{{MARK_48}}": mark(48),
    "{{MARK_96}}": mark(96), "{{MARK_160}}": mark(160), "{{MARK_56}}": mark(56),
    "{{ICON_LG}}": icon_at(240, 54, "a"), "{{ICON_MD}}": icon_at(120, 27, "b"), "{{ICON_SM}}": icon_at(60, 14, "c"),
}
for k, v in rep.items(): tpl = tpl.replace(k, v)
assert "{{" not in tpl, re.findall(r"\{\{\w+\}\}", tpl)
(B / "brand-guide.html").write_text(tpl, encoding="utf-8", newline="\n")
(here / "contrast-final.json").write_text(json.dumps(results, indent=1))
for k, v in results.items(): print(f"{v:6.2f} {k}")
