/*
 * LettersTests - "deal with this letter" (roadmap V1): reminder offers and days with a fake clock,
 * the voice phrases, the letters log (save, list, replace, delete, forget all, export as text and
 * CSV, kept out of backups), the rule-based explanations, the scam rules from the Android list,
 * the AI explanation's request (the text only, never an image), and MailTool end to end with a
 * fake camera, fake OCR, a fake reminders store and a fake AI explainer.
 */

import CoreGraphics
import SwiftUI
@testable import CameraAccess
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

// MARK: - Fixtures

private final class Builder {
  private(set) var lines: [LetterLine] = []
  private var blockNumber = 0

  func block(_ body: () -> Void) {
    body()
    blockNumber += 1
  }

  func line(_ text: String, _ x: CGFloat, _ y: CGFloat, h: CGFloat = 24, conf: Float = 0.95) {
    let width = CGFloat(text.utf16Count) * h * 0.5
    let words = text.split(separator: " ").map { word in
      LetterWord(text: String(word), confidence: conf, symbolConfidences: Array(repeating: conf, count: word.utf16.count))
    }
    lines.append(LetterLine(text: text, box: CGRect(x: x, y: y, width: width, height: h), block: blockNumber, confidence: conf, words: words))
  }
}

private func scan(_ build: (Builder) -> Void) -> LetterScan {
  let b = Builder()
  build(b)
  return LetterScan(width: 960, height: 1440, lines: b.lines)
}

private enum Letters {
  /// Northgate Energy, £84.17, pay by 24 November 2026.
  static func bill(sender: String = "Northgate Energy", extra: String? = nil) -> LetterScan {
    scan { b in
      b.block { b.line(sender, 80, 70, h: 48) }
      b.block {
        b.line("Mrs Jane Patel", 80, 250)
        b.line("14 Elm Road", 80, 282)
        b.line("Leeds", 80, 314)
        b.line("LS6 2AB", 80, 346)
      }
      b.block {
        b.line("Account number: 8842 1937 55", 520, 250, h: 20)
        b.line("3 November 2026", 520, 280, h: 20)
      }
      b.block { b.line("Your electricity bill", 80, 450, h: 34) }
      b.block { b.line("Dear Mrs Patel,", 80, 520) }
      b.block {
        b.line("Here is your bill for the period 1 October to 31 October 2026. Your", 80, 570)
        b.line("Direct Debit is not set up, so please pay by bank transfer or by", 80, 602)
        b.line("phone using the account number above.", 80, 634)
      }
      b.block {
        b.line("Amount due", 80, 764)
      }
      b.block {
        b.line("£84.17", 760, 764)
      }
      b.block {
        b.line("Please pay the amount due by 24 November 2026.", 80, 830)
        if let extra { b.line(extra, 80, 862) }
      }
      b.block {
        b.line("Yours sincerely,", 80, 940)
        b.line("Sam Lee", 80, 1010)
      }
    }
  }
}

private func visionPage(_ scan: LetterScan) -> ReadPage {
  ReadPage(
    lines: scan.lines.map { line in
      ReadLine(words: WordConfidence.words(top: line.text, confidence: 1, alternatives: []), box: line.box)
    },
    imageSize: CGSize(width: scan.width, height: scan.height))
}

private var london: Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "Europe/London")!
  c.locale = Locale(identifier: "en_GB")
  return c
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
  london.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func saved(
  kind: LetterKind = .bill, sender: String? = "Northgate Energy", subject: String? = nil,
  amount: LetterRecord.SavedAmount = .sure(currency: "£", minor: 8417, isTotal: false, minimumMinor: nil),
  dueKind: String? = "pay", due: String? = "24 November 2026", dueSure: Bool = true, signs: [ScamSign] = [],
  text: [String] = ["Please pay the amount due by 24 November 2026."], id: String = "letter-1", savedAt: Date = at(2026, 11, 10)
) -> LetterRecord {
  LetterRecord(
    id: id, savedAt: savedAt, kind: kind.rawValue, sender: sender, recipient: "Mrs Jane Patel",
    letterDate: LetterDay(year: 2026, month: 11, day: 3), subject: subject, amount: amount, dueKind: dueKind, dueSpoken: due,
    dueSure: dueSure, dueDay: due.flatMap { dueSure ? LetterDay(spoken: $0) : nil },
    references: [Reference(label: "account number", value: "8842 1937 55")], scamSigns: signs.map(\.rawValue), paragraphs: text,
    summary: "A bill from \(sender ?? "someone").", reminderAt: nil)
}

@MainActor
private func temporaryStore() -> LettersStore {
  LettersStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("letters-\(UUID().uuidString)"), defaults: nil)
}

// MARK: - Reminder offers and days

final class LetterReminderTests: XCTestCase {
  private let due = LetterDay(year: 2026, month: 11, day: 24)  // A Tuesday.

  func testThreeDaysBeforeIsNineInTheMorningThreeDaysEarly() {
    let planner = LetterReminderPlanner(now: at(2026, 11, 10), calendar: london)
    XCTAssertEqual(
      planner.plan(.daysBefore(3), due: due),
      .remind(fireDate: at(2026, 11, 21, 9), day: LetterDay(year: 2026, month: 11, day: 21), choice: .daysBefore(3)))
    XCTAssertEqual(
      planner.plan(.daysBefore(1), due: due),
      .remind(fireDate: at(2026, 11, 23, 9), day: LetterDay(year: 2026, month: 11, day: 23), choice: .daysBefore(1)))
    XCTAssertEqual(
      planner.plan(.onTheDay, due: due),
      .remind(fireDate: at(2026, 11, 24, 9), day: due, choice: .onTheDay))
  }

