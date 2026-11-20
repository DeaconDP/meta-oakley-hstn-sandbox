/*
 * MailReaderTests - the mail reader's rules on realistic letters, ported from the Android JVM tests
 * (LetterReaderTest, MailGrammarTest, LetterFixtures), plus the iOS-only parts
 *
 * Sender, recipient, kind, date, subject, amount due and deadline for a utility bill, a bank
 * letter, a council tax bill, a personal letter, a flyer, a window envelope, a hospital
 * appointment and a two-page bill; and the money rule: a smudged digit, a letter where a digit
 * should be, or two different amounts due, and no figure is ever spoken. iOS additions: Vision's
 * candidate readings as the confidence source, the second-look cross check, scam-sign hints,
 * "next page" on the same page, and MailTool end to end with a fake camera and fake OCR.
 *
 * Fixtures place lines where they sit on a 960x1440 photo of an A4 letter, one block per group
 * of lines, with word and character confidences. Body text is 24 px high. `low` marks single
 * characters as read with low confidence, the way a smudged digit comes back from ML Kit.
 */

import CoreGraphics
@testable import CameraAccess
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

// MARK: - Fixtures

private final class LetterBuilder {
  private(set) var lines: [LetterLine] = []
  private var blockNumber = 0

  /// Starts a new block.
  func block(_ body: () -> Void) {
    body()
    blockNumber += 1
  }

  /// A line at (x, y) of text height h. Width from the text (about 0.5 h per character).
  /// `low`: character index in the line -> confidence, for smudged characters.
  func line(_ text: String, _ x: CGFloat, _ y: CGFloat, h: CGFloat = 24, conf: Float = 0.95, low: [Int: Float] = [:]) {
    let width = CGFloat(text.utf16Count) * h * 0.5
    var at = 0
    let words = text.split(separator: " ").map(String.init).map { word -> LetterWord in
      let start = text.utf16Index(of: word, from: at) ?? at
      at = start + word.utf16Count
      let symbols = (0..<word.utf16Count).map { low[start + $0] ?? conf }
      return LetterWord(text: word, confidence: symbols.min() ?? conf, symbolConfidences: symbols)
    }
    lines.append(LetterLine(text: text, box: CGRect(x: x, y: y, width: width, height: h), block: blockNumber, confidence: conf, words: words))
  }
}

private func letter(_ build: (LetterBuilder) -> Void) -> LetterScan {
  let builder = LetterBuilder()
  build(builder)
  return LetterScan(width: 960, height: 1440, lines: builder.lines)
}

