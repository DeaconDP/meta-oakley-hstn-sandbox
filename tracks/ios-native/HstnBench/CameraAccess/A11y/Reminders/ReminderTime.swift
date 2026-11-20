/*
 * ReminderTime - turns "in 20 minutes", "at 6", "tomorrow at 9", "every day at 8 pm" into a date,
 * on the phone, with fixed rules first and NSDataDetector for anything else ("on 3 December at 10")
 *
 * Pure: words, now and a calendar in; a time out. Tests pass a fixed clock and time zone.
 *
 * Rules for a bare hour ("at 6"): the next 6 o'clock to come, morning or evening. With a day
 * ("tomorrow at 9") or "every day", a bare hour is daytime: 7 to 11 is morning, 12 is midday, and
 * 1 to 6 is afternoon or evening. "tonight", "this evening" and "in the evening" mean pm; "this
 * morning" and "in the morning" mean am. A time phrase must start with an anchor word ("at", "in",
 * "tomorrow", "every" ...) so a number in the task ("call 3 people") is never taken for a time.
 */

import Foundation

/// When a reminder goes off.
enum ReminderWhen: Equatable, Sendable {
  case once(Date)
  /// Every day at this time on the phone's clock.
  case daily(hour: Int, minute: Int)
}

/// One word as heard, and the form the rules match on ("6pm" becomes "6" and "pm", "twenty" "20").
struct ReminderToken: Equatable, Sendable {
  var norm: String
  var orig: String
}

/// Days and clock times as the user hears them: "6 pm today", "9:30 am tomorrow", "on Friday".
struct ReminderFormat {
  var calendar: Calendar
  var now: Date

  private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  private static let months = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
  ]

  /// "6 pm", "6:30 pm", "midday", "midnight".
  static func clock(hour: Int, minute: Int) -> String {
    if minute == 0, hour == 12 { return "midday" }
    if minute == 0, hour == 0 { return "midnight" }
    let twelve = hour % 12 == 0 ? 12 : hour % 12
    let suffix = hour < 12 ? "am" : "pm"
    return minute == 0 ? "\(twelve) \(suffix)" : String(format: "%d:%02d %@", twelve, minute, suffix)
  }

  func time(_ date: Date) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return Self.clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
  }

  /// "today", "tomorrow", "yesterday", "on Friday" (within the week), "on 3 December".
  func day(_ date: Date) -> String {
    let start = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case 0: return "today"
    case 1: return "tomorrow"
    case -1: return "yesterday"
    case 2...6, -6 ... -2:
      return "on \(Self.weekdays[calendar.component(.weekday, from: date) - 1])"
    default:
      let parts = calendar.dateComponents([.day, .month], from: date)
      return "on \(parts.day ?? 1) \(Self.months[(parts.month ?? 1) - 1])"
    }
  }

  /// "6 pm today", "9 am tomorrow", "10 am on 3 December".
  func when(_ date: Date) -> String { "\(time(date)) \(day(date))" }
}

enum ReminderTimeParser {
  /// Words a time phrase may start with.
  static let anchors: Set<String> = [
    "in", "at", "by", "for", "tomorrow", "today", "tonight", "this", "every", "daily", "noon", "midday", "midnight",
  ]

  // MARK: Words

