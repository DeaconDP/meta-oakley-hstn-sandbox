# Ask about the text (HstnBench, Android)

2026-11-06. Questions about what the book reader (or, once it publishes, the mail tool) has just read out, answered aloud, **on the phone with no cloud model**. A Claude path exists for open questions but is off unless an API key is built in. Code: `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/tools/ask/`. It plugs into the ask seam described in notes/tools-layer.md.

## What it does

| Say | Kind | Answer |
|---|---|---|
| "What does *recondite* mean?", "define …", "what's a hansom", "look up …" | define | Looks the word up in bundled WordNet 3.0: "Recondite, adjective: difficult to penetrate; …". One or two senses, then "Say more for other meanings". "More" gives the next two, saying "As a noun: …" when the part of speech changes. |
| (word misheard) "what does *recon dight* / *reconnect* mean" | define | If the word isn't in the text read so far, the closest-sounding or closest-spelled word that *is* in the text is offered: "Did you mean recondite? Recondite, adjective: …". "No" then defines the word as heard. |
| "Spell it", "spell *recondite*", "how is that spelt" | spell | "Recondite is spelt R, E, C, O, N, D, I, T, E." "It" is the last word talked about. A named word is matched to the text first. |
| "Who is Mr. Bennet?", "who's Watson?", "remind me who X is" | who | Quotes from the text: the first mention plus the latest one or two ("Watson first comes up here: … Most recently: …"), clipped to about 30 words each, with "more" for the other mentions. If there are none: "I haven't read anything about Mr. Bennet yet." |
| "What's the Time Machine?" | what | Like *who* if the name is in the text, otherwise the dictionary (WordNet does have "time machine"), otherwise "I haven't read anything about …". |
| "What happened last time?", "where did we leave off?", "recap", "where were we" | recap | The last ~60 words read in this session. If nothing has been read yet in this session, the end of the previous one ("Last time, we left off here: …"). That text survives closing the app. |
| "What did it say about the fire?", "find …", "did it mention …", "what did Holmes say" | find | The matching sentences, best match first: "About the fire: … That's 1 of 3. Say next for the next one." |
| Anything else ("why did he do that?") | open | "I can only define words, tell you who someone is, recap, and find things in the text. I can't answer that one." (Or Claude, if a key is configured; see below.) |

- **Only what has been heard counts.** The book reader publishes a whole page as it starts reading it. `ReadText` cuts the last page at the sentence being read now, so names, searches and "did you mean" never draw on the unread rest of the page.
- **It never makes anything up.** Every answer is either a quote from the text or a dictionary sense.
- **Barge-in, then carry on.** While reading, a partial transcript that already forms a whole question (`AskGrammar.isQuestion`) pauses the reader at once, as "stop" does, so the user doesn't wait for the recogniser to finish. The answer follows and **the reader stays paused**, so follow-ups like "more", "spell it" or "next" don't get talked over. "Carry on" reads on from the interrupted sentence. The first answer in a session adds "Say carry on to keep reading." (Before this change, an answer from ToolHub was followed by the reader resuming on its own.)
- **Follow-ups are gated.** "More", "next" and "no" are things a room says, so they only count for 2 minutes after an answer (`AskGrammar.FollowUps`). "No" only counts after a "Did you mean". "Spell it" always counts. "Next one" stays the book's next-page command, and "find me X" stays Watch for text.
- Text from any tool works. The mail tool only has to publish to `hub.recentText` (see the JVM test `mailTextWorksTheSameWay`). The "last session" store is only written by the book reader for now.

## Dictionary: source, licence, size

- **Source:** Princeton WordNet 3.0 (`WordNet-3.0.tar.gz` from wordnetcode.princeton.edu, sha256 `640db279…3a52`, checked by the script). Included: 117,659 definitions (examples and relations dropped), 147,306 lemmas in WordNet's sense order, and 5,947 irregular forms from `*.exc`.
- **Licence:** the WordNet 3.0 licence, a BSD-style permission to "use, copy, modify and distribute … for any purpose and without fee", on condition that the copyright notice and disclaimer appear on all copies. The full notice is the header of the asset itself (`#` lines), is quoted in `scripts/build_ask_dictionary.py`, and has a short credit string in `res/values/strings_ask.xml` (`ask_dictionary_credit`). It's fine to bundle. The name "Princeton" must not be used in advertising.
- **Build:** `scripts/build_ask_dictionary.py` (Python 3, stdlib only), run with `--download` or `--wordnet <dict dir>`, writes `app/src/main/assets/ask/wordnet.wnask`. The output is deterministic (gzip mtime 0; re-running gives identical bytes). **I chose to commit the generated asset** (3.46 MB) rather than have Gradle generate it, so a build needs no Python and no network, and the APK can't silently ship without a dictionary.
- **Format:** gzip'd UTF-8 text in three sections: definitions, lemmas sorted by bytes (`lemma\tpos ids;pos ids`, base-36 ids), and irregular forms. On the phone the whole file is read once into a single `ByteArray` with two `IntArray`s of line offsets. A lookup is a binary search with no per-entry objects. In memory it's about 10 MB.
- **Gotcha:** the asset is gzip data but **must not be named `.gz`**. The Android Gradle plugin unpacks `.gz` assets at build time: the first build put the 10 MB raw text in the APK (4.16 MB deflated) under a different name, so the `.gz` asset name would have failed at runtime.
- **APK growth:** the asset entry is 3,459,944 bytes in the APK (stored as-is, already compressed). The code is a few tens of kB. The debug APK is 151.4 MB in total, mostly ML Kit and DAT.

