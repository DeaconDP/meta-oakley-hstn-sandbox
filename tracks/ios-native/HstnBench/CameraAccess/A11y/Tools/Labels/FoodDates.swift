/*
 * FoodDates - a food label's date against today, said plainly
 *
 * Roadmap V2 food check: "Use by 21 November: that's tomorrow." LabelDates finds the dates; this
 * picks the one that matters (use by, then best before, then expiry; display-until and sell-by
 * are for the shop), says how far it is from today, and what kind of date it is:
 * - use by is about safety: don't eat it after that date (you can freeze it up to that date);
 * - best before is about quality, not safety.
 * Wording follows the UK Food Standards Agency's advice.
 *
 * It abstains when the date isn't fully read: a keyword with no date, a date line OCR wasn't sure of
 * (confidence below 0.5), or a date line running off the photo. Medicine dates don't come here
 * (MedicineCheck keeps its own stricter rule). Pure: today and now are passed in.
 *
 * `reminder` builds the ReminderRequest for "remind me before it goes off": 9 am the day before,
 * or 9 am on the day if that's already gone.
 */

import Foundation

struct FoodDateAnswer: Equatable, Sendable {
  var spoken: String
  /// The date said, when one was said clearly. nil when abstaining or nothing was found.
  var date: LabelDate?
}

enum FoodDates {
  /// Below this OCR confidence a date line isn't trusted.
  static let clearConfidence: Float = 0.5

  static let notFound = "I can't find a date on this side. Dates are often on the top, the bottom or the back. Turn it and ask again."

  private static let priority: [LabelDateKind] = [.useBy, .bestBefore, .expiry, .unlabelled, .displayUntil, .sellBy]

  /// What to say for "when does it expire" on food. `lines`: every side read, newest first.
  static func answer(_ lines: [LabelLine], today: CivilDate) -> FoodDateAnswer {
    let findings = LabelDates.find(lines.map(\.text).joined(separator: "\n"), today: today)
    guard !findings.dates.isEmpty else {
      return FoodDateAnswer(spoken: LabelDates.answer(findings, today: today) ?? notFound, date: nil)
    }
    let ranked = findings.dates.enumerated().sorted { a, b in
      let pa = priority.firstIndex(of: a.element.kind) ?? 99
      let pb = priority.firstIndex(of: b.element.kind) ?? 99
      return pa != pb ? pa < pb : a.offset < b.offset
    }.map(\.element)
    let main = ranked[0]

    // Is the date's line clear and whole?
    let source = linesHolding(main, in: lines, today: today)
    if source.contains(where: \.touchesEdge) {
      return FoodDateAnswer(
        spoken: "I can see \(kindName(main.kind)), but the date runs off the edge of the picture. Move the pack a little and ask again.",
        date: nil)
    }
    if source.contains(where: { ($0.confidence ?? 1) < clearConfidence }) {
      return FoodDateAnswer(
        spoken: "I can see \(kindName(main.kind)), but I can't read the date clearly enough to be sure. Hold it a little closer, keep it steady, and ask again.",
        date: nil)
    }

    var parts = [sentence(main, today: today)]
    if let other = ranked.dropFirst().first(where: { [.useBy, .bestBefore].contains($0.kind) && $0.kind != main.kind }) {
      parts.append(sentence(other, today: today, explain: false))
    }
    return FoodDateAnswer(spoken: parts.joined(separator: " "), date: [.displayUntil, .sellBy].contains(main.kind) ? nil : main)
  }

  private static func kindName(_ kind: LabelDateKind) -> String {
    kind == .unlabelled ? "a date" : "a \(kind.spoken.lowercased()) date"
  }

  /// The OCR lines the date came from: lines where it parses on its own, or with the line above.
  private static func linesHolding(_ date: LabelDate, in lines: [LabelLine], today: CivilDate) -> [LabelLine] {
    func same(_ d: LabelDate) -> Bool { d.year == date.year && d.month == date.month && d.day == date.day }
    var out: [LabelLine] = []
    for i in lines.indices {
      if LabelDates.find(lines[i].text, today: today).dates.contains(where: same) {
        out.append(lines[i])
      } else if i > 0, LabelDates.find(lines[i - 1].text + "\n" + lines[i].text, today: today).dates.contains(where: same) {
        out.append(lines[i - 1])
        out.append(lines[i])
      }
    }
    return out
  }

  /// "21 November" this year, "12 March 2027" otherwise, "the end of March 2027" for month-only.
  static func spokenDate(_ date: LabelDate, today: CivilDate) -> String {
    let name = LabelDate.monthNames[date.month - 1]
    let showYear = !date.yearGuessed && date.year != today.year
    if let day = date.day { return showYear ? "\(day) \(name) \(date.year)" : "\(day) \(name)" }
    return showYear ? "the end of \(name) \(date.year)" : "the end of \(name)"
  }

