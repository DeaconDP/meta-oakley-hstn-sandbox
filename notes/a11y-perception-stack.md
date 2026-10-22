# Accessibility perception stack (phone side)

2026-10-22. Research note for the blind/low-vision (BLV) showcase. It covers what runs on the phone after a frame arrives from HSTN, and what gets spoken back. Inputs: `notes/hstn-capabilities.md` (stream/photo formats) and `notes/bench-android-native.md` (mock latencies). Tags: **[doc]** = stated in a cited doc; **[est]** = my estimate, not measured, to be replaced by harness numbers; **[unverified]** = secondary source only.

## Constraints carried in from this repo

| Fact | Value | Source |
|---|---|---|
| Stream sizes | LOW 360x640, MEDIUM 504x896 (default), HIGH 720x1280; 2/7/15/24/30 fps; HEVC or raw YUV | `notes/hstn-capabilities.md` |
| Photo sizes | SMALL ~480p … FULL 4032x3024; **Experimental**, can't ship to production | `notes/hstn-capabilities.md` |
| `stream_to_first_frame` (mock) | 975 ms median (cold stream start) | `notes/bench-android-native.md` |
| `capture_to_photo` (mock) | **3940 ms** median, 960x1440 | `notes/bench-android-native.md` |
| `tts_to_audio_start` (Android TTS, phone speaker) | 211 ms median | `notes/bench-android-native.md` |
| Audio out | Plain BT: A2DP (stereo, output only) or HFP (mono, with mic); no DAT audio API | `notes/hstn-capabilities.md` |
| Mock feed injection | `MockCameraKit.setCameraFeed(videoUri)` (HEVC/h.265 file), `setCapturedImage(imageUri)`; iOS `setCameraFeed(fileURL:)` | `sdks/meta-wearables-dat-android/AGENTS.md:384-410`, `sdks/meta-wearables-dat-ios/AGENTS.md:418` |

**Consequence:** `capturePhoto()` costs ~3.9 s before any inference starts. On its own that exceeds a 1.5 s trigger-to-first-word budget, and it is Experimental anyway. Interactive tasks must **grab the latest decoded stream frame**. Use photo capture only where the user has accepted a delay ("read this whole page", "take a detailed look").

## Per-task comparison

Latency columns are per-frame inference after the frame is on the phone. "Offline" means it works with no network.

### On-device

| Task | Android option | iOS option | Offline | Latency | Device req. | Notes |
|---|---|---|---|---|---|---|
| OCR / read aloud | ML Kit Text Recognition v2 (Latin, Chinese, Devanagari, Japanese, Korean; blocks/lines/words + boxes + confidence) | Vision `RecognizeTextRequest` (Swift API, iOS 18+) / `VNRecognizeTextRequest`; VisionKit `DataScannerViewController` for live camera UI only, which doesn't fit glasses frames | Yes | [est] 30–150 ms at 504x896; `.fast` vs `.accurate` on iOS | Any recent phone | Good on signs and labels. Small print needs HIGH stream or a photo |
| Text *presence* trigger (continuous) | Same as OCR at LOW/7 fps, or count ML Kit text blocks | Vision `.fast` level | Yes | [est] <50 ms | Any | Drives a "text ahead" earcon and auto-read mode |
| Short scene description | ML Kit GenAI **Image Description** (Gemini Nano, **Beta**) or Prompt API with image | **Foundation Models** image `Attachment` (on-device model gained vision at WWDC26; OS version not stated in the session; on-device context 8192 tokens) | Yes | [doc, 2025, Pixel 9 Pro] ~0.8 s image encode + ~11 tok/s output → [est] ~1.2 s to first words if streamed, 3–4 s for 30 words | Android: device list only (Pixel 9–11, Galaxy S25/S26, Fold7/8 …). Foreground-only (`BACKGROUND_USE_BLOCKED` even in a foreground service), per-app quota (`BUSY`, battery quota). iOS: Apple Intelligence devices | Quality well below cloud VLMs. Useful as the offline fallback |
| Detailed Q&A about an image | ML Kit GenAI Prompt API (multimodal, Beta; Nano v2/v3/v4 by device) | Foundation Models with image + text | Yes | [est] multiple seconds | As above | Weak on fine detail and counting. Use cloud by default |
| Object / obstacle detection | ML Kit Object Detection (5 coarse classes + tracking); MediaPipe Object Detector (EfficientDet-Lite0, COCO 80 classes); custom LiteRT model | Vision `RecognizeAnimals`/`DetectHumanRectangles`; Core ML (YOLO-class model) | Yes | [doc] EfficientDet-Lite0 on Pixel 6: int8 29 ms CPU; fp32 61 ms CPU / 28 ms GPU | Any | Monocular with no depth sensor, so distance is guessed from box size. **Not a mobility aid** (see Risks) |
| Barcode → product | ML Kit Barcode Scanning (1D/2D) → Open Food Facts `GET /api/v2/product/{code}.json` (no key, send a descriptive User-Agent, cache) | Vision `DetectBarcodesRequest` → same lookup | Decode yes, lookup no | [est] decode <50 ms; lookup 200–600 ms | Any | Small 1D codes need HIGH stream or a photo. Fall back to a cloud VLM reading the label |
| Currency | No first-party API. Options: custom LiteRT/Core ML classifier per currency, OCR of numerals as a cross-check | Same (Core ML) | Custom model only | [est] <50 ms | Any | Training data and per-currency upkeep are the cost. Cloud VLM is easier but can hallucinate a denomination |
| Face / person presence (no ID) | ML Kit Face Detection (boxes, landmarks, no recognition); MediaPipe Face Detector; person class from object detector | Vision `DetectFaceRectanglesRequest`, `DetectHumanRectanglesRequest` | Yes | [est] 10–40 ms | Any | Speak "one person ahead, left". Never embed or store faces. Also the on-device input for **face blurring before cloud upload** |