## Morphology and spellings (Lemmatiser)

The approach is WordNet's own (morphy): irregular forms first, then suffix rules per part of speech (nouns: -s/-es/-ies/-men; verbs: -s/-es/-ed/-ing; adjectives: -er/-est), keeping only bases the dictionary has as that part of speech. On top of that:

- undoubling (stopped → stop, travelled → travel)
- -ly adverbs → adjectives
- possessives and hyphens (hearth-rug → hearthrug)
- British/American spellings, up to two changes deep: -our/-or, -ise/-ize, -isation, -yse/-yze, -tre/-ter, -ll-/-l-, ae/oe, -ogue/-og, -ence/-ense, grey/gray, -amme

The tests cover expounding → expound (verb), travellers → traveller, mice → mouse, went → go, colour → color, realised → realise/realize, centre → center, anaemia → anemia, catalogue → catalog, defence → defense, programme → program, and traveler → traveller. When the word in the text ends in -ing/-ed, the verb leads ("Expounding, from expound, verb: …"), even though WordNet also has a noun "expounding". If parts of speech tie on sense count, the order is adjective, verb, noun, adverb ("Ephemeral, adjective: lasting a very short time").

Misheard words: a sound key (consonant skeleton with common spellings merged; "recondite" and "recon dight" both give `rkndt`) plus Levenshtein on letters. A word heard that is itself in the dictionary needs a closer match before the text's word is offered instead. Words the dictionary knows are preferred, and so are longer (rarer) words.

## Lookup time on the phone

Galaxy A26 (SM-A266B, Android 16), `AskAboutTextTest#measuresDictionaryLoadAndLookupOnThePhone`, run twice:

- **Loading the asset** (gunzip + index): 193–197 ms. In the app (`metric=ask_dictionary_load`, background on IO at start): 157–216 ms.
- **One define question** (choose the word against the text, lemmatise, look up, word the answer), averaged over 400 questions: **3.7 ms**.
- Test process heap after loading: ~26 MB in total (the dictionary is ~10 MB of that).

On the JVM (M-series Mac): lemmatising a word takes ~28 µs. Loading the asset happens in the background on IO when the app starts (`AskProvider.dictionary`), so the first question normally doesn't wait for it. If it's still loading, the question waits for it.

## Privacy

- **No network unless a key is configured.** Without `anthropic_api_key` in `local.properties`, `BuildConfig.ANTHROPIC_API_KEY` is empty, `ClaudeAsk` is never created, and answering questions makes no network request at all.
- The "last session" text (the last ~3,000 characters read, as whole sentences, up to the sentence being read) is stored only in the book reader's own SharedPreferences (`book_reader`, key `recent_text`) next to the bookmark. It is never sent anywhere. In this session's memory, RecentText keeps text only (never images), as before.

## Optional Claude path (off by default)

- Enabled only if `local.properties` has `anthropic_api_key` (exposed as `BuildConfig.ANTHROPIC_API_KEY` by `app/build.gradle.kts`).
- Only **open** questions go online. Defining, spelling, who, recap and find always stay on the device. A question is sent only when the user asks one, and "Asking online." is said first, through a new `aside` callback on `AskAboutText.answer` that ToolHub passes `sayAside` to.
- Sent: the question, plus the text read so far (the last 12,000 characters at most). Never an image.
- The request: `POST https://api.anthropic.com/v1/messages`, `anthropic-version: 2026-10-21`, model `claude-haiku-5-5`, `max_tokens` 1024, `output_config.effort: "low"`, with a system prompt that says to answer only from the text, in 1–3 short spoken sentences, and otherwise reply exactly "The text doesn't say." (which becomes `AskResult.NotInText`). Refusals, HTTP errors, network errors and bad JSON give `Failed` ("Sorry, I couldn't answer that just now.").
- It uses raw HTTP (`HttpURLConnection`) with a tiny JSON helper, not the Anthropic Java SDK: one request on an off-by-default path doesn't justify the SDK's size in the APK, and a `Transport` interface lets tests play canned replies.
- **Untested live:** there is no API key on this machine. `ClaudeAskTest` checks the request body and how replies are handled using hand-written replies in the Messages API's documented shape (thinking + text blocks, refusal, 401, 529, network error, malformed JSON). These replies were not recorded from the live API.

