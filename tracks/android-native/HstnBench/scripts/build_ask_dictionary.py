#!/usr/bin/env python3
"""build_ask_dictionary - WordNet 3.0 into the compact dictionary asset for "Ask about the text"

The phone answers "what does recondite mean?" from a dictionary bundled in the APK, with no network.
This script turns Princeton WordNet 3.0 (licence: see LICENSE-WordNet below, BSD-style, allows
bundling with the notice) into one gzip'd UTF-8 text file the app loads into memory at first use:

    #WNASK 1
    #<the WordNet licence, one '#' line each>
    @S <count>                synsets: one definition per line (examples dropped), numbered from 0
    <definition>
    @L <count>                lemmas, sorted by UTF-8 bytes (binary search on the phone)
    <lemma>\t<pos><id>,<id>;<pos><id>    pos n/v/a/r; ids base 36, in WordNet's sense order
    @X <count>                irregular inflections (WordNet *.exc), sorted by form
    <form>\t<pos>\t<base>,<base>

Lemmas are lower case with spaces (WordNet's underscores). Adjective satellites count as 'a'.
Read on the phone by tools/ask/Dictionary.kt. The file is gzip data but deliberately not named
*.gz: the Android Gradle plugin unpacks .gz assets at build time, which would put the 10 MB raw
text in the APK (4.2 MB deflated) and break the asset name. The output is committed (about 3 MB), so a build needs
neither Python nor network; re-run this only to change the format.

Usage (from tracks/android-native/HstnBench):
    python3 scripts/build_ask_dictionary.py --download          # fetch WordNet-3.0.tar.gz (checked)
    python3 scripts/build_ask_dictionary.py --wordnet /path/to/WordNet-3.0/dict
"""

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile
import tempfile
import urllib.request

WORDNET_URL = "https://wordnetcode.princeton.edu/3.0/WordNet-3.0.tar.gz"
WORDNET_SHA256 = "640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52"
POS_FILES = [("n", "noun"), ("v", "verb"), ("a", "adj"), ("r", "adv")]
DEFAULT_OUT = os.path.join("app", "src", "main", "assets", "ask", "wordnet.wnask")

LICENCE = """WordNet Release 3.0. This software and database is being provided to you, the LICENSEE, by
Princeton University under the following license. By obtaining, using and/or copying this software
and database, you agree that you have read, understood, and will comply with these terms and
conditions.: Permission to use, copy, modify and distribute this software and database and its
documentation for any purpose and without fee or royalty is hereby granted, provided that you agree
to comply with the following copyright notice and statements, including the disclaimer, and that
the same appear on ALL copies of the software, database and documentation, including modifications
that you make for internal use or for distribution. WordNet 3.0 Copyright 2006 by Princeton
University. All rights reserved. THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON
UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED. BY WAY OF EXAMPLE, BUT NOT
LIMITATION, PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES OF MERCHANT- ABILITY OR
FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF THE LICENSED SOFTWARE, DATABASE OR
DOCUMENTATION WILL NOT INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.
The name of Princeton University or Princeton may not be used in advertising or publicity
pertaining to distribution of the software and/or database. Title to copyright in this software,
database and any associated documentation shall at all times remain with Princeton University and
LICENSEE agrees to preserve same. (Converted to this format by scripts/build_ask_dictionary.py:
definitions kept, examples and relations dropped.)"""


def base36(n):
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n == 0:
        return "0"
    out = []
    while n:
        n, r = divmod(n, 36)
        out.append(digits[r])
    return "".join(reversed(out))


def definition_of(gloss):
    """'difficult to understand; "a recondite subject"' -> 'difficult to understand'."""
    g = gloss.strip()
    cut = len(g)
    for marker in ['; "', ';"', ' "']:
        i = g.find(marker)
        if i != -1:
            cut = min(cut, i)
    if g.startswith('"'):
        cut = len(g)  # rare: a gloss that is only an example; keep it
    d = g[:cut].strip().rstrip(";").strip()
    return " ".join(d.split())


