# Use-cases: what glasses are good for, and what SpeakUp should build next

Written 2026-11-18. Three research passes fed this note: what DAT's display API allows on Meta Ray-Ban Display, a broad survey of smart-glasses use-cases in products and research, and deep dives on four priority areas (navigation, captions, awareness alerts, reminders). Vendor numbers are marked **[vendor]**. Anything not checked against a primary source is marked **[unverified]**.

**Idea.** Glasses win in two cases. The first is **hands-free**: camera, mic and speakers at head height while the hands hold a cane, a pan, a bag or a handrail. The second is **heads-up**: a glance at a lens instead of pulling out a phone, which only display glasses offer. HSTN covers only the first. Meta Ray-Ban Display covers both. SpeakUp stays audio-first on every device, and the display mirrors the audio, the same way the phone screen does today.

## 1. What each device can do

| | Oakley Meta HSTN (now) | Meta Ray-Ban Display (later) |
|---|---|---|
| Output | Open-ear stereo over A2DP. No display | The same audio, plus a **600×600 full-colour display, right eye only**, about 20° field of view **[unverified, third-party spec]** |
| Display API | none | `mwdat-display`, **GA since 0.7.0** (`sdks/meta-wearables-dat-android/CHANGELOG.md:112-118`). Needs the DAM app model (`DAM_ENABLED` meta-data) |
| What it can draw | n/a | `flexBox`, `text` (3 sizes, 2 colours only), `icon` (fixed set), `image` (URL or Bitmap, ≤600 px), `button`/`buttonGroup`, MP4 `video` (<400 px per side). Each `sendContent` **replaces the whole screen**, with vertical scroll only. A two-finger temple tap ends the display session |
| Input | Experimental `Inputs` (capture button, captouch) | GA: taps on display buttons. Experimental: Neural Band `Nav`/`Select`/`Drag` |
| Unknowns | per-temple stereo, mic channels | **whether the camera stream and display can run in one session at once**, update latency, sleep timeout |

Glasses **web apps** (Chromium on the Display glasses) get full HTML layout but **no camera and no mic** ("only the Device Access Toolkit can use the glasses' camera or capture microphone audio"). They don't suit SpeakUp's camera-and-voice core. A hybrid (phone app processes, web app shows the result) has no documented link between the two, so we skip it for now.

## 2. What Meta, Apple and Google already cover (don't duplicate)

- **Ray-Ban Display:** walking, cycling and transit navigation with a map; **live captions** of speech aimed at the wearer, and captions for calls; live translation; messaging; teleprompter; camera viewfinder with 3× zoom; reminders, calendar and weather widgets; mirrored phone notifications; screen reader and magnification settings **[magnifier unverified]**.
- **All Meta glasses:** detailed responses, Be My Eyes and Aira calls, Conversation Focus (boosts the voice in front of the wearer on HSTN; may conflict with our use of the mic **[unverified]**), and Garmin and Strava stats.
- **Phone OS:** Apple Sound Recognition and Name Recognition (iOS 26), Android Sound Notifications and Live Transcribe, OS reminders.

SpeakUp's angle stays the same as in `ROADMAP.md` > Positioning: word for word, says when it can't tell, user-paced, voice-first, private, and built around a blind user's needs rather than a sighted default.

## 3. The catalogue

Key: **A** = works audio-only (HSTN), **H** = needs a HUD, **A+H** = audio, better with a HUD. **Fit** = how well it suits SpeakUp (★★★ build soon, ★★ later, ★ only as a research flag, ✗ out of scope).

