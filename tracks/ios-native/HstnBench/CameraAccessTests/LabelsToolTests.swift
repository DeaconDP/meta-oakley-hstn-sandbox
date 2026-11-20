/*
 * LabelsToolTests - the label reader's pure logic, ported from Android's JVM tests
 * (tools/labels: LabelDatesTest, LabelTextTest, MedicineExpiryTest, BarcodeHintTest,
 * LabelsGrammarTest, OpenFoodFactsTest), plus the iOS tool's medicine date rule end to end.
 *
 * No camera: dates, sections, allergens, medicine, barcodes (synthetic bar rows), the grammar, and
 * the Open Food Facts reply parser (inline replies, a fake fetch; nothing goes online).
 * "Today" is fixed at 6 November 2026 so dates with no year and "already passed" are stable.
 */

import XCTest

@testable import CameraAccess

// MARK: - Dates

final class LabelDatesTests: XCTestCase {
  private let today = CivilDate(2026, 11, 6)

  private func first(_ text: String) -> LabelDate? { LabelDates.find(text, today: today).dates.first }
  private func said(_ text: String) -> String? { LabelDates.answer(LabelDates.find(text, today: today), today: today) }
  private func date(_ kind: LabelDateKind, _ y: Int, _ m: Int, _ d: Int?, guessed: Bool = false, end: Bool = false) -> LabelDate {
    LabelDate(kind: kind, year: y, month: m, day: d, yearGuessed: guessed, endOfMonth: end)
  }

