# Reminders (iOS)

2026-11-20. Roadmap U1 and V2. Reminders is the seventh tool on the tools home. It has time reminders, what's due this week, a medicine log, and "what was I doing?". It needs no camera.

Code is in `tracks/ios-native/HstnBench/CameraAccess/A11y/Reminders/`.

## What was built

- **`ReminderStore`** is the real `ReminderScheduling`. `CameraAccessApp` sets `Reminders.shared = ReminderStore.live()` at launch.
- It keeps one JSON file: `Application Support/Reminders/reminders.json`. The file is written with complete file protection. The folder is kept out of backups, so nothing leaves the phone.
- The file holds one-off reminders (`ReminderRequest`), daily reminders and the medicine log.
- Notifications go through `ReminderNotifying`. The app uses `SystemNotifications` (`UNUserNotificationCenter`). Tests use a fake. UI tests and the unit-test host use `QuietNotifications`, so no permission prompt shows.
- The permission prompt comes the first time something is scheduled.
- If the file can't be read (the phone is locked), the store doesn't write over it. It tries again before the next change.
- **`ReminderAlerts`** is the notification centre's delegate. With the app in front, a reminder is spoken with an earcon, not shown as a banner. Otherwise it is a normal notification, with Snooze and Done buttons.
- For 30 minutes after a reminder goes off, "done" and "snooze" answer it from any screen. ToolHub asks `ReminderAlerts.takesReply` before anything else. After that, "done" means close again.
- **`ReminderTime`** parses times on the phone. Fixed rules first, then `NSDataDetector`.
- **`ReminderGrammar`** turns words into an intent.
- **`RemindersTool`** answers and speaks. **`RemindersPanel`** is the screen.
- **`ActivityLog`** holds the last 30 steps in memory, for this session only.

## The contract

`ReminderScheduling` keeps its shape. Nothing was added to the protocol.

- `schedule` returns `.inThePast`, `.notAllowed` or `.unavailable` and keeps nothing in those cases. The same `id` replaces the first reminder.
- `upcoming(before:)` returns one-off reminders with a fire date or due date that is still to come and before the date. Soonest first, by the next of the two dates.
- A letter reminder that has fired stays in the list until its due date.
- Daily reminders are not `ReminderRequest`s, so they are not in `upcoming`. The store has them in `daily`.

## Voice

These work from any screen. Reminders opens first, without its opening line. "What was I doing?" answers in place.

| Say | Does |
|---|---|
| "remind me in 20 minutes to take the bins out" | Reminder in 20 minutes |
| "remind me at 6 to …" | The next 6 o'clock to come |
| "remind me tomorrow at 9 to …" | 9 am tomorrow |
| "remind me to … at 6 pm", "set a reminder for 5 pm to …" | The time can come first or last |
| "remind me every day at 8 pm to take my evening pill" | Daily reminder |
| "what reminders do I have" | Everything coming up, then the daily ones |
| "what's due this week" (or today, tomorrow) | Reminders and deadlines from other tools, like letters |
| "I took my evening pill", "I took it at 7" | Writes to the medicine log |
| "did I take my evening pill?" | "You logged evening pill today at 7:12 am." |
| "when did I last take metformin" | "You last logged metformin yesterday at 7:05 pm." |
| "what was I doing?" | The open tool, then the last steps |

These work with Reminders open: "cancel the bins reminder", "undo", "snooze", "snooze for 20 minutes", "mark it done", "my medicine log".

Every add is confirmed: "Reminder at 6 pm today: take the bins out. Say undo to cancel." "my" is said back as "your".

## Time rules

- A bare hour ("at 6") is the next 6 o'clock to come, morning or evening.
- With a day or "every day", a bare hour is daytime: 7 to 11 is am, 12 is midday, 1 to 6 is pm.
- "tonight", "this evening" and "in the evening" mean pm. "this morning" and "in the morning" mean am.
- "tomorrow" alone is 9 am. "tonight" alone is 8 pm.
- A time phrase must start with an anchor word ("at", "in", "tomorrow", "every" ...). So "call 3 people" and "a table for 6" are not times.
- `NSDataDetector` handles the rest, like "on 3 December at 10 am". It reads the phone's own clock, so its tests only check that a date is found.
- A time that has gone ("at 1 pm today" at 2 pm) is said back: "1 pm today has already gone."