  func testOnFridayIsTheNextFridayAndNeverAfterTheDeadline() {
    let early = LetterReminderPlanner(now: at(2026, 11, 10), calendar: london)  // Tuesday 10 November.
    XCTAssertEqual(
      early.plan(.weekday(6), due: due),
      .remind(fireDate: at(2026, 11, 13, 9), day: LetterDay(year: 2026, month: 11, day: 13), choice: .weekday(6)))
    let late = LetterReminderPlanner(now: at(2026, 11, 20), calendar: london)  // Friday 20 November.
    XCTAssertEqual(late.plan(.weekday(6), due: due), .afterDeadline(LetterDay(year: 2026, month: 11, day: 27)))
    XCTAssertEqual(
      late.line(for: late.plan(.weekday(6), due: due), kind: .pay),
      "Friday 27 November is after the deadline, so I didn't set a reminder. Say remind me the day before instead.")
  }

  func testAGoneDayIsTooLateAndSuggestedTakesTheClosestStillToCome() {
    let planner = LetterReminderPlanner(now: at(2026, 11, 23, 10), calendar: london)  // After 9 the day before.
    XCTAssertEqual(planner.plan(.daysBefore(1), due: due), .tooLate)
    XCTAssertEqual(planner.plan(.daysBefore(3), due: due), .tooLate)
    XCTAssertEqual(planner.plan(.suggested, due: due), .remind(fireDate: at(2026, 11, 24, 9), day: due, choice: .suggested))
    XCTAssertEqual(planner.plan(.daysBefore(3), due: nil), .noDate)
  }

  func testTheOfferListsOnlyDaysStillToCome() {
    let early = LetterReminderPlanner(now: at(2026, 11, 10), calendar: london)
    XCTAssertEqual(early.offers(due: due), [.daysBefore(3), .weekday(1), .daysBefore(1)])
    XCTAssertEqual(
      early.offerLine(due: due, kind: .pay),
      "Do you want a reminder before the deadline? Say remind me three days before, remind me on Sunday, or remind me the day before.")
    XCTAssertEqual(
      LetterReminderPlanner(now: at(2026, 11, 20), calendar: london).offers(due: due), [.daysBefore(3), .daysBefore(1)])
    XCTAssertEqual(LetterReminderPlanner(now: at(2026, 11, 23), calendar: london).offers(due: due), [])
    XCTAssertNil(LetterReminderPlanner(now: at(2026, 11, 25), calendar: london).offerLine(due: due, kind: .pay))
    XCTAssertTrue(
      early.offerLine(due: due, kind: .appointment)?.hasPrefix("Do you want a reminder before the appointment?") == true)
  }

  func testTheRequestSaysWhereTheDateCameFromAndUsesTheLettersID() throws {
    let planner = LetterReminderPlanner(now: at(2026, 11, 10), calendar: london)
    let request = try XCTUnwrap(planner.request(for: saved(), fireDate: at(2026, 11, 21, 9)))
    XCTAssertEqual(request.id, "letter-1")
    XCTAssertEqual(request.title, "Northgate Energy bill")
    XCTAssertEqual(request.spokenText, "Reminder. The letter from Northgate Energy says pay £84.17 by 24 November 2026.")
    XCTAssertEqual(request.fireDate, at(2026, 11, 21, 9))
    XCTAssertEqual(request.dueDate, at(2026, 11, 24, 9))
    XCTAssertEqual(request.source, "mail")
    // An unsure amount is never put in a reminder.
    let unsure = try XCTUnwrap(planner.request(for: saved(amount: .notSure), fireDate: at(2026, 11, 21, 9)))
    XCTAssertFalse(unsure.spokenText.contains("£"), unsure.spokenText)
    XCTAssertTrue(unsure.spokenText.contains("couldn't read the amount for sure"), unsure.spokenText)
    // No sure date, no reminder.
    XCTAssertNil(planner.request(for: saved(due: "within 14 days"), fireDate: at(2026, 11, 21, 9)))
  }

  func testEveryResultIsSpokenHonestly() {
    let planner = LetterReminderPlanner(now: at(2026, 11, 10), calendar: london)
    let day = LetterDay(year: 2026, month: 11, day: 21)
    XCTAssertEqual(
      planner.line(for: .scheduled, day: day, choice: .daysBefore(3), due: due, kind: .pay),
      "Done. I'll remind you on Saturday 21 November at 9 in the morning, three days before the deadline.")
    XCTAssertTrue(planner.line(for: .unavailable, day: day, choice: .daysBefore(3), due: due, kind: .pay).hasPrefix("Reminders aren't available"))
    XCTAssertTrue(planner.line(for: .notAllowed, day: day, choice: .daysBefore(3), due: due, kind: .pay).contains("notifications are off"))
    XCTAssertTrue(planner.line(for: .inThePast, day: day, choice: .daysBefore(3), due: due, kind: .pay).contains("already passed"))
  }

  func testTheStableIDIsTheSameForTheSameLetter() {
    let a = LetterReader.read([Letters.bill()])
    let b = LetterReader.read([Letters.bill()])
    let other = LetterReader.read([Letters.bill(sender: "Riverside Water")])
    XCTAssertEqual(LetterRecord.stableID(for: a), LetterRecord.stableID(for: b))
    XCTAssertNotEqual(LetterRecord.stableID(for: a), LetterRecord.stableID(for: other))
    XCTAssertTrue(LetterRecord.stableID(for: a).hasPrefix("letter-"))
  }
}

// MARK: - Voice