private enum Fixtures {
  /// An electricity bill: letterhead, window address, account number, heading, a table, a due date.
  static func utilityBill(
    amountDue: String = "£84.17", amountLow: [Int: Float] = [:], secondTotal: String? = nil, chargeLow: [Int: Float] = [:]
  ) -> LetterScan {
    letter { b in
      b.block { b.line("Northgate Energy", 80, 70, h: 48) }
      b.block {
        b.line("PO Box 512, Leeds LS1 4AB", 560, 80, h: 18)
        b.line("0800 123 4567", 560, 104, h: 18)
      }
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
        b.line("Standing charge", 80, 700)
        b.line("Energy used (412 kWh)", 80, 732)
        b.line("Amount due", 80, 764)
      }
      b.block {
        b.line("£12.30", 760, 700, low: chargeLow)
        b.line("£71.87", 760, 732)
        b.line(amountDue, 760, 764, low: amountLow)
      }
      b.block {
        b.line("Please pay the amount due by 24 November 2026.", 80, 830)
        if let secondTotal { b.line("Total to pay \(secondTotal)", 80, 862) }
      }
      b.block {
        b.line("Yours sincerely,", 80, 940)
        b.line("Sam Lee", 80, 1010)
        b.line("Customer Services", 80, 1042)
      }
    }
  }

  /// A bank writing about account changes: a "Re:" line, sort code, a balance that isn't owed.
  static let bankLetter = letter { b in
    b.block { b.line("Harbour Bank", 80, 70, h: 52) }
    b.block {
      b.line("Mr Tom Reid", 80, 250)
      b.line("7 Quay Street", 80, 282)
      b.line("Whitby", 80, 314)
      b.line("YO21 3PU", 80, 346)
    }
    b.block { b.line("28 October 2026", 640, 250, h: 20) }
    b.block { b.line("Re: Changes to your current account", 80, 440) }
    b.block { b.line("Dear Mr Reid,", 80, 500) }
    b.block {
      b.line("We are writing to let you know about changes to your current account,", 80, 550)
      b.line("sort code 20-45-77, account ending 4471. From 1 January 2027 the", 80, 582)
      b.line("arranged overdraft interest rate will change to 39.9% EAR. Your", 80, 614)
      b.line("balance on 27 October was £1,240.50. You don't need to do anything.", 80, 646)
    }
    b.block {
      b.line("Yours sincerely,", 80, 740)
      b.line("Priya Shah", 80, 800)
      b.line("Head of Current Accounts", 80, 832)
    }
  }

  /// A council tax bill: official, an amount payable and the first instalment date.
  static let councilTax = letter { b in
    b.block { b.line("Riverside Borough Council", 80, 70, h: 44) }
    b.block {
      b.line("Mr Ahmed Khan", 80, 250)
      b.line("Flat 3, 22 Mill Lane", 80, 282)
      b.line("Riverside", 80, 314)
      b.line("RV4 9TT", 80, 346)
    }
    b.block {
      b.line("Council tax reference: 6003 4471 2", 520, 250, h: 20)
      b.line("Date: 1 November 2026", 520, 280, h: 20)
    }
    b.block { b.line("Council Tax Bill 2026/27", 80, 440, h: 34) }
    b.block { b.line("Dear Mr Khan,", 80, 510) }
    b.block {
      b.line("Your property is in valuation band C. The council tax for the year", 80, 560)
      b.line("is shown below. You can pay in 10 monthly instalments of £168.40.", 80, 592)
    }
    b.block {
      b.line("Amount payable", 80, 660)
      b.line("First instalment due", 80, 692)
    }
    b.block {
      b.line("£1,684.00", 740, 660)
      b.line("1 December 2026", 680, 692)
    }
    b.block {
      b.line("Yours faithfully,", 80, 780)
      b.line("Revenues Manager", 80, 840)
    }
  }

  /// A personal letter: sender's address top right, no letterhead, "Lots of love".
  static let personal = letter { b in
    b.block {
      b.line("12 Oak Lane", 620, 70)
      b.line("Bristol", 620, 102)
      b.line("BS8 1QU", 620, 134)
    }
    b.block { b.line("2 November 2026", 620, 190) }
    b.block { b.line("Dear Jane,", 80, 280) }
    b.block {
      b.line("I hope you are well and that the new flat is warming up now that the", 80, 330)
      b.line("weather has turned. We had a lovely week in Cornwall and I thought of", 80, 362)
      b.line("you when we walked past the little bookshop in St Ives.", 80, 394)
    }
    b.block { b.line("Do come and visit soon. I miss you and can't wait to see you.", 80, 450) }
    b.block {
      b.line("Lots of love,", 80, 530)
      b.line("Margaret", 80, 590)
    }
  }

  /// A shop flyer addressed to the occupier.
  static let flyer = letter { b in
    b.block { b.line("MEGA SOFA SALE!", 80, 80, h: 72) }
    b.block { b.line("50% off everything, today only!", 80, 220, h: 40) }
    b.block {
      b.line("The Occupier", 80, 330)
      b.line("14 Elm Road", 80, 362)
      b.line("Leeds LS6 2AB", 80, 394)
    }
    b.block {
      b.line("Free delivery and a free footstool voucher for new customers.", 80, 480)
      b.line("Visit our showroom or call now on 0800 555 0101. Don't miss out!", 80, 512)
    }
    b.block { b.line("Prices from £299", 80, 600, h: 40) }
  }

  /// The front of a window envelope: the address, a return address, postage paid.
  static let windowEnvelope = letter { b in
    b.block { b.line("If undelivered please return to: Northgate Energy, PO Box 512, Leeds LS1 4AB", 60, 60, h: 14) }
    b.block {
      b.line("Royal Mail", 760, 60, h: 16)
      b.line("Postage Paid GB", 760, 80, h: 16)
    }
    b.block {
      b.line("Mrs Jane Patel", 120, 420)
      b.line("14 Elm Road", 120, 452)
      b.line("Leeds", 120, 484)
      b.line("LS6 2AB", 120, 516)
    }
  }

  /// A hospital appointment letter.
  static let appointment = letter { b in
    b.block { b.line("Leeds Teaching Hospitals NHS Trust", 80, 70, h: 40) }
    b.block {
      b.line("Ms Rosa Lind", 80, 250)
      b.line("5 Park View", 80, 282)
      b.line("Leeds LS2 7EE", 80, 314)
    }
    b.block {
      b.line("NHS number: 485 777 3456", 560, 250, h: 20)
      b.line("30 October 2026", 560, 280, h: 20)
    }
    b.block { b.line("Dear Ms Lind,", 80, 420) }
    b.block {
      b.line("Your outpatient appointment is on Tuesday 8 December 2026 at 10:30am", 80, 470)
      b.line("in the Eye Clinic, Chapel Allerton Hospital. Please bring your glasses.", 80, 502)
    }
    b.block {
      b.line("Yours sincerely,", 80, 580)
      b.line("Outpatient Bookings", 80, 640)
    }
  }

  /// Page 1 of a bill whose amount is on page 2.
  static let billPageOneNoAmount = letter { b in
    b.block { b.line("Northgate Energy", 80, 70, h: 48) }
    b.block {
      b.line("Mrs Jane Patel", 80, 250)
      b.line("14 Elm Road", 80, 282)
      b.line("Leeds LS6 2AB", 80, 314)
    }
    b.block { b.line("3 November 2026", 600, 250, h: 20) }
    b.block { b.line("Dear Mrs Patel,", 80, 420) }
    b.block {
      b.line("Your new tariff starts this month. The details of your charges are", 80, 470)
      b.line("on the next page, with how and when to pay.", 80, 502)
    }
  }

  static let billPageTwo = letter { b in
    b.block {
      b.line("Standing charge", 80, 100)
      b.line("Amount due", 80, 132)
    }
    b.block {
      b.line("£12.30", 760, 100)
      b.line("£84.17", 760, 132)
    }
    b.block { b.line("Please pay by 24 November 2026.", 80, 200) }
    b.block {
      b.line("Yours sincerely,", 80, 300)
      b.line("Sam Lee", 80, 360)
    }
  }

  /// A scam letter: a prize, a release fee, gift cards, secrecy.
  static let scam = letter { b in
    b.block { b.line("International Prize Board", 80, 70, h: 48) }
    b.block {
      b.line("Mrs Jane Patel", 80, 250)
      b.line("14 Elm Road", 80, 282)
      b.line("Leeds LS6 2AB", 80, 314)
    }
    b.block { b.line("Dear Mrs Patel,", 80, 420) }
    b.block {
      b.line("Congratulations, you have won £250,000 in our annual draw. To release", 80, 470)
      b.line("your winnings, pay the processing fee of £95 in Google Play cards", 80, 502)
      b.line("within 48 hours. Do not tell anyone until the money arrives.", 80, 534)
    }
    b.block {
      b.line("Yours sincerely,", 80, 600)
      b.line("Claims Department", 80, 660)
    }
  }
}