### Navigation and orientation
| Use-case | | Fit | Notes |
|---|---|---|---|
| "Where am I?" (address, nearest junction, rough heading) | A | ★★★ | Phone GPS plus reverse geocoding. GA |
| Markers and "take me back" (café, bus stop, front door) | A | ★★★ | GPS breadcrumbs, a clock-face bearing on request |
| "Is this my bus?" (due time from transit data, number confirmed by the camera) | A | ★★★ | GTFS-realtime plus the existing watch-for-text |
| Soundscape-style callouts (streets, places, a beacon tick) | A | ★★ | VoiceVista and Soundscape Community are open source (MIT). Head-following pan needs Motion (Experimental) |
| Turn-by-turn walking | A+H | ★★ | Routes API or OSM. Meta already does it on Display |
| Rideshare check ("is this my Uber?": make, colour, plate) | A | ★★ | Seleste's most-praised feature. Plate is text, so watch-for-text reuse |
| Indoor wayfinding | A | ★ | Needs a partner (GoodMaps, NaviLens SDK licence) |
| Crossing help (pedestrian signal state) | A | ✗ | Ground rule: never says when to cross |
| Guide-dog-style head pull (.lumen) | haptic | ✗ | A mobility aid |

### Hearing, captions and listening help
| Use-case | | Fit | Notes |
|---|---|---|---|
| "What did they say?" replay of the last 60 s (announcements, a mumbled number) | A | ★★★ | Phone on-device ASR, kept in memory only. Numbers read digit by digit with a hedge |
| Name-called alert (clinic waiting room) | A+H | ★★★ | Keyword spotting on the same transcript |
| Sound recognition (alarm, doorbell, siren, kettle, knock) | A+H | ★★★ | MediaPipe + YAMNet (521 classes, on-device). Phone mic GA, glasses PCM Experimental |
| Spoken translation of what someone says | A | ★★ | Meta already does it; only worth it if fully on-device |
| Live captions in the lens (deaf, hard of hearing) | H | ★ | Meta ships this. Ours only adds value with something Meta lacks (braille out, phone media captions, stored phrase list) |
| Captions to a braille display (deaf-blind) | A | ★★ | Transcript into TalkBack/VoiceOver. Nobody else does this on glasses |
| Speaker direction ("voice on your left") | A+H | ★ | Needs a multi-channel mic; not confirmed for HSTN |
| Conversation recap ("what did the doctor say?") | A | ★ | Consent law, and an obvious recording cue needed |

### Awareness alerts (formerly "threat warnings")
Split by speed. Slow, static checks on text we already read are reliable. Fast, dynamic hazards are not, and they collide with "Awareness, not safety" (see `ROADMAP.md` > Ground rules).

| Use-case | | Fit | Notes |
|---|---|---|---|
| Expiry date check ("use by 12 November, 6 days ago") | A | ★★★ | Labels tool. Abstain if the date is unclear |
| Allergen check against the user's own list | A | ★★★ | Labels tool. Abstain if the text is cut off |
| Scam signs in a letter (urgent payment, gift cards, "final notice") | A | ★★★ | Mail tool, fixed rules on the phone. "Check with someone you trust" |
| Siren, smoke alarm, horn heard nearby | A+H | ★★ | Same YAMNet path as sound recognition. No direction claim |
| "Is the hob on?" on request | A | ★★ | Light tool glow check; reading appliance displays needs a seven-segment model (already in Later tools) |
| Head-height obstacle ahead (branch, open van door) | A | ★ | The one dynamic case an eye-level camera sees and a cane misses. Experimental demo only, measured on misses and false alarms |
| Approaching vehicle or bike | A | ✗ | At 10 m/s a 1.5 s pipeline means 15 m travelled; the camera can't see sideways or behind |
| Step, kerb or drop | A | ✗ | The forward camera sees the ground poorly; single-camera depth is unreliable |
| Glasses heat and battery | A | done | Pitfalls in ToolHub |

### Reminders and memory
Note: SpeakUp has **no user-facing reminders yet**. `IdleNudge` only drives the silence prompts inside a tool. This is a new tool on ToolHub.