final class LetterGrammarTests: XCTestCase {
  func testReminderPhrases() {
    XCTAssertEqual(LetterGrammar.parse("remind me three days before"), .remind(.daysBefore(3)))
    XCTAssertEqual(LetterGrammar.parse("Please remind me 3 days before the deadline"), .remind(.daysBefore(3)))
    XCTAssertEqual(LetterGrammar.parse("remind me a week before"), .remind(.daysBefore(7)))
    XCTAssertEqual(LetterGrammar.parse("remind me the day before"), .remind(.daysBefore(1)))
    XCTAssertEqual(LetterGrammar.parse("remind me on Friday"), .remind(.weekday(6)))
    XCTAssertEqual(LetterGrammar.parse("remind me on the day"), .remind(.onTheDay))
    XCTAssertEqual(LetterGrammar.parse("yes remind me"), .remind(.suggested))
    XCTAssertEqual(LetterGrammar.parse("cancel the reminder"), .cancelReminder)
    XCTAssertEqual(LetterGrammar.parse("yes"), .yes)
    XCTAssertEqual(LetterGrammar.parse("no thanks"), .no)
  }

  func testExplainPhrases() {
    XCTAssertEqual(LetterGrammar.parse("explain this letter"), .explain(.onDevice))
    XCTAssertEqual(LetterGrammar.parse("what does this mean?"), .explain(.onDevice))
    XCTAssertEqual(LetterGrammar.parse("what do I need to do"), .explain(.onDevice))
    XCTAssertEqual(LetterGrammar.parse("explain online"), .explain(.online))
    XCTAssertEqual(LetterGrammar.parse("explain in Polish"), .explain(.language("Polish")))
    XCTAssertEqual(LetterGrammar.parse("explain it in my language"), .explain(.language(nil)))
    XCTAssertEqual(LetterGrammar.parse("explain in plain English"), .explain(.onDevice))
    XCTAssertEqual(LetterGrammar.parse("explain in Klingon"), .unknownLanguage("klingon"))
  }

  func testLogPhrases() {
    XCTAssertEqual(LetterGrammar.parse("my letters"), .myLetters)
    XCTAssertEqual(LetterGrammar.parse("what letters do I have"), .myLetters)
    XCTAssertEqual(LetterGrammar.parse("read the letter from Northgate Energy"), .readSaved("northgate energy"))
    XCTAssertEqual(LetterGrammar.parse("delete that letter"), .deleteThat)
    XCTAssertEqual(LetterGrammar.parse("forget all letters"), .forgetAll)
    XCTAssertEqual(LetterGrammar.parse("export my letters"), .export)
  }

  func testLeavesTheMailReadersOwnPhrasesAlone() {
    for phrase in ["read it all", "read this letter", "read the letter", "what is this letter", "how much", "is it a scam", "stop", "read the label"] {
      XCTAssertNil(LetterGrammar.parse(phrase), phrase)
    }
    // "what's due this week" belongs to the reminders feature.
    XCTAssertNil(LetterGrammar.parse("what's due this week"))
  }
}

// MARK: - The letters log

@MainActor
final class LettersStoreTests: XCTestCase {
  func testSaveListReplaceAndDelete() throws {
    let store = temporaryStore()
    XCTAssertTrue(store.letters.isEmpty)
    XCTAssertTrue(store.save(saved(id: "a", savedAt: at(2026, 11, 1))))
    XCTAssertTrue(store.save(saved(sender: "Harbour Bank", id: "b", savedAt: at(2026, 11, 5))))
    XCTAssertEqual(store.letters.map(\.id), ["b", "a"])  // Newest first.
    // The same letter again replaces it.
    XCTAssertTrue(store.save(saved(subject: "Updated", id: "a", savedAt: at(2026, 11, 6))))
    XCTAssertEqual(store.letters.map(\.id), ["a", "b"])
    XCTAssertEqual(store.letters.first?.subject, "Updated")

    // It's on disk, and comes back.
    let again = LettersStore(directory: store.directory, defaults: nil)
    XCTAssertEqual(again.letters.map(\.id), ["a", "b"])
    XCTAssertEqual(again.find(sender: "harbour").map(\.id), ["b"])
    XCTAssertEqual(again.find(sender: "northgate energy").map(\.id), ["a"])
    XCTAssertEqual(again.find(sender: "nobody"), [])

    XCTAssertTrue(again.delete(id: "a"))
    XCTAssertEqual(again.letters.map(\.id), ["b"])
    XCTAssertFalse(again.delete(id: "a"))
    XCTAssertTrue(again.deleteAll())
    XCTAssertEqual(again.letters, [])
    XCTAssertEqual(LettersStore(directory: store.directory, defaults: nil).letters, [])
  }