private func read(_ scans: LetterScan...) -> Letter { LetterReader.read(scans) }

/// A ReadPage as TextRecognizer would build it: one Vision observation per line, words from
/// WordConfidence. `alternatives` per line text, for Vision's runner-up readings.
private func visionPage(_ scan: LetterScan, confidence: Float = 1, alternatives: [String: [(String, Float)]] = [:]) -> ReadPage {
  ReadPage(
    lines: scan.lines.map { line in
      ReadLine(
        words: WordConfidence.words(top: line.text, confidence: confidence, alternatives: alternatives[line.text] ?? []),
        box: line.box)
    },
    imageSize: CGSize(width: scan.width, height: scan.height))
}

// MARK: - Letters

final class MailReaderTests: XCTestCase {
  func testUtilityBill() {
    let l = read(Fixtures.utilityBill())
    XCTAssertFalse(l.isEnvelope)
    XCTAssertEqual(l.kind, .bill)
    XCTAssertEqual(l.sender, "Northgate Energy")
    XCTAssertEqual(l.recipient, "Mrs Jane Patel")
    XCTAssertEqual(l.recipientAddress, "14 Elm Road, Leeds, LS6 2AB")
    XCTAssertEqual(l.salutation, "Mrs Patel")
    XCTAssertEqual(l.date?.spoken(), "3 November 2026")
    XCTAssertEqual(l.subject, "Your electricity bill")
    XCTAssertEqual(l.amount, .sure(Money(currency: "£", minor: 8417)))
    XCTAssertEqual(l.due, DueDate(kind: .pay, spoken: "24 November 2026", sure: true))
    XCTAssertEqual(l.references.first?.label, "account number")
    XCTAssertEqual(l.references.first?.spoken, "account number 8 8 4 2, 1 9 3 7, 5 5")
    XCTAssertEqual(l.scamSigns, [])

    XCTAssertEqual(
      LetterSpeech.summary(l),
      "A bill from Northgate Energy, for Mrs Jane Patel. Dated 3 November 2026. About: Your electricity bill. "
        + "Amount due: £84.17, by 24 November 2026. Say read it all to hear every word.")
    XCTAssertEqual(LetterSpeech.howMuch(l), "The amount due is £84.17. Pay by 24 November 2026.")
    XCTAssertEqual(LetterSpeech.isJunk(l), "It doesn't look like junk. It's a bill.")
  }

  func testUtilityBillReadsTheTableAsRowsInOrder() {
    let text = read(Fixtures.utilityBill()).fullText
    XCTAssertTrue(text.contains("Standing charge £12.30"), text)
    XCTAssertTrue(text.contains("Energy used (412 kWh) £71.87"), text)
    XCTAssertTrue(text.contains("Amount due £84.17"), text)
    // Letterhead, then the address as one sentence, then the paragraphs.
    XCTAssertTrue(text.contains("Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB."), text)
    XCTAssertLessThan(offset(text, "Northgate Energy"), offset(text, "Mrs Jane Patel, 14 Elm Road"))
    XCTAssertLessThan(offset(text, "Dear Mrs Patel"), offset(text, "Here is your bill"))
    XCTAssertLessThan(offset(text, "Standing charge"), offset(text, "Yours sincerely"))
    // The paragraph's lines are joined into one.
    XCTAssertTrue(text.contains("31 October 2026. Your Direct Debit is not set up"), text)
  }

  func testBankLetter() {
    let l = read(Fixtures.bankLetter)
    XCTAssertEqual(l.kind, .bank)
    XCTAssertEqual(l.sender, "Harbour Bank")
    XCTAssertEqual(l.recipient, "Mr Tom Reid")
    XCTAssertEqual(l.subject, "Changes to your current account")
    XCTAssertEqual(l.date?.spoken(), "28 October 2026")
    // A balance isn't an amount due.
    XCTAssertEqual(l.amount, AmountDue.none)
    XCTAssertEqual(
      LetterSpeech.howMuch(l), "I can't see an amount to pay. The letter mentions one amount; say read it all to hear them.")
    XCTAssertTrue(l.references.contains { $0.label == "sort code" && $0.value == "20-45-77" })
    XCTAssertTrue(l.references.contains { $0.label == "account ending" && $0.value == "4471" })
  }

  func testCouncilTaxBill() {
    let l = read(Fixtures.councilTax)
    XCTAssertEqual(l.kind, .official)
    XCTAssertEqual(l.sender, "Riverside Borough Council")
    XCTAssertEqual(l.recipient, "Mr Ahmed Khan")
    XCTAssertEqual(l.date?.spoken(), "1 November 2026")
    XCTAssertEqual(l.subject, "Council Tax Bill 2026/27")
    XCTAssertEqual(l.amount, .sure(Money(currency: "£", minor: 168_400)))
    XCTAssertEqual(l.due, DueDate(kind: .pay, spoken: "1 December 2026", sure: true))
    XCTAssertEqual(l.references.first?.spoken, "council tax reference 6 0 0 3, 4 4 7 1, 2")
    let summary = LetterSpeech.summary(l)
    XCTAssertTrue(summary.hasPrefix("An official letter from Riverside Borough Council, for Mr Ahmed Khan."), summary)
    XCTAssertTrue(summary.contains("Amount due: £1,684, by 1 December 2026."), summary)
  }

