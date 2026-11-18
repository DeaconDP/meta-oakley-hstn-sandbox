# Value strategy: from accessibility to everyday use

Written 2026-11-18. Four research passes fed this note: a code audit of how tightly SpeakUp is tied to the glasses, the phone-only competitive landscape, audiences and everyday jobs beyond blind and low-vision users, and business model and distribution. Figures marked **[unverified]** come from secondary sources or a single source. Related: notes/use-cases.md (the catalogue), notes/a11y-prior-art.md, notes/customisation-roadmap.md.

## The short version

1. **Phones first, glasses as the upgrade.** About 9M Meta glasses exist. Phones number in the billions. Meta hasn't opened publishing for glasses apps, and an iOS app linking the DAT SDK is rejected by the App Store. A phone-only app can ship to both stores now.
2. **Lead with jobs, not conditions.** Follow subtitles and OXO Good Grips: name the situation ("deal with your post", "no reading glasses needed", "hands full while cooking"). Keep the accessibility depth as the quality promise underneath.
3. **Sell what nobody else does, not what's free.** Describing a scene, one-off OCR, translation and barcode-to-name are free from Google, Apple and Microsoft. SpeakUp's edge is the workflow around them: every word read honestly, letters triaged into "what do I do and by when", continuous "watch for", reminders that follow on, a log you can trust, hands-free voice, offline and private.
4. **Free core, sponsored and paid extras.** A consumer subscription aimed only at blind users is the weakest model: Envision is winding down at the end of 2026. Keep the reading and safety core free and offline. Charge for extras that cost money or serve a payer who isn't the user (cloud reading, family sharing). Pursue sponsors with a duty to vulnerable customers (banks, energy firms, councils).

## 1. Where the value is

### Audiences (the curb-cut)
| Audience | Size | Their everyday job |
|---|---|---|
| Presbyopia (reading glasses) | ~1.8bn worldwide (Fricke 2018) | Small print: medicine leaflets, receipts, menus, labels |
| Low literacy and numeracy | England 7.1M adults "very poor literacy"; US 28% at Level 1 or below (PIAAC 2023) | Bills and official letters |
| Second-language readers | US 26M limited English; England and Wales ~1–2.8M | Official letters, forms, signs |
| Older adults on many medicines | ~40–50% of over-65s take 5+ | Pills: what, when, did I take it |
| Unpaid carers | UK 5.8M, US 63M | A parent's post and pills, from a distance |
| ADHD adults | England ~2.5M | The unopened-post pile, missed deadlines |
| Hearing loss | UK 18M, worldwide 1.5bn | "What did the announcer say?" |
| Food allergy | US 33M, UK ~2.4M adults | Allergens and changed recipes |
| Everyone with a fridge | every household | "Is this still OK?" (UK households bin 6.6M tonnes of food a year, WRAP) |
| Blind and low vision | the core; RNIB: 9 in 10 can't read medicine or food packaging | Everything above, plus orientation |

### Jobs ranked by frequency × reach × pain
1. **"What is this letter and what do I do?"** 42% of UK people behind on bills ignore warning letters or leave them unopened (FCA 2024). Nobody does read → decide → remind end to end.
2. **"Read this small print"** without hunting for reading glasses.
3. **"Is this still OK to eat, and is it safe for me?"** (dates, allergens, cooking steps)
4. **"Did I take my pills?"** Look at the pack, say "took it", get a log.
5. **"What did they say?"** No current app replays the last 60 s of speech on request.
6. **"Explain this form in my language"**, meaning and next step, not just word-for-word translation.
7. **"Read me the next step"** while cooking or doing DIY.
8. **"Tell me when you see my bus / gate / platform."**
9. **"Help Mum with her post"** (carer mode, with her consent).
10. **"Ask about what I just read"** (define, recap, simplify).

