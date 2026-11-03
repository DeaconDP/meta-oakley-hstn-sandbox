"""Lay out and render synthetic book pages, and write per-page ground truth.

Output:
  out/pages/<id>.png   grayscale ink render at PX_PER_MM (white = no ink)
  gt/<id>.body.txt     body lines as printed (line-end hyphens kept), one per line
  gt/<id>.rejoined.txt body with line-end hyphenation undone, one paragraph per line
  gt/<id>.meta.txt     running header(s) and page number(s), one per line
  gt/<id>.json         geometry: page rects, line boxes (mm), columns, half-page region

Usage: python layout.py
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from passages import BOOK_FLOWS, CHAPTERS

HERE = Path(__file__).resolve().parent
OUT_PAGES = HERE / "out" / "pages"
GT_DIR = HERE / "gt"
FONT_DIR = Path(r"C:\Windows\Fonts")

PX_PER_MM = 12.0  # ~305 dpi
PT_MM = 25.4 / 72.0


def mm(v: float) -> int:
    return int(round(v * PX_PER_MM))


@dataclass
class BookStyle:
    kind: str
    page_w: float  # mm, one page
    page_h: float
    top: float
    bottom: float
    inner: float
    outer: float
    font: str
    font_bold: str
    size_pt: float
    leading_pt: float
    columns: int = 1
    col_gap: float = 0.0
    folio: str = "header"  # "header" = page number in header outer corner, "footer" = bottom centre
    font_index: int = 0


STYLES = {
    # Mass-market paperback, ~11pt serif, ~35 lines, narrow margins.
    "paperback": BookStyle("paperback", 110, 178, 13, 12, 12, 9, "times.ttf", "timesbd.ttf", 11, 12.4),
    # Hardback, 12pt, roomier margins.
    "hardback": BookStyle("hardback", 152, 229, 20, 20, 19, 17, "pala.ttf", "palab.ttf", 12, 14.5, folio="footer"),
    # Trade paperback, photographed as an open two-page spread.
    "spread": BookStyle("spread", 135, 205, 17, 17, 16, 13, "georgia.ttf", "georgiab.ttf", 10.5, 13.5, folio="footer"),
    # Two-column textbook page, smaller type.
    "textbook": BookStyle("textbook", 210, 270, 18, 18, 18, 15, "cambria.ttc", "cambriab.ttf", 9, 11,
                          columns=2, col_gap=7),
}

# id, book kind, first page number, number of page images (a spread is 2 pages in 1 image)
PAGE_PLAN = [
    ("paperback", 1, 7),
    ("hardback", 3, 5),
    ("spread", 10, 2),
    ("textbook", 7, 3),
]


def smarten(s: str) -> str:
    s = s.replace("--", "\u2014")
    s = re.sub(r'(^|[\s(\u2014])"', "\\1\u201c", s)
    s = s.replace('"', "\u201d")
    s = re.sub(r"(^|[\s(\u2014])'", "\\1\u2018", s)
    s = s.replace("'", "\u2019")
    return s


@dataclass
class Tok:
    text: str
    space_before: bool = True


def tokenize(par: str) -> list[Tok]:
    toks: list[Tok] = []
    for word in par.split():
        parts = re.split(r"(?<=\u2014)", word)  # allow a break after an em dash
        parts = [p for p in parts if p]
        for i, p in enumerate(parts):
            toks.append(Tok(p, space_before=(i == 0)))
    return toks


@dataclass
class Para:
    toks: list[Tok]
    heading: bool = False
    indent: bool = True
    chapter: str = ""


def build_flow(kind: str, repeat: int = 3) -> list[Para]:
    paras: list[Para] = []
    for _ in range(repeat):
        for cid in BOOK_FLOWS[kind]:
            ch = CHAPTERS[cid]
            paras.append(Para(tokenize(smarten(ch["heading"])), heading=True, indent=False, chapter=cid))
            first = True
            for p in re.split(r"\n\s*\n", ch["text"].strip()):
                paras.append(Para(tokenize(smarten(" ".join(p.split()))), indent=not first, chapter=cid))
                first = False
    return paras


VOWELS = set("aeiouyAEIOUY")
NO_SPLIT = {"th", "sh", "ch", "ph", "wh", "ck", "gh", "qu", "ng"}


def hyphen_points(word: str) -> list[int]:
    """Cheap VC|CV hyphenation points plus existing hyphens. Index = length of the first part."""
    pts = []
    m = re.match(r"^([\u2018\u201c(]*)([A-Za-z\-]+)([^A-Za-z]*)$", word)
    if not m:
        return pts
    lead, core = len(m.group(1)), m.group(2)
    for i, c in enumerate(core):
        if c == "-" and 2 <= i <= len(core) - 3:
            pts.append(lead + i + 1)  # break after an existing hyphen
    if "-" not in core and len(core) >= 7:
        for i in range(3, len(core) - 2):
            a, b = core[i - 1], core[i]
            vc_cv = (core[i - 2] in VOWELS and a not in VOWELS and b not in VOWELS
                     and core[i + 1] in VOWELS and (a + b).lower() not in NO_SPLIT)
            double = a not in VOWELS and a.lower() == b.lower()
            if vc_cv or double:
                pts.append(lead + i)
    return sorted(set(pts))


@dataclass
class Line:
    text: str
    x0: float  # mm, image coords
    y0: float
    x1: float
    y1: float
    col: int
    heading: bool = False
    para_end: bool = False
    soft_hyphen: bool = False  # ends with a hyphen that this layout inserted
    hard_break_hyphen: bool = False  # broke after a hyphen that is part of the word


class Flow:
    def __init__(self, paras: list[Para]):
        self.paras = paras
        self.pi = 0
        self.ti = 0
        self.pending: Tok | None = None  # remainder of a hyphenated word

    def peek(self) -> Para:
        return self.paras[self.pi]

    def next_line(self, font, width_px: float) -> tuple[list[Tok], bool, str]:
        """Return (tokens, para_end, hyphen_kind) for one line."""
        para = self.paras[self.pi]
        toks: list[Tok] = []
        hyph = ""
        space_w = font.getlength(" ")

        def width(ts: list[Tok]) -> float:
            w = 0.0
            for i, t in enumerate(ts):
                if i and t.space_before:
                    w += space_w
                w += font.getlength(t.text)
            return w

        while True:
            if self.pending is not None:
                cand = self.pending
            elif self.ti < len(para.toks):
                cand = para.toks[self.ti]
            else:
                break
            if width(toks + [cand]) <= width_px:
                toks.append(cand)
                if self.pending is not None:
                    self.pending = None
                else:
                    self.ti += 1
                continue
            # does not fit: try hyphenating if the line would be loose
            slack = width_px - width(toks)
            if not para.heading and slack > 0.06 * width_px:
                for p in reversed(hyphen_points(cand.text)):
                    head = cand.text[:p]
                    hard = head.endswith("-")
                    shown = head if hard else head + "-"
                    if width(toks + [Tok(shown, cand.space_before)]) <= width_px:
                        toks.append(Tok(shown, cand.space_before))
                        rest = Tok(cand.text[p:], space_before=False)
                        if self.pending is None:
                            self.ti += 1
                        self.pending = rest
                        hyph = "hard" if hard else "soft"
                        break
            if not toks:  # single over-long token: force it
                toks.append(cand)
                if self.pending is not None:
                    self.pending = None
                else:
                    self.ti += 1
            break
        para_end = self.pending is None and self.ti >= len(para.toks)
        if para_end:
            self.pi += 1
            self.ti = 0
        return toks, para_end, hyph


def toks_text(toks: list[Tok]) -> str:
    out = ""
    for i, t in enumerate(toks):
        if i and t.space_before:
            out += " "
        out += t.text
    return out


def draw_line(draw, font, toks, x, y, width_px, justify: bool):
    space_w = font.getlength(" ")
    natural = sum(font.getlength(t.text) for t in toks)
    gaps = [i for i, t in enumerate(toks) if i and t.space_before]
    extra = 0.0
    if justify and gaps:
        extra = (width_px - natural - space_w * len(gaps)) / len(gaps)
        extra = max(0.0, min(extra, space_w * 2.5))
    cx = x
    for i, t in enumerate(toks):
        if i and t.space_before:
            cx += space_w + extra
        draw.text((cx, y), t.text, font=font, fill=0)
        cx += font.getlength(t.text)
    return cx


def load_font(name: str, size_px: int):
    return ImageFont.truetype(str(FONT_DIR / name), size_px, index=0)


def render_page(draw, st: BookStyle, flow: Flow, page_no: int, ox: float, col_base: int,
                lines: list[Line], meta: list[dict]):
    """Render one page whose left edge is at ox mm in the image."""
    recto = page_no % 2 == 1
    inner_left = recto  # recto: binding on the left
    left = ox + (st.inner if inner_left else st.outer)
    right = ox + st.page_w - (st.outer if inner_left else st.inner)
    top, bottom = st.top, st.page_h - st.bottom
    size_px = int(round(st.size_pt * PT_MM * PX_PER_MM))
    lead_mm = st.leading_pt * PT_MM
    font = load_font(st.font, size_px)
    hfont = load_font(st.font_bold, int(size_px * 1.35))
    small = load_font(st.font, int(size_px * 0.82))
    ascent = font.getmetrics()[0] / PX_PER_MM

    opener = flow.peek().heading and flow.ti == 0 and flow.pending is None
    # running header and folio
    header_y = top - 8.0
    chapter_cid = flow.peek().chapter
    if not opener:
        htxt = CHAPTERS[chapter_cid]["book"].upper() if not recto else CHAPTERS[chapter_cid]["heading"]
        if st.kind == "textbook":
            htxt = f"{CHAPTERS[chapter_cid]['author']}  \u00b7  {CHAPTERS[chapter_cid]['book']}"
        hw = small.getlength(htxt) / PX_PER_MM
        if st.kind == "textbook":
            hx = right - hw if not recto else left  # inner side; folio goes outer
        else:
            hx = (left + right) / 2 - hw / 2
        draw.text((mm(hx), mm(header_y)), htxt, font=small, fill=0)
        meta.append({"kind": "header", "text": htxt, "box": [hx, header_y, hx + hw, header_y + size_px * 0.82 / PX_PER_MM]})
    ftxt = str(page_no)
    fw = small.getlength(ftxt) / PX_PER_MM
    if st.folio == "header" and not opener:
        fx, fy = (left if not recto else right - fw), header_y
    else:
        fx, fy = (left + right) / 2 - fw / 2, st.page_h - st.bottom + 6.0
    draw.text((mm(fx), mm(fy)), ftxt, font=small, fill=0)
    meta.append({"kind": "page_number", "text": ftxt, "box": [fx, fy, fx + fw, fy + size_px * 0.82 / PX_PER_MM]})

    ncol = st.columns
    col_w = (right - left - st.col_gap * (ncol - 1)) / ncol
    y_start = top + (22.0 if opener else 0.0)
    for c in range(ncol):
        cx0 = left + c * (col_w + st.col_gap)
        y = y_start if c == 0 else top
        while y + lead_mm <= bottom + 0.01:
            para = flow.peek()
            if para.heading and flow.ti == 0 and flow.pending is None:
                if lines and lines[-1].col == col_base + c and y > top:
                    y += lead_mm * 0.8  # space above a heading mid-page
                if y + 3 * lead_mm > bottom:
                    break  # don't strand a heading at the bottom
                toks, _, _ = flow.next_line(hfont, col_w * PX_PER_MM)
                text = toks_text(toks)
                w = hfont.getlength(text) / PX_PER_MM
                hx = cx0 + (col_w - w) / 2 if st.columns == 1 else cx0
                draw.text((mm(hx), mm(y)), text, font=hfont, fill=0)
                lines.append(Line(text, hx, y, hx + w, y + 1.35 * size_px / PX_PER_MM, col_base + c, heading=True, para_end=True))
                y += lead_mm * 2.2
                continue
            indent = 0.0
            if para.indent and flow.ti == 0 and flow.pending is None:
                indent = 1.5 * size_px / PX_PER_MM
            toks, para_end, hyph = flow.next_line(font, (col_w - indent) * PX_PER_MM)
            x_end = draw_line(draw, font, toks, mm(cx0 + indent), mm(y), (col_w - indent) * PX_PER_MM,
                              justify=not para_end)
            lines.append(Line(toks_text(toks), cx0 + indent, y, x_end / PX_PER_MM, y + ascent, col_base + c,
                              para_end=para_end, soft_hyphen=hyph == "soft", hard_break_hyphen=hyph == "hard"))
            y += lead_mm
    return font


def rejoin(lines: list[Line]) -> str:
    paras, cur = [], ""
    for ln in lines:
        t = ln.text
        if ln.soft_hyphen and t.endswith("-"):
            cur += t[:-1]
        elif ln.hard_break_hyphen:
            cur += t
        else:
            cur += t + ("\n" if ln.para_end else " ")
    for p in cur.split("\n"):
        if p.strip():
            paras.append(p.strip())
    return "\n".join(paras) + "\n"


def main():
    OUT_PAGES.mkdir(parents=True, exist_ok=True)
    GT_DIR.mkdir(parents=True, exist_ok=True)
    index = []
    for kind, first_no, n_images in PAGE_PLAN:
        st = STYLES[kind]
        flow = Flow(build_flow(kind))
        page_no = first_no
        for n in range(n_images):
            spread = kind == "spread"
            if spread and page_no % 2 == 1:
                page_no += 1  # spreads start on a verso
            pid = f"{kind[:2]}-{n + 1:02d}"
            img_w = st.page_w * (2 if spread else 1)
            img = Image.new("L", (mm(img_w), mm(st.page_h)), 255)
            draw = ImageDraw.Draw(img)
            lines: list[Line] = []
            meta: list[dict] = []
            pages = []
            font = None
            for k in range(2 if spread else 1):
                ox = k * st.page_w
                font = render_page(draw, st, flow, page_no, ox, col_base=k * st.columns, lines=lines, meta=meta)
                pages.append({"page_no": page_no, "rect": [ox, 0, ox + st.page_w, st.page_h],
                              "gutter": "left" if page_no % 2 == 1 else "right"})
                page_no += 1
            if spread:
                page_no += 30  # next spread is further into the book
            img.save(OUT_PAGES / f"{pid}.png")
            # half-page target: top half of the (left-hand) page
            p0 = pages[0]["rect"]
            half = [p0[0], 0.0, p0[2], st.page_h / 2]
            xb = font.getbbox("x")
            info = {
                "id": pid,
                "kind": kind,
                "image_mm": [img_w, st.page_h],
                "px_per_mm": PX_PER_MM,
                "font": st.font,
                "size_pt": st.size_pt,
                "leading_pt": st.leading_pt,
                "x_height_mm": round((xb[3] - xb[1]) / PX_PER_MM, 3),
                "pages": pages,
                "half_region": half,
                "lines": [ln.__dict__ for ln in lines],
                "meta": meta,
            }
            (GT_DIR / f"{pid}.json").write_text(json.dumps(info, indent=1, ensure_ascii=False), encoding="utf-8")
            (GT_DIR / f"{pid}.body.txt").write_text("\n".join(ln.text for ln in lines) + "\n", encoding="utf-8")
            (GT_DIR / f"{pid}.rejoined.txt").write_text(rejoin(lines), encoding="utf-8")
            (GT_DIR / f"{pid}.meta.txt").write_text("\n".join(m["text"] for m in meta) + "\n", encoding="utf-8")
            nh = sum(ln.soft_hyphen or ln.hard_break_hyphen for ln in lines)
            print(f"{pid}: {len(lines)} lines, {nh} line-end hyphens, pages {[p['page_no'] for p in pages]}")
            index.append(pid)
    (GT_DIR / "index.txt").write_text("\n".join(index) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