  func testPersonalLetter() {
    let l = read(Fixtures.personal)
    XCTAssertEqual(l.kind, .personal)
    XCTAssertEqual(l.sender, "Margaret")
    // The address top right is the sender's, not the recipient's.
    XCTAssertNil(l.recipient)
    XCTAssertEqual(l.salutation, "Jane")
    XCTAssertEqual(l.date?.spoken(), "2 November 2026")
    XCTAssertEqual(l.amount, AmountDue.none)
    let s = LetterSpeech.summary(l)
    XCTAssertTrue(
      s.hasPrefix("A personal letter from Margaret, for Jane. Dated 2 November 2026. It starts: I hope you are well"), s)
  }

  func testFlyerIsJunk() {
    let l = read(Fixtures.flyer)
    XCTAssertEqual(l.kind, .advert)
    XCTAssertFalse(l.isEnvelope, "an addressed flyer isn't an envelope")
    XCTAssertEqual(l.recipient, "The Occupier")
    XCTAssertEqual(LetterSpeech.isJunk(l), "It looks like an advert, so probably junk mail.")
  }

  func testWindowEnvelope() {
    let l = read(Fixtures.windowEnvelope)
    XCTAssertTrue(l.isEnvelope)
    XCTAssertEqual(l.recipient, "Mrs Jane Patel")
    XCTAssertEqual(l.sender, "Northgate Energy")
    XCTAssertEqual(
      LetterSpeech.summary(l),
      "This is the outside of an envelope, addressed to Mrs Jane Patel, 14 Elm Road, Leeds, LS6 2AB, from Northgate Energy. "
        + "Open it and hold up the letter, then say read.")
  }

  func testHospitalAppointment() {
    let l = read(Fixtures.appointment)
    XCTAssertEqual(l.kind, .medical)
    XCTAssertEqual(l.sender, "Leeds Teaching Hospitals NHS Trust")
    XCTAssertEqual(l.recipient, "Ms Rosa Lind")
    XCTAssertEqual(l.date?.spoken(), "30 October 2026")
    XCTAssertEqual(l.due, DueDate(kind: .appointment, spoken: "8 December 2026 at 10:30am", sure: true))
    XCTAssertTrue(LetterSpeech.summary(l).contains("Appointment: 8 December 2026 at 10:30am."))
    XCTAssertEqual(LetterSpeech.references(l), "NHS number 4 8 5, 7 7 7, 3 4 5 6.")
  }

  func testSecondPageAddsTheAmountAndKeepsTheHeader() {
    XCTAssertEqual(read(Fixtures.billPageOneNoAmount).amount, AmountDue.none)
    let both = read(Fixtures.billPageOneNoAmount, Fixtures.billPageTwo)
    XCTAssertEqual(both.sender, "Northgate Energy")
    XCTAssertEqual(both.recipient, "Mrs Jane Patel")
    XCTAssertEqual(both.amount, .sure(Money(currency: "£", minor: 8417)))
    XCTAssertEqual(both.due?.spoken, "24 November 2026")
    XCTAssertTrue(LetterSpeech.summary(both).hasPrefix("2 pages. A bill from Northgate Energy"))
    XCTAssertTrue(both.paragraphs.contains("Page 2."))
  }

  // MARK: The money rule

  func testLowConfidenceDigitMeansNoFigure() {
    // "£84.17" with the 4 smudged (confidence 0.3).
    let l = read(Fixtures.utilityBill(amountLow: [2: 0.3]))
    XCTAssertEqual(l.amount, .unsure)
    let s = LetterSpeech.summary(l)
    XCTAssertTrue(s.contains(LetterSpeech.unsureAmount), s)
    XCTAssertFalse(s.contains("84"), s)
    XCTAssertFalse(LetterSpeech.howMuch(l).contains("84"))
    XCTAssertTrue(LetterSpeech.howMuch(l).hasPrefix("I can't read the amount for sure"))
    // Reading it all doesn't say the figure either, but still says the sure ones.
    let reading = l.readingParagraphs.joined(separator: " ")
    XCTAssertFalse(reading.contains("£84.17"), reading)
    XCTAssertTrue(reading.contains("Amount due an amount I can't read for sure"), reading)
    XCTAssertTrue(reading.contains("£12.30"), reading)
  }

  func testALetterWhereADigitShouldBeMeansNoFigure() {
    let l = read(Fixtures.utilityBill(amountDue: "£8O.17"))
    XCTAssertEqual(l.amount, .unsure)
    XCTAssertFalse(LetterSpeech.summary(l).contains("8O"))
  }

  func testTwoDifferentAmountsDueConflict() {
    let l = read(Fixtures.utilityBill(secondTotal: "£48.17"))
    XCTAssertEqual(l.amount, .conflict)
    let s = LetterSpeech.summary(l)
    XCTAssertTrue(s.contains(LetterSpeech.conflictingAmounts))
    XCTAssertFalse(s.contains("84.17") || s.contains("48.17"), s)
  }

  func testTheSameAmountTwiceIsFine() {
    XCTAssertEqual(read(Fixtures.utilityBill(secondTotal: "£84.17")).amount, .sure(Money(currency: "£", minor: 8417)))
  }