## Files

- New, in `tools/ask/`: `AskGrammar.kt` (rewritten: question kinds, gated follow-ups, `isQuestion`), `Dictionary.kt`, `Lemmatiser.kt`, `TextTools.kt` (Sentences, ReadText, Words, Mentions, Search, Recap), `WordLookup.kt`, `AskWording.kt`, `OnDeviceAsk.kt`, `ClaudeAsk.kt`, `MiniJson.kt`, `AskMemory.kt`, `AskProvider.kt` (now returns OnDeviceAsk).
- Also new: `res/values/strings_ask.xml`, `assets/ask/wordnet.wnask`, `scripts/build_ask_dictionary.py`.
- Tests: `app/src/test/.../tools/ask/` (AskGrammarTest, DictionaryTest, TextToolsTest, OnDeviceAskTest, ClaudeAskTest, AskTestData) and `app/src/androidTest/.../AskAboutTextTest.kt`.
- **Shared files touched (minimal):**
  - `bookreader/BookReaderViewModel.kt`: a question partial pauses reading; a question pauses (and stays paused) before ToolHub answers; `saveBookmark` also stores the recent-text tail through `AskMemory`.
  - `tools/core/AskAboutText.kt`: an `answer(question, text, aside)` overload with a default.
  - `tools/ToolHub.kt`: one line, calling that overload with `sayAside`.
  - `app/build.gradle.kts`: the `ANTHROPIC_API_KEY` buildConfigField.
  - `androidTest/.../ToolsTest.kt`: the Penang lawyer assertion now expects the on-device answer, followed by "carry on".

## Test results

- **JVM:** `./gradlew testDebugUnitTest`: **142 tests, 0 failures** (101 before + 41 new): AskGrammarTest 9, DictionaryTest 8, TextToolsTest 7, OnDeviceAskTest 14, ClaudeAskTest 3. They run on the committed asset itself and on the Conan Doyle and Wells fixture pages.

- **Instrumented** (Galaxy A26, mock HSTN): `AskAboutTextTest`: **2/2 pass.** What was spoken in the run (from `hub.recentSpeech()`):
  - the partial "what does effusive mean" paused reading ("Paused" status), then
  - "Effusive, adjective: uttered with unrestrained enthusiasm. Or: extravagantly demonstrative. Say carry on to keep reading."
  - "Effusive is spelt E, F, F, U, S, I, V, E."
  - "Sherlock Holmes is mentioned once: To Sherlock Holmes she is always the woman."
  - "About the fire: He stood before the fire and looked me Over in his singular introspective fashion." (ML Kit's capital "Over", as read)
  - "carry on" re-read "His manner was not effusive."
  - After closing and launching again: "Last time, we left off here: To Sherlock Holmes … His manner was not effusive."

  The first run failed on my own assertion: it waited for the status line to say "Reading", but the reader doesn't update the status line on resume. The test now checks that page text is spoken again.
- `ToolsTest` (its ask step now expects the on-device answer, then "carry on"): **3/3 pass.**
- Not run after this change: `BookReaderTest`, `VoiceFirstLaunchTest`, `PitfallsTest`, and the rest of the suite. The book reader change only affects partials that form a question and the Ask command, so they shouldn't be affected, but that's unverified.

## Not done / not verified

- The Claude path has never made a live request (no key here).
- Real speech recognition: the misheard-word matching is tested on invented mishearings ("recon dight", "reconnect", "tinkled"), not on recordings from the glasses or phone recogniser.
- Barge-in on a real recogniser: it depends on partial results arriving with the whole question before the final result. The mock delivers whatever partial the test sends.
- Echo: the first answer ends "Say carry on to keep reading". If the user says "carry on" while that hint is still being spoken, the echo guard drops it as our own speech, and they have to say it again.
- WordNet is American-leaning and has gaps: no "Penang lawyer", no "reconnect", and some odd first senses (realise → "earn on some commercial or business transaction" comes before "be fully aware of"). Glosses are spoken as written, including dated wording in a few senses.
- "Who is" finds mentions, not descriptions: it reads where a name appears, and doesn't summarise who the person is.
- The mail tool doesn't publish yet (it's being built in parallel). Only the book reader writes the "last session" store.
