/*
 * LetterReminders - "Do you want a reminder before the deadline?" and the days it can mean
 *
 * After the summary, a letter with a sure deadline still to come gets an offer: "remind me three
 * days before", "remind me on Friday", "remind me the day before". This file turns those choices
 * into a day, builds the ReminderRequest (A11y/Reminders/ReminderScheduling.swift), and words
 * every result honestly: Reminders.shared answers .unavailable until the reminders feature is in
 * the build, and the line says so.
 *
 * Rules: a reminder only for a date the letter gives and that was read for sure (never "within
 * 14 days" turned into a guessed day); it fires at 9 in the morning; the spoken reminder says
 * where the date came from ("the letter from Northgate Energy says pay by 24 November 2026"), and
 * an amount only when it was read for sure. The id is the letter's stable id, so asking again
 * replaces the reminder. The clock and calendar are passed in, so tests use a fake clock.
 * Pure Swift.
 */

import Foundation

/// What the user asked for.
enum LetterReminderChoice: Equatable, Sendable {
  /// "remind me three days before", "a week before".
  case daysBefore(Int)
  /// "remind me on Friday": Calendar weekday, 1 is Sunday.
  case weekday(Int)
  /// "remind me on the day".
  case onTheDay
  /// "yes" or "remind me" after the offer: three days before, or the closest that's still to come.
  case suggested
}

enum LetterReminderPlan: Equatable, Sendable {
  case remind(fireDate: Date, day: LetterDay, choice: LetterReminderChoice)
  /// The letter has no sure date to remind about.
  case noDate
  /// The chosen day is after the deadline.
  case afterDeadline(LetterDay)
  /// The chosen day (or its 9 o'clock) has already gone.
  case tooLate
}

struct LetterReminderPlanner: Sendable {
  static let fireHour = 9

  var now: Date
  var calendar: Calendar

  init(now: Date, calendar: Calendar = .current) {
    self.now = now
    self.calendar = calendar
  }

  var today: LetterDay { LetterDay(now, calendar: calendar) }

  func adding(_ days: Int, to day: LetterDay) -> LetterDay? {
    guard let date = day.date(in: calendar, hour: 12), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
    return LetterDay(moved, calendar: calendar)
  }

  func weekday(of day: LetterDay) -> Int? {
    day.date(in: calendar, hour: 12).map { calendar.component(.weekday, from: $0) }
  }

  func daysUntil(_ day: LetterDay) -> Int? {
    guard let from = today.date(in: calendar, hour: 12), let to = day.date(in: calendar, hour: 12) else { return nil }
    return calendar.dateComponents([.day], from: from, to: to).day
  }

  /// The day a choice means for a deadline on `due`.
  func plan(_ choice: LetterReminderChoice, due: LetterDay?) -> LetterReminderPlan {
    guard let due else { return .noDate }
    let day: LetterDay?
    switch choice {
    case .daysBefore(let n): day = adding(-max(0, n), to: due)
    case .onTheDay: day = due
    case .weekday(let wanted):
      // The next one after today.
      day = (1...7).lazy.compactMap { offset -> LetterDay? in
        guard let candidate = adding(offset, to: today), weekday(of: candidate) == wanted else { return nil }
        return candidate
      }.first
    case .suggested:
      day = [3, 1, 0].lazy.compactMap { n -> LetterDay? in
        guard let candidate = adding(-n, to: due), let fire = candidate.date(in: calendar, hour: Self.fireHour), fire > now else {
          return nil
        }
        return candidate
      }.first
    }
    guard let day else { return .tooLate }
    if day > due { return .afterDeadline(day) }
    guard let fire = day.date(in: calendar, hour: Self.fireHour), fire > now else { return .tooLate }
    return .remind(fireDate: fire, day: day, choice: choice)
  }

  /// The choices worth offering for this deadline, in the order they're said. Empty when the
  /// deadline is today or gone, or there's no sure date.
  func offers(due: LetterDay?) -> [LetterReminderChoice] {
    guard let due, let days = daysUntil(due), days >= 1 else { return [] }
    var out: [LetterReminderChoice] = []
    if days > 3 { out.append(.daysBefore(3)) }
    // A weekday a couple of days before the deadline, when it isn't one of the other two.
    if days > 4, let day = adding(-2, to: due), let weekday = weekday(of: day) { out.append(.weekday(weekday)) }
    if case .remind = plan(.daysBefore(1), due: due) { out.append(.daysBefore(1)) }
    return out
  }

  // MARK: Words