  func testASmudgedCurrencySignOrPointCountsToo() {
    XCTAssertEqual(read(Fixtures.utilityBill(amountLow: [0: 0.2])).amount, .unsure)
    XCTAssertEqual(read(Fixtures.utilityBill(amountLow: [3: 0.3])).amount, .unsure)
  }

  func testAnUnsureChargeIsNotReadButTheAmountDueStillIs() {
    let l = read(Fixtures.utilityBill(chargeLow: [1: 0.2]))
    XCTAssertEqual(l.amount, .sure(Money(currency: "£", minor: 8417)))
    let reading = l.readingParagraphs.joined(separator: " ")
    XCTAssertTrue(reading.contains("Standing charge an amount I can't read for sure."), reading)
    XCTAssertTrue(reading.contains("Amount due £84.17."), reading)
  }

  func testADigitThatWentMissingIsCaughtFromTheCharacterBoxes() {
    // What the Galaxy A26 returned for "£84.17" with the 4 smudged: "£8.17", every digit
    // confident, but the boxes show the gap. iOS keeps the check for an OCR pass with boxes.
    func line(_ boxes: [(CGFloat, CGFloat)]) -> LetterLine {
      let text = "£8.17"
      let word = LetterWord(
        text: text, confidence: 0.9, symbolConfidences: Array(repeating: 0.9, count: 5),
        symbolBoxes: boxes.map { CGRect(x: $0.0, y: 100, width: $0.1 - $0.0, height: 24) })
      return LetterLine(
        text: "Amount due \(text)", box: CGRect(x: 80, y: 100, width: 806, height: 24), block: 0, confidence: 0.9,
        words: [LetterWord(text: "Amount", confidence: 0.9), LetterWord(text: "due", confidence: 0.9), word])
    }
    let normal: [(CGFloat, CGFloat)] = [(804, 817), (819, 831), (836, 838), (843, 850), (858, 870)]
    let wideDot: [(CGFloat, CGFloat)] = [(804, 824), (827, 840), (849, 862), (867, 877), (882, 894)]
    let stretched: [(CGFloat, CGFloat)] = [(804, 818), (819, 846), (847, 852), (853, 866), (867, 880)]
    let gap: [(CGFloat, CGFloat)] = [(804, 818), (819, 832), (846, 851), (852, 865), (866, 879)]
    func letterOf(_ l: LetterLine) -> Letter { LetterReader.read([LetterScan(width: 960, height: 1440, lines: [l])]) }
    XCTAssertEqual(letterOf(line(normal)).amount, .sure(Money(currency: "£", minor: 817)))
    XCTAssertTrue(letterOf(line(normal)).safeText.contains("£8.17"))
    for boxes in [stretched, gap, wideDot] {
      let l = letterOf(line(boxes))
      XCTAssertEqual(l.amount, .unsure)
      // What the screen shows can't carry the wrong figure either.
      XCTAssertFalse(l.safeText.contains("£8.17"), l.safeText)
      XCTAssertTrue(l.safeText.contains(LetterSpeech.notSureFigure), l.safeText)
    }
  }

  func testTheScreenGetsTheMaskedText() {
    let l = read(Fixtures.utilityBill(amountLow: [2: 0.3]))
    XCTAssertFalse(l.safeText.contains("£84.17"), l.safeText)
    XCTAssertTrue(l.safeText.contains("Amount due an amount I can't read for sure"), l.safeText)
    // Only the unsure amount is touched: sure ones and reference numbers stay as printed.
    XCTAssertTrue(l.safeText.contains("£12.30"), l.safeText)
    XCTAssertEqual(read(Fixtures.utilityBill()).fullText, read(Fixtures.utilityBill()).safeText)
  }

  func testLineConfidenceOnlyIsUsedWhenThatIsAllThereIs() {
    let scan = letter { b in b.block { b.line("Amount due £20.00", 80, 100) } }
    var noWords = scan
    noWords.lines = scan.lines.map { var l = $0; l.words = []; l.confidence = 0.4; return l }
    XCTAssertEqual(LetterReader.read([noWords]).amount, .unsure)
    var sure = scan
    sure.lines = scan.lines.map { var l = $0; l.words = []; l.confidence = 0.9; return l }
    XCTAssertEqual(LetterReader.read([sure]).amount, .sure(Money(currency: "£", minor: 2000)))
  }

  func testMinimumPaymentIsNotAConflict() {
    let scan = letter { b in
      b.block { b.line("Harbour Bank Credit Card", 80, 70, h: 48) }
      b.block {
        b.line("Statement balance £1,234.56", 80, 400)
        b.line("Minimum payment £25.00", 80, 432)
        b.line("Payment due date: 18 December 2026", 80, 464)
      }
    }
    let l = LetterReader.read([scan])
    XCTAssertEqual(l.amount, .sure(Money(currency: "£", minor: 123_456), minimum: Money(currency: "£", minor: 2500)))
    XCTAssertEqual(l.due?.spoken, "18 December 2026")
  }

  // MARK: iOS: Vision's candidates as the confidence source

  func testACleanVisionReadingOfTheBillIsSure() {
    let l = LetterReader.read([LetterScan(page: visionPage(Fixtures.utilityBill()))])
    XCTAssertEqual(l.amount, .sure(Money(currency: "£", minor: 8417)))
    XCTAssertEqual(l.sender, "Northgate Energy")
    XCTAssertEqual(l.kind, .bill)
  }