  func testTheFileIsKeptOutOfBackupsAndHasNoPhoto() throws {
    let store = temporaryStore()
    XCTAssertTrue(store.save(saved()))
    let url = try XCTUnwrap(store.fileURL)
    XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(try XCTUnwrap(store.directory).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    let json = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(json.contains("jpeg") || json.contains("image") || json.contains("photo"), json)
    XCTAssertTrue(store.directory?.path.contains("letters-") == true)
    XCTAssertEqual(LettersStore.defaultDirectory()?.deletingLastPathComponent().lastPathComponent, "Application Support")
  }

  func testAnUnreadableFileIsNeverOverwritten() throws {
    let store = temporaryStore()
    XCTAssertTrue(store.save(saved(id: "a")))
    let url = try XCTUnwrap(store.fileURL)
    try Data("not json".utf8).write(to: url)
    let broken = LettersStore(directory: store.directory, defaults: nil)
    XCTAssertFalse(broken.save(saved(id: "b")))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
  }

  func testARecordKeepsOnlyWhatIsSafeToSay() {
    var letter = LetterReader.read([Letters.bill()])
    letter.amount = .unsure
    letter.unsureMoney = ["£84.17"]
    let saved = LetterRecord(letter: letter, id: "x", summary: "s", savedAt: at(2026, 11, 10))
    XCTAssertEqual(saved.amount, .notSure)
    XCTAssertFalse(saved.text.contains("84.17"), saved.text)
    XCTAssertEqual(saved.dueDay, LetterDay(year: 2026, month: 11, day: 24))
    XCTAssertEqual(saved.sender, "Northgate Energy")
  }

  func testExportAsText() {
    let text = LettersExport.text(
      [saved(subject: "Your electricity bill", text: ["Dear Mrs Patel,", "Please pay by 24 November 2026."])], now: at(2026, 11, 20),
      calendar: london)
    XCTAssertEqual(
      text,
      """
      SpeakUp letters
      Exported 20 November 2026. 1 letter.

      Letter 1: Northgate Energy bill
      Saved: 10 November 2026
      From: Northgate Energy
      For: Mrs Jane Patel
      Kind: a bill
      Dated: 3 November 2026
      About: Your electricity bill
      Amount: £84.17
      Due: pay by 24 November 2026
      References: account number 8842 1937 55
      Scam signs: none found
      Text:
      Dear Mrs Patel,

      Please pay by 24 November 2026.

      """)
  }

  func testExportAsCSV() {
    let csv = LettersExport.csv(
      [saved(subject: "=HYPERLINK(\"x\")", amount: .notSure, text: ["Line one, with a comma", "Say \"hello\""])], calendar: london)
    let rows = csv.components(separatedBy: "\r\n")
    XCTAssertEqual(rows[0], "saved,from,for,kind,dated,about,amount,due,references,scam_signs,text")
    XCTAssertEqual(
      rows[1],
      "2026-11-10,Northgate Energy,Mrs Jane Patel,bill,2026-11-03,\"'=HYPERLINK(\"\"x\"\")\",not read for sure,pay by 24 November 2026,"
        + "account number 8842 1937 55,none found,\"Line one, with a comma\n\nSay \"\"hello\"\"\"")
    XCTAssertTrue(csv.hasSuffix("\r\n"))
  }

  func testTheListIsSpoken() {
    XCTAssertTrue(LettersSpeech.list([], calendar: london).hasPrefix("You have no saved letters."))
    let line = LettersSpeech.list([saved(id: "a"), saved(sender: "Harbour Bank", id: "b")], calendar: london)
    XCTAssertTrue(line.hasPrefix("You have 2 saved letters. Newest first: Northgate Energy bill, saved 10 November 2026, pay by 24 November 2026."), line)
  }
}

// MARK: - Explanations

final class LetterExplainerTests: XCTestCase {
  func testTopics() {
    XCTAssertEqual(LetterExplainer.topic(saved()), .bill)
    XCTAssertEqual(LetterExplainer.topic(saved(text: ["Final notice. Your account is overdue."])), .finalNotice)
    XCTAssertEqual(
      LetterExplainer.topic(saved(kind: .medical, amount: .none, dueKind: "appointment", due: "8 December 2026 at 10:30am")), .appointment)
    XCTAssertEqual(LetterExplainer.topic(saved(kind: .bank, amount: .none, dueKind: nil, due: nil, text: ["Changes to your account."])), .bank)
    XCTAssertEqual(LetterExplainer.topic(saved(kind: .official, text: ["Your council tax bill for 2026/27."])), .councilTax)
    XCTAssertEqual(
      LetterExplainer.topic(saved(kind: .official, amount: .none, text: ["Your Universal Credit payment is changing."])), .benefit)
    XCTAssertEqual(LetterExplainer.topic(saved(kind: .official, text: ["Penalty Charge Notice for parking in Elm Road."])), .fine)
    XCTAssertEqual(LetterExplainer.topic(saved(kind: .advert, amount: .none, dueKind: nil, due: nil)), .advert)
    // "I'm fine" in a personal letter isn't a fine.
    XCTAssertEqual(LetterExplainer.topic(saved(kind: .personal, amount: .none, dueKind: nil, due: nil, text: ["I'm fine, hope you are."])), .personal)
  }

  func testABillIsExplainedFromItsFields() {
    let text = LetterExplainer.explain(saved(subject: "Your electricity bill"), offerOnline: false)
    XCTAssertTrue(text.hasPrefix("This is a bill."), text)
    XCTAssertTrue(text.contains("It's from Northgate Energy."), text)
    XCTAssertTrue(text.contains("It's about: Your electricity bill."), text)
    XCTAssertTrue(text.contains("It asks you to pay £84.17."), text)
    XCTAssertTrue(text.contains("Pay by 24 November 2026."), text)
    XCTAssertTrue(text.hasSuffix("That's a general explanation from rules on your phone."), text)
    XCTAssertFalse(text.contains("explain online"))
    XCTAssertTrue(LetterExplainer.explain(saved(), offerOnline: true).hasSuffix("say explain online."))
  }

  func testWhatTheLetterDoesNotSayIsSaid() {
    let text = LetterExplainer.explain(
      saved(sender: nil, amount: .none, dueKind: nil, due: nil, text: ["Final notice. Your account is in arrears."]), offerOnline: false)
    XCTAssertTrue(text.hasPrefix("This is a final notice."), text)
    XCTAssertTrue(text.contains("The letter doesn't say clearly who it's from."), text)
    XCTAssertTrue(text.contains("I couldn't find an amount to pay in it."), text)
    XCTAssertTrue(text.contains("I couldn't find a date to pay by."), text)
    XCTAssertTrue(text.contains("Citizens Advice"), text)
  }