  func testNumericDayFirstDates() {
    XCTAssertEqual(first("BB 12/03/27"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(first("Best before: 12.03.2027"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(first("USE BY 12-03-27"), date(.useBy, 2027, 3, 12))
    XCTAssertEqual(first("Best Before 12 03 2027"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(said("BB 12/03/27"), "Best before 12 March 2027.")
  }

  func testMonthFirstOnlyWhenDayFirstIsImpossible() {
    XCTAssertEqual(first("EXP 03/25/2027"), date(.expiry, 2027, 3, 25))
  }

  func testIsoAndYearMonthDates() {
    XCTAssertEqual(first("EXP 2027-03-12"), date(.expiry, 2027, 3, 12))
    XCTAssertEqual(first("EXP 2027-03"), date(.expiry, 2027, 3, nil, end: true))
    XCTAssertEqual(said("EXP 2027-03"), "Expiry date the end of March 2027.")
  }

  func testMonthNames() {
    XCTAssertEqual(first("Best before 12 March 2027"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(first("BEST BEFORE 12MAR27"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(first("BBE 12 MAR 2027"), date(.bestBefore, 2027, 3, 12))
    XCTAssertEqual(first("Expires March 12, 2027"), date(.expiry, 2027, 3, 12))
    XCTAssertEqual(first("best before 5th Jan 2027"), date(.bestBefore, 2027, 1, 5))
  }

  func testDayAndMonthWithoutYearTakeTheNearestYearAndDontSayIt() {
    // 12 March: next March is nearer than last March.
    XCTAssertEqual(first("use by 12 MAR"), date(.useBy, 2027, 3, 12, guessed: true))
    XCTAssertEqual(said("use by 12 MAR"), "Use by 12 March.")
    // 1 November: last week, so it has passed.
    XCTAssertEqual(said("USE BY 01 NOV"), "Use by 1 November. That date has already passed.")
    XCTAssertEqual(first("BB 12/03"), date(.bestBefore, 2027, 3, 12, guessed: true))
  }

  func testBestBeforeEndIsAMonth() {
    XCTAssertEqual(first("best before end: 03 2027"), date(.bestBefore, 2027, 3, nil, end: true))
    XCTAssertEqual(said("best before end: 03 2027"), "Best before the end of March 2027.")
    XCTAssertEqual(first("BBE 03/27"), date(.bestBefore, 2027, 3, nil, end: true))
    XCTAssertEqual(first("Best Before End MAR 27"), date(.bestBefore, 2027, 3, nil, end: true))
    XCTAssertEqual(first("EXP 03/27"), date(.expiry, 2027, 3, nil, end: true))
    XCTAssertEqual(first("EXP JUN 2028"), date(.expiry, 2028, 6, nil, end: true))
  }

  func testDateOnTheNextLine() {
    XCTAssertEqual(first("BEST BEFORE\n12/03/2027"), date(.bestBefore, 2027, 3, 12))
  }

  func testPastDatesAreSaidAsPassed() {
    XCTAssertEqual(said("BB 01/06/26"), "Best before 1 June 2026. That date has already passed.")
    // A month-only date isn't passed until the month is over.
    XCTAssertEqual(said("BBE 11 2026"), "Best before the end of November 2026.")
    XCTAssertEqual(said("BBE 10 2026"), "Best before the end of October 2026. That date has already passed.")
    XCTAssertEqual(said("Use by 06/11/2026"), "Use by 6 November 2026. That's today.")
  }

  func testTwoKindsOfDate() {
    XCTAssertEqual(said("DISPLAY UNTIL 10/03/27\nUSE BY 12/03/27"), "Display until 10 March 2027. Use by 12 March 2027.")
  }

  func testUnlabelledFullDatesAreReported() {
    let f = LabelDates.find("L2345 12/03/2027 10:42", today: today)
    XCTAssertEqual(f.dates, [date(.unlabelled, 2027, 3, 12)])
    // A labelled date wins over an unlabelled one.
    XCTAssertEqual(said("Packed 01/11/2026\nBest before 01/04/2027"), "Best before 1 April 2027.")
  }

  func testSeeElsewhereAndKeywordWithoutADate() {
    XCTAssertEqual(
      said("Best before: see top of pack"), "The label says the date is on the top. Turn it so I can see the top, then ask again.")
    XCTAssertEqual(LabelDates.find("For use by date see lid", today: today).elsewhere, "lid")
    XCTAssertEqual(LabelDates.find("BEST BEFORE ##/##", today: today).keywordWithoutDate, .bestBefore)
    XCTAssertTrue(said("BEST BEFORE ##/##")?.hasPrefix("I can see best before, but I can't make out the date") ?? false)
  }

  func testNoDatesAtAll() {
    XCTAssertNil(said("Ingredients: oats, sugar, salt. Store in a cool dry place."))
    // Nutrition numbers and weights aren't dates.
    XCTAssertTrue(LabelDates.find("Energy 1580kJ / 375kcal per 100g. 500 g. Fat 12.5", today: today).dates.isEmpty)
    // Words that contain the keywords aren't keywords.
    XCTAssertTrue(LabelDates.find("Explore the BBC website. Expert taste.", today: today).dates.isEmpty)
  }

  func testInvalidDatesAreIgnored() {
    XCTAssertTrue(LabelDates.find("BB 31/02/27", today: today).dates.isEmpty)
    XCTAssertTrue(LabelDates.find("EXP 13/2027", today: today).dates.isEmpty)
  }

  func testCivilDateDays() {
    XCTAssertEqual(CivilDate(1970, 1, 1).epochDay, 0)
    XCTAssertEqual(CivilDate(2026, 11, 6).epochDay - CivilDate(2026, 3, 12).epochDay, 239)
    XCTAssertEqual(CivilDate.daysIn(2028, 2), 29)
    XCTAssertEqual(CivilDate.daysIn(2100, 2), 28)
  }
}

// MARK: - Sections, names, allergens, medicine

final class LabelTextTests: XCTestCase {
  private let cereal = [
    LabelLine(text: "OAT CRUNCH", height: 60),
    LabelLine(text: "Crunchy oat clusters", height: 30),
    LabelLine(text: "Ingredients: Wholegrain oats (55%), sugar,", height: 18),
    LabelLine(text: "almonds (6%), honey, salt.", height: 18),
    LabelLine(text: "Allergy advice: for allergens, see", height: 18),
    LabelLine(text: "ingredients in bold. May contain milk.", height: 18),
    LabelLine(text: "Nutrition information per 100g", height: 18),
    LabelLine(text: "Energy 1580kJ", height: 18),
    LabelLine(text: "Best before: 12/03/2027", height: 18),
  ]

  private func label(_ lines: [LabelLine]) -> String { lines.map(\.text).joined(separator: "\n") }

  private let snickers = OffProduct(
    code: "1", name: "Snickers", brands: ["Mars"], quantity: "50 g", allergenTags: ["en:milk", "en:peanuts"], traceTags: ["en:nuts"],
    ingredients: nil, categoryTags: [])

  func testIngredientsSectionEndsAtTheNextHeading() {
    XCTAssertEqual(LabelText.section(cereal, .ingredients), "Wholegrain oats (55%), sugar, almonds (6%), honey, salt.")
    XCTAssertEqual(LabelText.section(cereal, .allergens), "for allergens, see ingredients in bold. May contain milk.")
    XCTAssertNil(LabelText.section(cereal, .cooking))
  }

  func testCookingSectionKeepsItsSubheadings() {
    let pie = [
      LabelLine(text: "Cooking instructions", height: 20),
      LabelLine(text: "Oven: 200C, Fan 180C, Gas 6.", height: 16),
      LabelLine(text: "Remove film. Cook for 25 minutes.", height: 16),
      LabelLine(text: "Microwave: 800W 4 mins, stand 1 min.", height: 16),
      LabelLine(text: "Storage: keep refrigerated.", height: 16),
    ]
    XCTAssertEqual(
      LabelText.section(pie, .cooking),
      "Cooking instructions Oven: 200C, Fan 180C, Gas 6. Remove film. Cook for 25 minutes. Microwave: 800W 4 mins, stand 1 min.")
  }

  func testNameIsTheBiggestPrint() {
    XCTAssertEqual(LabelText.nameGuess(cereal), "OAT CRUNCH")
    XCTAssertEqual(
      LabelText.nameGuess([LabelLine(text: "Paracetamol 500 mg Tablets", height: 50), LabelLine(text: "16 tablets", height: 20)]),
      "Paracetamol 500 mg Tablets")
    XCTAssertNil(LabelText.nameGuess([LabelLine(text: "12", height: 40)]))
  }

  func testAllergenFoundInIngredients() {
    XCTAssertEqual(LabelText.allergenAnswer("nuts", label: label(cereal), product: nil), "Yes. The label mentions almonds.")
  }

  func testMayContainIsTraces() {
    XCTAssertEqual(
      LabelText.allergenAnswer("milk", label: label(cereal), product: nil), "It may contain milk. The label says: May contain milk.")
  }

  func testNotFoundIsNeverNo() {
    let a = LabelText.allergenAnswer("sesame", label: label(cereal), product: nil)
    XCTAssertTrue(a.hasPrefix("I couldn't find sesame on the part of the label I read."), a)
    XCTAssertTrue(a.contains("That doesn't mean it's free from sesame"))
    XCTAssertFalse(a.hasPrefix("No"))
    XCTAssertTrue(LabelText.allergenAnswer("eggs", label: nil, product: nil).hasPrefix("I couldn't find eggs anywhere yet."))
  }

  func testFreeFromIsQuoted() {
    XCTAssertEqual(
      LabelText.allergenAnswer("gluten", label: "Gluten free oat bars. Ingredients: rice, sugar.", product: nil),
      "The label says: Gluten free oat bars.")
    let b = LabelText.allergenAnswer("nuts", label: "Free from nuts and peanuts.", product: nil)
    XCTAssertTrue(b.hasPrefix("Yes") || b.hasPrefix("The label says"), b)
  }

  func testLookAlikesDontCount() {
    let a = LabelText.allergenAnswer("milk", label: "Ingredients: sugar, cocoa butter, cocoa mass, coconut milk powder.", product: nil)
    XCTAssertTrue(a.hasPrefix("I couldn't find milk"), a)
    let b = LabelText.allergenAnswer("nuts", label: "Ingredients: pumpkin, nutmeg, coconut.", product: nil)
    XCTAssertTrue(b.hasPrefix("I couldn't find nuts"), b)
    // Peanuts are reported to someone asking about nuts.
    XCTAssertEqual(LabelText.allergenAnswer("nuts", label: "Ingredients: peanuts, salt.", product: nil), "Yes. The label mentions peanuts.")
  }

  func testProductDataAnswersToo() {
    XCTAssertEqual(
      LabelText.allergenAnswer("dairy", label: nil, product: snickers), "Yes. Open Food Facts lists milk as an allergen in this product.")
    XCTAssertEqual(
      LabelText.allergenAnswer("nuts", label: nil, product: snickers), "Yes. Open Food Facts lists nuts as an allergen in this product.")
    var plain = snickers
    plain.allergenTags = []
    plain.traceTags = ["en:sesame-seeds"]
    XCTAssertEqual(
      LabelText.allergenAnswer("sesame", label: nil, product: plain), "It may contain sesame. Open Food Facts lists it as a possible trace.")
    let nothing = LabelText.allergenAnswer("fish", label: "Ingredients: oats.", product: plain)
    XCTAssertTrue(nothing.hasPrefix("I couldn't find fish on the label or in the product data."), nothing)
  }

  func testAllergenSummary() {
    XCTAssertEqual(
      LabelText.allergenSummary(cereal, product: snickers),
      "Allergy advice on the label: for allergens, see ingredients in bold. May contain milk. Open Food Facts lists milk and peanuts. It may contain traces of nuts."
    )
    XCTAssertNil(LabelText.allergenSummary([LabelLine(text: "Oats")], product: nil))
  }

  func testMedicineDetection() {
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Paracetamol 500 mg Tablets. Adults: take 2 tablets every 4 hours."))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Hay fever relief. 30 capsules"))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Read the patient information leaflet"))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Pharmacy medicine"))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Dosage: see leaflet"))
    // Two weak signs.
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Vitamin D 25 mcg. Take one daily with food."))
    // Food: at most one weak sign.
    XCTAssertFalse(MedicineCheck.looksLikeMedicine(label(cereal) + "\nSodium 400mg. % Daily Value 17%"))
    XCTAssertFalse(MedicineCheck.looksLikeMedicine("Take care, contents hot. Salt 0.5g. Sodium 200mg"))
    XCTAssertFalse(MedicineCheck.looksLikeMedicine("Heinz Baked Beans in tomato sauce"))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("Zinc", categoryTags: ["en:dietary-supplements"]))
    XCTAssertTrue(MedicineCheck.looksLikeMedicine("", categoryTags: ["en:medicines"]))
  }

  func testMedicineNamesLoseTheirStrength() {
    XCTAssertEqual(MedicineCheck.nameOnly("Paracetamol 500 mg Tablets"), "Paracetamol Tablets")
    XCTAssertEqual(MedicineCheck.nameOnly("Ibuprofen 200mg x 16"), "Ibuprofen")
    XCTAssertEqual(MedicineCheck.nameOnly("Cough Syrup 5 ml"), "Cough Syrup")
    XCTAssertEqual(MedicineCheck.nameOnly("500 mg"), "a medicine")
  }
}

// MARK: - Medicine expiry

final class MedicineExpiryTests: XCTestCase {
  private let today = CivilDate(2026, 11, 7)
  private func answer(_ text: String) -> String? { LabelDates.answer(LabelDates.find(text, today: today), today: today) }

  func testAClearDateIsSaidWithTheReminder() throws {
    let said = try XCTUnwrap(MedicineCheck.expiry(answer("EXP 06/2028"), dateLineConfidences: [0.95]))
    XCTAssertTrue(said.hasPrefix("Expiry date"), said)
    XCTAssertTrue(said.contains("2028"), said)
    XCTAssertTrue(said.hasSuffix(MedicineCheck.expiryCheck), said)
  }

  func testAnUnsureLineMeansNoDateAtAll() {
    let said = MedicineCheck.expiry(answer("EXP 06/2028"), dateLineConfidences: [0.95, 0.6])
    XCTAssertEqual(said, MedicineCheck.expiryUnsure)
    XCTAssertFalse(said?.contains("2028") ?? true)
  }

  func testNoConfidenceFromTheEngineCountsAsUnsure() {
    XCTAssertEqual(MedicineCheck.expiry(answer("EXP 06/2028"), dateLineConfidences: [nil]), MedicineCheck.expiryUnsure)
  }

  func testNoDateFoundIsLeftToTheCaller() {
    XCTAssertNil(MedicineCheck.expiry(nil, dateLineConfidences: []))
  }

  func testAPassedDateStillGetsTheReminder() throws {
    let said = try XCTUnwrap(MedicineCheck.expiry(answer("EXP 01/2025"), dateLineConfidences: [0.9]))
    XCTAssertTrue(said.contains("already passed"), said)
    XCTAssertTrue(said.hasSuffix(MedicineCheck.expiryCheck), said)
  }
}

// MARK: - The tool: medicine gives the name and a clear date only

private struct NoLookups: ProductSource {
  func lookup(_ code: String) async -> ProductLookupResult { .failed("tests don't go online") }
}

@MainActor
final class LabelsToolMedicineTests: XCTestCase {
  private func tool() -> LabelsTool { LabelsTool(productSource: NoLookups(), today: { CivilDate(2026, 11, 7) }) }

  private let paracetamol = [
    LabelLine(text: "PARACETAMOL", height: 60, confidence: 0.95),
    LabelLine(text: "500 mg Tablets", height: 30, confidence: 0.95),
    LabelLine(text: "Dosage: adults take 2 tablets every 4 hours.", height: 16, confidence: 0.9),
    LabelLine(text: "Do not exceed 8 tablets in 24 hours.", height: 16, confidence: 0.9),
  ]

  func testMedicineIsDetectedAndItsTextIsNotShown() {
    let t = tool()
    t.addViewForTesting(paracetamol + [LabelLine(text: "EXP 2028-06", height: 16, confidence: 0.95)])
    XCTAssertTrue(t.isMedicine)
    XCTAssertEqual(t.medicineName, "PARACETAMOL")
    XCTAssertNil(t.labelText)
  }

  func testAClearMedicineDateIsSaidWithTheReminderAndNoDose() {
    let t = tool()
    t.addViewForTesting(paracetamol + [LabelLine(text: "EXP 2028-06", height: 16, confidence: 0.95)])
    let said = t.expiryAnswer()
    XCTAssertEqual(said, "Expiry date the end of June 2028. " + MedicineCheck.expiryCheck)
    for dose in ["500", "2 tablets", "4 hours", "Dosage", "exceed"] { XCTAssertFalse(said.contains(dose), dose) }
  }

  func testAnUnclearMedicineDateIsNotSaid() {
    let t = tool()
    t.addViewForTesting(paracetamol + [LabelLine(text: "EXP 2028-06", height: 16, confidence: 0.55)])
    XCTAssertEqual(t.expiryAnswer(), MedicineCheck.expiryUnsure)
  }

  func testFoodDatesAreSaidPlainly() {
    let t = tool()
    t.addViewForTesting([LabelLine(text: "OAT CRUNCH", height: 60), LabelLine(text: "Best before: 12/03/2027", height: 18, confidence: 0.9)])
    XCTAssertFalse(t.isMedicine)
    XCTAssertEqual(t.expiryAnswer(), "Best before 12 March 2027: that's in about 4 months. Best before is about quality, not safety.")
    XCTAssertNotNil(t.labelText)
  }

  func testAnUnclearFoodDateIsNotSaid() {
    // Food check (FoodDates): a date line read with low confidence abstains, as medicine does.
    let t = tool()
    t.addViewForTesting([LabelLine(text: "OAT CRUNCH", height: 60), LabelLine(text: "Best before: 12/03/2027", height: 18, confidence: 0.4)])
    XCTAssertFalse(t.expiryAnswer().contains("12 March"))
  }

  func testDoseQuestionsAreHandledByTheTool() {
    let t = tool()
    XCTAssertTrue(t.handle(transcript: "How many should I take?"))
    XCTAssertEqual(t.lastLine, LabelsSpeech.medicineDose)
  }
}

// MARK: - Barcodes

final class BarcodeHintTests: XCTestCase {
  private let width = 480
  private let rows = 48

  /// EAN-13 modules for a code (95 modules, true = bar).
  private func ean13(_ code: String) -> [Bool] {
    let l = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    let g = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
    let r = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
    let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
    let d = code.compactMap(\.wholeNumberValue)
    var s = "101"
    let p = Array(parity[d[0]])
    for i in 1...6 { s += p[i - 1] == "L" ? l[d[i]] : g[d[i]] }
    s += "01010"
    for i in 7...12 { s += r[d[i]] }
    s += "101"
    return s.map { $0 == "1" }
  }

  /// A deterministic generator, so "text" rows are the same every run.
  private struct Lcg {
    var state: UInt64
    mutating func next(_ lower: Int, _ upper: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return lower + Int((state >> 33) % UInt64(upper - lower))
    }
    mutating func coin() -> Bool { next(0, 2) == 0 }
  }

  private func frame(barLeft: Int = -1, barWidth: Int = 0, barTop: Int = 0, barRows: Int = 0, textRows: ClosedRange<Int>? = nil) -> [UInt8] {
    var luma = [UInt8](repeating: 230, count: width * rows)
    if barWidth > 0 {
      let modules = ean13("5012345678900")
      for r in barTop..<(barTop + barRows) {
        for x in barLeft..<(barLeft + barWidth) where modules[(x - barLeft) * modules.count / barWidth] {
          luma[r * width + x] = 25
        }
      }
    }
    if let textRows {
      var rnd = Lcg(state: 7)
      for r in textRows {
        var x = 20
        while x < width - 20 {
          let w = rnd.next(2, 6)
          if rnd.coin() { for k in x..<min(width, x + w) { luma[r * width + k] = 30 } }
          x += w + rnd.next(2, 6)
        }
      }
    }
    return luma
  }

  func testFindsABarcodeAndItsPlace() throws {
    let r = try XCTUnwrap(BarcodeHint.find(frame(barLeft: 120, barWidth: 240, barTop: 18, barRows: 10), width: width, rows: rows))
    XCTAssertEqual(r.left, 0.25, accuracy: 0.03)
    XCTAssertEqual(r.right, 0.75, accuracy: 0.03)
    XCTAssertTrue((0.3...0.45).contains(r.top), "\(r.top)")
    XCTAssertGreaterThan(r.closeness, 0.85, "centred and half the width")
  }

  func testSmallerOrOffCentreIsLessClose() throws {
    let small = try XCTUnwrap(BarcodeHint.find(frame(barLeft: 190, barWidth: 100, barTop: 20, barRows: 6), width: width, rows: rows))
    let corner = try XCTUnwrap(BarcodeHint.find(frame(barLeft: 10, barWidth: 200, barTop: 2, barRows: 6), width: width, rows: rows))
    let big = try XCTUnwrap(BarcodeHint.find(frame(barLeft: 120, barWidth: 240, barTop: 18, barRows: 10), width: width, rows: rows))
    XCTAssertLessThan(small.closeness, big.closeness)
    XCTAssertLessThan(corner.closeness, big.closeness)
    // Closer means more ticks, higher.
    XCTAssertGreaterThan(BarcodeHint.ticks(for: big.closeness).hz, BarcodeHint.ticks(for: small.closeness).hz)
    XCTAssertEqual(BarcodeHint.ticks(for: 0).count, 1)
    XCTAssertEqual(BarcodeHint.ticks(for: 1).count, 4)
  }

  func testTextAndPaperAreNotBarcodes() {
    XCTAssertNil(BarcodeHint.find(frame(), width: width, rows: rows))
    XCTAssertNil(BarcodeHint.find(frame(textRows: 4...40), width: width, rows: rows))
  }

  func testBarcodeNextToText() throws {
    var luma = frame(barLeft: 140, barWidth: 200, barTop: 30, barRows: 8)
    let text = frame(textRows: 2...20)
    for i in 0..<(width * 21) { luma[i] = text[i] }
    let r = try XCTUnwrap(BarcodeHint.find(luma, width: width, rows: rows))
    XCTAssertGreaterThanOrEqual(r.top, 0.55)
  }

  func testCheckDigitsAndProductCodes() {
    XCTAssertTrue(LabelCodes.checkDigitOk("5012345678900"))
    XCTAssertTrue(LabelCodes.checkDigitOk("3017620422003"))
    XCTAssertTrue(LabelCodes.checkDigitOk("96385074"))  // EAN-8
    XCTAssertFalse(LabelCodes.checkDigitOk("5012345678901"))
    XCTAssertEqual(LabelCodes.productCode("5000159461122"), "5000159461122")
    XCTAssertEqual(LabelCodes.productCode("036000291452"), "0036000291452")  // UPC-A padded
    XCTAssertEqual(LabelCodes.productCode("01234565"), "01234565")  // UPC-E
    XCTAssertNil(LabelCodes.productCode("5012345678901"))
    XCTAssertNil(LabelCodes.productCode("ABC"))
    XCTAssertNil(ScannedCode(raw: "5012345678901", kind: .product, format: "EAN-13").productCode)
    XCTAssertNil(ScannedCode(raw: "5012345678900", kind: .other, format: "barcode").productCode)
  }

  func testQrCodesAreDescribedNotOpened() {
    XCTAssertEqual(
      LabelCodes.describeQr("https://www.example.com/promo?id=42"), "This is a QR code. It links to example.com. I won't open links.")
    XCTAssertEqual(
      LabelCodes.describeQr("http://shop.example.co.uk"), "This is a QR code. It links to shop.example.co.uk. I won't open links.")
    let wifi = LabelCodes.describeQr("WIFI:T:WPA;S:Cafe Guest;P:secret123;;")
    XCTAssertEqual(wifi, "This is a QR code for a Wi-Fi network called Cafe Guest.")
    XCTAssertFalse(wifi.contains("secret"))
    XCTAssertEqual(LabelCodes.describeQr("Table 12"), "This is a QR code. It says: Table 12")
    XCTAssertEqual(LabelCodes.describeQr("tel:01234"), "This is a QR code with a phone number: 0 1 2 3 4.")
    XCTAssertTrue(LabelCodes.describeQr(String(repeating: "x", count: 10) + " " + String(repeating: "word ", count: 80)).hasSuffix("\u{2026}"))
  }
}

// MARK: - Grammar

final class LabelsGrammarTests: XCTestCase {
  private func check(_ command: LabelsCommand, _ phrases: String..., file: StaticString = #filePath, line: UInt = #line) {
    for p in phrases { XCTAssertEqual(LabelsGrammar.parse(p), command, p, file: file, line: line) }
  }

  func testScanAndLookUp() {
    check(.scan, "scan this", "Scan again", "what's this?", "what is that", "try again", "next one", "scan")
    check(.lookUp, "look it up", "Look it up, please", "can you look that up", "search for it", "what product is it", "look up")
    check(.stopScan, "stop scanning", "cancel", "never mind")
  }

  func testReadingTheLabel() {
    check(.readLabel, "read the label", "read it", "read", "read the box", "what does it say", "read it to me")
    check(.readAll, "read it all", "read everything", "read the whole label", "read the rest", "read all of it")
  }

  func testQuickJumps() {
    check(
      .expiry, "when does it expire", "best before", "what's the use by date", "is it out of date", "has it expired", "expiry date",
      "when does it go off", "what's the date on it", "sell by")
    check(.cooking, "cooking instructions", "how do I cook it", "how do I heat this up", "microwave instructions", "how long in the oven")
    check(.ingredients, "ingredients", "what are the ingredients", "what's in it", "read the ingredients", "what is it made of")
    check(.name, "what is it", "what's it called", "say the name again")
  }

  func testAllergens() {
    check(.allergens(nil), "allergens", "allergy advice", "what are the allergens", "any allergens", "does it contain any allergens")
    check(
      .allergens("nuts"), "does it contain nuts", "does it have nuts in it", "is there any nuts in it", "are there nuts in this",
      "any nuts in it")
    check(.allergens("gluten"), "is it gluten free", "is it gluten-free?", "does this contain gluten")
    check(.allergens("milk"), "does it have milk", "has it got milk in it")
  }

  func testDosesAreAlwaysCaught() {
    check(
      .dose, "how many should I take", "what's the dose", "what is the dosage", "how often", "how many tablets can I have",
      "how much should I give", "when should I take it", "can I take another one", "directions for use", "how do I take it")
  }

  func testLeavesOtherToolsAndGlobalCommandsAlone() {
    for p in [
      "read my mail", "watch for 42", "tell me when you see the exit", "what colour is this", "is the light on", "open the book reader",
      "back to my book", "battery", "help", "close", "faster", "say that again", "stop", "what does ephemeral mean",
    ] {
      XCTAssertNil(LabelsGrammar.parse(p), p)
    }
  }

  func testNormalisationDropsAddressAndFiller() {
    XCTAssertEqual(LabelsPhrases.normalize("Reader, can you look it up please?"), "look it up")
    XCTAssertEqual(LabelsPhrases.normalize("What\u{2019}s in it?"), "whats in it")
    XCTAssertEqual(LabelsPhrases.normalize("is it gluten-free"), "is it gluten free")
  }
}

// MARK: - Open Food Facts

final class OpenFoodFactsTests: XCTestCase {
  private let snickersReply = """
    {"code":"5000159461122","product":{"product_name":"Snickers","brands":"Mars, Snickers, Mars","quantity":"50 g",
    "allergens_tags":["en:milk","en:peanuts"],"traces_tags":["en:nuts"],"ingredients_text":"Milk chocolate, peanuts",
    "categories_tags":["en:snacks"]},"status":1,"status_verbose":"product found"}
    """
  private let notFoundReply = """
    {"code":"5012345678900","status":0,"status_verbose":"no code or invalid code"}
    """

  func testParsesAFoundProduct() throws {
    guard case .found(let p, let fromCache) = try OpenFoodFacts.parse(Data(snickersReply.utf8)) else {
      return XCTFail("not found")
    }
    XCTAssertFalse(fromCache)
    XCTAssertEqual(p.name, "Snickers")
    XCTAssertEqual(p.brands, ["Mars", "Snickers"])
    XCTAssertEqual(p.allergens, ["milk", "peanuts"])
    XCTAssertEqual(p.traces, ["nuts"])
    XCTAssertEqual(p.summary(), "Snickers, by Mars, 50 grams.")
    XCTAssertFalse(MedicineCheck.looksLikeMedicine(p.name ?? "", categoryTags: p.categoryTags))
  }

  func testNotFoundAndGarbage() {
    XCTAssertEqual(try OpenFoodFacts.parse(Data(notFoundReply.utf8)), .notFound)
    XCTAssertThrowsError(try OpenFoodFacts.parse(Data("<html>".utf8)))
  }

  func testQuantitiesAndTags() {
    XCTAssertEqual(OpenFoodFacts.spokenQuantity("400 g e"), "400 grams")
    XCTAssertEqual(OpenFoodFacts.spokenQuantity("50 G"), "50 grams")
    XCTAssertEqual(OpenFoodFacts.spokenQuantity("6 x 330ml"), "6 x 330 millilitres")
    XCTAssertEqual(OpenFoodFacts.tagName("en:soybeans"), "soya")
    XCTAssertEqual(OpenFoodFacts.tagName("fr:fruits-a-coque"), "fruits a coque")
  }

  func testTheRequestHoldsOnlyTheBarcode() throws {
    let url = try XCTUnwrap(OpenFoodFacts.url("5000159461122"))
    XCTAssertEqual(url.host, "world.openfoodfacts.org")
    XCTAssertEqual(url.path, "/api/v2/product/5000159461122.json")
    let query = url.query ?? ""
    XCTAssertTrue(query.hasPrefix("fields="))
    XCTAssertFalse(query.contains("5000159461122"))
  }

  func testSourceCachesAndReportsOffline() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("off-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let reply = Data(snickersReply.utf8)
    let calls = Counter()
    let online = OpenFoodFactsSource(cacheDirectory: dir) { url in
      await calls.add(url)
      return (200, reply)
    }
    guard case .found(_, false) = await online.lookup("5000159461122") else { return XCTFail("first lookup") }
    let offline = OpenFoodFactsSource(cacheDirectory: dir) { _ in throw URLError(.notConnectedToInternet) }
    guard case .found(_, true) = await offline.lookup("5000159461122") else { return XCTFail("cached lookup") }
    let unknown = await offline.lookup("5012345678900")
    XCTAssertEqual(unknown, .offline)
    let urls = await calls.urls
    XCTAssertEqual(urls.count, 1)
    XCTAssertEqual(urls.first?.lastPathComponent, "5000159461122.json")
    let failing = OpenFoodFactsSource(cacheDirectory: dir) { _ in (503, Data()) }
    let unavailable = await failing.lookup("5012345678900")
    XCTAssertEqual(unavailable, .failed("HTTP 503"))
    let letters = await failing.lookup("12ab")
    XCTAssertEqual(letters, .failed("Barcode must be digits"))
  }
}

private actor Counter {
  var urls: [URL] = []
  func add(_ url: URL) { urls.append(url) }
}