  func testARunnerUpWithAnotherDigitMeansNoFigure() {
    // Vision's top reading lost the 4; its runner-up kept it. Numbers are compared strictly.
    let page = visionPage(Fixtures.utilityBill(amountDue: "£8.17"), alternatives: ["£8.17": [("£84.17", 0.9)]])
    let l = LetterReader.read([LetterScan(page: page)])
    XCTAssertEqual(l.amount, .unsure)
    XCTAssertFalse(LetterSpeech.summary(l).contains("8.17"))
    XCTAssertFalse(l.safeText.contains("£8.17"), l.safeText)
  }

  func testAMiddlingVisionConfidenceIsNotEnoughForMoney() {
    // Vision often scores a line 0.5; Read text withholds money below 0.8, and so does mail.
    let l = LetterReader.read([LetterScan(page: visionPage(Fixtures.utilityBill(), confidence: 0.5))])
    XCTAssertEqual(l.amount, .unsure)
    XCTAssertEqual(LetterReader.minWordConfidence, ReadSpeech.sensitiveNumberBelow)
  }

  func testAWeakRunnerUpIsNoDoubt() {
    // A runner-up far below the top reading doesn't count (WordConfidence.alternativeWeight).
    let page = visionPage(Fixtures.utilityBill(), alternatives: ["£84.17": [("£64.17", 0.2)]])
    XCTAssertEqual(LetterReader.read([LetterScan(page: page)]).amount, .sure(Money(currency: "£", minor: 8417)))
  }

  func testTheSecondLookVetoesADifferentFigure() {
    let first = read(Fixtures.utilityBill())
    let second = read(Fixtures.utilityBill(amountDue: "£34.17"))
    let checked = LetterReader.crossChecked(first, with: second)
    XCTAssertEqual(checked.amount, .unsure)
    XCTAssertFalse(LetterSpeech.summary(checked).contains("84.17"))
    XCTAssertFalse(checked.safeText.contains("£84.17"), checked.safeText)
    XCTAssertFalse(checked.readingParagraphs.joined(separator: " ").contains("£84.17"))
    XCTAssertTrue(checked.safeText.contains("£12.30"))
  }

  func testTheSecondLookKeepsAnAgreeingOrUnreadableFigure() {
    let first = read(Fixtures.utilityBill())
    XCTAssertEqual(LetterReader.crossChecked(first, with: read(Fixtures.utilityBill())).amount, first.amount)
    // A blurred second frame that can't read the amount is no evidence against the first.
    XCTAssertEqual(LetterReader.crossChecked(first, with: read(Fixtures.utilityBill(amountLow: [2: 0.3]))).amount, first.amount)
    XCTAssertEqual(LetterReader.crossChecked(first, with: read(Fixtures.bankLetter)).amount, first.amount)
  }

  // MARK: iOS: scam signs are hints, never verdicts

  func testScamSignsAreAHint() {
    let l = read(Fixtures.scam)
    XCTAssertEqual(Set(l.scamSigns), [.oddPayment, .prizeOrFee, .urgency, .secrecy])
    XCTAssertTrue(l.scamSigns.first?.isStrong == true)
    let summary = LetterSpeech.summary(l)
    XCTAssertTrue(summary.contains("It has signs of a scam"), summary)
    XCTAssertTrue(summary.contains("Check with someone you trust"), summary)
    let answer = LetterSpeech.scam(l)
    XCTAssertTrue(answer.hasPrefix("It has signs of a scam: it asks for payment in an unusual way, like gift cards"), answer)
    XCTAssertTrue(answer.hasSuffix(LetterSpeech.scamAdvice), answer)
  }

  func testNoScamSignsIsNeverCalledGenuine() {
    for scan in [Fixtures.utilityBill(), Fixtures.bankLetter, Fixtures.councilTax, Fixtures.personal, Fixtures.appointment] {
      let l = read(scan)
      XCTAssertEqual(l.scamSigns, [])
      let answer = LetterSpeech.scam(l)
      XCTAssertTrue(answer.hasPrefix("No scam signs found."), answer)
      XCTAssertFalse(answer.lowercased().contains("genuine"), answer)
      for line in [answer, LetterSpeech.summary(l), LetterSpeech.isJunk(l), LetterSpeech.kind(l)] {
        XCTAssertFalse(line.lowercased().contains("it's genuine") || line.lowercased().contains("it is genuine"), line)
      }
    }
  }

  func testOneWeakSignIsNotEnough() {
    // Councils send real final notices.
    XCTAssertEqual(ScamSigns.find("Final notice. Your council tax is overdue. Please pay £120 by 1 December 2026."), [])
    XCTAssertEqual(ScamSigns.find("Final notice: pay within 24 hours or you will be arrested."), [.urgency, .threat])
    XCTAssertEqual(ScamSigns.find("Please confirm your bank details by replying to this letter."), [.asksForSecrets])
  }

  // MARK: Pages and sentences

  func testTheSamePageAgainIsNotANewPage() {
    XCTAssertTrue(MailPages.isSamePage(Fixtures.utilityBill(), Fixtures.utilityBill(amountLow: [2: 0.3])))
    XCTAssertFalse(MailPages.isSamePage(Fixtures.billPageOneNoAmount, Fixtures.billPageTwo))
  }