  func testAnUnsureAmountIsNeverGuessed() {
    let text = LetterExplainer.explain(saved(amount: .notSure, text: ["Please pay an amount I can't read for sure."]), offerOnline: false)
    XCTAssertTrue(text.contains("I couldn't read it for sure, so I won't guess it"), text)
    XCTAssertFalse(text.contains("£"), text)
  }

  func testEachKindHasItsOwnExplanation() {
    let intros = Set(LetterTopic.allCases.map(LetterExplainer.intro))
    XCTAssertEqual(intros.count, LetterTopic.allCases.count)
    let advert = LetterExplainer.explain(saved(kind: .advert, amount: .none, dueKind: nil, due: nil), offerOnline: false)
    XCTAssertTrue(advert.hasPrefix("This looks like an advert. You don't have to do anything with it."), advert)
    let appointment = LetterExplainer.explain(
      saved(kind: .medical, sender: "Leeds General Infirmary", amount: .none, dueKind: "appointment", due: "8 December 2026 at 10:30am"),
      offerOnline: false)
    XCTAssertTrue(appointment.contains("The appointment is on 8 December 2026 at 10:30am."), appointment)
    let scam = LetterExplainer.explain(saved(signs: [.oddPayment]), offerOnline: false)
    XCTAssertTrue(scam.contains("It also has signs of a scam, so check with someone you trust"), scam)
    for topic in LetterTopic.allCases {
      XCTAssertFalse(LetterExplainer.intro(topic).lowercased().contains("genuine"))
    }
  }
}

// MARK: - Scam signs (the Android list)

final class LetterScamRuleTests: XCTestCase {
  func testTheAndroidList() {
    // "Final notice" pressure and urgent payment are the same kind of weak sign: alone, no hint.
    XCTAssertEqual(ScamSigns.find("FINAL NOTICE. Urgent payment required. Pay now to avoid court."), [])
    XCTAssertEqual(Set(ScamSigns.find("Final notice. Urgent payment required within 24 hours or you will be arrested.")), [.urgency, .threat])
    // Gift cards.
    XCTAssertEqual(ScamSigns.find("Pay the balance with Google Play cards."), [.oddPayment])
    // Bank details or passwords asked for.
    XCTAssertEqual(ScamSigns.find("Please send us your bank details to receive your refund."), [.asksForSecrets])
    XCTAssertEqual(ScamSigns.find("Reply with your online banking password."), [.asksForSecrets])
    // Odd payment methods.
    XCTAssertEqual(ScamSigns.find("A courier will collect the cash from your home."), [.oddPayment])
    XCTAssertEqual(ScamSigns.find("Pay with paysafecard vouchers."), [.oddPayment])
  }

  func testAMismatchedSender() {
    let text = "HMRC\nYou are owed a tax refund.\nTo claim, email hmrc.refunds@gmail.com today."
    XCTAssertEqual(ScamSigns.find(text, sender: "HMRC", kind: .official), [.mismatchedSender])
    XCTAssertEqual(ScamSigns.find("Contact your adviser on 07700 900123.", sender: "Harbour Bank", kind: .bank), [.mismatchedSender])
    // A small trader's bill with a Gmail address isn't a sign on its own.
    XCTAssertEqual(ScamSigns.find("Invoice. Questions? dave.plumbing@gmail.com", sender: "Dave's Plumbing", kind: .bill), [])
    // A friend's letter isn't either.
    XCTAssertEqual(ScamSigns.find("Write to me at jo@gmail.com", sender: "Jo", kind: .personal), [])
  }

  func testAMismatchedSenderIsFoundInARealLetterRead() {
    let l = LetterReader.read([Letters.bill(sender: "Harbour Bank", extra: "Reply to harbourbank.help@hotmail.com")])
    XCTAssertTrue(l.scamSigns.contains(.mismatchedSender), "\(l.scamSigns)")
    XCTAssertTrue(LetterSpeech.scam(l).hasPrefix("It has signs of a scam"))
  }

  func testNoSignsIsNoScamSignsFoundNeverGenuine() {
    let l = LetterReader.read([Letters.bill()])
    XCTAssertEqual(l.scamSigns, [])
    let answer = LetterSpeech.scam(l)
    XCTAssertTrue(answer.hasPrefix("No scam signs found."), answer)
    XCTAssertFalse(answer.lowercased().contains("genuine"), answer)
    XCTAssertFalse(LettersSpeech.answer(.scam, saved()).lowercased().contains("genuine"))
  }
}

// MARK: - The AI explanation's request

final class LetterExplainOnlineTests: XCTestCase {
  func testTheBodyHoldsTheTextOnlyNeverAnImage() throws {
    let body = OpenAILetterExplainer.body(text: "Please pay an amount I can't read for sure by 24 November 2026.", language: nil)
    XCTAssertEqual(body["store"] as? Bool, false)
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.count, 1)
    let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
    XCTAssertEqual(content.map { $0["type"] as? String }, ["input_text"])
    XCTAssertTrue((content[0]["text"] as? String)?.contains("24 November 2026") == true)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    XCTAssertFalse(json.contains("input_image") || json.contains("image_url") || json.contains("base64"), json)
    let instructions = try XCTUnwrap(body["instructions"] as? String)
    XCTAssertTrue(instructions.contains("Never guess, estimate or work out an amount"))
    XCTAssertTrue(instructions.contains("If the letter doesn't say one of these, say that the letter doesn't say it."))
    XCTAssertTrue(instructions.contains("Never say a letter is genuine"))
    XCTAssertTrue(instructions.hasSuffix("Write in plain British English."))
  }