### Cloud VLMs (neutral, prices from current provider pages)

| | Claude (Anthropic) | Gemini (Google) | GPT (OpenAI) |
|---|---|---|---|
| Current fit-for-purpose models | Haiku 5.5 `claude-haiku-5-5` ($0.10 / $0.50 per MTok in/out); Sonnet 5.5 `claude-sonnet-5-5` ($2 / $10); Opus 5.5 `claude-opus-5-5` ($4 / $20) | Gemini 3.x Flash-Lite ($0.25–0.30 / $1.50–2.50), 3.8 Flash ($0.75 / $3.75, doubles 2027-01-01); **Live API** for continuous video ($0.002/min image/video input) | GPT-5.x mini/nano families. Image cost from the official calculator |
| Image token rule | `ceil(w/28) × ceil(h/28)`; Claude 4.7+ models cap at 2576 px long edge / 4784 tokens | 258 tokens per image ≤384 px, else 258 per 768-px tile (Gemini 3 caps per image via `media_resolution`, so check `countTokens`) | `ceil(w/32) × ceil(h/32)` patches × per-model multiplier; `detail` low/high/original (reports say some mini/nano ignore `detail`) [unverified] |
| Limits | 10 MB per image (base64, direct API); 8000x8000 px; 32 MB request; JPEG/PNG/GIF/WebP; stricter 2000 px limit above 20 images per request | 20 MB inline request; 3,600 images per request | See guide |
| Streaming | SSE `messages.stream`; text deltas | SSE + Live API (bidirectional WebSocket, audio out) | SSE + Realtime API |
| Person ID | Refuses to name people (docs, Limitations) | Policy-restricted | Policy-restricted |
| Latency (TTFT with image) | No official figure; Haiku 5.5 has no Artificial Analysis data yet. [est] 0.4–0.9 s for a ~600-token image with thinking off | [est] similar for Flash-Lite | [est] similar for mini |

Claude request knobs that matter for time-to-first-word (from the claude-api skill, cached 2026-10-06):

- **Haiku 5.5**: thinking runs by default and default effort is `medium`. Send `thinking: {type: "disabled"}` (allowed at effort ≤ high) or `effort: "low"`. Otherwise thinking runs silently (`display` defaults to `"omitted"`) and TTFT grows.
- **Sonnet 5.5**: `{type:"disabled"}` returns a 400. Use `thinking: {type: "between_tools"}` at effort ≤ high.
- **Opus 5.5**: thinking can't be disabled, so use `effort: "low"`. Too slow for the interactive tier; keep it for opt-in "detailed look".
- Put the image before the text in content. Keep the system prompt stable and cache it (`cache_control`). Note the minimum cacheable prefix is 512–4096 tokens by model, so a short system prompt may not cache.
- Check `stop_reason` before reading content (`refusal`).

