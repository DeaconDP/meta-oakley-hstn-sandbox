/*
 * LettersSpeech - what the mail reader says about the letters log
 *
 * "my letters" (a count, then the newest five), a saved letter picked by sender, and the answers
 * to "how much", "when is it due", "who is it from" about a saved letter. Amounts follow the log:
 * a sure figure, or that it couldn't be read for sure (the money rule). Pure Swift.
 */

import Foundation

enum LettersSpeech {
  static let listLimit = 5

  /// One line per letter in a list: "Northgate Energy bill, saved 20 November, pay by 24 November 2026".
  static func listItem(_ record: LetterRecord, calendar: Calendar) -> String {
    var out = "\(record.title), saved \(LetterDay(record.savedAt, calendar: calendar).spoken)"
    let due = LettersExport.dueText(record)
    if !due.isEmpty && record.dueSure { out += ", \(due)" }
    return out
  }

  static func list(_ records: [LetterRecord], calendar: Calendar) -> String {
    guard !records.isEmpty else {
      return "You have no saved letters. Letters you read with the mail reader are kept here, on this phone."
    }
    let count = records.count == 1 ? "You have one saved letter" : "You have \(records.count) saved letters"
    let shown = records.prefix(listLimit).map { listItem($0, calendar: calendar) }
    var out = "\(count). " + (records.count > 1 ? "Newest first: " : "") + shown.joined(separator: ". ") + "."
    if records.count > listLimit { out += " And \(records.count - listLimit) more on the screen." }
    out += " Say read the letter from, then who it's from."
    return out
  }

  static func opened(_ record: LetterRecord, matches: Int, calendar: Calendar) -> String {
    var out = "\(record.title.capitalisedFirst), saved on \(LetterDay(record.savedAt, calendar: calendar).spoken)."
    if matches > 1 { out += " There are \(matches) letters that match; this is the newest." }
    return out + " " + record.summary
  }

  /// The answer to a question about a saved letter.
  static func answer(_ command: MailCommand, _ record: LetterRecord) -> String {
    switch command {
    case .from:
      return record.sender.map { "It's from \($0)." } ?? "I couldn't see who it was from when it was saved."
    case .forWhom:
      return record.recipient.map { "It's addressed to \($0)." } ?? "I couldn't see who it was for."
    case .howMuch:
      switch record.amount {
      case .sure(let currency, let minor, let isTotal, let minimum):
        var out = (isTotal ? "The total is " : "The amount due is ") + Money(currency: currency, minor: minor).spoken() + "."
        if let minimum { out += " The minimum payment is \(Money(currency: currency, minor: minimum).spoken())." }
        return out
      case .notSure:
        return "I couldn't read the amount for sure when this letter was saved. Hold the letter up and say what is this letter."
      case .none:
        return "I didn't find an amount to pay in this letter."
      }
    case .whenDue:
      guard let spoken = record.dueSpoken else { return "I didn't find a due date or deadline in this letter." }
      guard record.dueSure else { return "There's a date in it I couldn't read for sure." }
      return LettersExport.dueText(record).capitalisedFirst + "."
    case .scam:
      guard !record.signs.isEmpty else { return LetterSpeech.noScamSigns }
      let signs = record.signs.map(\.spoken)
      let list = signs.count == 1 ? signs[0] : signs.dropLast().joined(separator: ", ") + ", and " + signs[signs.count - 1]
      return "It has signs of a scam: it \(list). \(LetterSpeech.scamAdvice)"
    case .kind:
      return "It's \(LetterSpeech.kindPhrase(kind: record.letterKind))" + (record.sender.map { " from \($0)" } ?? "") + "."
    case .date:
      return record.letterDate.map { "It's dated \($0.spoken)." } ?? "I didn't see a date on it."
    case .reference:
      return record.references.isEmpty
        ? "I didn't see an account or reference number."
        : record.references.prefix(3).map { $0.spoken.capitalisedFirst + "." }.joined(separator: " ")
    default:
      return record.summary
    }
  }
}