  func testALanguageIsAskedForInTheInstructions() throws {
    let body = OpenAILetterExplainer.body(text: "x", language: "Polish")
    XCTAssertTrue((body["instructions"] as? String)?.hasSuffix("Write the whole explanation in Polish.") == true)
  }

  func testTheRequestGoesToOpenAIWithTheKey() throws {
    let request = try OpenAILetterExplainer(apiKey: "sk-test").request(text: "hello", language: nil)
    XCTAssertEqual(request.url?.host(), "api.openai.com")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    XCTAssertThrowsError(try OpenAILetterExplainer(apiKey: " ").request(text: "hello", language: nil))
  }

  func testRepliesAndFailures() {
    let ok = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"It's a bill."}]}]}"#.utf8)
    XCTAssertEqual(OpenAILetterExplainer.result(status: 200, body: ok), .explanation("It's a bill."))
    XCTAssertEqual(OpenAILetterExplainer.result(status: 401, body: Data()), .failed("unauthorized"))
    XCTAssertTrue(MailTool.onlineFailure("network").hasPrefix("I couldn't reach the internet."))
    XCTAssertTrue(MailTool.aiLine("It's a bill.").contains("written by AI"))
  }

  func testThePhonesLanguage() {
    XCTAssertEqual(LetterLanguages.phoneLanguage(preferred: ["pl-PL", "en-GB"]), "Polish")
    XCTAssertNil(LetterLanguages.phoneLanguage(preferred: ["en-GB"]))
  }
}

// MARK: - MailTool end to end

@MainActor
private final class Camera: ReadFrameSource {
  var latestReadFrame: ReadFrame?
  var cameraKind: CameraKind { .phone }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in } }
}

@MainActor
private final class FakeReminders: ReminderScheduling {
  var answer: ReminderScheduleResult = .scheduled
  var scheduled: [ReminderRequest] = []
  var cancelled: [String] = []
  func schedule(_ request: ReminderRequest) async -> ReminderScheduleResult {
    scheduled.append(request)
    return answer
  }
  func cancel(id: String) { cancelled.append(id) }
  func upcoming(before date: Date) -> [ReminderRequest] { [] }
}

private final class FakeExplainer: LetterExplainOnline, @unchecked Sendable {
  private let lock = NSLock()
  private var _calls: [(String, String?)] = []
  var calls: [(String, String?)] { lock.withLock { _calls } }
  func explain(text: String, language: String?) async -> LetterExplainResult {
    lock.withLock { _calls.append((text, language)) }
    return .explanation("This is a bill from Northgate Energy.")
  }
}

@MainActor
final class LettersMailToolTests: XCTestCase {
  private func tool(
    _ page: LetterScan = Letters.bill(), store: LettersStore, reminders: any ReminderScheduling = NoReminders(),
    online: (any LetterExplainOnline)? = nil, now: Date = at(2026, 11, 10)
  ) -> MailTool {
    let photo = visionPage(page)
    let mail = MailTool(
      recognize: { _ in RecognizedFrame(page: photo, quality: .unknown, ocrMilliseconds: 1) }, letters: store,
      reminders: { reminders }, online: { online }, now: { now })
    mail.calendar = london
    mail.recentText = RecentText(defaults: nil)
    return mail
  }

