"""Text normalisation, Levenshtein distance, CER and WER. No dependencies."""

from __future__ import annotations

import re
import unicodedata

_MAP = str.maketrans({
    "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'", "`": "'",
    "“": '"', "”": '"', "„": '"', "″": '"',
    "—": "-", "–": "-", "‒": "-", "―": "-", "−": "-",
    " ": " ",
})


def normalise(s: str) -> str:
    """NFKC, ASCII quotes and dashes, collapse whitespace. Case and punctuation kept."""
    s = unicodedata.normalize("NFKC", s).translate(_MAP)
    s = s.replace("…", "...")
    return re.sub(r"\s+", " ", s).strip()


def levenshtein(a, b) -> int:
    """Edit distance between two sequences (Myers/Hyyro bit-parallel, Python ints as bit vectors)."""
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    # pattern = b (shorter)
    m = len(b)
    peq: dict = {}
    for i, c in enumerate(b):
        peq[c] = peq.get(c, 0) | (1 << i)
    mask = (1 << m) - 1
    last = 1 << (m - 1)
    pv, mv, score = mask, 0, m
    for c in a:
        eq = peq.get(c, 0)
        xv = eq | mv
        xh = (((eq & pv) + pv) ^ pv) | eq
        ph = mv | (~(xh | pv) & mask)
        mh = pv & xh
        if ph & last:
            score += 1
        elif mh & last:
            score -= 1
        ph = ((ph << 1) | 1) & mask
        mh = (mh << 1) & mask
        pv = mh | (~(xv | ph) & mask)
        mv = ph & xv
    return score


def _words(s: str) -> list[str]:
    return s.split()


def cer_wer(hyp: str, ref: str) -> dict:
    h, r = normalise(hyp), normalise(ref)
    ce = levenshtein(h, r)
    hw, rw = _words(h), _words(r)
    vocab: dict[str, str] = {}
    enc = lambda ws: "".join(vocab.setdefault(w, chr(0x4E00 + len(vocab))) for w in ws)  # noqa: E731
    we = levenshtein(enc(hw), enc(rw))
    return {"char_edits": ce, "ref_chars": len(r), "word_edits": we, "ref_words": len(rw),
            "cer": ce / max(1, len(r)), "wer": we / max(1, len(rw))}


def _dp(a, b) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


if __name__ == "__main__":  # self-test against the plain DP
    import random
    rnd = random.Random(1)
    for _ in range(2000):
        a = "".join(rnd.choice("abc d") for _ in range(rnd.randint(0, 90)))
        b = "".join(rnd.choice("abc d") for _ in range(rnd.randint(0, 90)))
        assert levenshtein(a, b) == _dp(a, b), (a, b)
    print("levenshtein ok")