  func testReadItAllGoesSentenceBySentence() {
    let sentences = read(Fixtures.utilityBill()).readingParagraphs.flatMap(LetterSentences.split)
    XCTAssertEqual(sentences.first, "Northgate Energy")
    XCTAssertTrue(sentences.contains("Standing charge £12.30."), "\(sentences)")
    XCTAssertTrue(sentences.contains("Amount due £84.17."), "\(sentences)")
    // The account and phone numbers are spelled out digit by digit.
    XCTAssertTrue(sentences.contains { $0.contains("Account number: 8 8 4 2, 1 9 3 7, 5 5") }, "\(sentences)")
    XCTAssertTrue(sentences.contains { $0.contains("0 8 0 0, 1 2 3, 4 5 6 7") }, "\(sentences)")
    XCTAssertEqual(LetterSentences.split("Dear Mr. Reid. It is 3 p.m. now. Done!"), ["Dear Mr. Reid.", "It is 3 p.m. now.", "Done!"])
  }

  // MARK: Grammar and patterns

  func testBriefPhrases() {
    let cases: [(String, MailCommand)] = [
      ("What is this letter?", .summarise), ("what's this letter about", .summarise), ("read", .summarise),
      ("read this please", .summarise), ("what does it say", .summarise), ("read it all", .readAll),
      ("Read the whole letter", .readAll), ("read every word", .readAll), ("who's it from", .from),
      ("who is this letter from", .from), ("who sent this", .from), ("who's it for", .forWhom),
      ("who is it addressed to", .forWhom), ("how much", .howMuch), ("how much do I owe", .howMuch),
      ("what's the amount due", .howMuch), ("when is it due", .whenDue), ("when do I have to pay", .whenDue),
      ("what's the deadline", .whenDue), ("is it junk", .isJunk), ("is this junk mail", .isJunk),
      ("is it important", .isJunk), ("is this a bill", .kind), ("what kind of letter is this", .kind),
      ("read the envelope", .envelope), ("next page", .nextPage), ("there's another page", .nextPage),
      ("I've turned it over", .nextPage), ("new letter", .newLetter), ("next letter", .newLetter),
      ("what's the account number", .reference), ("what's the reference", .reference), ("what's the date on it", .date),
      ("go back", .back), ("back a sentence", .back), ("skip", .skip), ("next", .skip), ("start again", .startAgain),
      ("from the top", .startAgain), ("summary", .summary), ("tell me again", .summary),
      // iOS additions
      ("is it a scam", .scam), ("Is this letter genuine?", .scam), ("does it look like a scam", .scam),
      ("repeat", .repeatLast), ("repeat that", .repeatLast), ("carry on reading", .resume), ("keep reading", .resume),
      ("could you read it all for me please", .readAll), ("um how much is it", .howMuch),
    ]
    for (phrase, command) in cases {
      XCTAssertEqual(MailGrammar.parse(phrase), command, phrase)
    }
  }

  func testLeavesOtherToolsAndGlobalCommandsAlone() {
    for phrase in [
      "read the label", "read a book", "open the book reader", "watch for 42", "scan this", "is the light on",
      "what colour is this", "stop", "carry on", "close", "say that again", "faster", "help", "battery",
      "what does Penang lawyer mean", "turn right at the lights", "my mail came late", "I'll read this later", "",
    ] {
      XCTAssertNil(MailGrammar.parse(phrase), phrase)
    }
  }

  func testMoney() {
    XCTAssertEqual(LetterText.money("Amount due £84.17").first?.money, Money(currency: "£", minor: 8417))
    XCTAssertEqual(LetterText.money("Amount payable £1,684.00").first?.money, Money(currency: "£", minor: 168_400))
    XCTAssertEqual(LetterText.money("Total €1,250").first?.money, Money(currency: "€", minor: 125_000))
    XCTAssertEqual(LetterText.money("You owe 19.99 GBP").first?.money, Money(currency: "£", minor: 1999))
    XCTAssertEqual(LetterText.money("pay $5, and").first?.money, Money(currency: "$", minor: 500))
    XCTAssertEqual(LetterText.money("Amount due £8O.17").count, 1)
    XCTAssertNil(LetterText.money("Amount due £8O.17").first?.money)
    XCTAssertNil(LetterText.money("Amount due £l2.50").first?.money)
    XCTAssertEqual(LetterText.money("Refund £12.30 CR").first?.credit, true)
    XCTAssertEqual(Money(currency: "£", minor: 8417).spoken(), "£84.17")
    XCTAssertEqual(Money(currency: "£", minor: 168_400).spoken(), "£1,684")
    XCTAssertEqual(Money(currency: "£", minor: 123_456_700).spoken(), "£1,234,567")
    XCTAssertEqual(LetterText.money("39.9% EAR, 412 kWh"), [])
  }

  func testDates() {
    func one(_ t: String) -> String? {
      let dates = LetterText.dates(t)
      XCTAssertEqual(dates.count, 1, t)
      return dates.first?.spoken()
    }
    XCTAssertEqual(one("Please pay by 24 November 2026."), "24 November 2026")
    XCTAssertEqual(one("by 24th Nov 2026"), "24 November 2026")
    XCTAssertEqual(one("November 24, 2026"), "24 November 2026")
    XCTAssertEqual(one("Date: 04/11/2026"), "4 November 2026")
    XCTAssertEqual(one("2026-11-06"), "6 November 2026")
    XCTAssertEqual(LetterText.dates("1 October to 31 Octob 2026"), [])
  }

