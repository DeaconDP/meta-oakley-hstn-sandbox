/*
 * LabelDates - finding best-before, use-by and expiry dates in label text
 *
 * Port of Android's tools/labels/LabelDates.kt (same rules, same tests).
 * "When does it expire?" reads the date out as a date ("12 March 2027") and says if it has passed.
 * Labels print dates in many ways, so this looks for a date keyword (BEST BEFORE, BBE, BB, USE BY,
 * EXP, EXPIRY, DISPLAY UNTIL, SELL BY...) and then for a date just after it, on the same line or the
 * next: 12/03/27, 12.03.2027, 2027-03-12, 12 MAR, 12MAR27, March 12, 2027, MAR 2027, 03 2027,
 * 03/27, 2027-03. Numbers are read day first (UK and EU labels) unless that's impossible. A day and
 * month with no year get the year that puts the date nearest today, and the year isn't spoken. Full
 * dates with no keyword are reported too, as "a date". "Best before: see top of pack" is reported
 * as where to look. Pure: today is passed in, so tests are stable.
 */

import Foundation

/// A calendar day with no time zone, so "today" and label dates compare as days.
struct CivilDate: Equatable, Comparable, Sendable {
  var year: Int
  var month: Int
  var day: Int

  init(_ year: Int, _ month: Int, _ day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  static func today(calendar: Calendar = .current, now: Date = Date()) -> CivilDate {
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    return CivilDate(parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
  }

  static func < (a: CivilDate, b: CivilDate) -> Bool {
    (a.year, a.month, a.day) < (b.year, b.month, b.day)
  }

  static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

  static func daysIn(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// Days since 1970-01-01 (proleptic Gregorian), for "nearest year" distances.
  var epochDay: Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }
}

enum LabelDateKind: String, Sendable {
  case bestBefore
  case useBy
  case expiry
  case displayUntil
  case sellBy
  /// A full date with no keyword next to it.
  case unlabelled

  var spoken: String {
    switch self {
    case .bestBefore: "Best before"
    case .useBy: "Use by"
    case .expiry: "Expiry date"
    case .displayUntil: "Display until"
    case .sellBy: "Sell by"
    case .unlabelled: "There's a date:"
    }
  }
}

/// A date found on a label. `day` is nil for month-only dates ("best before end 03 2027").
struct LabelDate: Equatable, Sendable {
  var kind: LabelDateKind
  var year: Int
  var month: Int
  var day: Int?
  /// No year was printed; `year` is the nearest one to today.
  var yearGuessed = false
  /// "Best before end" / month-only: the date means the end of that month.
  var endOfMonth = false

  static let monthNames = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
  ]

  /// The last day the date covers.
  var lastDay: CivilDate { CivilDate(year, month, day ?? CivilDate.daysIn(year, month)) }

  func isPast(_ today: CivilDate) -> Bool { lastDay < today }

  /// "12 March 2027", "12 March" (no year printed), "the end of March 2027", "March 2027".
  func spoken() -> String {
    let name = Self.monthNames[month - 1]
    if let day, yearGuessed { return "\(day) \(name)" }
    if let day { return "\(day) \(name) \(year)" }
    if endOfMonth { return "the end of \(name) \(year)" }
    return "\(name) \(year)"
  }
}

/// What LabelDates.find saw. `elsewhere` is where the label says the date is ("top", "lid").
struct DateFindings: Equatable, Sendable {
  var dates: [LabelDate]
  var keywordWithoutDate: LabelDateKind?
  var elsewhere: String?
}

enum LabelDates {
  private static let mon =
    "(JANUARY|FEBRUARY|MARCH|APRIL|JUNE|JULY|AUGUST|SEPTEMBER|SEPT|OCTOBER|NOVEMBER|DECEMBER|"
    + "JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)"

