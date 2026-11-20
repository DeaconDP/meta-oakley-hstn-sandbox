# Letters first (iOS, roadmap V1)

2026-11-20. The mail reader now helps you deal with a letter. After the summary it offers a reminder before the deadline. Every letter it reads is kept in a letters log on the phone. It can explain a letter in plain English, on the phone or, if you ask, with AI. The scam hints now cover the Android list.

Code: `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Mail/` and the new `A11y/Letters/`. Tests: `CameraAccessTests/LettersTests.swift`.

## Files

| File | What it does |
|---|---|
| `Mail/LetterReminders.swift` | `LetterReminderPlanner`: the offer, what each choice means as a day, the `ReminderRequest`, and the line for every result. Clock and calendar are passed in. |
| `Mail/LetterGrammar.swift` | The new voice phrases (reminders, explain, letters log, yes and no). Runs before `MailGrammar`. |
| `Mail/LetterExplainer.swift` | The plain-English explanation from rules on the phone. |
| `Mail/LetterExplainOnline.swift` | The optional AI explanation (OpenAI, text only), and the language names. |
| `Mail/ScamSigns.swift` | More rules (below). |
| `Mail/MailTool.swift`, `Mail/MailPanel.swift` | Wiring and the panel. |
| `Letters/LetterRecord.swift` | One saved letter: summary fields and text. `LetterDay`. The stable id. |
| `Letters/LettersStore.swift` | The log on disk. |
| `Letters/LettersExport.swift` | Plain text and CSV, and the `Transferable` for `ShareLink`. |
| `Letters/LettersSpeech.swift` | What it says about the log and about a saved letter. |
| `Letters/LettersPanel.swift` | "My letters" inside the mail panel. |

Small changes in Mail: `Reference` is `Codable`, `LetterSpeech.kindPhrase(kind:)`, `LetterSpeech.noScamSigns`, `MailGrammar.phrases(_:)`, and `ScamSigns.find` gets the sender and kind.

## Reminders

- After the summary, if the letter has a sure date still to come: "Do you want a reminder before the deadline? Say remind me three days before, remind me on Sunday, or remind me the day before." It says "the appointment" for appointments.
- Only choices still to come are offered. The weekday is the day two days before the deadline, when the deadline is more than four days away.
- "remind me three days before", "a week before", "the day before", "on Friday" (the next Friday), "on the day", and "yes" or "remind me" (three days before, or the closest day still to come). "no" or "no thanks" says "OK, no reminder." "cancel the reminder" cancels it.
- Reminders fire at 9 in the morning. A day after the deadline, or already gone, is refused and said.
- No reminder for "within 14 days" or a date read unsure. The app never turns those into a guessed day.
- It calls `Reminders.shared.schedule(_:)`. The id is the letter's stable id, so asking again replaces the reminder. The spoken text says where the date came from: "Reminder. The letter from Northgate Energy says pay £84.17 by 24 November 2026." An unsure amount is never in it.
- Every result is spoken. Today `Reminders.shared` is `NoReminders`, so it says "Reminders aren't available in this version of SpeakUp yet, so I didn't set one. The letter is saved in your letters."
- `ReminderScheduling.swift` was not changed, and no change is needed.

## Letters log

- Each letter read (not an envelope) is saved. Kept: kind, sender, recipient, date, subject, amount, deadline, references, scam signs, the summary, and the text. Never the photo.
- The amount is a figure only when sure. Otherwise "not read for sure". The text is `Letter.safeText`, so a guessed figure can't come back.
- The id comes from the sender, the letter's date and the first reference. Reading the same letter again replaces its entry and keeps its reminder.
- One JSON file: `Application Support/Letters/letters.json`. Written atomically with `NSFileProtectionComplete`. The folder and the file are excluded from backup.
- If the file exists but can't be read (phone locked, damaged file), saving is refused. The log is never overwritten with one letter.
- The first time a letter is saved, it says once: "I've kept it in your letters on this phone."
- Voice, with the mail reader open: "my letters", "what letters do I have", "read the letter from Northgate", "delete that letter", "forget all letters" (asks: "Say yes to forget them, or no to keep them"), "export my letters" (says to tap an export button).
- A letter opened from the log answers "how much", "when is it due", "who is it from", "is it a scam" and "read it all" without a new picture. Deleting a letter also cancels its reminder.
- Export only when the user taps Export as text or Export as CSV in My letters. That's a `ShareLink`; the file is made when the share sheet asks. CSV is RFC 4180, and a cell starting with = + - @ gets an apostrophe so spreadsheets don't run it.