#### Cost per image at HSTN sizes (Claude, input image tokens only)

| Frame | Claude tokens | Haiku 5.5 / 1k imgs | Sonnet 5.5 / 1k | Opus 5.5 / 1k |
|---|---|---|---|---|
| LOW 360x640 | 13×23 = **299** | $0.03 | $0.60 | $1.20 |
| MEDIUM 504x896 | 18×32 = **576** | $0.06 | $1.15 | $2.30 |
| HIGH 720x1280 | 26×46 = **1,196** | $0.12 | $2.39 | $4.78 |
| Photo MEDIUM decoded 960x1440 | 35×52 = **1,820** | $0.18 | $3.64 | $7.28 |
| Photo FULL 4032x3024 (downscaled) | **4,784** (cap) | $0.48 | $9.57 | $19.14 |

Add ~150–300 prompt tokens and the output: a 40-word description is ~60 tokens, i.e. $0.03 / $0.60 / $1.20 per 1k on Haiku / Sonnet / Opus. For comparison, Gemini's tiling formula gives 720x1280 → 6 tiles × 258 = 1,548 tokens (Gemini 2.x rule; Gemini 3 differs). **Cost is negligible at Haiku tier even at 1 query/10 s; a continuous cloud loop at 2 fps on Sonnet is ~$4–8/hour. Do not stream frames to a cloud model continuously unless you use a per-minute-priced live API.**

### Streaming text into TTS (time-to-first-word)

| Step | Approach |
|---|---|
| Prompt | "Answer in short sentences. Most important fact first. No preamble, no markdown." Cap `max_tokens` ~200 for describe and ~400 for Q&A |
| Chunking | Buffer text deltas until a clause boundary (`. , ; :` or ~8 words), then `speak(chunk, QUEUE_ADD)` / `AVSpeechSynthesizer.speak` (queues). First chunk lands after ~8–12 output tokens |
| Barge-in | New trigger or a user gesture → cancel the HTTP stream, then `tts.stop()` / `stopSpeaking(at: .word)` |
| Ack earcon | Play a short tone within 100 ms of the trigger so silence never means "did it hear me?" |

### Privacy (bystanders)

| Issue | Mitigation |
|---|---|
| Cloud frames contain bystanders' faces, screens, documents | On-device face detection, then **blur faces before upload** (default on; offer an off switch for "describe this person's expression" with consent); crop to region of interest when the task is text |
| Provider retention | Anthropic and others default to retaining API data (reported 30-day default for commercial API; ZDR only on application and excluded for "Covered" models like Fable 5/5.1 [unverified, secondary press]); images are not used for training per the Claude vision FAQ. Pick a model and plan that allow ZDR if required. Disclose in the app's privacy text |
| Always-on capture | Cloud calls only on explicit trigger (button, captouch, voice). Continuous loop stays on-device. Respect the glasses' capture LED convention |
| Identification | Never identify people. Claude refuses by policy; enforce it in our prompt too |
| Logs / eval recordings | Don't persist user frames by default. The eval harness uses public datasets and our own consented recordings only |

## Tiered architecture

```
HSTN stream (LOW or MEDIUM, 7 fps, HEVC) ──► decoder ──► ring buffer (last ~1 s of frames + sharpness score)
                                                     │
          Tier 0: continuous on-device (every Nth frame, ≤50 ms budget)
            text-present? ─► earcon "text ahead" / auto-read mode
            person/face present? ─► "person, left"
            barcode decoded? ─► lookup ─► speak product
            (optional) object classes ─► spatialised earcons (not safety-grade)
                                                     │
          Tier 1: on-demand (user trigger)
            pick sharpest frame from ring buffer (not capturePhoto)
            ├─ online  ─► face-blur ─► JPEG q80 ─► cloud VLM stream ─► clause chunker ─► TTS
            └─ offline ─► Gemini Nano / Foundation Models ─► TTS
                                                     │
          Tier 2: opt-in "detailed look" / "read whole page"
            capturePhoto (FULL or LARGE, ~4 s on mock) ─► OCR on-device + cloud VLM (Sonnet/Opus) ─► TTS
            (spoken "taking a photo, hold still" covers the wait)
```