  func testNumbersForSpeech() {
    XCTAssertEqual(LetterText.spellOut("8842 1937 55"), "8 8 4 2, 1 9 3 7, 5 5")
    XCTAssertEqual(LetterText.spellOut("AB 123456 C"), "A B, 1 2 3 4 5 6, C")
    XCTAssertEqual(LetterText.forSpeech("Call 0800 123 4567 now"), "Call 0 8 0 0, 1 2 3, 4 5 6 7 now")
    XCTAssertEqual(LetterText.forSpeech("Ref 12345678."), "Ref 1 2 3 4 5 6 7 8.")
    // Money, years and short numbers are left for the voice to say normally.
    XCTAssertEqual(LetterText.forSpeech("Pay £1,684.00 in 2026, 10 times."), "Pay £1,684.00 in 2026, 10 times.")
  }

  private func offset(_ text: String, _ needle: String) -> Int {
    guard let range = text.range(of: needle) else {
      XCTFail("\"\(needle)\" not in \(text)")
      return Int.max
    }
    return text.distance(from: text.startIndex, to: range.lowerBound)
  }
}

// MARK: - MailTool end to end (fake camera, fake OCR)

@MainActor
private final class FakeLetterCamera: ReadFrameSource {
  var latestReadFrame: ReadFrame?
  var cameraKind: CameraKind { .phone }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { MailToolTests.image(width: 4) }
}

@MainActor
final class MailToolTests: XCTestCase {
  static func image(width: Int) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: width, height: 4)).image { _ in }
  }

  /// OCR that returns the photo's page for a 4 px image and the frame's page for anything else.
  private func tool(photo: LetterScan, frame: LetterScan? = nil) -> MailTool {
    let photoPage = visionPage(photo)
    let framePage = frame.map { visionPage($0) }
    let store = LettersStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent("letters-\(UUID().uuidString)"), defaults: nil)
    return MailTool(
      recognize: { image in
        let page = image.size.width == 4 ? photoPage : (framePage ?? photoPage)
        return RecognizedFrame(page: page, quality: .unknown, ocrMilliseconds: 1)
      }, letters: store, reminders: { NoReminders() }, online: { nil })
  }

  private func waitUntilLooked(_ tool: MailTool) async {
    for _ in 0..<200 where tool.phase == .looking {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func testTheToolSeam() {
    let mail = tool(photo: Fixtures.utilityBill())
    XCTAssertEqual(mail.toolID, .mail)
    XCTAssertTrue(mail.helpLine.contains("what is this letter"))
    XCTAssertFalse(mail.handle(transcript: "read the label"))
    XCTAssertFalse(mail.handle(transcript: "stop"))
    _ = mail.makePanel()
  }

  func testWhatIsThisLetterSummarisesTheBill() async {
    let mail = tool(photo: Fixtures.utilityBill())
    let camera = FakeLetterCamera()
    mail.start(source: camera)
    XCTAssertTrue(mail.handle(transcript: "What is this letter?"))
    XCTAssertEqual(mail.phase, .looking)
    await waitUntilLooked(mail)
    XCTAssertEqual(mail.phase, .ready)
    XCTAssertEqual(mail.letter?.sender, "Northgate Energy")
    XCTAssertEqual(mail.letter?.amount, .sure(Money(currency: "£", minor: 8417)))
    XCTAssertTrue(mail.summary.hasPrefix("A bill from Northgate Energy"), mail.summary)
    XCTAssertTrue(mail.handle(transcript: "read it all"))
    XCTAssertEqual(mail.phase, .reading)
    XCTAssertEqual(mail.currentSentence, "Northgate Energy")
    mail.stop()
    XCTAssertEqual(mail.phase, .paused)
    withExtendedLifetime(camera) {}
  }

  func testAStreamFrameThatReadsAnotherFigureMeansNoFigure() async {
    let mail = tool(photo: Fixtures.utilityBill(), frame: Fixtures.utilityBill(amountDue: "£34.17"))
    let camera = FakeLetterCamera()
    camera.latestReadFrame = ReadFrame(image: Self.image(width: 2), arrivedAt: BenchClock.uptimeNanoseconds())
    mail.start(source: camera)
    mail.perform(.howMuch)
    await waitUntilLooked(mail)
    XCTAssertEqual(mail.letter?.amount, .unsure)
    XCTAssertFalse(mail.summary.contains("84.17"), mail.summary)
    mail.stop()
    withExtendedLifetime(camera) {}
  }

  /// Ask about the text works after a letter: its masked text and the sentence being read.
  func testALettersSafeTextIsPublishedAndTheSentenceTracked() async {
    let store = RecentText(defaults: nil)
    let mail = tool(photo: Fixtures.utilityBill())
    mail.recentText = store
    let camera = FakeLetterCamera()
    mail.start(source: camera)
    mail.perform(.summarise)
    await waitUntilLooked(mail)
    let text = store.snapshot(source: .mail)?.fullText ?? ""
    XCTAssertTrue(text.contains("Northgate Energy"), text)
    mail.perform(.readAll)
    XCTAssertEqual(store.snapshot(source: .mail)?.current, mail.currentSentence)
    mail.stop()
    withExtendedLifetime(camera) {}
  }

  func testNextPageOnTheSamePageAddsNothing() async {
    let mail = tool(photo: Fixtures.utilityBill())
    let camera = FakeLetterCamera()  // The tool holds its source weakly, as TextReader does.
    mail.start(source: camera)
    mail.perform(.summarise)
    await waitUntilLooked(mail)
    mail.perform(.nextPage)
    await waitUntilLooked(mail)
    XCTAssertEqual(mail.letter?.pages.count, 1)
    XCTAssertEqual(mail.notice, "That looks like the same page.")
    mail.stop()
    withExtendedLifetime(camera) {}
  }
}
