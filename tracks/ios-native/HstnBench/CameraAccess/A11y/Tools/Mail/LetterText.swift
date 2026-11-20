/*
 * LetterText - finding money, dates, postcodes and reference numbers in a line of letter text
 *
 * Port of the Android LetterText.kt, same patterns. Fixed patterns, no guessing. Money: "£84.17",
 * "€1,250", "$19.99", "84.17 GBP". A token that looks like money but has a letter where a digit
 * should be ("£8O.17", "£1l.50": OCR confusing O/0 and l/1) is reported as unreadable, never
 * corrected. Dates: "24 November 2026", "Nov 24, 2026", "24/11/2026" (UK order: day first),
 * "2026-11-24". Reference numbers are spoken one character at a time ("1 2 3 4, 5 6 7 8"), so the
 * voice never says "twelve million...". Ranges are UTF-16 NSRanges. Pure Swift.
 */

import Foundation

/// An amount of money in minor units (pence, cents).
struct Money: Hashable, Sendable {
  var currency: String
  var minor: Int

  /// "£84.17", "£1,250", "€3.50". Whole amounts drop the ".00".
  func spoken() -> String {
    let major = minor / 100
    let cents = minor % 100
    let grouped = Self.grouped(major)
    return cents == 0 ? "\(currency)\(grouped)" : "\(currency)\(grouped).\(String(format: "%02d", cents))"
  }

  /// 1684 -> "1,684" (UK grouping, whatever the phone's locale).
  static func grouped(_ value: Int) -> String {
    let digits = Array(String(value))
    var out = ""
    for (i, digit) in digits.enumerated() {
      if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
      out.append(digit)
    }
    return out
  }
}

/// One money-looking token in a line. `money` is nil when a character isn't a digit.
struct MoneyToken: Equatable, Sendable {
  var raw: String
  var range: NSRange
  var money: Money?
  var credit: Bool

  var first: Int { range.location }
  var last: Int { range.location + range.length - 1 }
}

struct LetterDate: Equatable, Sendable {
  var day: Int
  var month: Int
  var year: Int
  var raw: String
  var range: NSRange

  var first: Int { range.location }
  var last: Int { range.location + range.length - 1 }

  func spoken() -> String { "\(day) \(LetterText.months[month - 1]) \(year)" }
}