| Use-case | | Fit | Notes |
|---|---|---|---|
| Time reminders ("at 6, call Mum"), spoken on the glasses when worn | A+H | ★★★ | AlarmManager/WorkManager, `UNUserNotificationCenter`; `donState` decides glasses or phone. Top-ranked feature for older adults with cognitive impairment (JMIR Aging 2026, n=26) |
| Notes and "what was I doing?" | A | ★★★ | Log of tool actions and spoken notes. No frames stored |
| Medication log ("did I take my evening pill?" → "you said so at 7:12") | A | ★★★ | Never says or changes a dose |
| Routine checklists ("leaving the house": keys, lights, hob) | A+H | ★★★ | Ticked off by voice; can call the Light tool |
| Place reminders ("when I get to Tesco") | A | ★★ | Geofencing, about a 100 m minimum radius **[unverified]** |
| Text-triggered ("when you see Boots, remind me…") | A | ★★ | Watch-for-text with a payload. Only while a stream runs |
| "Where did I put my keys?" | A | ★★ | Ego4D-style episodic memory. Spoken notes first, camera-based later (EgoTrigger: sound-triggered capture, 54% fewer frames) |
| Object-triggered ("when you see the kettle") | A | ★ | Needs a detector; "kettle" probably isn't a COCO class |
| Pill check against the user's own photographed list | A | ★★ | A second check, never dosing advice. Look-alike pills make errors dangerous |
| Person-triggered ("next time Sam is near…") | A | ✗ | Close to identifying people |

### Everyday tasks
| Use-case | | Fit | Notes |
|---|---|---|---|
| Kitchen companion: step tracking, "is it browned?", "did I add the salt?" | A+H | ★★ | Four 2025 ASSETS, CHI and UIST papers (OSCAR, AROMA, Vid2Coach). Steam and hands block the view |
| Step-by-step coach from a manual or video (flat-pack, appliance setup) | A+H | ★★ | Reuses the reading pipeline |
| Hand-off to a human (trusted contact, Aira, Be My Eyes) | A | ★★ | One voice command. Users want a human fallback when the AI is unsure |
| "Check this answer" sent to a contact | A | ★ | Aira Access AI pattern; builds trust |
| Smart-home control by voice | A | ★ | The main complaint from a disabled Ray-Ban Meta reviewer |

### Sport and wellbeing (Oakley's home ground)
| Use-case | | Fit | Notes |
|---|---|---|---|
| Spoken workout stats on request (Health Connect / HealthKit) | A | ★★ | Blind runners and gym users. Glasses have no GPS or heart-rate sensor of their own |
| Posture and head-angle cues from the IMU, hydration nudges | A | ★★ | Solos users rated posture the most useful health feature **[vendor-adjacent review]**. Motion is Experimental |
| Running or ski form from the IMU | A | ★ | No product found; open space, but needs research |
| Guided-run audio for blind runners (pace beeps, lap cues) | A | ★★ | Phone GPS; fits "Out and about" |
| Cycling data fields on a HUD | H | ✗ | Off-mission, and Meta does cycling directions |

### Cognitive and communication
| Use-case | | Fit | Notes |
|---|---|---|---|
| Object naming for dementia ("this is the kettle, for hot water") | A+H | ★★ | CrossSense: naming rose from 46% to 82% **[press figures]**. Caregiver-configured |
| Word-finding prompts for aphasia | A+H | ★ | ASSETS'16 found head-worn beats a phone; audio prompts untested |
| User-made routines and skills | A | ★★ | Grows out of C3 macros (`notes/customisation-roadmap.md`) |
| Emotion or social-cue coaching | H | ✗ | Touches faces; ethically fraught |

### Display-only (Meta Ray-Ban Display)
| Use-case | Fit | Notes |
|---|---|---|
| Large-print text in the lens: OCR'd text a few lines at a time, user-paced | ★★★ | No one does this for the world (Meta's magnifier magnifies its own UI). HEADING size is the biggest; we can't set font sizes |
| Glanceable status (listening, battery, last tip) | ★★★ | Backs up audio for hard-of-hearing users. Cheap |
| Label, mail or reminder summary card | ★★ | One card, one glance |
| A cropped, contrast-boosted still of what the camera sees | ★★ | No shaders and BT bandwidth limits mean stills only; depends on camera + display together |
| Step-by-step task card | ★★ | Same content as the audio coach |
| Live edge-enhanced video overlay | ✗ | Not possible with this API |