  /// "that's tomorrow", "that was 3 days ago", "that's in about 4 months".
  static func relative(_ date: LabelDate, today: CivilDate) -> String {
    let days = date.lastDay.epochDay - today.epochDay
    switch days {
    case ..<(-59): return "that was about \(Int((Double(-days) / 30.4).rounded())) months ago"
    case -59 ... -14: return "that was about \(Int((Double(-days) / 7).rounded())) weeks ago"
    case -13 ... -2: return "that was \(-days) days ago"
    case -1: return "that was yesterday"
    case 0: return "that's today"
    case 1: return "that's tomorrow"
    case 2...13: return "that's in \(days) days"
    case 14...59: return "that's in about \(Int((Double(days) / 7).rounded())) weeks"
    default: return "that's in about \(Int((Double(days) / 30.4).rounded())) months"
    }
  }

  /// What the kind of date means, for this many days to go.
  static func meaning(_ kind: LabelDateKind, days: Int) -> String? {
    switch kind {
    case .useBy:
      if days < 0 { return "Use by is about safety, so don't eat it." }
      if days == 0 { return "Use by is about safety: eat it, cook it or freeze it by the end of today." }
      return "Use by is about safety: don't eat it after that date."
    case .bestBefore:
      return days < 0 ? "Best before is about quality, not safety, so it may just be past its best." : "Best before is about quality, not safety."
    case .displayUntil, .sellBy:
      return "That date is for the shop. Look for a use by or best before date."
    case .expiry, .unlabelled:
      return nil
    }
  }

  /// "Use by 21 November: that's tomorrow. Use by is about safety: don't eat it after that date."
  static func sentence(_ date: LabelDate, today: CivilDate, explain: Bool = true) -> String {
    let head = date.kind == .unlabelled ? "There's a date, \(spokenDate(date, today: today))" : "\(date.kind.spoken) \(spokenDate(date, today: today))"
    var out = "\(head): \(relative(date, today: today))."
    if explain, let meaning = meaning(date.kind, days: date.lastDay.epochDay - today.epochDay) { out += " " + meaning }
    return out
  }

  // MARK: Reminders

  static let offer = "Say remind me before it goes off, if you'd like a reminder."

  enum ReminderPlan: Equatable {
    case request(ReminderRequest)
    /// The date has passed.
    case passed
    /// It goes off today and 9 am has gone.
    case tooSoon
  }

  /// The reminder for `date`, 9 am the day before (or 9 am on the day if that has gone).
  static func reminder(
    for date: LabelDate, name: String?, key: String, today: CivilDate, now: Date, calendar: Calendar = .current
  ) -> ReminderPlan {
    let last = date.lastDay
    if last < today { return .passed }
    func at9(_ civil: CivilDate, plusDays: Int = 0) -> Date? {
      guard let day = calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day, hour: 9)) else { return nil }
      return calendar.date(byAdding: .day, value: plusDays, to: day)
    }
    guard let dayBefore = at9(last, plusDays: -1), let onTheDay = at9(last) else { return .tooSoon }
    let fire: Date
    let when: String
    if dayBefore > now {
      fire = dayBefore
      when = "that's tomorrow"
    } else if onTheDay > now {
      fire = onTheDay
      when = "that's today"
    } else {
      return .tooSoon
    }
    let what = name.map { LabelsString.trimmed($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Food"
    let kind = date.kind == .unlabelled ? "date" : date.kind.spoken.lowercased()
    let spokenDay = spokenDate(date, today: today)
    return .request(
      ReminderRequest(
        id: "labels.food.\(key).\(date.year)-\(date.month)-\(date.day ?? 0).\(date.kind.rawValue)",
        title: "\(what) \(kind)",
        spokenText: "Reminder: the \(what) label says \(kind) \(spokenDay), \(when).",
        fireDate: fire,
        dueDate: at9(last),
        source: ToolID.labels.rawValue))
  }

  /// What to say after scheduling.
  static func scheduled(_ result: ReminderScheduleResult, fireDate: Date, date: LabelDate, today: CivilDate, calendar: Calendar = .current) -> String {
    let kind = date.kind == .unlabelled ? "date" : date.kind.spoken.lowercased()
    switch result {
    case .scheduled:
      let fireCivil = CivilDate.today(calendar: calendar, now: fireDate)
      let onTheDay = fireCivil == date.lastDay
      let day = onTheDay ? "on the morning of the \(kind) date" : "on the morning before the \(kind) date"
      return "Done. I'll remind you \(day), \(spokenDate(date, today: today))."
    case .notAllowed:
      return "I can't set a reminder because notifications are off for SpeakUp. Turn them on in Settings, then ask again."
    case .inThePast:
      return "That's too soon for a reminder: the date is today or has passed."
    case .unavailable:
      return "Reminders aren't available in this version yet. The \(kind) date is \(spokenDate(date, today: today))."
    }
  }
}