  private static let units: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19,
  ]
  private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50]

  /// Phrases rewritten before matching. Longest first.
  private static let rewrites: [([String], [String])] = [
    (["an", "hour", "and", "a", "half"], ["90", "minutes"]),
    (["1", "hour", "and", "a", "half"], ["90", "minutes"]),
    (["a", "quarter", "of", "an", "hour"], ["15", "minutes"]),
    (["quarter", "of", "an", "hour"], ["15", "minutes"]),
    (["half", "an", "hour"], ["30", "minutes"]),
    (["a", "half", "hour"], ["30", "minutes"]),
    (["a", "quarter", "hour"], ["15", "minutes"]),
    (["a", "quarter", "past"], ["quarter", "past"]),
    (["a", "quarter", "to"], ["quarter", "to"]),
    (["half", "hour"], ["30", "minutes"]),
    (["an", "hour"], ["1", "hour"]),
    (["a", "minute"], ["1", "minute"]),
    (["each", "day"], ["every", "day"]),
    (["o", "clock"], []),
    (["everyday"], ["every", "day"]),
    (["oclock"], []),
  ]

  /// Splits `text` into words for matching: lowercased, apostrophes closed up, outer punctuation
  /// off, "p.m." as "pm", "6pm" as "6" "pm", number words as digits ("twenty five" is "25").
  static func tokens(_ text: String) -> [ReminderToken] {
    var out: [ReminderToken] = []
    for piece in text.replacingOccurrences(of: "\u{2019}", with: "'").split(whereSeparator: \.isWhitespace) {
      let orig = String(piece)
      var norm = orig.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",!?;:\"()[]"))
      if ["a.m.", "a.m", "am."].contains(norm) { norm = "am" }
      if ["p.m.", "p.m", "pm."].contains(norm) { norm = "pm" }
      while norm.hasSuffix(".") { norm.removeLast() }
      norm = norm.replacingOccurrences(of: "'", with: "")
      guard !norm.isEmpty else { continue }
      if let match = norm.wholeMatch(of: #/(\d{1,2}(?:[:.]\d{2})?)(am|pm)/#) {
        out.append(ReminderToken(norm: String(match.1), orig: orig))
        out.append(ReminderToken(norm: String(match.2), orig: ""))
        continue
      }
      out.append(ReminderToken(norm: norm, orig: orig))
    }
    // "p m" after a number.
    var merged: [ReminderToken] = []
    for token in out {
      if token.norm == "m", let last = merged.last, last.norm == "a" || last.norm == "p", merged.count >= 2,
        isNumber(merged[merged.count - 2].norm)
      {
        merged[merged.count - 1] = ReminderToken(norm: last.norm + "m", orig: last.orig + " " + token.orig)
        continue
      }
      merged.append(token)
    }
    // Number words.
    var numbered: [ReminderToken] = []
    var index = 0
    while index < merged.count {
      let token = merged[index]
      if let ten = tens[token.norm] {
        if index + 1 < merged.count, let unit = units[merged[index + 1].norm], unit > 0, unit < 10 {
          numbered.append(ReminderToken(norm: String(ten + unit), orig: token.orig + " " + merged[index + 1].orig))
          index += 2
          continue
        }
        numbered.append(ReminderToken(norm: String(ten), orig: token.orig))
      } else if let unit = units[token.norm] {
        numbered.append(ReminderToken(norm: String(unit), orig: token.orig))
      } else {
        numbered.append(token)
      }
      index += 1
    }
    // Phrases.
    var result: [ReminderToken] = []
    index = 0
    outer: while index < numbered.count {
      for (pattern, replacement) in rewrites where index + pattern.count <= numbered.count {
        guard numbered[index..<(index + pattern.count)].map(\.norm) == pattern else { continue }
        let origs = numbered[index..<(index + pattern.count)].map(\.orig).joined(separator: " ")
        for (offset, norm) in replacement.enumerated() {
          result.append(ReminderToken(norm: norm, orig: offset == 0 ? origs : ""))
        }
        index += pattern.count
        continue outer
      }
      result.append(numbered[index])
      index += 1
    }
    return result
  }

  static func isNumber(_ word: String) -> Bool {
    !word.isEmpty && word.allSatisfy(\.isNumber)
  }

  // MARK: A time phrase

  enum Meridiem: Sendable { case am, pm }

  struct Clock: Equatable, Sendable {
    var hour: Int
    var minute: Int
    var meridiem: Meridiem?
    /// Said as a 24-hour or unambiguous time ("18:00", "06:30", "midday").
    var fixed = false
  }

  private enum Day { case today, tomorrow }

  /// A clock time at `words[index...]`: "6", "6:30", "6.30 pm", "half past 6", "quarter to 7",
  /// "noon", "1830". Returns the clock and how many words it used.
  static func clock(in words: ArraySlice<String>, at index: Int) -> (Clock, Int)? {
    guard index < words.endIndex else { return nil }
    let word = words[index]
    let next = index + 1 < words.endIndex ? words[index + 1] : nil
    let afterNext = index + 2 < words.endIndex ? words[index + 2] : nil
    switch word {
    case "noon", "midday": return (Clock(hour: 12, minute: 0, fixed: true), 1)
    case "midnight": return (Clock(hour: 0, minute: 0, fixed: true), 1)
    case "half", "quarter":
      guard let next, next == "past" || next == "to", let afterNext, let hour = Int(afterNext), (1...12).contains(hour) else {
        return nil
      }
      var used = 3
      var meridiem: Meridiem?
      if index + 3 < words.endIndex, let mer = Self.meridiem(words[index + 3]) {
        meridiem = mer
        used = 4
      }
      if word == "half" {
        guard next == "past" else { return nil }
        return (Clock(hour: hour, minute: 30, meridiem: meridiem), used)
      }
      if next == "past" { return (Clock(hour: hour, minute: 15, meridiem: meridiem), used) }
      return (Clock(hour: hour == 1 ? 12 : hour - 1, minute: 45, meridiem: meridiem), used)
    default:
      break
    }
    var hour: Int
    var minute = 0
    var fixed = false
    if let match = word.wholeMatch(of: #/(\d{1,2})[:.](\d{2})/#), let h = Int(match.1), let m = Int(match.2) {
      hour = h
      minute = m
      fixed = match.1.count == 2 && match.1.hasPrefix("0")
    } else if word.count <= 2, let h = Int(word) {
      hour = h
    } else if word.count == 4 || word.count == 3, let value = Int(word) {
      hour = value / 100
      minute = value % 100
      fixed = true
    } else {
      return nil
    }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    if let next, let mer = Self.meridiem(next) {
      guard (1...12).contains(hour) else { return nil }
      return (Clock(hour: hour, minute: minute, meridiem: mer), 2)
    }
    return (Clock(hour: hour, minute: minute, fixed: fixed || hour == 0 || hour > 12), 1)
  }

  private static func meridiem(_ word: String) -> Meridiem? {
    switch word {
    case "am": .am
    case "pm": .pm
    default: nil
    }
  }

  /// A whole time phrase, every word of it, or nil.
  static func parsePhrase(_ words: ArraySlice<String>, now: Date, calendar: Calendar) -> ReminderWhen? {
    guard let first = words.first else { return nil }
    if first == "in", words.count > 1, isNumber(words[words.startIndex + 1]) {
      guard let minutes = duration(words.dropFirst()) else { return nil }
      return .once(now.addingTimeInterval(TimeInterval(minutes * 60)))
    }
    var index = words.startIndex
    var daily = false
    var day: Day?
    var hint: Meridiem?
    var defaultTime: (Int, Int)?
    var clock: Clock?
    func word(_ offset: Int) -> String? { index + offset < words.endIndex ? words[index + offset] : nil }
    while index < words.endIndex {
      let current = words[index]
      let part1 = word(1).flatMap(partOfDay)
      let part2 = word(1) == "the" ? word(2).flatMap(partOfDay) : nil
      if current == "every", word(1) == "day" {
        guard !daily else { return nil }
        daily = true
        index += 2
      } else if current == "daily" {
        guard !daily else { return nil }
        daily = true
        index += 1
      } else if current == "today" {
        guard day == nil else { return nil }
        day = .today
        index += 1
      } else if current == "tonight" {
        guard day == nil else { return nil }
        day = .today
        hint = .pm
        defaultTime = (20, 0)
        index += 1
      } else if current == "tomorrow" {
        guard day == nil else { return nil }
        day = .tomorrow
        defaultTime = (9, 0)
        index += 1
        if let part = part1 {
          hint = part.meridiem
          defaultTime = part.time
          index += 1
        }
      } else if current == "this", let part = part1, word(1) != "night" {
        guard day == nil else { return nil }
        day = .today
        hint = part.meridiem
        defaultTime = part.time
        index += 2
      } else if current == "in", let part = part2, word(2) != "night" {
        guard hint == nil else { return nil }
        hint = part.meridiem
        if defaultTime == nil { defaultTime = part.time }
        index += 3
      } else if current == "at", word(1) == "night" {
        guard hint == nil else { return nil }
        hint = .pm
        index += 2
      } else if current == "at" || current == "by" || current == "for" || current == "on" {
        index += 1
      } else if let found = Self.clock(in: words, at: index) {
        guard clock == nil else { return nil }
        clock = found.0
        index += found.1
      } else {
        return nil
      }
    }
    if let clock {
      return resolve(clock, day: day, hint: hint, daily: daily, now: now, calendar: calendar)
    }
    guard let defaultTime, !daily else { return nil }
    let clockDefault = Clock(hour: defaultTime.0, minute: defaultTime.1, fixed: true)
    return resolve(clockDefault, day: day, hint: nil, daily: false, now: now, calendar: calendar)
  }

  private struct PartOfDay {
    var meridiem: Meridiem
    var time: (Int, Int)
  }

  private static func partOfDay(_ word: String) -> PartOfDay? {
    switch word {
    case "morning": PartOfDay(meridiem: .am, time: (9, 0))
    case "afternoon": PartOfDay(meridiem: .pm, time: (14, 0))
    case "evening": PartOfDay(meridiem: .pm, time: (18, 0))
    case "night": PartOfDay(meridiem: .pm, time: (20, 0))
    default: nil
    }
  }

  /// "20 minutes", "2 hours", "1 hour and 30 minutes", "90 mins". Minutes, or nil.
  static func duration(_ words: ArraySlice<String>) -> Int? {
    var total = 0
    var index = words.startIndex
    var parts = 0
    while index < words.endIndex {
      if parts > 0 {
        guard words[index] == "and" else { return nil }
        index += 1
      }
      guard index + 1 < words.endIndex, let value = Int(words[index]) else { return nil }
      switch words[index + 1] {
      case "minute", "minutes", "min", "mins": total += value
      case "hour", "hours", "hr", "hrs": total += value * 60
      default: return nil
      }
      index += 2
      parts += 1
    }
    return parts > 0 && total > 0 && total <= 60 * 24 * 7 ? total : nil
  }

  private static func resolve(
    _ clock: Clock, day: Day?, hint: Meridiem?, daily: Bool, now: Date, calendar: Calendar
  ) -> ReminderWhen? {
    let meridiem = clock.meridiem ?? hint
    let hour = clock.hour
    let minute = clock.minute
    let candidates: [Int]
    if clock.fixed {
      candidates = [hour]
    } else if let meridiem {
      candidates = [hour % 12 + (meridiem == .pm ? 12 : 0)]
    } else if hour == 12 {
      candidates = [12]
    } else if daily || day == .tomorrow {
      candidates = [(7...11).contains(hour) ? hour : hour + 12]
    } else {
      candidates = [hour, hour + 12]
    }
    if daily { return .daily(hour: candidates[0], minute: minute) }
    let today = calendar.startOfDay(for: now)
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
    func at(_ base: Date, _ hour: Int) -> Date? {
      calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)
    }
    switch day {
    case .today:
      let dates = candidates.compactMap { at(today, $0) }
      return dates.first(where: { $0 > now }).map(ReminderWhen.once) ?? dates.last.map(ReminderWhen.once)
    case .tomorrow:
      return at(tomorrow, candidates[0]).map(ReminderWhen.once)
    case nil:
      let dates = (candidates.compactMap { at(today, $0) } + candidates.compactMap { at(tomorrow, $0) }).sorted()
      return dates.first(where: { $0 > now }).map(ReminderWhen.once)
    }
  }

  /// "at 7" in "I took my pill at 7": the latest such time that has already passed (today or
  /// yesterday).
  static func pastTime(_ clock: Clock, now: Date, calendar: Calendar) -> Date? {
    var hours: [Int]
    if clock.fixed || clock.hour == 0 || clock.hour > 12 {
      hours = [clock.hour]
    } else if let meridiem = clock.meridiem {
      hours = [clock.hour % 12 + (meridiem == .pm ? 12 : 0)]
    } else {
      hours = [clock.hour % 12, clock.hour % 12 + 12]
    }
    let today = calendar.startOfDay(for: now)
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
    let dates = [today, yesterday].flatMap { base in
      hours.compactMap { calendar.date(bySettingHour: $0, minute: clock.minute, second: 0, of: base) }
    }
    return dates.filter { $0 <= now }.max()
  }

  // MARK: Finding the time in a sentence

  /// The time and the rest of the words, from "in 20 minutes to take the bins out", "to call Mum at
  /// 6 tomorrow" or "tomorrow to call Mum at 9". Fixed rules, then NSDataDetector. nil if there is
  /// no time.
  static func split(_ tokens: [ReminderToken], now: Date, calendar: Calendar) -> (when: ReminderWhen, rest: [ReminderToken])? {
    let words = tokens.map(\.norm)
    guard !words.isEmpty else { return nil }
    guard let found = fixedRules(tokens, now: now, calendar: calendar) else { return detected(tokens, now: now) }
    // "on 3 December at 10 am": the fixed rules only saw "at 10 am"; a date word left in the task
    // means NSDataDetector should read the whole thing.
    if found.rest.contains(where: { dateWords.contains($0.norm) }), let whole = detected(tokens, now: now) { return whole }
    return found
  }

  private static let dateWords: Set<String> = [
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
    "june", "july", "august", "september", "october", "november", "december", "jan", "feb", "apr", "jun", "jul", "aug", "sep",
    "sept", "oct", "nov", "dec",
  ]

  private static func fixedRules(
    _ tokens: [ReminderToken], now: Date, calendar: Calendar
  ) -> (when: ReminderWhen, rest: [ReminderToken])? {
    let words = tokens.map(\.norm)
    if let lead = longestPhrase(words, from: 0, now: now, calendar: calendar) {
      var rest = Array(tokens[lead.length...])
      // "tomorrow to call Mum at 9": a day first and a clock last make one time.
      let restWords = rest.map(\.norm)
      if let trail = trailingPhrase(restWords, now: now, calendar: calendar),
        let both = parsePhrase(
          ArraySlice(Array(words[0..<lead.length]) + Array(restWords[trail.start...])), now: now, calendar: calendar)
      {
        rest = Array(rest[..<trail.start])
        return (both, rest)
      }
      return (lead.when, rest)
    }
    if let trail = trailingPhrase(words, now: now, calendar: calendar), trail.start > 0 {
      return (trail.when, Array(tokens[..<trail.start]))
    }
    return nil
  }

  private static func longestPhrase(
    _ words: [String], from start: Int, now: Date, calendar: Calendar
  ) -> (when: ReminderWhen, length: Int)? {
    guard start < words.count, anchors.contains(words[start]) else { return nil }
    for length in stride(from: min(10, words.count - start), through: 1, by: -1) {
      if let when = parsePhrase(words[start..<(start + length)], now: now, calendar: calendar) { return (when, length) }
    }
    return nil
  }

  private static func trailingPhrase(_ words: [String], now: Date, calendar: Calendar) -> (when: ReminderWhen, start: Int)? {
    let count = words.count
    guard count > 0 else { return nil }
    // Not "for" at the end: "book a table for 6" is about people, not a time.
    for start in max(0, count - 10)..<count where anchors.contains(words[start]) && words[start] != "for" {
      if let when = parsePhrase(words[start..<count], now: now, calendar: calendar) { return (when, start) }
    }
    return nil
  }

  /// NSDataDetector for what the fixed rules don't cover ("on Friday at 3", "on 3 December at 10 am").
  /// It reads the phone's own clock and time zone.
  private static func detected(_ tokens: [ReminderToken], now: Date) -> (when: ReminderWhen, rest: [ReminderToken])? {
    let text = tokens.map(\.orig).filter { !$0.isEmpty }.joined(separator: " ")
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
      let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let date = match.date, let range = Range(match.range, in: text)
    else { return nil }
    var rest = text
    rest.removeSubrange(range)
    var restTokens = ReminderTimeParser.tokens(rest)
    while let last = restTokens.last, ["on", "at", "by", "for"].contains(last.norm) { restTokens.removeLast() }
    return (.once(date), restTokens)
  }
}