## Explain

- "explain this letter", "what does this mean", "what do I need to do": rules on the phone. Topics: bill, final notice, appointment, bank, council tax, benefit, fine, advert, plus medical, official, personal and unknown.
- It uses the fields already found. It says when the letter doesn't say something that kind of letter normally says ("I couldn't find an amount to pay in it."). An unsure amount: "I couldn't read it for sure, so I won't guess it."
- It ends with "That's a general explanation from rules on your phone." With a key set, it adds "say explain online."
- "explain online", "explain in Polish", "explain in my language": the AI path. Only with an OpenAI key (`OpenAIKey`, the same as Ask). Never under test.
- No key: "An AI explanation needs an OpenAI key in Settings. Nothing was sent. Say explain this letter for the explanation on the phone."
- Before sending: "Asking online for an AI explanation. Only the letter's text is sent, not the photo." Sent: the letter's masked text and the language. Nothing else.
- The model is told to use only the text, say when the letter doesn't say who, what, how much or by when, never work out an amount, and never call a letter genuine.
- The answer starts "AI explanation:" and ends "This was written by AI from the letter's text, so check anything important." The panel marks it "AI explanation".
- "my language" is the phone's first language. If that's English, it asks which language.

## Scam signs

Added to the iOS rules, so the Android list (TODO.md) is covered:

- Bank details or passwords asked for: "send us your bank details", "online banking password", "confirm your login details".
- Odd payment methods: Apple and paysafecard vouchers, prepaid cards, money orders, cash by post, "a courier will collect".
- Urgent payment: "pay now to avoid", "last chance to pay". With "final notice" these are weak signs. One kind alone gives no hint, because councils send real final notices.
- Mismatched sender (strong): a bank, council, government body, NHS or big company that wants replies at a free email address (Gmail, Hotmail...) or a mobile number. Counted by the letter's kind (bank, official, medical) or the sender's name. A trader's bill with a Gmail address isn't counted.
- With no signs: "No scam signs found. That doesn't prove a letter is safe, so if you're unsure, check with someone you trust." The word "genuine" is no longer said.

## Panel

Under the main buttons: the reminder offer as buttons (with No reminder), then Explain this letter, Explain with AI and My letters. The explanation shows in large text. My letters replaces the letter view: one row per letter (opens it), Delete, Export as text, Export as CSV, Forget all letters (asks on screen and by voice). A letter opened from the log shows its summary and text, with a way back. Buttons are at least 60 pt. Identifiers start with `mail_` and `letters_`.

## Phrases that need global routing

Done 2026-11-20 (integration): "my letters", "what letters do I have" and "read the letter from <sender>" now work from any screen (ToolHub.route, step 6). "Explain this letter" from the home is still to do. The original list:

- "my letters", "what letters do I have": open Mail, then `MailTool.listLetters()`.
- "read the letter from <sender>": open Mail, then `MailTool.openSaved(named:)`.
- "explain this letter" from the home: open Mail only if a letter was just read.

"yes" and "no" already reach the tool when the app isn't waiting for its own yes-or-no answer.

## Tests

Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp Letters iPhone 17", signed, `-parallel-testing-enabled NO`. CameraAccess and SpeakUp schemes both build.

- New in `LettersTests.swift` (36): `LetterReminderTests` (7: three days before with a fake clock, the next Friday, after the deadline, too late, the offer list, the request, every result line, the stable id), `LetterGrammarTests` (4), `LettersStoreTests` (7: save, list, replace, delete, forget all, reload, backup exclusion, an unreadable file is never overwritten, what a record keeps, text and CSV export, the spoken list), `LetterExplainerTests` (5), `LetterScamRuleTests` (4), `LetterExplainOnlineTests` (5: the body is text only with no image, the language, the request, replies), `LettersMailToolTests` (4: end to end with a fake reminders store and a fake AI).
- `MailReaderTests` was updated for the new scam wording. `MailToolTests` now uses a temporary letters store.
- Full unit tests, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`: 561 passed, 0 failed.
- No UI test drives the new buttons yet.

## Not tried yet

- Not tried on a real iPhone or with real letters.
- No live OpenAI request was made. The request and reply handling are unit tested.
- An AI explanation in another language is read by the app's English voice. It will sound wrong until the voice follows the language.
- The real reminders store isn't in yet, so "Done. I'll remind you on ..." has only run against a fake.
- File protection can't be checked on the Simulator. Backup exclusion was checked.