  // Longest first, so "BEST BEFORE END" wins over "BEST BEFORE", "EXPIRY DATE" over "EXP".
  private static let keywords: [(LabelDateKind, LabelsRegex)] = [
    (.bestBefore, LabelsRegex("BEST\\s*BEFORE\\s*END(?:\\s*OF)?|\\bBBE\\b")),
    (.bestBefore, LabelsRegex("BEST\\s*BEFORE|BEST\\s*BY|\\bB\\.?B\\b\\.?")),
    (.useBy, LabelsRegex("USE\\s*BY|USE\\s*BEFORE|CONSUME\\s*BY|ENJOY\\s*BY")),
    (.expiry, LabelsRegex("EXPIRY\\s*DATE|EXPIRATION\\s*DATE|EXPIRY|EXPIRES|EXPIRATION|\\bEXP\\b\\.?")),
    (.displayUntil, LabelsRegex("DISPLAY\\s*UNTIL")),
    (.sellBy, LabelsRegex("SELL\\s*BY")),
  ]

  private static let see = LabelsRegex(
    "^SEE\\s+(?:THE\\s+)?(TOP|BASE|BOTTOM|LID|SIDE|BACK|FRONT|CAP|END|NECK|SEAL|SHOULDER|CRIMP|CARTON|BOX)")
  private static let gap = LabelsRegex("^[\\s:.,\\-\u{2013}]*(?:(?:DATE|ON|IS)\\b[\\s:.,\\-]*)*")
  private static let wordStart = LabelsRegex("(?<![0-9A-Z])(?=[0-9A-Z])")

  private struct Parsed {
    var date: LabelDate
    var length: Int
  }

  /// All dates in `text` (any case; OCR lines joined with newlines), keyword dates first, in the
  /// order they appear. `today` decides the year for dates printed without one.
  static func find(_ text: String, today: CivilDate) -> DateFindings {
    let up = text.uppercased().replacingOccurrences(of: "\u{2019}", with: "'")
    let length = LabelsString.length(up)
    var dates: [LabelDate] = []
    var used: [Range<Int>] = []
    var keywordWithoutDate: LabelDateKind?
    var elsewhere: String?

    let hits = keywords.flatMap { kind, regex in regex.all(in: up).map { ($0, kind) } }
      .sorted { a, b in a.0.start != b.0.start ? a.0.start < b.0.start : a.0.range.length > b.0.range.length }
    var lastEnd = -1
    for (match, kind) in hits {
      if match.start <= lastEnd { continue }  // inside a longer keyword already taken
      lastEnd = match.end - 1
      let isEnd = match.value.contains("END") || LabelsString.trimmed(match.value) == "BBE"
      let after = match.end
      let gapLength = gap.first(in: LabelsString.substring(up, from: after))?.range.length ?? 0
      let start = after + gapLength
      let window = LabelsString.substring(up, from: start, to: min(length, start + 40))
      if let where_ = see.first(in: window) {
        elsewhere = elsewhere ?? where_.group(1).lowercased()
        continue
      }
      if let parsed = parseAt(window, kind: kind, end: isEnd, today: today, labelled: true) {
        dates.append(parsed.date)
        used.append(start..<(start + parsed.length))
        lastEnd = max(lastEnd, start + parsed.length - 1)
      } else {
        keywordWithoutDate = keywordWithoutDate ?? kind
      }
    }

    // Full dates with no keyword: only unambiguous forms with a year, at word boundaries.
    for match in wordStart.all(in: up) {
      let index = match.start
      if used.contains(where: { $0.contains(index) }) { continue }
      let window = LabelsString.substring(up, from: index, to: min(length, index + 40))
      guard let parsed = parseAt(window, kind: .unlabelled, end: false, today: today, labelled: false) else { continue }
      if !dates.contains(where: { $0.year == parsed.date.year && $0.month == parsed.date.month && $0.day == parsed.date.day }) {
        dates.append(parsed.date)
      }
      used.append(index..<(index + parsed.length))
    }
    return DateFindings(dates: dates, keywordWithoutDate: dates.isEmpty ? keywordWithoutDate : nil, elsewhere: elsewhere)
  }