  private func look(_ mail: MailTool) async {
    mail.perform(.newLetter)
    for _ in 0..<200 where mail.phase == .looking {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func testTheSummaryOffersAReminderAndTheLetterIsSaved() async {
    let store = temporaryStore()
    let reminders = FakeReminders()
    let mail = tool(store: store, reminders: reminders)
    let camera = Camera()
    mail.start(source: camera)
    await look(mail)
    XCTAssertEqual(mail.pendingQuestion, .reminder)
    XCTAssertEqual(mail.reminderOffers, [.daysBefore(3), .weekday(1), .daysBefore(1)])
    XCTAssertEqual(store.letters.count, 1)
    XCTAssertEqual(store.letters.first?.sender, "Northgate Energy")
    XCTAssertEqual(mail.record?.id, store.letters.first?.id)

    XCTAssertTrue(mail.handle(transcript: "remind me three days before"))
    await mail.reminderTask?.value
    XCTAssertEqual(reminders.scheduled.count, 1)
    XCTAssertEqual(reminders.scheduled.first?.id, store.letters.first?.id)
    XCTAssertEqual(reminders.scheduled.first?.fireDate, at(2026, 11, 21, 9))
    XCTAssertEqual(mail.notice, "Done. I'll remind you on Saturday 21 November at 9 in the morning, three days before the deadline.")
    XCTAssertEqual(store.letters.first?.reminderAt, at(2026, 11, 21, 9))
    XCTAssertEqual(mail.pendingQuestion, .none)

    // Reading the same letter again replaces it, and asking again replaces the reminder (same id).
    await look(mail)
    XCTAssertEqual(store.letters.count, 1)
    XCTAssertTrue(mail.handle(transcript: "yes"))
    await mail.reminderTask?.value
    XCTAssertEqual(reminders.scheduled.map(\.id), [reminders.scheduled[0].id, reminders.scheduled[0].id])
    mail.stop()
    withExtendedLifetime(camera) {}
  }

  func testWithoutTheRemindersFeatureItSaysSo() async {
    let mail = tool(store: temporaryStore())
    let camera = Camera()
    mail.start(source: camera)
    await look(mail)
    XCTAssertTrue(mail.handle(transcript: "remind me the day before"))
    await mail.reminderTask?.value
    XCTAssertTrue(mail.notice?.hasPrefix("Reminders aren't available in this version of SpeakUp yet") == true, mail.notice ?? "")
    XCTAssertNil(mail.record?.reminderAt)
    // "no" after the offer, and "yes" with nothing asked isn't taken.
    await look(mail)
    XCTAssertTrue(mail.handle(transcript: "no thanks"))
    XCTAssertEqual(mail.pendingQuestion, .none)
    XCTAssertFalse(mail.handle(transcript: "yes"))
    mail.stop()
    withExtendedLifetime(camera) {}
  }

  func testTheLettersLogByVoice() async {
    let store = temporaryStore()
    XCTAssertTrue(store.save(saved(sender: "Harbour Bank", id: "bank", savedAt: at(2026, 11, 1))))
    let reminders = FakeReminders()
    let mail = tool(store: store, reminders: reminders)
    let camera = Camera()
    mail.start(source: camera)
    await look(mail)
    XCTAssertEqual(store.letters.count, 2)

    XCTAssertTrue(mail.handle(transcript: "my letters"))
    XCTAssertTrue(mail.showingLetters)
    XCTAssertTrue(mail.handle(transcript: "read the letter from Harbour Bank"))
    XCTAssertEqual(mail.savedFocus?.id, "bank")
    XCTAssertFalse(mail.showingLetters)
    XCTAssertTrue(mail.handle(transcript: "read it all"))
    XCTAssertEqual(mail.phase, .reading)
    XCTAssertEqual(mail.currentSentence, "Please pay the amount due by 24 November 2026.")
    XCTAssertTrue(mail.handle(transcript: "delete that letter"))
    XCTAssertNil(mail.savedFocus)
    XCTAssertEqual(store.letters.count, 1)

    XCTAssertTrue(mail.handle(transcript: "read the letter from nobody"))
    XCTAssertEqual(mail.notice, "I can't find a saved letter from nobody. Say my letters to hear them all.")

    XCTAssertTrue(mail.handle(transcript: "forget all letters"))
    XCTAssertEqual(mail.pendingQuestion, .forgetAll)
    XCTAssertEqual(store.letters.count, 1)  // Not until "yes".
    XCTAssertTrue(mail.handle(transcript: "yes"))
    XCTAssertEqual(store.letters, [])
    XCTAssertNil(mail.record)
    mail.stop()
    withExtendedLifetime(camera) {}
  }

  func testExplainOnTheDeviceAndOnlineOnlyWithAKey() async {
    let mail = tool(store: temporaryStore())
    let camera = Camera()
    mail.start(source: camera)
    await look(mail)
    XCTAssertTrue(mail.handle(transcript: "explain this letter"))
    XCTAssertTrue(mail.explanation?.hasPrefix("This is a bill.") == true, mail.explanation ?? "")
    XCTAssertFalse(mail.explanationIsAI)
    XCTAssertTrue(mail.handle(transcript: "explain in Polish"))
    XCTAssertEqual(mail.notice, MailTool.needsKey)
    XCTAssertNil(mail.explainTask)
    mail.stop()

    let explainer = FakeExplainer()
    let online = tool(store: temporaryStore(), online: explainer)
    online.start(source: camera)
    await look(online)
    XCTAssertTrue(online.handle(transcript: "explain in Polish"))
    XCTAssertTrue(online.isExplainingOnline)
    await online.explainTask?.value
    XCTAssertEqual(online.explanation, "This is a bill from Northgate Energy.")
    XCTAssertTrue(online.explanationIsAI)
    XCTAssertEqual(explainer.calls.count, 1)
    XCTAssertEqual(explainer.calls.first?.1, "Polish")
    XCTAssertEqual(explainer.calls.first?.0, online.record?.text)
    online.stop()
    withExtendedLifetime(camera) {}
  }
}

// MARK: - Voice clashes: the mail reader's questions and letters from anywhere

@MainActor
private final class QuietNotifier: ReminderNotifying {
  func requestPermission() async -> Bool { true }
  func permission() async -> Bool? { true }
  func add(_ notification: ReminderNotification) async -> Bool { true }
  func remove(ids: [String]) {}
}

@MainActor
private final class PlainTool: SpeakUpTool {
  let toolID: ToolID
  init(_ id: ToolID) { toolID = id }
  func start(source: ReadFrameSource) {}
  func stop() {}
  func handle(transcript: String) -> Bool { false }
  var helpLine: String { "" }
  func makePanel() -> AnyView { AnyView(EmptyView()) }
}

/// "yes" and "no" go to the newest question: the mail reader's offer, the app's own question, or a
/// reminder added since. "my letters" and "read the letter from ..." work from anywhere.
@MainActor
final class LetterVoiceClashTests: XCTestCase {
  private var camera: Camera!

  override func setUp() async throws {
    try await super.setUp()
    camera = Camera()
    VoiceQuestions.shared.reset()
  }

  override func tearDown() async throws {
    Announcer.shared.stop()
    VoiceQuestions.shared.reset()
    try await super.tearDown()
  }

  private func mailTool(store: LettersStore, reminders: any ReminderScheduling) -> MailTool {
    let photo = visionPage(Letters.bill())
    let mail = MailTool(
      recognize: { _ in RecognizedFrame(page: photo, quality: .unknown, ocrMilliseconds: 1) }, letters: store,
      reminders: { reminders }, online: { nil }, now: { at(2026, 11, 10) })
    mail.calendar = london
    mail.recentText = RecentText(defaults: nil)
    return mail
  }

  private func look(_ mail: MailTool) async {
    mail.perform(.newLetter)
    for _ in 0..<200 where mail.phase == .looking {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeHub(mail: MailTool, reminders: RemindersTool? = nil) -> ToolHub {
    ToolHub(source: camera) { id -> any SpeakUpTool in
      switch id {
      case .mail: mail
      case .reminders: reminders ?? PlainTool(id)
      default: PlainTool(id)
      }
    }
  }

  /// The app asked (glasses registration, say) after the mail reader's offer: "yes" is the app's.
  /// Once that's answered, "yes" is the offer's again.
  func testYesGoesToTheNewestQuestion() async {
    let reminders = FakeReminders()
    let mail = mailTool(store: temporaryStore(), reminders: reminders)
    mail.start(source: camera)
    await look(mail)
    XCTAssertEqual(mail.pendingQuestion, .reminder)
    XCTAssertTrue(VoiceQuestions.shared.isNewest(.mail))

    VoiceQuestions.shared.ask(.app)
    XCTAssertFalse(mail.handle(transcript: "yes"), "the app asked last")
    XCTAssertFalse(mail.handle(transcript: "no"))
    XCTAssertEqual(mail.pendingQuestion, .reminder, "the offer still waits")

    VoiceQuestions.shared.settle(.app)
    XCTAssertTrue(mail.handle(transcript: "yes"))
    await mail.reminderTask?.value
    XCTAssertEqual(reminders.scheduled.count, 1)
    XCTAssertFalse(VoiceQuestions.shared.isWaiting(.mail))
    mail.stop()
  }

  /// A reminder added from the mail reader is newer than the offer: "yes" isn't the offer's then,
  /// and "undo" takes the reminder back without leaving the letter. After that, "yes" is the
  /// offer's again.
  func testAReminderAddedInTheMailReaderComesBeforeTheOffer() async {
    let letterReminders = FakeReminders()
    let mail = mailTool(store: temporaryStore(), reminders: letterReminders)
    let store = ReminderStore(fileURL: nil, notifier: QuietNotifier(), clock: ReminderClock(now: { at(2026, 11, 10, 14) }, calendar: london))
    var lines: [String] = []
    let reminders = RemindersTool(store: store, alerts: ReminderAlerts(), activity: ActivityLog()) { line, _ in lines.append(line) }
    let hub = makeHub(mail: mail, reminders: reminders)
    hub.open(.mail)
    await look(mail)
    XCTAssertEqual(mail.pendingQuestion, .reminder)

    XCTAssertTrue(hub.route("remind me at 6 pm to call the bank", command: nil))
    XCTAssertEqual(hub.openTool, .mail)
    for _ in 0..<250 where lines.last?.hasPrefix("Reminder at") != true { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(lines.last, "Reminder at 6 pm today: call the bank. Say undo to cancel.")

    XCTAssertFalse(hub.route("yes", command: nil), "the newest question is the reminder just added, not the offer")
    XCTAssertTrue(letterReminders.scheduled.isEmpty)

    XCTAssertTrue(hub.route("undo", command: nil))
    for _ in 0..<250 where !store.reminders.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertEqual(hub.openTool, .mail)

    XCTAssertTrue(hub.route("yes", command: nil), "the offer is the newest question again")
    await mail.reminderTask?.value
    XCTAssertEqual(letterReminders.scheduled.count, 1)
    hub.close(announce: false)
  }

  /// Opening another tool drops the offer: "yes" back in the mail reader isn't a reminder.
  func testSwitchingToolsDropsTheOffer() async {
    let letterReminders = FakeReminders()
    let mail = mailTool(store: temporaryStore(), reminders: letterReminders)
    let hub = makeHub(mail: mail)
    hub.open(.mail)
    await look(mail)
    XCTAssertEqual(mail.pendingQuestion, .reminder)
    hub.open(.read)
    XCTAssertEqual(mail.pendingQuestion, .none)
    XCTAssertFalse(VoiceQuestions.shared.isWaiting(.mail))
    hub.open(.mail)
    XCTAssertFalse(hub.route("yes", command: nil))
    XCTAssertTrue(letterReminders.scheduled.isEmpty)
    hub.close(announce: false)
  }

  /// "my letters", "what letters do I have" and "read the letter from ..." open the mail reader
  /// and its letters log from the home or from another tool.
  func testLettersFromAnywhere() {
    let store = temporaryStore()
    XCTAssertTrue(store.save(saved(sender: "Harbour Bank", id: "bank", savedAt: at(2026, 11, 1))))
    let mail = mailTool(store: store, reminders: FakeReminders())
    let hub = makeHub(mail: mail)

    XCTAssertTrue(hub.route("my letters", command: nil))
    XCTAssertEqual(hub.openTool, .mail)
    XCTAssertTrue(mail.showingLetters)
    XCTAssertFalse(mail.quietStart, "the quiet start was used up")

    hub.open(.labels)
    XCTAssertTrue(hub.route("read the letter from Harbour Bank", command: nil))
    XCTAssertEqual(hub.openTool, .mail)
    XCTAssertEqual(mail.savedFocus?.id, "bank")

    hub.open(.read)
    XCTAssertTrue(hub.route("what letters do I have", command: nil))
    XCTAssertEqual(hub.openTool, .mail)
    XCTAssertTrue(mail.showingLetters)

    hub.close(announce: false)
    XCTAssertFalse(hub.route("read the council letter", command: nil), "that one is the mail reader's own")
    XCTAssertNil(hub.openTool)
    mail.stop()
  }
}