## 4. Deep dives on the four priorities

### 4.1 Navigation (orientation only)
- **HSTN:** an earcon, then terse speech: "Oak Street, ahead. Café on your left." Stereo pan gives side cues. With mono on, use pitch or clock-face words. Most of the value is in staying quiet: callouts only on request or at junctions.
- **HUD:** next-turn arrow, distance, street name, a large-print stop name. Speech stays primary.
- **Feasibility:** all phone-side except sign reading. City GPS error is about 5–20 m, so the camera matters for the last 10 m (the gap in `notes/a11y-prior-art.md`). Heading: phone compass is unreliable in a pocket; the glasses gyro (Motion) is Experimental; the magnetometer is probably absent.
- **Reuse:** ToolHub, watch-for-text, ToneSynth for a beacon, the C5 "Out and about" profile. "Where am I" is already a phrase inside the book reader, so the global opener needs a carve-out.
- **First milestone (GA):** "where am I", then "remember this place" / "take me back", then "watch for my bus, the 42" (due time from GTFS-realtime, arrival confirmed by watch-for-text).

### 4.2 Captions as listening help
For a blind user, "captions" means hearing and understanding, not text. The audience widens to hard of hearing and deaf-blind.
- **HSTN:** never a continuous spoken mirror (it would talk over the speaker). On request or on a keyword match: earcon, then "Announcement: platform 6".
- **HUD:** scrolling transcript, but Meta already ships this, so only build what Meta doesn't.
- **Feasibility:** phone on-device ASR (`SpeechRecognizer` / `SFSpeechRecognizer`), restart loops already in the voice layer. Caption mode and commands share one recogniser, so in caption mode commands must be addressed ("glasses, what did they say?"); `Phrases` already strips an address and EchoGuard exists. The glasses' in-stream PCM mic is better (not beamformed, keeps stereo out) but Experimental, needs a running stream, and isn't sent by the mock.
- **Risks:** recording-consent law (in-memory and never saved is assumed lower risk **[unverified legally]**), misheard numbers, battery.
- **First milestone (GA):** a "what did they say?" tool on the phone mic with a rolling 60 s transcript; name-called alert next; sound recognition after.

### 4.3 Awareness alerts
- **Language:** "I heard a siren", "something at head height, ahead". Never "danger", "safe" or "all clear". Silence must not imply safety, so first use and "help" say so once.
- **HSTN:** one reserved "attention" earcon used for nothing else, plus a terse phrase, panned when the side is known. **HUD:** a corner icon, never full-screen.
- **First milestone (GA):** expiry and allergen lines in Labels, scam signs in Mail. These are rules on text already read, with no new sensors.

### 4.4 Reminders
- **HSTN:** a gentle chime, the reminder, then "say done, snooze or repeat". **HUD:** a card.
- **Feasibility:** OS APIs. The open question is whether a phone notification read by TalkBack/VoiceOver reaches the glasses when SpeakUp isn't running (A2DP route). Text- and object-triggered reminders cost about 0.3–0.4 of a phone core while a stream runs (the watch-for-text measurement).
- **First milestone (GA):** "remind me in 20 minutes / at 6 to …", "what reminders do I have", "remember that …", "what was I doing?". Medication log with the dose rule next.

## 5. Proposed order

1. **U1 Reminders and memory**, plus the static awareness checks in Labels and Mail. GA, lowest risk, no new sensors.
2. **U2 Orientation**: where am I, markers, take me back, my bus. Callouts after; head-relative pan behind the Motion flag.
3. **U3 Listening help**: what did they say, name called, sound recognition. Phone mic in GA, glasses PCM behind a flag.
4. **U4 Display mirror (Meta Ray-Ban Display)**: status, large-print text, summary cards. First test whether camera and display run together.
5. **U5 Everyday and sport**: kitchen coach, task coach, human hand-off, workout stats, posture.
6. **U6 Research flags (Experimental, never production)**: head-height obstacle demo, IMU form coaching, camera-based "where did I put it".

