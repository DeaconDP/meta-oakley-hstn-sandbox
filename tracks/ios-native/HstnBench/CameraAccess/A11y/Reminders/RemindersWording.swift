/*
 * RemindersWording - every line Reminders says, in one place: short, plain, and honest about
 * failures (ROADMAP.md > Ground rules)
 */

import Foundation

enum RemindersWording {
  static let start = "Say remind me at 6 to take the bins out, what's due this week, or I took my evening pill."

  static let help =
    "Reminders. Say remind me at 6 to take the bins out, what's due this week, or I took my evening pill. "
    + "When a reminder goes off, say done or snooze."

  /// The line a reminder says when it goes off, from the words the user gave and nothing else.
  static func fired(_ text: String) -> String { "Reminder: \(yours(text))." }

  static func firedSpoken(_ line: String) -> String { "\(line) Say done, or snooze." }

  /// "take my pill" is said back as "take your pill".
  static func yours(_ text: String) -> String {
    text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
      switch word.lowercased() {
      case "my": "your"
      case "myself": "yourself"
      case "mine": "yours"
      default: String(word)
      }
    }.joined(separator: " ")
  }

  // MARK: Adding

  static func added(_ text: String, when: String) -> String {
    "Reminder at \(when): \(yours(text)). Say undo to cancel."
  }

  static func addedDaily(_ text: String, clock: String) -> String {
    "Reminder every day at \(clock): \(yours(text)). Say undo to cancel."
  }

  static func needsTime(_ text: String) -> String {
    "When should I remind you? Say, for example, remind me at 6 to \(yours(text))."
  }

  static let needsText = "What should I remind you about? Say, for example, remind me at 6 to take the bins out."

  static func inThePast(_ when: String) -> String { "\(when.prefix(1).uppercased() + when.dropFirst()) has already gone. Say a later time." }

  static let notificationsOff =
    "Notifications are off for SpeakUp, so I can't remind you. To turn them on, open Settings, then Apps, then SpeakUp, "
    + "then Notifications, and turn on Allow Notifications."

  static let couldNotSave = "I couldn't save that on this phone. Please try again."

  static let unavailable = "Reminders aren't available in this build."

  static func failed(_ result: ReminderScheduleResult) -> String {
    switch result {
    case .notAllowed: notificationsOff
    case .inThePast: "That time has already gone. Say a later time."
    case .unavailable, .scheduled: couldNotSave
    }
  }

  // MARK: Listing

  static let nothingComingUp = "You have no reminders coming up."
  static func nothingDue(_ range: ReminderIntent.DueRange) -> String {
    switch range {
    case .today: "Nothing is due today."
    case .tomorrow: "Nothing is due tomorrow."
    case .week: "Nothing is due this week."
    }
  }

  static func count(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }

  // MARK: Cancel, snooze, done, undo

  static func cancelled(_ text: String) -> String { "Cancelled the reminder: \(yours(text))." }
  static func noMatch(_ query: String) -> String {
    "I couldn't find a reminder about \(query). Say what reminders do I have to hear them."
  }
  static func which(_ names: [String]) -> String {
    "I found \(names.count): \(names.map(yours).joined(separator: ", and ")). Say cancel and more of its name."
  }
  static let cancelAll = "To be safe, I cancel one at a time. Say cancel and the reminder's name, or use the Cancel buttons."
  static let nothingToUndo = "There's nothing to undo."
  static func undoneReminder(_ text: String) -> String { "Undone. No reminder for \(yours(text))." }
  static func undoneLog(_ name: String) -> String { "Undone. \(name.prefix(1).uppercased() + name.dropFirst()) is off your log." }
  static let nothingToAnswer = "No reminder has gone off just now."
  static func done(_ text: String) -> String { "Done: \(yours(text))." }
  static func snoozed(minutes: Int, at time: String) -> String {
    "Snoozed for \(count(minutes, "minute")). I'll remind you at \(time)."
  }

  // MARK: Medicine log

  static func logged(_ name: String, at time: String, day: String) -> String {
    let when = day == "today" ? time : "\(time) \(day)"
    return "Logged: \(name), at \(when). Say undo if that's wrong."
  }

  static func takenToday(_ name: String, at time: String) -> String {
    "You logged \(name) today at \(time)."
  }

  static func notToday(_ name: String, last: String?) -> String {
    guard let last else { return "There's nothing in your log for \(name)." }
    return "You haven't logged \(name) today. The last time was \(last)."
  }

  static func lastTaken(_ name: String, when: String?) -> String {
    guard let when else { return "There's nothing in your log for \(name)." }
    return "You last logged \(name) \(when)."
  }

  static let emptyLog = "Your medicine log is empty. When you take something, say I took, and its name."

  /// Every dose question gets this and nothing more (notes/value-strategy.md > 7).
  static let doseRefusal = "I can't help with doses. Check the label, or ask your pharmacist."

  static let logNote = "This is your own log of what you said you took. SpeakUp never gives doses. For doses, check the label or ask your pharmacist."

  static let privacy = "Reminders and your medicine log stay on this phone."

  static let notUnderstood = "I didn't catch that. Say remind me at 6 to take the bins out, or what's due this week."
}
