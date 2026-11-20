/*
 * LettersExport - the letters log as plain text or CSV, for the share sheet
 *
 * Only built when the user taps an export button (ShareLink in LettersPanel); the data is made
 * when the share sheet asks for it. Amounts follow the log: a sure figure, or "not read for sure".
 * CSV is RFC 4180 (quoted fields, doubled quotes, CRLF rows) and a cell that starts with = + - @
 * gets a leading apostrophe, so a spreadsheet can't run a letter's text as a formula. Pure Swift
 * apart from the Transferable wrapper.
 */

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum LettersExport {
  enum Format: Sendable { case text, csv }

  static func amountText(_ record: LetterRecord) -> String {
    switch record.amount {
    case .none: ""
    case .notSure: "not read for sure"
    case .sure(let currency, let minor, let isTotal, let minimum):
      (isTotal ? "total " : "") + Money(currency: currency, minor: minor).spoken()
        + (minimum.map { ", minimum " + Money(currency: currency, minor: $0).spoken() } ?? "")
    }
  }

  static func dueText(_ record: LetterRecord) -> String {
    guard let spoken = record.dueSpoken else { return "" }
    guard record.dueSure else { return "a date not read for sure" }
    switch record.deadlineKind {
    case .pay: return "pay by \(spoken)"
    case .reply: return "reply by \(spoken)"
    case .appointment: return "appointment \(spoken)"
    default: return spoken
    }
  }

  static func scamText(_ record: LetterRecord) -> String {
    let signs = record.signs
    return signs.isEmpty ? "none found" : signs.map(\.spoken).joined(separator: "; ")
  }

  static func text(_ records: [LetterRecord], now: Date, calendar: Calendar = .current) -> String {
    var out = [
      "SpeakUp letters",
      "Exported \(LetterDay(now, calendar: calendar).spoken). \(records.count == 1 ? "1 letter" : "\(records.count) letters").",
    ]
    for (i, record) in records.enumerated() {
      out.append("")
      out.append("Letter \(i + 1): \(record.title)")
      var fields: [(String, String)] = [("Saved", LetterDay(record.savedAt, calendar: calendar).spoken)]
      fields.append(("From", record.sender ?? "not found"))
      if let to = record.recipient { fields.append(("For", to)) }
      fields.append(("Kind", LetterSpeech.kindPhrase(kind: record.letterKind)))
      if let date = record.letterDate { fields.append(("Dated", date.spoken)) }
      if let subject = record.subject { fields.append(("About", subject)) }
      let amount = amountText(record)
      if !amount.isEmpty { fields.append(("Amount", amount)) }
      let due = dueText(record)
      if !due.isEmpty { fields.append(("Due", due)) }
      if !record.references.isEmpty { fields.append(("References", record.referenceLines.joined(separator: "; "))) }
      fields.append(("Scam signs", scamText(record)))
      out += fields.map { "\($0.0): \($0.1)" }
      out.append("Text:")
      out.append(record.text)
    }
    return out.joined(separator: "\n") + "\n"
  }

  static let csvHeader = ["saved", "from", "for", "kind", "dated", "about", "amount", "due", "references", "scam_signs", "text"]

  static func csv(_ records: [LetterRecord], calendar: Calendar = .current) -> String {
    var rows = [csvHeader]
    for record in records {
      rows.append([
        isoDay(LetterDay(record.savedAt, calendar: calendar)), record.sender ?? "", record.recipient ?? "", record.kind,
        record.letterDate.map(isoDay) ?? "", record.subject ?? "", amountText(record), dueText(record),
        record.referenceLines.joined(separator: "; "), scamText(record), record.text,
      ])
    }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
  }

  static func isoDay(_ day: LetterDay) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }

  static func csvField(_ value: String) -> String {
    var value = value
    if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// What the share sheet gets. The file is made when it's asked for.
struct LettersExportFile: Transferable, Sendable {
  let records: [LetterRecord]
  let format: LettersExport.Format

  var fileName: String { format == .csv ? "SpeakUp letters.csv" : "SpeakUp letters.txt" }

  var data: Data {
    switch format {
    case .text: Data(LettersExport.text(records, now: Date()).utf8)
    case .csv: Data(LettersExport.csv(records).utf8)
    }
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { file in file.data }
      .suggestedFileName("SpeakUp letters.csv")
      .exportingCondition { $0.format == .csv }
    DataRepresentation(exportedContentType: .plainText) { file in file.data }
      .suggestedFileName("SpeakUp letters.txt")
      .exportingCondition { $0.format == .text }
  }
}