### What keeps people coming back
Utility apps keep roughly 4–5% of users at day 30 (AppsFlyer averages). The exceptions win in two ways. They are **one tap away**: Lens lives in the camera, Chrome and the home button. They also attach to **a trigger that comes with real life**: the post (daily, and there's a pile to clear), pills (same time, same place), meals, the commute, the weekly shop. Habit builders: a memory that pays off later ("2 bills due this week"), a log that makes you feel safe, other people (a carer sees the summary), and honesty, so people trust it with money and medicine.

## 2. Competitive position (phone alone)

| Commodity, free elsewhere | Differentiated, no one found doing it |
|---|---|
| One-off text OCR (Lens, Live Text, Seeing AI) | **Every word, honestly**: LLM readers summarise and invent (AFB AccessWorld 2025, Hadley 2026, UMD CHI study: answers 10× longer than the question) |
| Scene description (Gemini Live, Be My AI, Apple Live Recognition) | **Letter triage**: sender, purpose, amount, deadline, scam signs, then a reminder |
| Translation (Lens, Translate) | **Continuous "watch for"** as a standing on-device trigger |
| Barcode → product (Yuka, Lookout) | **Physical book reading** hands-free with page turns and bookmarks (Microsoft Lens + Immersive Reader retired 2025) |
| Colour, light, currency (Seeing AI, Lookout) | **Label specifics**: expiry against today, your own allergen list, cooking instructions |
| Definitions (any LLM) | **Fully voice-controlled**, short answers, user-paced |
| | **Offline, no ads, no per-feature paywall** (answers the Voice Dream, Speechify and ChatGPT-camera complaints) |

The biggest risk is **Meta and Google shipping generic read-and-describe for free**: Meta AI already reads, describes and captions, and Muse is coming. Our defence is structured, workflow-specific tools that a general assistant won't build: bills and deadlines, logs, sharing, honesty, offline.

## 3. What glasses add, and what they don't
- **For:** no aiming (Lee et al. 2021; Vuzix study of 12 blind users), both hands free with a cane, dog, pan or bag, always ready, head-height view for signs and buses. Focus-group studies report a strong preference for head-worn.
- **Against:** close-up checks at the fingertips are awkward with a head camera. Head-worn assistance apps are opened less often than phone apps ("Eyes on the Palm", CHI 2026). Battery is ~4 h. The camera sits on the left and crops the right edge.
- **So:** one app where the same tools run on either camera, and the user switches mid-task ("use the phone" for a close-up pill check, back to the glasses for the bus).

## 4. Distribution facts (checked 2026-11-18)
- **Meta glasses publishing isn't open.** DAT 1.0 is stable, but the FAQ still says submission is coming "soon". Today: private Beta release channels with invited testers, one third-party app registered at a time in Developer Mode. Planned discovery is a curated catalogue in the Meta AI app, with no published criteria.
- **iOS App Store rejects apps that link DAT** ("since the SDK currently uses the ExternalAccessory framework, it will lead to App Store rejection", docs `build-integration-ios` > Prerequisites). A store-ready iOS app must be a **separate build without the DAT SDK**. Android Play has no equivalent warning.
- **Meta is seeding blind glasses owners:** free Ray-Ban Meta for every legally blind US veteran (130k+ eligible, via BVA, VA Blind Rehab Centers, TechSoup; ACB and Lighthouse Guild partner), 15,000 pairs in Ireland via Vision Ireland, and AI Glasses Impact Grants ($200k Catalyst grants to DAT developers). Their trainers need tools to recommend once the basics are covered: our warmest channel.
- **Other channels:** RNIB Technology for Life, NFB, Guide Dogs, AbilityNet, AppleVis and Double Tap, libraries, Age UK and AARP (letters angle), dyslexia associations.

## 5. Business model

| Model | Evidence | Verdict |
|---|---|---|
| Consumer subscription aimed at blind users | Envision ($100–200/yr Ally Pro) winding down 31 Dec 2026; Voice Dream subscription backlash | Avoid as the main engine |
| Free, funded by a big company | Seeing AI (Microsoft) sets the price users expect: free | Our core must be free |
| Free to users, brands pay | Be My Eyes "Specialized Help" (Microsoft, Google, P&G, banks, Tesco); Aira Access zones (an airport paid $5,000 per 2,500 minutes) | Proven. Fits "understand your letter" for banks and energy firms with FCA Consumer Duty and Priority Services Register obligations |
| Mass-market productivity subscription | Speechify (~$139/yr, 50M+ users claimed), born in dyslexia | Works when sold on speed and convenience, not disability |
| Public funding | UK Access to Work (assistive software, ~106 working days to decide); US VA and state vocational rehab; grants | Supplementary |

**Cloud cost per page** (Anthropic list prices; one page ≈ 2k in, 600 out): Haiku 5.5 ≈ $0.0005, Sonnet 5.5 ≈ $0.01. **OpenAI TTS ≈ $0.027 per page** is the biggest cost, and tts-1 / gpt-4o-mini-tts are reported to shut down on 6 Jan 2027 **[unverified, check OpenAI's page]**. With on-device speech and Haiku, a heavy user costs about $0.30 a month; with Sonnet and cloud speech, about $22.

### Three strategies considered
- **A. Free accessibility core + paid everyday pack.** Goodwill, but thin revenue from blind users alone.
- **B. Phone-first utility, glasses as premium.** Not blocked by Meta, much bigger market, fixes the iOS problem. Crowded, and loses some of the glasses story.
- **C. B2B letter sponsors.** The only proven payer, but slow sales cycles and data-protection reviews.

**Pick: B now, with A's free core, and C as the revenue engine.** Ship phone-only to both stores, free and offline-first. Keep the glasses build in Meta's Beta channel with BVA, Vision Ireland and ACB testers, and talk to Meta's accessibility team about the curated catalogue. Pilot one letter sponsor (a UK bank or energy firm) and apply for grants. Add an optional "Plus" tier priced near cost for cloud reading, family sharing and multi-device, and never take away something that was free.

## 6. Product moves, in order

### V0. Glasses optional (the unlock)
Every Android tool except Ask already gets frames through `PageCamera` (`tools/PageCamera.kt:42-87`), and only `CameraViewModel` talks to DAT. So the tools don't change.
- Android **M (~1–2 weeks):** add `PhoneCamera : PageCamera` (CameraX `ImageAnalysis` + `ImageCapture`) chosen in `ToolHub.Factory` from a "glasses optional" setting. Its link goes straight to streaming, and `deviceSession` is null so voice falls back to the phone mic, which already works. Stop DAT types leaking out of `PageCamera` (`deviceSession`, `connectAndStream(Permission)`), and add a `motion` signal so the book reader can detect page turns without HEVC frame sizes. Bypass the registration gate (`ui/CameraAccessScaffold.kt:102`), make Bluetooth optional (`MainActivity.kt:85`), and skip glasses health, connect narration and reconnecting. Re-tune frame rates and framing checks for phone optics; lock exposure and white balance for the light tool.
- iOS **S–M:** add `PhoneFrameSource : ReadFrameSource` (AVCaptureSession) and bypass `registrationState` in `MainAppView.swift:34`. **Store build is a separate target without the DAT SDK.** iOS only has the Read tool, so the other tools also need porting.
- Phone-specific UX: "hold the phone about 30 cm above the page" guidance, torch on for low light, haptics for framing, and a big-text mirror of what's read (helps presbyopia and low vision). Switch cameras by voice: "use the phone", "use the glasses".

### V1. Letters first (the hero feature)
Grow the mail reader into **"deal with this letter"**: who, what, how much, by when, and any scam signs, then "remind me three days before", and "what's due this week". Add a **plain-English explain** (optional Haiku call on the text only) and **"explain in my language"**. A letters log with an export. This is the most frequent, broadest, most painful job, and nobody does it end to end.

### V2. Daily triggers
Reminders and the medication log (U1 in ROADMAP), food check (expiry against today, your allergens, cooking steps), and "read me the next step" for recipes and manuals. These turn a try-once camera app into a daily habit.

### V3. Carer mode
The user consents and chooses what to share: letter summaries (text, amount, deadline), the medication log, and an "ask a helper" hand-off. Asynchronous, not a video call. The buyer is often the carer, so this suits a family plan.

### V4. Reach
- One-tap and one-word entry points: Android Quick Settings tile, home-screen widget and share target ("read this photo" from any app); iOS Action Button, App Intents, Shortcuts and Back Tap; lock-screen launch.
- Read **images and PDFs from other apps** (screenshots, e-bills, emailed letters) through the share sheet. Same honest reader, no camera.
- Languages: UI and speech beyond English, starting with the largest second-language groups.
- Names and store copy that lead with jobs: "Read it. Sort it. Remember it." Keywords: read mail aloud, scan letters, read small print, expiry date, allergens, plus the accessibility terms.

### V5. Glasses as the premium layer
When Meta opens publishing: hands-free versions of the same tools, "watch for my bus", "what did they say?", and the display mirror on Ray-Ban Display. The beta with Meta-funded blind glasses owners runs meanwhile.

## 7. Guardrails that carry over
- The ground rules in `ROADMAP.md` stay: voice-first, honest, private by default, awareness not safety.
- **Medication:** "reads the label" and "your log", never "identifies your pill" or doses (keeps it out of medical-device territory; FDA enforcement discretion covers user-set reminders, MHRA/EU MDR depend on stated purpose).
- **EU AI Act Article 50** (from 2 Aug 2026): say it's AI, mark synthetic audio where required. SpeakUp is most likely limited-risk **[our reading, not legal advice]**.
- **Letters and carer sharing** handle financial and health data: on-device by default, sharing is explicit, per item, and revocable.
- **Scam signs** are hints ("this has signs of a scam, check with someone you trust"), never a verdict that a letter is genuine. When nothing is found, say "no scam signs found", never "it's genuine".

## 8. Open questions
- When does Meta open publishing, and what does the curated catalogue require?
- Does the Play Store accept the Android app with DAT linked, as the docs imply?
- Does phone-camera OCR at arm's length beat the glasses' 960x1440 in-stream photo for full pages? (Likely yes: re-run `experiments/book-reader-resolution` on phone frames.)
- Will a UK bank or energy firm sponsor "understand your letter"? Who owns vulnerable-customer budgets there?
- OpenAI TTS shutdown date and replacement price; make on-device speech the default either way.

## Sources
- Code audit: `tools/PageCamera.kt`, `camera/CameraViewModel.kt`, `tools/ToolHub.kt`, `tools/GlassesWatch.kt`, `ui/CameraAccessScaffold.kt`, `MainActivity.kt` (Android); `A11y/Read/TextReader.swift`, `Views/MainAppView.swift` (iOS).
- DAT docs: `build-integration-ios` > Prerequisites (App Store warning), `set-up-release-channels`; [Wearables FAQ](https://developers.meta.com/wearables/faq/).
- Meta programmes: [free glasses for blind veterans](https://about.fb.com/news/2026/06/free-ai-glasses-for-every-blind-veteran/), [Vision Ireland](https://vr.org/articles/meta-vision-ireland-15000-ray-ban-glasses-accessibility-2026), [Impact Grants](https://vr.org/articles/meta-ai-glasses-impact-grants-catalyst-developers-2026).
- Competitors: [AFB AccessWorld](https://afb.org/aw/fall2025/meta-glasses-review), [Hadley](https://hadleyhelps.org/blog/meta-glasses-and-vision-loss-7-questions-answered), [UMD/TRAILS](https://www.trails.umd.edu/news/apps-ai-eyes-for-blind-users-fall-short-umd-researchers-find), [Microsoft Lens retirement](https://techcrunch.com/2025/08/08/rip-microsoft-lens-a-simple-little-app-thats-getting-replaced-by-ai/), [Envision letter](https://www.letsenvision.com/blog/all-we-had-as-far-as-we-could), [Be My Eyes 1M](https://www.bemyeyes.com/news/be-my-eyes-reaches-1-million-blind-and-low-vision-users-and-10-million-volunteers/), [Aira plans](https://aira.io/subscriptions/).
- Audiences: [Fricke presbyopia](https://www.aao.org/editors-choice/study-reveals-significant-worldwide-burden-from-un), [PIAAC 2023](https://nces.ed.gov/surveys/piaac/2023/national_results.asp), [FCA Financial Lives 2024](https://www.fca.org.uk/publication/financial-lives/financial-lives-cost-of-living-jan-2024-recontact-survey-findings.pdf), [Carers UK](https://www.carersuk.org/policy-and-research/key-facts-and-figures/), [AARP 2025](https://www.aarp.org/pri/topics/ltss/family-caregiving/caregiving-in-the-us-2025/), [RNID](https://rnid.org.uk/2024/06/why-the-number-of-people-with-hearing-loss-has-increased/), [FARE](https://www.foodallergy.org/media-room/statement-sung-poblete-rn-phd-ceo-fare-regarding-33-million-individuals-united-states), [WRAP](https://www.wrap.ngo/resources/report/deep-dive-household-food-waste-uk-2022-reasons-patterns-and-opportunities-change), [RNIB reading research](https://www.rnib.org.uk/professionals/research-and-data/reports-and-insight/reading-and-braille-research/).
- Glasses vs phone: [Lee et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC8855357/), [arXiv 2505.19325](https://arxiv.org/pdf/2505.19325), [Eyes on the Palm](https://doi.org/10.1145/3772318.3791659), [glasses sales](https://www.uploadvr.com/meta-essilorluxottica-sold-7-million-smart-glasses-in-2025/).
- Business: [Speechify](https://en.wikipedia.org/wiki/Speechify), [OXO](https://en.wikipedia.org/wiki/OXO_(kitchen_utensils_brand)), [AppsFlyer-based retention](https://sendbird.com/blog/app-retention-benchmarks-broken-down-by-industry), [NAO Access to Work](https://www.nao.org.uk/wp-content/uploads/2026/02/the-access-to-work-scheme.pdf), [FDA enforcement discretion](https://www.fda.gov/medical-devices/device-software-functions-including-mobile-medical-applications/examples-software-functions-which-fda-will-exercise-enforcement-discretion), [EU AI Act deadlines](https://www.technology.org/2026/10/13/eu-ai-act-deadlines-after-the-digital-omnibus-what-applies-from-december-2026-to-august-2028/).
