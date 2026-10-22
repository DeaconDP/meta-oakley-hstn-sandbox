# Accessibility prior art: camera glasses and phone apps for blind and low-vision (BLV) users

Researched 2026-10-22 by web search. Dates are given per item. "Unverified" means the search found no primary source for the claim. Companion to `notes/hstn-capabilities.md` (DAT 1.0 surface) and `notes/a11y-sdk-mapping.md`.

## 1. Existing products

### 1a. Landscape

| Product | What it does (as of date) | Gap that remains | Source |
|---|---|---|---|
| **Meta AI on Ray-Ban/Oakley Meta** (built in) | "Hey Meta, look and describe / read". Short answers by default. **Detailed responses** toggle (2025, US/CA first, wider since) adds spatial layout, colours, and signage. **Live AI** (continuous session, early access 2025). Screen reader on Ray-Ban Display (2025). | Turn-based. Summarises text instead of reading it verbatim unless asked to read "every single word". Hallucinates spatial layout (a lamp placed left, then right). Not reliable for crossings. Camera sits on the left, so the right side of a page gets cut off. Many features are US/CA only. Verbosity is only on/off. | [UploadVR](https://www.uploadvr.com/ray-ban-meta-glasses-meta-ai-detailed-responses-blind-low-vision/), [Meta a11y page](https://www.meta.com/ai-glasses/accessibility/), [AFB AccessWorld review, Fall 2025](https://afb.org/aw/fall2025/meta-glasses-review), [VI Ireland](https://vi.ie/meta-glasses-get-some-useful-software-updates-for-blind-and-vision-impaired-users/), [AppleVis Live AI, Mar 2025](https://applevis.com/comment/185316), [AppleVis Display review](https://applevis.com/comment/205250) |
| **Be My Eyes** on Meta glasses | "Hey Meta, Be My Eyes" starts a hands-free **volunteer** call (Sep 2024). Mar 2026 (CSUN): hands-free calls to trusted contacts and to brand service desks (Tesco, Sony, Amtrak, Hilton). | **Be My AI (the GPT-based describer) does not run through the glasses**: only human calls do (AFB, Fall 2025). Needs a human to be available. | [BME + Meta, Mar 2026](https://www.bemyeyes.com/news/be-my-eyes-and-meta-launch-new-accessibility-functions/?lang=el), [Meta help](https://www.meta.com/help/ai-glasses/1524316621830425/), [BME support](https://support.bemyeyes.com/hc/en-us/articles/29751558947985-Call-a-volunteer-with-Meta-AI-Glasses) |
| **Aira** | Paid professional visual interpreters. Hands-free on Meta glasses via the Aira Explorer app (voice-start Mar 2026, announced April 2026). This replaced the earlier WhatsApp workaround. | Cost and minutes. Human-in-the-loop latency. | [Airacast Apr 2026](https://airacast.pinecast.co/episode/4467cc70/april-2026-aira-with-ai-glasses-from-meta-is-here-), [Double Tap 2024 pilot](https://doubletaponair.com/aira-introduces-pilot-programs-with-meta-ray-ban-and-arx-smart-glasses/) |
| **Seeing AI** (Microsoft) | Phone app with channels: short text, documents, products/barcodes, people, scenes, currency, colour, light. Named a DAT launch partner (Sep 2025): "hands-free use has been a top customer request". | **We found no evidence of a shipped glasses integration as of Oct 2026 (unverified).** Expect it to land, so a generic "Seeing AI on glasses" demo would duplicate it. | [Meta DAT blog, Sep 2025 / Dec 2025](https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/), [Double Tap](https://doubletaponair.com/seeing-ai-meets-meta-smart-glasses-hands-free-accessibility/) |
| **HumanWare** | Named DAT partner (quote only). | No product announced. | DAT blog above |
| **Envision Glasses / Ally / Ally Solos** | Envision Glasses (Google Glass EE2, $1,899–3,499, 2020). Ally conversational assistant (multi-model: Llama, GPT, Gemini, Perplexity). Ally Solos glasses ($399 pre-order, Aug 2025). | **Envision announced a wind-down on 2026-10-05**: product development stops at year end unless a partner is found. Users had reported pairing and reliability complaints in 2025. Lesson: dedicated BLV hardware struggles commercially against Meta and Apple. | [The National, Oct 2026](https://www.thenationalnews.com/future/technology/2026/10/06/envision-glasses-shut-down/), [Envision blog](https://letsenvision.com/blog/ally-solos-glasses), [AppleVis](https://applevis.com/comment/200558) |
| **Google Lookout** (Android) | Modes: text, documents, food labels, currency, explore. Image Q&A (2023, RNIB co-tested) upgraded to Gemini 1.5 (Dec 2024). | Phone only, no glasses path. We found no 2025–26 update. | [TechCrunch Dec 2024](https://techcrunch.com/2024/12/05/googles-latest-feature-drop-includes-new-gemini-extensions-and-accesiblity-features), [9to5Google](https://9to5google.com/2023/05/18/lookout-image-qa/) |
| **OKO** (AYES) | Phone back-camera AI reads the pedestrian signal and gives audio and haptic cues. Offline, needs no infrastructure. Good Design 2023. | Safety-critical. Phone held up. Availability is regional. Sources are 2021–2023; current status unverified. | [Good Design](https://good-design.org/projects/oko-ai-copilot-for-blind-and-visually-impaired/), [EU road-safety charter](https://road-safety-charter.ec.europa.eu/content/oko-revolutionary-pedestrian-crossing-app-0) |
| **NaviLens** | High-contrast fiducial codes readable at about 12 m in pilots (vendor claims 30 m+), at a 160° angle, while moving, without aiming. Deployed in transit (NYC MTA, Intercity Transit, VIA). | Needs installed codes and a phone pointed at them. **We found no glasses integration (unverified).** A licensed SDK is required to decode NaviLens codes. | [navilens.com](https://navilens.com/en/technology), [Intercity Transit](https://intercitytransit.com/how-to-ride/navilens) |
| **Soundscape → VoiceVista** (and other forks) | Microsoft open-sourced Soundscape in Jan 2023. VoiceVista (iOS, free) uses 3D spatial audio for callouts of streets, intersections, and POIs, plus beacons. It works globally and is VoiceOver-accessible. | GPS only, with no camera awareness (doors, signs, last-10-metres problem). Phone-heading based. | [App Store](https://apps.apple.com/app/id6450388413), [AppleVis](https://applevis.com/comment/149533), [AppleVis Soundscape EOL](https://applevis.com/comment/142619) |
| **Celeste** glasses | Small-startup camera glasses (2024). | Long waits, refunds. Status unverified. | [AppleVis 2024](https://applevis.com/comment/164228) |
| **WhatsAI** (research) | Hackable template that pipes Ray-Ban Meta via WhatsApp to custom VLM, OCR, and detection, aimed at BLV hackers (arXiv, May 2025). | Pre-DAT workaround with no evaluation. DAT makes it obsolete, but its "disability-led, extensible" ethos is worth keeping. | [arXiv 2505.09823](https://arxiv.org/abs/2505.09823) |

Context: Meta's AI Glasses Impact Grants (Jul 2026) fund BLV *training and distribution* (ACB, Braille Institute, Carroll Center, VisionCorps, PACER lending library) rather than BLV software ([PDF](https://about.fb.com/wp-content/uploads/2026/07/AI-Glasses-Impact-Grant-Recipient-List.pdf)). These organisations are natural recruiting partners. Connect 2026 (Sep 23) added hearing enhancement and mono or balanced audio but no BLV features ([Meta](https://www.meta.com/blog/meta-connect-2026-everything-we-announced/)). Meta is also pushing the Muse agent onto glasses "in coming months".

### 1b. What a third-party DAT app can add vs. duplicate

DAT gives a camera stream and photos, the mic, speakers (over OS Bluetooth), IMU, inputs, and device state. It does **not** give Meta AI or "Hey Meta". Voice invocation, speech, inputs, motion, and photo are Experimental in 1.0 (see `hstn-capabilities.md`).

| Duplicates (avoid as a headline demo) | Under-served (DAT app can do; Meta AI can't or won't) |
|---|---|
| One-shot "describe the scene" / "what am I holding" | **Verbatim, complete reading** with on-device OCR, per-line confidence, and *aiming feedback* ("text cut off on right, turn head right") |
| Calling a sighted human (BME, Aira already hands-free) | **Proactive, continuous watch-for-X** ("tell me when you see exit sign / my bus number / my keys"), with earcons and no repeated prompting |
| Generic Live AI chat | **User-tunable verbosity** (more than on/off): hurry mode, levels, speech rate, interruptible output |
| Translation, captions | **Explicit uncertainty and abstention** ("I can't read the dose, retake closer") instead of confident guessing |
| | **IMU-anchored spatial audio**: head-relative object or text cues and beacons (a camera-aware VoiceVista) |
| | **Structured domain readers**: appliance displays, thermostat or oven LCDs, receipts, mail sorting, with deterministic parsing |
| | **Fiducial and code detection at a distance** (QR now; NaviLens if licensed) hands-free while walking |
| | **Offline or on-device mode** with no cloud upload of bystanders, plus local logs for evaluation |
| | **Personal or teachable objects** (ORBIT-style few-shot "find *my* white cane / *my* mug") |

## 2. What BLV users report

| Theme | Evidence |
|---|---|
| **Hallucination / trust** | CHI'26 diary study (n=20, 2 weeks): users rated the app trustworthy (3.76/5) yet answers were **wrong 22.2%** of the time, with 10.8% abstentions ([arXiv 2602.13469](https://arxiv.org/abs/2602.13469)). ASSETS'24 "Misfitting with AI" (n=26): errors are hard to verify non-visually, and users cross-check across apps or humans ([arXiv 2408.06546](https://arxiv.org/abs/2408.06546)). ACL'25 (Søgaard et al., 13 models): confident answers on insufficient images, poor abstention, weak on Braille and assistive devices, worse in non-English ([ScienceNews.dk, Apr 2026](https://www.sciencenews.dk/en/when-ai-sounds-certain-blind-users-have-to-trust-it-even-when-it-is-guessing)). |
| **Dynamic and navigation scenes** | ASSETS'25 ChatGPT live video (n=8): good for static scenes, **fails in dynamic ones**. Distances are inaccurate. Sycophancy and assumptions about the user's vision cause distrust and risk. It needs proactive intervention timing, not just turn-taking ([arXiv 2508.03651](https://arxiv.org/abs/2508.03651)). AFB: "cannot replace a white cane", not accurate for crossings. |
| **Verbosity / control** | CHI'26 "Say It My Way" (n=11, 418 interactions): responses are about 10× longer than queries, there are **no verbosity controls**, little camera-framing guidance, and spatial and temporal estimation is poor. Users want control that adapts to context and time pressure ([arXiv 2602.16930](https://arxiv.org/abs/2602.16930)). Meta defaults to brevity so it doesn't block hearing (UploadVR). |
| **Turn-taking / interruption** | TouchScribe (CHI'26): photo-then-ask flow is verbose and breaks tactile exploration. LifeInsight (CHI'25): single-click goal-oriented queries on a wearable worked, n=13 ([alexandria.unisg.ch](https://alexandria.unisg.ch/handle/20.500.14171/121982)). |
| **Framing / aiming** | Left-mounted camera crops the right side (AFB). Lack of camera guidance (Say It My Way). |
| **Latency** | "Fairly quick but not instantaneous" (AFB). Live scenes need sub-second updates to be useful (ASSETS'25). |
| **Battery** | About 4 h moderate use on Ray-Ban Meta Gen 1 (AFB). Gen 2 claims about 8 h ([Wareable](https://www.wareable.com/wearable-tech/ray-ban-meta-gen-2-smart-glasses-price-features-upgrade)). Continuous streaming will be far worse, so plan duty cycling. |
| **Availability / setup** | Features are "only US and Canada". Setup tours are inaccessible to screen readers ([AppleVis, Aug 2026](https://applevis.com/comment/214222), [AppleVis Display](https://applevis.com/comment/205250)). |
| **Usefulness by vision level** | Guide Dogs Victoria clients: "not helpful when fully blind" for some users, great for barcodes for others ([ADA Southeast](https://adasoutheast.org/meta-ray-bans-blind-users-experience-with-smart-glasses/)). Low-vision and blind users want different things. |
| **Social / bystander** | Akter et al. ASSETS'20 (n=128 VI + 136 sighted): VI users are fine getting bystander info but uneasy about inferred weight and gender, and both groups fear AI misrepresenting bystanders ([PDF](https://homes.luddy.indiana.edu/kapadia/papers/akter-assets20.pdf)). |
| **Episodic use** | Users wear or invoke assistance when needed rather than always on ([The Pen, arXiv 2603.06564](https://arxiv.org/pdf/2603.06564)). |
| **Positive** | Hands-free is the top request (Seeing AI quote). Menu reading feels like "magic glasses" (AFB). Rich descriptions are valued more than sighted helpers' terse ones, which also makes hallucinations more believable. |

## 3. Audio-first UX guidelines

| Principle | Concrete rule for this sandbox |
|---|---|
| **Earcons before speech** | A short distinct tone for state changes: listening, capturing, working (soft tick every ~1 s while waiting), done, error, low confidence. Earcons are faster than words and don't collide with VoiceOver speech. Keep them under 300 ms and give each a different contour. |
| **Never silent** | Every input gets acknowledgment within 200 ms (earcon). Every failure is spoken with a cause and a next step ("Glasses disconnected, hinges closed", "Too dark, try light"). Watchdog: if no result within N s, say so. |
| **Verbosity levels** | At least 3 levels (terse, normal, detailed) plus one-shot "more" and "hurry" commands. Lead with the answer, then the detail ("Exit sign, ahead slightly left. More?"). |
| **Speech rate** | User-set and independent of system rate. Expert screen-reader users listen far faster than sighted norms (mean about 298 wpm-equivalent in Bragg et al. TACCESS 2021, rising with experience). Comprehension holds at 350 wpm for experts ([CHI'18 PDF](https://wildlab.cs.washington.edu/Publications_files/Bragg_CHI2018.pdf), [TACCESS](https://homes.cs.washington.edu/~dkbragg/papers/Expanding_a_Large_Inclusive_Study.pdf)). Default to the OS rate. |
| **Barge-in / interruptibility** | Any tap or "stop" cuts speech immediately and keeps the result in a "repeat last" buffer. Queue priority: safety > user-requested > ambient. Ambient callouts are dropped, not queued, if stale (more than 2 s old). |
| **Spatial audio** | Use IMU yaw to pan cues head-relative (clock-face wording as fallback: "2 o'clock"). Note that HFP is mono and A2DP is stereo, and they are mutually exclusive (`hstn-capabilities.md`). The mic-via-HFP path kills stereo panning, so use DAT in-band mic audio or phone mic when panning matters. |
| **Coexist with VoiceOver / TalkBack** | Detect the running screen reader. Offer "speak via screen reader" (UIAccessibility announcement / TalkBack announcement) vs. own TTS, and avoid double-speaking. Duck, don't pause, others. Don't steal focus. Respect the screen reader's mute. |
| **Uncertainty reporting** | Use calibrated verbal hedges tied to scores ("probably", "can't tell"). Report *what* is uncertain ("dose number unreadable") and a remedy (closer, more light, rotate). Abstain rather than guess on numbers, medications, and money. |
| **Framing guidance** | Before reading, run a cheap on-device check for text present, edge-cropped, blur, or dark, and give directional hints. Compensate for the left-mounted camera. |
| **Hands-free input map** | Map captouch tap / swipe / capture button (Experimental Inputs) to stop, repeat, more, mode. Always mirror these on the phone and with voice. |
| **Low vision (companion app)** | Meet [WCAG 2.2 AA](https://www.w3.org/TR/WCAG22/): 4.5:1 contrast, 200% text resize and Dynamic Type / font scale up to the largest accessibility sizes without truncation, 24×24 px minimum targets (2.5.8), focus not obscured (2.4.11), no drag-only actions (2.5.7). Offer a high-contrast or inverted theme, reduced motion, and a large-print live transcript of what was spoken. Optional on-phone magnifier view of the last glasses frame (pinch zoom plus contrast and inversion filters). |

## 4. Ethics, safety, legal

| Topic | Position |
|---|---|
| **Mobility** | Never claim to replace cane, dog, or O&M training. AFB and ASSETS'25 both show spatial and distance errors. Avoid pedestrian-signal or "safe to cross" output. If any obstacle or nav feature is demoed, label it "orientation aid, not a mobility aid". VoiceVista frames itself the same way. |
| **Face recognition** | **Out of scope.** Meta's own "Name Tag" plan (NYT Feb 2026, WIRED code finding Jun 2026) drew an EPIC FTC complaint and a letter from 70+ groups including the ACLU ([EPIC](https://epic.org/epic-urges-ftc-states-to-block-metas-facial-recognition-smart-glasses-plan/), [Computing](https://www.computing.co.uk/news/2026/meta-explores-facial-recognition-smart-glasses)). Illinois **BIPA** (740 ILCS 14) requires written consent before collecting face geometry, with a private right of action. Texas CUBI and Washington have similar laws. **GDPR Art. 9**: biometric data for unique identification is special-category, and bystanders can't consent. **EU AI Act Art. 5** (applies from 2 Feb 2025): bans untargeted face scraping to build databases (5(1)(e)), biometric categorisation inferring sensitive traits (5(1)(g)), and law-enforcement real-time RBI (5(1)(h)). We found no accessibility exemption ([FPF](https://fpf.org/blog/red-lines-under-the-eu-ai-act-understanding-the-ban-of-the-untargeted-scraping-of-facial-images-and-facial-recognition-databases/)). Also avoid inferring gender, age, weight, or emotion of bystanders (Akter et al.). "A person is ahead" is fine. |
| **Bystander data** | Process frames ephemerally. No cloud upload of frames by default, or blur faces before upload. Keep the capture LED behaviour intact. Don't log raw frames from field tests without consent. |
| **Medication / money / food safety** | High-stakes categories (the CHI'26 diary study saw users do exactly this). Read verbatim, never infer. Abstain if any digit has low confidence. Say "verify with pharmacist / second source" for meds. Currency: deterministic recogniser or abstain. |
| **Disclaimers** | Spoken once at first run and available on demand. Written in the app and README: experimental sandbox, may be wrong, not a medical or mobility device. No disclaimer spam on every answer, which users hate. Hedge only when uncertain. |
| **Dependency / availability** | Envision's shutdown shows users get stranded. Keep the sandbox open-source and document offline fallbacks. |

## 5. Evaluating with BLV people

- **Co-design**: "Nothing about us without us". Involve BLV people from problem selection onward, not just at final testing. Envision and Meta both cite BLV co-designers. Credit contributors. Disability scholars note people are often recruited without benefit ([arXiv 2407.19351](https://www.arxiv.org/pdf/2407.19351)).
- **Pay** participants at professional rates (expert users are domain experts). Use accessible payment (e-gift or bank transfer, not inaccessible portals). Cover travel and sighted-guide time.
- **Recruit** via NFB and ACB chapters and listservs, Braille Institute, Carroll Center, local VI agencies, AppleVis, and r/Blind. Several of these are Meta grant recipients already training users on Meta glasses. Balance totally blind vs. low vision, congenital vs. acquired, and screen-reader expertise.
- **Accessible consent**: screen-reader-tested HTML (not a scanned PDF), large print, Braille on request, and recorded verbal consent ([UNMC IRB guide](https://guides.unmc.edu/attachments/53?open=true)). Explain camera and bystander capture plainly. Allow withdrawal of recordings.
- **Protocols seen in the literature**: lab tasks (ASSETS'25: locate objects, recognise landmarks), 1–2 week diary studies (CHI'26), and in-situ query logs (Say It My Way). Use orientation-and-mobility-safe settings, and have a sighted safety spotter for any walking task.

| Metric | Use |
|---|---|
| Task success (binary or graded) and time-on-task | Primary outcome per task |
| **Error rate split**: wrong-answer vs. abstention vs. correct | The ACL'25 and CHI'26 framing. Track "confidently wrong" separately |
| Number of turns / retakes to success | Captures framing and verbosity cost |
| Speech seconds per task, interruptions used | Verbosity burden |
| SUS (usability), NASA-TLX (workload), trust scale (e.g. 5-pt, as CHI'26) | Standard post-task questionnaires |
| End-to-end latency (input → first earcon → first word) | Instrumented, from the existing benchmark harness |
| Battery drain per hour per mode | Device state API |

**Offline benchmark datasets** (no participants needed, for regression-testing OCR and description quality):

| Dataset | Content | Use here |
|---|---|---|
| [VizWiz](https://vizwiz.org/) VQA (31k+ blind-taken photos + spoken questions, 10 answers each), VizWiz-Captions, answer grounding, **VizWiz-Priv** | Real blind photography: blur, crop, unanswerable | Accuracy **and abstention** on unanswerable items. Privacy-region detection |
| VizWiz-LF (COLM 2024): 4.2k long-form answers to 600 questions | Expert vs. model long answers. Hallucination on unanswerable items | Long-form and verbosity quality ([arXiv 2408.06303](https://arxiv.org/abs/2408.06303)) |
| [ORBIT](https://github.com/microsoft/ORBIT-Dataset) (Microsoft): blind-collected videos of personal objects | Few-shot teachable recognition | "Find *my* object" demo |
| Say It My Way dataset (CHI'26) | Conversational VQA interactions by blind users | Multi-turn and verbosity evaluation |
| Søgaard et al. ACL'25 test suite | Packaging, messages, Braille, assistive devices, video. Includes insufficient-info items | Abstention calibration |

Caveat: these are phone photos, not head-worn. Glasses framing (eye-level, left-offset, 9:16 at 504×896 default) differs, so collect a small consented HSTN set to calibrate.

## Implications for this sandbox

1. **Don't build "describe the scene" or "call a human".** Meta AI (with Detailed responses), Be My Eyes, Aira, and soon Seeing AI cover these. Our value is in what turn-based assistants structurally don't do.
2. **Demo A: Verbatim reader with aiming guidance and confidence.** On-device OCR on DAT photo or stream, with live "text cut off right / too dark / closer" earcon guidance. Reads every word. Flags low-confidence digits and abstains on dose and money. This directly targets the top complaints: summarising, cropping, hallucination.
3. **Demo B: Proactive "watch for X".** Continuous low-fps stream with an on-device detector or OCR for a user-named target (sign text, bus number, QR or NaviLens-style code, a taught personal object), using geiger-style earcons and IMU-panned direction. It needs no repeated prompting, which is the gap the ASSETS'25 paper calls out.
4. **Demo C: Head-relative spatial cues.** Fuse IMU yaw with detections for clock-face and stereo-panned callouts. Frame it as orientation, never mobility. No crossing or obstacle-safety claims.
5. **Make the UX layer the showcase, shared by all demos**: earcon vocabulary, 3 verbosity levels plus "more" and "hurry", user speech rate, instant barge-in plus "repeat", never-silent failures (disconnect, hinge closed, thermal, low battery from device state), and screen-reader-aware speech routing.
6. **Companion phone app as a WCAG 2.2 AA exemplar**: VoiceOver and TalkBack first, Dynamic Type at max sizes, high contrast, large-print transcript, and a magnifier of the last frame for low-vision users.
7. **Privacy by default**: no face ID, no bystander attribute inference, on-device first, no frame retention. Write this into the README as a design commitment.
8. **Evaluation plan from day one**: VizWiz-based offline harness scoring correct, wrong, and abstain plus latency, then a small paid co-design round recruited via ACB, NFB, or Braille Institute. Measure task success, turns, SUS, NASA-TLX, and trust.