enum LetterText {
  static let months = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
  ]

  private static let month =
    "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
    + "sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"

  // Currency first. The body allows O/o/l/I/S/B so misread digits are caught, then rejected.
  private static let moneyPrefix = MailRegex(
    "(?<![A-Za-z0-9])(£|\\$|€|GBP ?|EUR ?|USD ?)\\s?([0-9OoIlSB](?:[0-9OoIlSB]|,(?=[0-9OoIlSB]))*(?:\\.[0-9OoIlSB]{2})?)(?![0-9A-Za-z])(\\s?CR\\b)?"
  )
  private static let moneySuffix = MailRegex(
    "(?<![A-Za-z0-9£$€.,])(\\d[\\d,]*(?:\\.\\d{2})?) ?(GBP|EUR|USD|pounds|euros|dollars)\\b", ignoreCase: true)
  private static let groupedDigits = MailRegex("\\d{1,3}(?:,\\d{3})*|\\d+")

  private static let dateDMY = MailRegex(
    "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(month)\\.?,?\\s+(\\d{4})\\b", ignoreCase: true)
  private static let dateMDY = MailRegex(
    "\\b\(month)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b", ignoreCase: true)
  private static let dateNumeric = MailRegex("\\b(\\d{1,2})[/.](\\d{1,2})[/.](\\d{4}|\\d{2})\\b")
  private static let dateISO = MailRegex("\\b(\\d{4})-(\\d{2})-(\\d{2})\\b")

  static let ukPostcode = MailRegex("\\b[A-Z]{1,2}\\d[A-Z\\d]? ?\\d[A-Z]{2}\\b")
  private static let usZip = MailRegex("\\b[A-Z]{2} \\d{5}(?:-\\d{4})?\\b")

  static func money(_ line: String) -> [MoneyToken] {
    var out: [MoneyToken] = []
    for match in moneyPrefix.matches(in: line) {
      let printed = (match.group(1, in: line) ?? "").trimmed
      let symbol =
        switch printed {
        case "GBP": "£"
        case "EUR": "€"
        case "USD": "$"
        default: printed
        }
      let body = match.group(2, in: line) ?? ""
      // A lone "£S" isn't money.
      guard body.contains(where: \.isASCIIDigit) else { continue }
      let credit = !(match.group(3, in: line) ?? "").trimmed.isEmpty
      out.append(MoneyToken(raw: match.value(in: line).trimmed, range: match.range, money: parse(symbol, body), credit: credit))
    }
    for match in moneySuffix.matches(in: line) {
      let r = match.range
      if out.contains(where: { $0.first <= r.location + r.length - 1 && r.location <= $0.last }) { continue }
      let symbol =
        switch (match.group(2, in: line) ?? "").lowercased() {
        case "gbp", "pounds": "£"
        case "eur", "euros": "€"
        default: "$"
        }
      out.append(MoneyToken(raw: match.value(in: line), range: r, money: parse(symbol, match.group(1, in: line) ?? ""), credit: false))
    }
    return out.stableSorted { $0.first }
  }

  /// Strict parse: digits, optional thousands commas, optional two decimals. Else nil.
  private static func parse(_ symbol: String, _ body: String) -> Money? {
    let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count <= 2 else { return nil }
    let whole = parts[0]
    guard groupedDigits.matchesWhole(whole) else { return nil }
    var cents = "00"
    if parts.count == 2 {
      guard parts[1].count == 2, parts[1].allSatisfy(\.isASCIIDigit) else { return nil }
      cents = parts[1]
    }
    guard let major = Int(whole.replacingOccurrences(of: ",", with: "")), let minor = Int(cents) else { return nil }
    return Money(currency: symbol, minor: major * 100 + minor)
  }

  static func dates(_ line: String) -> [LetterDate] {
    var out: [LetterDate] = []
    func add(_ day: Int, _ month: Int, _ year: Int, _ match: NSTextCheckingResult) {
      guard (1...12).contains(month), (1...31).contains(day) else { return }
      let r = match.range
      if out.contains(where: { $0.first <= r.location + r.length - 1 && r.location <= $0.last }) { return }
      out.append(LetterDate(day: day, month: month, year: year < 100 ? 2000 + year : year, raw: match.value(in: line), range: r))
    }
    func int(_ match: NSTextCheckingResult, _ group: Int) -> Int { Int(match.group(group, in: line) ?? "") ?? 0 }
    for m in dateDMY.matches(in: line) { add(int(m, 1), monthOf(m.group(2, in: line) ?? ""), int(m, 3), m) }
    for m in dateMDY.matches(in: line) { add(int(m, 2), monthOf(m.group(1, in: line) ?? ""), int(m, 3), m) }
    for m in dateISO.matches(in: line) { add(int(m, 3), int(m, 2), int(m, 1), m) }
    for m in dateNumeric.matches(in: line) { add(int(m, 1), int(m, 2), int(m, 3), m) }
    return out.stableSorted { $0.first }
  }

  private static func monthOf(_ word: String) -> Int {
    let w = String(word.lowercased().prefix(3))
    return (months.firstIndex { $0.lowercased().hasPrefix(w) } ?? -1) + 1
  }

  static func hasPostcode(_ line: String) -> Bool { ukPostcode.contains(line) || usZip.contains(line) }

  /// A reference spoken character by character: "AB 1234-56" -> "A B, 1 2 3 4, 5 6". Groups
  /// (split at spaces, dashes and slashes) are separated by commas so the voice pauses where the
  /// print does.
  static func spellOut(_ value: String) -> String {
    value.trimmed
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
      .map { group in group.filter { $0.isLetter || $0.isNumber }.uppercased().map(String.init).joined(separator: " ") }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  private static let phoneRun = MailRegex("(?<![£$€\\d.,/])\\b0\\d{2,}(?: \\d{3,})*\\b(?![.,]\\d)")
  private static let longRun = MailRegex("(?<![£$€\\d.,/])\\b\\d{5,}\\b(?![.,]\\d)")

  /// Text made safe to read aloud: long digit runs (account numbers, phone numbers starting with
  /// 0) are spaced out so they're read digit by digit. Money, dates and years are left alone.
  static func forSpeech(_ text: String) -> String {
    let phones = phoneRun.replace(in: text) { spellOut($0.value(in: text)) }
    return longRun.replace(in: phones) { spellOut($0.value(in: phones)) }
  }
}
