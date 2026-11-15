# SpeakUp brand

"Your glasses, out loud." By deac online · Worldbuild.io

Open `brand-guide.html` in a browser for the full guide: mark, colour and contrast, type, the voice ribbon, do and don't, and voice and tone.

| File | What it's for |
| --- | --- |
| `speakup-mark.svg` | The "speaking lens" mark on its own, filled with `currentColor`. Set `color` (Signal Yellow on Night by default). Smallest size is 24 px. |
| `speakup-wordmark.svg` | "SpeakUp" in Atkinson Hyperlegible Bold, converted to outlines (no font needed). `currentColor`. |
| `speakup-lockup.svg` | Mark and wordmark together: yellow mark, Paper wordmark. For dark backgrounds. |
| `speakup-lockup-mono.svg` | The same lockup in one colour (`currentColor`). Use it on Paper, or anywhere that needs a single colour. |
| `app-icon.svg` / `app-icon-1024.png` | Store and app icon: yellow mark on Night with a soft violet glow. Full-bleed square; the platform applies its own corner mask. |
| `tokens.json` | Colours, dark and light roles, state colours (idle, listening, thinking, speaking, error), type scale (body 20 sp minimum), radii, spacing, sizes, motion. |
| `fonts/` | Atkinson Hyperlegible Regular and Bold, plus `OFL.txt`, from google/fonts `ofl/atkinsonhyperlegible`. |
| `brand-guide.html` | One self-contained guide page. It meets WCAG AA itself. |
| `source/` | The generators. `gen.py` draws the mark geometry, outlines the wordmark (fontTools + uharfbuzz), and writes the SVGs, the PNGs and the Android vectors. `build_guide.py` inlines everything into `guide.tpl.html` to make `brand-guide.html`. |

## Rebuilding

```sh
python -m venv .venv && .venv/Scripts/pip install fonttools uharfbuzz resvg-py pillow
.venv/Scripts/python -I design/brand/source/gen.py .          # run from the repo root
.venv/Scripts/python -I design/brand/source/build_guide.py .
```

`gen.py` also rewrites these Android launcher files in `tracks/android-native/HstnBench/app/src/main/res/`:

- `drawable/ic_launcher_foreground_speakup.xml`, `ic_launcher_background_speakup.xml`, `ic_launcher_monochrome_speakup.xml`
- `drawable/speakup_mark.xml`
- `mipmap-anydpi-v26/ic_launcher.xml`
- `mipmap-xxxhdpi/ic_launcher.png`

## Using the mark on Android

`@drawable/speakup_mark` is a white 24 dp vector. Tint it from the caller, for example `Icon(painterResource(R.drawable.speakup_mark), contentDescription = null, tint = SignalYellow)`. Set `contentDescription` to "SpeakUp" when the mark is the only label.

## Rules you'll trip over

- Yellow, Cyan and Coral are never used as text on Paper (1.3 to 2.6:1). In light mode they only appear as fills behind Night text.
- Dusk Line (`#3A3470`) is for decorative dividers only (1.77:1 on Night). Give controls a Paper edge or a fill that reaches 3:1.
- Coral on Dusk is 5.91:1, so it's fine for large text and icons but not for body text.