## 6. Open questions
- Can the camera stream and the display run in one session at once? (Decides most of U4.)
- Is the HSTN in-stream mic more than one channel? (Speaker and sound direction.)
- Does on-glasses `Speech` transcribe other people, or only the wearer?
- Can a DAT app use the mic while Meta's Conversation Focus is on?
- Do phone notifications reach the glasses over A2DP when SpeakUp isn't running?
- Display update latency and sleep timeout; whether Meta's magnifier exists and what it magnifies.
- Recording-consent rules for in-memory transcription (two-party-consent states, UK, EU).

## Sources
- DAT: `sdks/meta-wearables-dat-android/CHANGELOG.md`, `samples/DisplayAccess/.../DisplayViewModel.kt`; docs `display-overview`, `inputs`, `speech`, `motion`, `acceptable-use` (narrow purpose, short retention, obvious to bystanders). Web apps docs "Choose between DAT and Web Apps".
- Meta features: [launch](https://about.fb.com/news/2025/09/meta-ray-ban-display-ai-glasses-emg-wristband/), [live captions](https://www.meta.com/help/ai-glasses/23879220601763496/), [Connect 2026](https://www.meta.com/blog/meta-connect-2026-everything-we-announced/), [Conversation Focus](https://about.fb.com/news/2025/12/updates-to-meta-ai-glasses-conversation-focus-spotify-integration/), [accessibility](https://www.meta.com/ai-glasses/accessibility/), [AppleVis review](https://applevis.com/forum/assistive-technology/meta-ray-ban-display-neural-band-blind-users-honest-take-future-wearable).
- HUD reading: [Krasovsky et al. 2023](https://www.tandfonline.com/doi/full/10.1080/10447318.2023.2254616), [Rzayev et al. CHI '18](https://www.researchgate.net/publication/324665702), [ForeSee TACCESS 2019](https://dl.acm.org/doi/10.1145/3361866).
- Navigation: [VoiceVista](https://drwjf.github.io/vvt/index.html), [Soundscape-Android](https://github.com/Scottish-Tech-Army/Soundscape-Android), [Biped](https://biped.ai/cz/noa-vs-glidance), [ETA study, Scientific Reports](https://www.nature.com/articles/s41598-026-37578-9).
- Listening: [MediaPipe Audio Classifier](https://developers.google.com/edge/mediapipe/solutions/audio/audio_classifier), [Android Sound Notifications](https://support.google.com/accessibility/android/answer/10092548), [AirCaps guide](https://aircaps.com/blog/best-caption-glasses-deaf-hard-of-hearing).
- Awareness: [smart-glasses survey, arXiv 2608.24877](https://arxiv.org/pdf/2608.24877), [Sensors 2019](https://doi.org/10.3390/s19071630).
- Memory and cognition: [JMIR Aging 2026](https://aging.jmir.org/2026/1/e81840), [EgoTrigger](https://arxiv.org/pdf/2508.01915), [Brilliant Labs Halo](https://brilliant.xyz/products/halo), [Williams ASSETS'16](https://www.cs.emory.edu/~kwil271/pdf/cost_assets2016.pdf).
- Everyday: [OSCAR](https://arxiv.org/abs/2507.03942), [AROMA](https://arxiv.org/pdf/2507.10963), [Vid2Coach](https://dl.acm.org/doi/10.1145/3746059.3747612), [Aira](https://aira.io/aira-now-works-with-ai-glasses-from-meta/), [Seleste](https://doubletaponair.com/seleste-smart-glasses/).
- Sport: [Garmin on HSTN](https://www.androidcentral.com/apps-software/meta/garmin-integration-is-rolling-out-for-oakley-meta-hstn-and-ray-ban-meta), [Solos AirGo 3](https://www.wareable.com/wearable-tech/solos-airgo-3-smartglasses-review).