  private static let ymd = LabelsRegex("^(\\d{4})[-/. ](\\d{1,2})[-/. ](\\d{1,2})(?!\\d)")
  private static let dmy = LabelsRegex("^(\\d{1,2})\\s?([/.\\-])\\s?(\\d{1,2})\\s?\\2\\s?(\\d{4}|\\d{2})(?!\\d)")
  private static let dmySpaced = LabelsRegex("^(\\d{1,2}) (\\d{1,2}) (\\d{4}|\\d{2})(?!\\d)")
  private static let dMonY = LabelsRegex(
    "^(\\d{1,2})(?:ST|ND|RD|TH)?\\s?[-/.]?\\s?\(mon)\\.?(?:\\s?[-/.,]?\\s?(\\d{4}|\\d{2})(?!\\d))?(?![A-Z])")
  private static let monDY = LabelsRegex("^\(mon)\\.?\\s?(\\d{1,2})(?:ST|ND|RD|TH)?,?\\s(\\d{4})(?!\\d)")
  private static let monY = LabelsRegex("^\(mon)\\.?\\s?[-/.,]?\\s?(\\d{4}|\\d{2})(?!\\d)")
  private static let yM = LabelsRegex("^(\\d{4})[-/.](\\d{1,2})(?!\\d)")
  private static let mYYYY = LabelsRegex("^(\\d{1,2})\\s?[-/. ]\\s?(\\d{4})(?!\\d)")
  private static let nnNN = LabelsRegex("^(\\d{1,2})\\s?[-/.]\\s?(\\d{1,2})(?![\\d/.\\-])")

  private static func parseAt(_ w: String, kind: LabelDateKind, end: Bool, today: CivilDate, labelled: Bool) -> Parsed? {
    func int(_ s: String) -> Int { Int(s) ?? 0 }
    if let m = ymd.first(in: w), let d = date(kind, int(m.group(1)), int(m.group(2)), int(m.group(3))) {
      return Parsed(date: d, length: m.range.length)
    }
    if let m = dmy.first(in: w) {
      let a = int(m.group(1))
      let b = int(m.group(3))
      let y = year(m.group(4))
      // Day first unless the second number can't be a month.
      let d = b > 12 && a <= 12 ? date(kind, y, a, b) : date(kind, y, b, a)
      if let d { return Parsed(date: d, length: m.range.length) }
    }
    if labelled, let m = dmySpaced.first(in: w), let d = date(kind, year(m.group(3)), int(m.group(2)), int(m.group(1))) {
      return Parsed(date: d, length: m.range.length)
    }
    if let m = dMonY.first(in: w) {
      let d = int(m.group(1))
      let mo = month(m.group(2))
      let y = m.group(3)
      if !y.isEmpty {
        if let found = date(kind, year(y), mo, d) { return Parsed(date: found, length: m.range.length) }
      } else if labelled, let found = guessYear(kind, mo, d, today) {
        return Parsed(date: found, length: m.range.length)
      }
    }
    if let m = monDY.first(in: w), let d = date(kind, int(m.group(3)), month(m.group(1)), int(m.group(2))) {
      return Parsed(date: d, length: m.range.length)
    }
    guard labelled else { return nil }
    if let m = monY.first(in: w) {
      let mo = month(m.group(1))
      let n = m.group(2)
      // "MAR 27": a year for expiry and best-before-end dates, otherwise the 27th.
      if n.count == 4 || end || kind == .expiry {
        return Parsed(date: LabelDate(kind: kind, year: year(n), month: mo, day: nil, endOfMonth: true), length: m.range.length)
      }
      if let found = guessYear(kind, mo, int(n), today) { return Parsed(date: found, length: m.range.length) }
    }
    if let m = yM.first(in: w) {
      let mo = int(m.group(2))
      if (1...12).contains(mo) {
        return Parsed(date: LabelDate(kind: kind, year: int(m.group(1)), month: mo, day: nil, endOfMonth: true), length: m.range.length)
      }
    }
    if let m = mYYYY.first(in: w) {
      let mo = int(m.group(1))
      if (1...12).contains(mo) {
        return Parsed(date: LabelDate(kind: kind, year: int(m.group(2)), month: mo, day: nil, endOfMonth: true), length: m.range.length)
      }
    }
    if let m = nnNN.first(in: w) {
      let a = int(m.group(1))
      let b = int(m.group(2))
      // "03/27": month and year when the second can't be a month or it's an expiry date;
      // otherwise day and month ("BB 12/03"), year guessed.
      if (1...12).contains(a), b > 12 || end || kind == .expiry {
        return Parsed(date: LabelDate(kind: kind, year: 2000 + b, month: a, day: nil, endOfMonth: true), length: m.range.length)
      }
      if let found = guessYear(kind, b, a, today) { return Parsed(date: found, length: m.range.length) }
    }
    return nil
  }

