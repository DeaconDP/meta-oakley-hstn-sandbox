/*
 * LetterRecord - one letter in the letters log: the summary fields and the text, never the photo
 *
 * Built from a Letter the mail reader has read (LetterRecord(letter:...)). Only what's safe to say
 * is kept: a sure amount as a figure, an unsure one as "not read for sure" (the money rule), and
 * the text is Letter.safeText per paragraph, so a guessed figure can't come back from the log
 * either. The id is stable per letter (sender, letter date, first reference), so reading the same
 * letter again replaces its entry and its reminder instead of adding a second one.
 * Pure Swift, Codable; LettersStore keeps the list on the phone.
 */

import Foundation

/// A calendar day with no time or time zone: "24 November 2026".
struct LetterDay: Equatable, Hashable, Codable, Sendable, Comparable {
  var year: Int
  var month: Int
  var day: Int

  init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  init(_ date: LetterDate) { self.init(year: date.year, month: date.month, day: date.day) }

  init(_ date: Date, calendar: Calendar) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
  }

  /// The first day in a spoken deadline ("24 November 2026 at 10:30am"); nil for "within 14 days".
  init?(spoken: String) {
    guard let date = LetterText.dates(spoken).first else { return nil }
    self.init(date)
  }

  var spoken: String { "\(day) \(LetterText.months[max(0, min(11, month - 1))]) \(year)" }

  /// This day at `hour`:00 in the calendar's time zone.
  func date(in calendar: Calendar, hour: Int = 0) -> Date? {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
  }

  static func < (a: LetterDay, b: LetterDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

struct LetterRecord: Equatable, Codable, Identifiable, Sendable {
  enum SavedAmount: Equatable, Codable, Sendable {
    case none
    case sure(currency: String, minor: Int, isTotal: Bool, minimumMinor: Int?)
    /// There was an amount, but it couldn't be read for sure. No figure is kept.
    case notSure
  }

  var id: String
  var savedAt: Date
  /// LetterKind raw value.
  var kind: String
  var sender: String?
  var recipient: String?
  var letterDate: LetterDay?
  var subject: String?
  var amount: SavedAmount
  /// "pay", "reply", "appointment", "other".
  var dueKind: String?
  /// As the letter says it: "24 November 2026", "within 14 days", "8 December 2026 at 10:30am".
  var dueSpoken: String?
  var dueSure: Bool
  /// The deadline's day, when the letter gives one that was read for sure.
  var dueDay: LetterDay?
  var references: [Reference]
  /// ScamSign raw values.
  var scamSigns: [String]
  /// The letter's paragraphs, unsure amounts masked (Letter.safeText).
  var paragraphs: [String]
  /// The summary as it was spoken.
  var summary: String
  /// When a reminder was set for it, if one was.
  var reminderAt: Date?

  /// "account number 8842 1937 55", as printed.
  var referenceLines: [String] { references.map { "\($0.label) \($0.value)" } }

  var letterKind: LetterKind { LetterKind(rawValue: kind) ?? .unknown }
  var signs: [ScamSign] { scamSigns.compactMap(ScamSign.init(rawValue:)) }
  var text: String { paragraphs.joined(separator: "\n\n") }

  var money: Money? {
    if case .sure(let currency, let minor, _, _) = amount { return Money(currency: currency, minor: minor) }
    return nil
  }

  var deadlineKind: DueKind? {
    switch dueKind {
    case "pay": .pay
    case "reply": .reply
    case "appointment": .appointment
    case "other": .other
    default: nil
    }
  }

  /// "the letter from Northgate Energy" / "the letter you saved on 20 November 2026".
  func spokenName(calendar: Calendar = .current) -> String {
    if let sender { return "the letter from \(sender)" }
    return "the letter you saved on \(LetterDay(savedAt, calendar: calendar).spoken)"
  }

  /// Short, for a list: "Northgate Energy bill".
  var title: String {
    let noun: String =
      switch letterKind {
      case .bill: "bill"
      case .bank: "bank letter"
      case .official: "official letter"
      case .medical: "medical letter"
      case .personal: "personal letter"
      case .advert: "advert"
      case .unknown: "letter"
      }
    return sender.map { "\($0) \(noun)" } ?? noun.capitalisedFirst
  }
}

extension LetterRecord {
  init(letter: Letter, id: String, summary: String, savedAt: Date) {
    let amount: SavedAmount =
      switch letter.amount {
      case .none: .none
      case .sure(let money, let minimum, let isTotal):
        .sure(currency: money.currency, minor: money.minor, isTotal: isTotal, minimumMinor: minimum?.minor)
      case .unsure, .conflict: .notSure
      }
    let dueKind: String? = letter.due.map { due in
      switch due.kind {
      case .pay: "pay"
      case .reply: "reply"
      case .appointment: "appointment"
      case .other: "other"
      }
    }
    let dueDay = letter.due.flatMap { $0.sure ? LetterDay(spoken: $0.spoken) : nil }
    self.init(
      id: id, savedAt: savedAt, kind: letter.kind.rawValue, sender: letter.sender, recipient: letter.recipient ?? letter.salutation,
      letterDate: letter.date.map(LetterDay.init), subject: letter.subject, amount: amount, dueKind: dueKind,
      dueSpoken: letter.due?.spoken, dueSure: letter.due?.sure ?? false, dueDay: dueDay,
      references: letter.references, scamSigns: letter.scamSigns.map(\.rawValue),
      paragraphs: letter.paragraphs.map { LetterSpeech.masked($0, unsureMoney: letter.unsureMoney) }, summary: summary,
      reminderAt: nil)
  }

  /// A stable id for a letter: the same letter read again gets the same id.
  static func stableID(for letter: Letter) -> String {
    var key = [letter.sender ?? "", letter.date.map { LetterDay($0).spoken } ?? "", letter.references.first?.value ?? ""]
      .joined(separator: "|")
    if key == "||" {
      key = String(letter.safeText.prefix(300))
    }
    return "letter-" + fnv1a(normalised(key))
  }

  static func normalised(_ text: String) -> String {
    text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "|" }.joined(separator: " ")
  }

  /// FNV-1a, 64 bit, as hex: stable across launches (Swift's hashValue isn't).
  static func fnv1a(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