### Latency budget: trigger → first spoken word ≤ 1.5 s (Tier 1, online)

| Step | Budget | Basis |
|---|---|---|
| Trigger detect (captouch/button via `mwdat-inputs`, Experimental) | 50 ms | [est] |
| Ack earcon | (parallel, <100 ms) | [est] |
| Frame from ring buffer (stream already running) | 0–30 ms | stream is live. A **cold** stream adds 975 ms (bench), so keep it warm while the a11y mode is on |
| Sharpest-frame pick + face blur + resize + JPEG | 40–80 ms | [est] |
| Upload ~60–120 KB (MEDIUM JPEG) on LTE/Wi-Fi | 100–250 ms | [est] |
| VLM TTFT (Haiku 5.5, thinking off) | 400–800 ms | [est], measure |
| First clause (~10 tokens) | 50–150 ms | [est] |
| TTS `onStart` | 211 ms | bench (phone speaker) |
| BT A2DP output latency | 100–200 ms | [est], unmeasured on HSTN |
| **Total** | **~1.0–1.8 s** | Tight. Achievable only with a warm stream, the smallest fast model, thinking off, and clause streaming |

Levers if over budget: drop to LOW 360x640 (299 tokens) for describe and keep MEDIUM/HIGH for read; pre-open the HTTPS connection (keep-alive/HTTP2) when a11y mode starts; use HFP only when the mic is needed (HFP/A2DP switching costs time); speak the on-device Tier-0 result first ("Sign with text. Reading…") while the cloud request runs.

**Stream frame vs `capturePhoto`:**

| | Stream frame | `capturePhoto` |
|---|---|---|
| Latency | ~0 ms if warm | ~3.9 s (mock); unknown on HW |
| Resolution | ≤720x1280 | up to 4032x3024 |
| Status | GA | Experimental, not shippable |
| Use for | describe, Q&A, signs, currency, barcodes (large) | dense documents, small print, small barcodes |
| Cost | battery/thermal of a running stream (watch `thermalLevel`) | per shot |

## TTS

| Option | Offline | Latency | Rate control | Notes |
|---|---|---|---|---|
| Android `TextToSpeech` (Google Speech Services) | Yes (with voice pack) | 211 ms to `onStart` (bench) | `setSpeechRate()` (1.0 = normal; BLV users often run 2–3×) | Set `AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY` so it mixes with TalkBack and routes like accessibility audio |
| iOS `AVSpeechSynthesizer` | Yes | [est] 100–250 ms | `rate`; or `prefersAssistiveTechnologySettings = true`, which takes VoiceOver's voice, rate and pitch (they **override** your own utterance properties) | Recommended default: mirror VoiceOver's rate |
| Cloud neural TTS (e.g. Gemini Live native audio, OpenAI, ElevenLabs) | No | +200–500 ms network [est] | Varies | Nicer voice, but adds latency and a second privacy surface. BLV power users prefer fast and intelligible over natural. Skip for v1 |
| Screen-reader announcement (`UIAccessibility.post(.announcement)` / Android `announceForAccessibility`) | Yes | Screen reader dependent | User's SR settings | Android **deprecated `announceForAccessibility` in API 36** (interrupts TalkBack). Announcements can't be queued or streamed well. Use only for short status, never for streamed descriptions |

**Coexistence rule:** the app speaks with its own TTS engine (accessibility usage on Android; `prefersAssistiveTechnologySettings` on iOS). It mirrors the screen reader's rate where the platform allows, and offers an in-app rate setting on Android. Long output must not go through SR announcements. The glasses-first flow is phone-in-pocket, so the screen reader may not be focused on our app at all.

## Offline evaluation harness

Goal: the same pipeline code that runs on device scores accuracy and latency with **no glasses**, on the Mock Device Kit locally and in CI.