  private static func year(_ s: String) -> Int { s.count == 2 ? 2000 + (Int(s) ?? 0) : (Int(s) ?? 0) }

  private static func month(_ s: String) -> Int {
    switch String(s.prefix(3)) {
    case "JAN": 1
    case "FEB": 2
    case "MAR": 3
    case "APR": 4
    case "MAY": 5
    case "JUN": 6
    case "JUL": 7
    case "AUG": 8
    case "SEP": 9
    case "OCT": 10
    case "NOV": 11
    default: 12
    }
  }

  private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
    (1990...2100).contains(y) && (1...12).contains(m) && d >= 1 && d <= CivilDate.daysIn(y, m)
  }

  private static func date(_ kind: LabelDateKind, _ y: Int, _ m: Int, _ d: Int) -> LabelDate? {
    valid(y, m, d) ? LabelDate(kind: kind, year: y, month: m, day: d) : nil
  }

  /// A day and month with no year: the year that puts it nearest `today`.
  private static func guessYear(_ kind: LabelDateKind, _ m: Int, _ d: Int, _ today: CivilDate) -> LabelDate? {
    guard (1...12).contains(m) else { return nil }
    let best = ((today.year - 1)...(today.year + 1))
      .filter { valid($0, m, d) }
      .min { abs(CivilDate($0, m, d).epochDay - today.epochDay) < abs(CivilDate($1, m, d).epochDay - today.epochDay) }
    guard let best else { return nil }
    return LabelDate(kind: kind, year: best, month: m, day: d, yearGuessed: true)
  }

  /// What to say for "when does it expire": the first date (and a second of another kind), said as
  /// dates, and whether each has passed. nil when nothing was found, so the caller can ask the user
  /// to turn the pack. "The label says the date is on the top" when the label points elsewhere.
  static func answer(_ findings: DateFindings, today: CivilDate) -> String? {
    if findings.dates.isEmpty {
      if let place = findings.elsewhere {
        return "The label says the date is on the \(place). Turn it so I can see the \(place), then ask again."
      }
      if let kind = findings.keywordWithoutDate {
        return "I can see \(kind.spoken.lowercased()), but I can't make out the date. Hold it a little closer and ask again."
      }
      return nil
    }
    let labelled = findings.dates.filter { $0.kind != .unlabelled }
    let list = labelled.isEmpty ? findings.dates : labelled
    let first = list[0]
    var chosen = [first]
    if let other = list.dropFirst().first(where: { $0.kind != first.kind }) { chosen.append(other) }
    return chosen.map { date in
      let head = "\(date.kind.spoken) \(date.spoken())."
      if date.isPast(today) { return head + " That date has already passed." }
      if date.lastDay == today { return head + " That's today." }
      return head
    }.joined(separator: " ")
  }
}