def read_synsets(dict_dir):
    """{(pos_file_letter, offset): index}, [definition]"""
    ids, defs = {}, []
    for letter, name in POS_FILES:
        with open(os.path.join(dict_dir, "data." + name), encoding="latin-1") as f:
            for line in f:
                if line.startswith("  "):
                    continue  # licence header
                head, _, gloss = line.partition(" | ")
                offset = head.split(" ", 1)[0]
                ids[(letter, offset)] = len(defs)
                defs.append(definition_of(gloss) or "(no definition)")
    return ids, defs


def read_lemmas(dict_dir, ids):
    """{lemma: [(pos, [synset index])]} in WordNet's sense order."""
    lemmas = {}
    for letter, name in POS_FILES:
        with open(os.path.join(dict_dir, "index." + name), encoding="latin-1") as f:
            for line in f:
                if line.startswith("  "):
                    continue
                parts = line.split()
                lemma = parts[0].replace("_", " ").lower()
                synset_cnt = int(parts[2])
                offsets = parts[-synset_cnt:]
                senses = [ids[(letter, o)] for o in offsets]
                lemmas.setdefault(lemma, []).append((letter, senses))
    return lemmas


def read_exceptions(dict_dir):
    out = {}
    for letter, name in POS_FILES:
        with open(os.path.join(dict_dir, name + ".exc"), encoding="latin-1") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2:
                    continue
                form = parts[0].replace("_", " ")
                bases = [b.replace("_", " ") for b in parts[1:]]
                out[(form, letter)] = bases
    return out


def build(dict_dir):
    ids, defs = read_synsets(dict_dir)
    lemmas = read_lemmas(dict_dir, ids)
    exc = read_exceptions(dict_dir)
    lines = ["#WNASK 1"]
    lines += ["#" + l for l in LICENCE.splitlines()]
    lines.append("@S %d" % len(defs))
    lines += defs
    lines.append("@L %d" % len(lemmas))
    for lemma in sorted(lemmas, key=lambda s: s.encode("utf-8")):
        groups = ";".join(p + ",".join(base36(i) for i in senses) for p, senses in lemmas[lemma])
        lines.append(lemma + "\t" + groups)
    lines.append("@X %d" % len(exc))
    for (form, pos) in sorted(exc, key=lambda k: (k[0].encode("utf-8"), k[1])):
        lines.append("%s\t%s\t%s" % (form, pos, ",".join(exc[(form, pos)])))
    for l in lines:
        if "\t" in l and l.count("\t") > 2:
            raise ValueError("tab in data: " + l)
    return ("\n".join(lines) + "\n").encode("utf-8"), len(defs), len(lemmas), len(exc)


def download():
    tmp = tempfile.mkdtemp(prefix="wordnet-")
    print("downloading", WORDNET_URL, file=sys.stderr)
    data = urllib.request.urlopen(WORDNET_URL).read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != WORDNET_SHA256:
        sys.exit("checksum mismatch: %s" % digest)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        members = [m for m in tar.getmembers() if "/dict/" in m.name and m.isfile()]
        tar.extractall(tmp, members=members)
    return os.path.join(tmp, "WordNet-3.0", "dict")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wordnet", help="WordNet 3.0 dict directory (data.*, index.*, *.exc)")
    ap.add_argument("--download", action="store_true", help="fetch WordNet-3.0.tar.gz first")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()
    if not args.wordnet and not args.download:
        ap.error("give --wordnet DIR or --download")
    dict_dir = download() if args.download else args.wordnet
    raw, n_syn, n_lem, n_exc = build(dict_dir)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "wb") as f:
        # mtime=0 so the same input always gives the same bytes.
        with gzip.GzipFile(fileobj=f, mode="wb", compresslevel=9, mtime=0, filename="") as gz:
            gz.write(raw)
    print("synsets=%d lemmas=%d exceptions=%d raw=%d bytes gz=%d bytes -> %s"
          % (n_syn, n_lem, n_exc, len(raw), os.path.getsize(args.out), args.out))


if __name__ == "__main__":
    main()