| Layer | Design |
|---|---|
| `FrameSource` interface | `DatStreamSource` (HW), `MockDeviceSource` (`MockCameraKit.setCameraFeed(videoUri)` with HEVC clips; `setCapturedImage(imageUri)` for photo path), `FileReplaySource` (decode MP4/JPEG directly, JVM/host-only, fastest) |
| `Perceiver` interface | One impl per backend: MLKitOcr, VisionOcr, NanoDescribe, FoundationModelsDescribe, ClaudeVlm, GeminiVlm, … Same prompt templates across clouds |
| `Speaker` interface | Real TTS on device; `NullSpeaker` in CI records the time the first chunk *would* be spoken |
| Datasets | **VizWiz-VQA** (~31k questions from blind users, 10 answers each, *answerable* flag; CC BY 4.0 per catalog [verify]); **VizWiz-Captions** (39k images, 5 captions); **TextVQA** (scene-text Q&A); **ORBIT** (BLV-recorded object videos, good for "find my keys"); **VizWiz-Priv** for testing the private-info and face-blur path; plus our own consented HSTN clips (signs, menus, currency, doorways) once HW arrives |
| Preprocessing | Re-render each still to HSTN geometry (9:16 crop, 360x640 / 504x896 / 720x1280, HEVC round-trip via ffmpeg) so the harness sees glasses-like degradation |
| Metrics | VQA accuracy `min(#matching humans / 3, 1)`; **unanswerable precision** (does it say "I can't tell" on VizWiz unanswerables, i.e. the hallucination check); OCR CER/WER and ANLS; captions: CIDEr plus LLM-judge rubric (salience-first, no hallucinated text, no identification); currency/barcode exact match; latency p50/p95 for each stage (frame → request → TTFT → first chunk); $ per 1k queries from `usage` |
| CI mode | Fixed ~200-item stratified slice. Cloud responses **recorded once and replayed** (cassettes keyed by image hash + prompt + model) so PR CI is free and deterministic; on-device ML Kit runs in an emulator job; nightly job re-runs live cloud calls on the slice and fails on accuracy regression > X pts or p95 TTFT regression > Y ms |
| Output | `bench/a11y/<date>.json` + a table in `notes/bench-a11y-*.md`, in the same shape as `bench-android-native.md` |

Caveat: dataset images are phone photos, not HSTN frames. FOV, mounting height and HEVC artifacts differ, so treat dataset scores as relative (backend A vs B) until HSTN recordings exist.

## Recommended stack

### android-native

| Layer | Pick |
|---|---|
| Frames | Warm stream, MEDIUM 504x896 @ 7 fps HEVC, MediaCodec decode into a ring buffer; LOW when the device is thermally throttled |
| Tier 0 | ML Kit Text Recognition v2 (bundled Latin), ML Kit Barcode, ML Kit Face Detection, MediaPipe Object Detector (EfficientDet-Lite0 int8) every 2nd–4th frame |
| Tier 1 online | Claude Haiku 5.5, thinking disabled, streaming, face-blurred MEDIUM JPEG. Escalate to Sonnet 5.5 (`between_tools`) for Q&A follow-ups. Gemini Flash-Lite as a config-swappable alternative for A/B in the harness |
| Tier 1 offline | ML Kit GenAI Image Description / Prompt API where `checkFeatureStatus` says available; else an OCR-only plus "no connection" message |
| Tier 2 | `capturePhoto` LARGE (dev builds only while Experimental) → OCR + Sonnet 5.5 |
| Product | Open Food Facts lookup with a local cache |
| TTS | `TextToSpeech`, `USAGE_ASSISTANCE_ACCESSIBILITY`, clause-chunked `QUEUE_ADD`, in-app rate (default 1.5×) |

### ios-native

| Layer | Pick |
|---|---|
| Frames | Same stream config (iOS default is 30 fps, so set 7 explicitly). VideoToolbox decode to `CVPixelBuffer` ring |
| Tier 0 | Vision `RecognizeTextRequest(.fast)`, `DetectBarcodesRequest`, `DetectFaceRectanglesRequest` / `DetectHumanRectanglesRequest`; Core ML detector (YOLO-class) for objects |
| Tier 1 online | Same Claude path via URLSession SSE (no official Swift SDK; raw HTTP) |
| Tier 1 offline | Foundation Models with image `Attachment` on supported OS/devices (`SystemLanguageModel.availability`) |
| Tier 2 | Photo → Vision `.accurate` OCR + cloud VLM |
| TTS | `AVSpeechSynthesizer` with `prefersAssistiveTechnologySettings = true`; `UIAccessibility.post(.announcement)` for one-word status only |

## Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | Real HSTN stream latency/fps over BT is unknown; mock numbers may be optimistic | Budget blown | Measure on HW first; keep LOW fallback |
| 2 | Photo capture, Inputs, Speech are **Experimental**, not shippable | Tier 2 and captouch triggers are dev-only | Design trigger fallback via phone (volume key / BT media button / phone UI) |
| 3 | 1.5 s budget relies on estimated VLM TTFT | Feels sluggish | Earcon ack, Tier-0 pre-announcement, measure p95 in the harness |
| 4 | VLM hallucination (wrong denomination, invented text, false "path clear") | User harm or loss of trust | Prompt for "unsure" answers; cross-check currency with OCR; score unanswerable precision in eval |
| 5 | Obstacle detection is monocular, low fps, possibly stale frames | Safety | Present as "awareness", never as a mobility aid; no "clear path" claims; disclaimer in onboarding |
| 6 | Bystander privacy / regional law (GDPR, biometric statutes) | Legal, reputational | Face blur before upload, trigger-only cloud, no storage, no ID |
| 7 | Gemini Nano: device allow-list, foreground-only, per-app quotas, Beta API | Offline tier unavailable on many phones | Feature-detect; degrade to OCR-only |
| 8 | Foundation Models vision: OS version and device floor not yet confirmed | iOS offline tier may not exist on users' phones | `availability` check; treat as optional |
| 9 | Cloud cost spikes if someone wires a continuous loop to the cloud | $ | Hard rate limit (e.g. ≤1 cloud call / 2 s) and per-day budget |
| 10 | Provider retention/ZDR terms vary by model and change (Covered Models) | Compliance | Pin model per plan; re-check terms per release |
| 11 | A2DP ↔ HFP switching when voice Q&A starts | Audio gaps, extra latency | Use DAT Speech (Experimental) or phone mic for questions; keep A2DP for output |
| 12 | TalkBack/VoiceOver double-speaking or interruption | Confusing UX | Own TTS on accessibility stream; no long SR announcements; test with SR on |
| 13 | Dataset domain gap (phone photos vs glasses POV) | Misleading eval scores | Use relative comparisons until consented HSTN clips exist |

## Sources

- Claude vision limits/tokens: https://platform.claude.com/docs/en/build-with-claude/vision
- Claude model IDs, prices, thinking/effort rules: claude-api skill (model table cached 2026-10-06); pricing https://claude.com/pricing
- ML Kit GenAI overview (APIs, status, devices, foreground/quota): https://developers.google.com/ml-kit/genai
- Gemini Nano image latency (Pixel 9 Pro, 2025): https://android-developers.googleblog.com/2025/05/on-device-gen-ai-apis-ml-kit-gemini-nano.html
- ML Kit Text Recognition v2: https://developers.google.com/ml-kit/vision/text-recognition/v2
- MediaPipe Object Detector benchmarks: https://developers.google.com/edge/mediapipe/solutions/vision/object_detector
- Foundation Models image input (WWDC26 session 241): https://developer.apple.com/videos/play/wwdc2026/241
- Apple Vision text recognition sample: https://developer.apple.com/documentation/vision/locating-and-displaying-recognized-text
- AVSpeechSynthesizer + VoiceOver (`prefersAssistiveTechnologySettings`, announcements): https://developer.apple.com/wwdc20/10022
- Android API 36 `announceForAccessibility` deprecation: https://developer.android.com/sdk/api_diff/36/changes/android.view.View
- Gemini image tokens: https://ai.google.dev/gemini-api/docs/image-understanding ; pricing: https://ai.google.dev/gemini-api/docs/pricing
- OpenAI image tokens: https://developers.openai.com/docs/guides/images-vision ; calculator: https://developers.openai.com/api/docs/guides/image-cost-calculator.md
- Claude TTFT data gap: https://artificialanalysis.ai/models/claude-haiku-5-5/providers
- Anthropic retention reporting [secondary]: https://www.theregister.com/a/5293789 , https://www.thestar.com.my/tech/tech-news/2026/08/21/anthropic-plans-to-change-enterprise-data-retention-policy-source-says
- VizWiz-VQA: https://arxiv.org/abs/1802.08218 ; VizWiz-Captions: https://arxiv.org/abs/2002.08565 ; datasets at https://vizwiz.org
- Mock feed injection: `sdks/meta-wearables-dat-android/AGENTS.md:384-410`, `sdks/meta-wearables-dat-ios/AGENTS.md:418`