  static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

  static func numberWord(_ n: Int) -> String {
    let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen"]
    return words.indices.contains(n) ? words[n] : "\(n)"
  }

  static func phrase(_ choice: LetterReminderChoice) -> String {
    switch choice {
    case .daysBefore(1): "remind me the day before"
    case .daysBefore(7): "remind me a week before"
    case .daysBefore(let n): "remind me \(numberWord(n)) days before"
    case .weekday(let w): "remind me on \(weekdays[(w - 1 + 7) % 7])"
    case .onTheDay: "remind me on the day"
    case .suggested: "remind me"
    }
  }

  /// "Friday 21 November".
  func spokenDay(_ day: LetterDay) -> String {
    let name = weekday(of: day).map { Self.weekdays[($0 - 1 + 7) % 7] + " " } ?? ""
    let month = LetterText.months[max(0, min(11, day.month - 1))]
    return "\(name)\(day.day) \(month)" + (day.year == today.year ? "" : " \(day.year)")
  }

  /// The question after the summary, or nil when there's nothing to offer.
  func offerLine(due: LetterDay?, kind: DueKind?) -> String? {
    let choices = offers(due: due)
    guard !choices.isEmpty else { return nil }
    let what = kind == .appointment ? "the appointment" : "the deadline"
    let said = choices.map(Self.phrase)
    let list = said.count == 1 ? said[0] : said.dropLast().joined(separator: ", ") + ", or " + said[said.count - 1]
    return "Do you want a reminder before \(what)? Say \(list)."
  }

  // MARK: The request

  func request(for record: LetterRecord, fireDate: Date) -> ReminderRequest? {
    guard let due = record.dueDay, let spoken = record.dueSpoken else { return nil }
    let who = record.sender.map { "The letter from \($0)" } ?? "A letter you read"
    let what: String =
      switch record.deadlineKind {
      case .appointment: "says your appointment is on \(spoken)"
      case .reply: "says reply by \(spoken)"
      case .pay?, .other?, nil:
        if let money = record.money {
          "says pay \(money.spoken()) by \(spoken)"
        } else if record.amount == .notSure {
          "says pay by \(spoken). I couldn't read the amount for sure, so check the letter"
        } else {
          "says the deadline is \(spoken)"
        }
      }
    return ReminderRequest(
      id: record.id, title: record.title, spokenText: "Reminder. \(who) \(what).", fireDate: fireDate,
      dueDate: due.date(in: calendar, hour: Self.fireHour), source: ToolID.mail.rawValue)
  }

  /// What to say for a plan that couldn't be scheduled, or nil for .remind.
  func line(for plan: LetterReminderPlan, kind: DueKind?) -> String? {
    let what = kind == .appointment ? "the appointment" : "the deadline"
    switch plan {
    case .remind: return nil
    case .noDate:
      return "This letter doesn't give a date I can read for sure, so I can't set a reminder for it."
    case .afterDeadline(let day):
      return "\(spokenDay(day)) is after \(what), so I didn't set a reminder. Say remind me the day before instead."
    case .tooLate:
      return "That day has already gone, so I didn't set a reminder."
    }
  }

  /// The line for what the reminders feature answered.
  func line(for result: ReminderScheduleResult, day: LetterDay, choice: LetterReminderChoice, due: LetterDay, kind: DueKind?)
    -> String
  {
    let what = kind == .appointment ? "the appointment" : "the deadline"
    switch result {
    case .scheduled:
      let gap = daysBetween(day, due)
      let when: String =
        switch gap {
        case 0: "on the day of \(what)"
        case 1: "the day before \(what)"
        case 7: "a week before \(what)"
        default: "\(Self.numberWord(gap)) days before \(what)"
        }
      return "Done. I'll remind you on \(spokenDay(day)) at 9 in the morning, \(when)."
    case .notAllowed:
      return "I couldn't set the reminder because notifications are off for SpeakUp. Turn them on in Settings, Notifications, SpeakUp, then ask again."
    case .inThePast:
      return "That time has already passed, so I didn't set a reminder."
    case .unavailable:
      return "Reminders aren't available in this version of SpeakUp yet, so I didn't set one. The letter is saved in your letters."
    }
  }

  private func daysBetween(_ a: LetterDay, _ b: LetterDay) -> Int {
    guard let from = a.date(in: calendar, hour: 12), let to = b.date(in: calendar, hour: 12) else { return 0 }
    return calendar.dateComponents([.day], from: from, to: to).day ?? 0
  }
}