## Medicine guardrails

- The log is what the user says they took. It is never a dose.
- A name never keeps a number or unit. "I took 2 paracetamol" logs "paracetamol". So a number is never said back.
- A medicine reminder drops numbers too: "take 2 pills" becomes "take pills".
- A dose question gets one line: "I can't help with doses. Check the label, or ask your pharmacist." A question counts as a dose question when it is about a medicine and has "dose", "how many", "how much", "how often", "too many", or starts with "should I", "can I", "is it safe" and similar. A dose question never writes to the log.
- "I took the bins out" is not logged: a non-medicine word needs "my" and no errand word.
- Daily medicine reminders say only the user's words: "Reminder: take your evening pill."

## Failures

Every failure is spoken with the error earcon:

- Notifications refused: "Notifications are off for SpeakUp, so I can't remind you. To turn them on, open Settings, then Apps, then SpeakUp, then Notifications, and turn on Allow Notifications." The panel also shows a button to the settings.
- Can't save: "I couldn't save that on this phone."
- No time heard, or nothing to remind about: it asks for the missing part.

## The panel

The last line said, in large text. A field to type a reminder (the same words as by voice). Coming up, each with a Cancel button named for the reminder. Every day. The medicine log, with an "I took …" button for each name already logged. A line on what you can say, and the privacy line. Theme font with Dynamic Type, 60 pt targets.

## Wiring (shared files)

- `ToolID.reminders`: "Reminders", bell icon, red coin. Open phrases: "open reminders", "reminders", "my reminders", "medicine log".
- `ToolHub.liveTool`, `ToolHub.open/close` (notes to `ActivityLog`), `ToolHub.route` (alert replies first; reminder phrases after Watch, before Ask).
- `HandsFreeTool.reminders`, `LaunchAction.openReminders`, `VoiceCommand.openReminders`, help's tool list, "SpeakUp has seven tools".
- `VoiceControl` and `CameraView` switches got `.openReminders`.
- App Intents: `OpenRemindersIntent` ("My reminders in SpeakUp", "What's due with SpeakUp", "SpeakUp reminders").
- **The App Shortcut limit.** There were already 10. Reminders took Ask's slot. Ask only helps right after something was read, so people reach it from inside the app. Reminders is a daily job people start cold. Ask keeps its intent for Shortcuts, the Action Button and Back Tap, and "Open Ask about the text in SpeakUp" still works through `OpenToolIntent`.

## Tests

Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp Reminders iPhone 17", signed, `-parallel-testing-enabled NO`. CameraAccess and SpeakUp both build.

- Unit tests, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`: 570 run, 0 failures.
- New: 45 tests in `RemindersTests.swift`. Time phrases on a fixed clock (Friday 20 November 2026, 2 pm, Europe/London), the grammar, the store and its file, `upcoming(before:)` order, dose refusals, the log's answers, reminders going off, done and snooze, "what was I doing?", and the ToolID wiring.
- Updated: `ToolPhraseTests`, `HandsFreeTests`, `OpenToolIntentTests` for the seventh tool.
- UI tests: `ToolsHomeUITests`, 4 run, 0 failures. New: `testReminderByVoiceFromTheHome` ("reader, remind me in 20 minutes to take the bins out", then "reader, undo").
- Building the SpeakUp scheme into the same derived data broke the next UI test run (`MWDATCore` not loaded). Building CameraAccess for testing again fixed it.

## Not tried on a real iPhone

- A notification going off: with the app in front (spoken), in the background, and with the phone locked.
- The permission prompt and the "notifications are off" path with the real setting.
- Snooze and Done on the notification itself.
- Reading the store while the phone is locked (complete file protection).
- Whether a reminder spoken in the app reaches the glasses over A2DP.
- VoiceOver on the panel.

## Next

- Routine checklists ("leaving the house"), spoken notes, and place reminders (U1).
- Mail can call `Reminders.shared.schedule` for letter deadlines now; "what's due" already lists them.
