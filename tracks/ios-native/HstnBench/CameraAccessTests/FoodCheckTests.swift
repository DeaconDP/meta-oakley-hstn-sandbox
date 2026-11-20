/*
 * FoodCheckTests - roadmap V2 food check inside Labels and barcodes
 *
 * Allergen words and "may contain", abstaining on a partial read, the date against a fixed today,
 * cooking steps, the Open Food Facts disagreement rule, the grammar, the stored list, and the tool
 * end to end with OCR'd sides fed in (no camera in the Simulator; nothing goes online).
 */

import XCTest

@testable import CameraAccess

private func lines(_ texts: String...) -> [LabelLine] { texts.map { LabelLine(text: $0, height: 18, confidence: 0.95) } }
private func allergens(_ ids: String...) -> [FoodAllergen] { ids.compactMap(FoodAllergens.allergen(id:)) }
private func product(allergens: [String] = [], traces: [String] = []) -> OffProduct {
  OffProduct(
    code: "5000000000000", name: "Oat Crunch", brands: [], quantity: nil, allergenTags: allergens, traceTags: traces, ingredients: nil,
    categoryTags: [])
}

/// Every spoken answer must stay honest: never "safe", never "allergen free".
private func assertHonest(_ spoken: String, file: StaticString = #filePath, line: UInt = #line) {
  let lower = spoken.lowercased()
  for banned in ["safe", "allergen free", "allergen-free", "free from"] {
    XCTAssertFalse(lower.contains(banned), "\(banned) in: \(spoken)", file: file, line: line)
  }
}

// MARK: - Allergens and synonyms

final class FoodAllergenTests: XCTestCase {
  func testThereAreTheFourteenMajorAllergens() {
    XCTAssertEqual(FoodAllergens.all.count, 14)
    XCTAssertEqual(Set(FoodAllergens.all.map(\.id)).count, 14)
  }

  func testSpokenListsResolve() {
    XCTAssertEqual(FoodAllergens.resolve("peanuts and milk").allergens, allergens("peanuts", "milk"))
    XCTAssertEqual(FoodAllergens.resolve("dairy, sesame seeds").allergens, allergens("milk", "sesame"))
    XCTAssertEqual(FoodAllergens.resolve("wheat").allergens, allergens("gluten"))
    XCTAssertEqual(FoodAllergens.resolve("soy").allergens, allergens("soya"))
    XCTAssertEqual(FoodAllergens.resolve("tree nuts").allergens, allergens("treenuts"))
    XCTAssertTrue(FoodAllergens.resolve("tree nuts").notes.isEmpty)
    let nuts = FoodAllergens.resolve("nuts")
    XCTAssertEqual(nuts.allergens, allergens("treenuts"))
    XCTAssertTrue(nuts.notes.first?.contains("Peanuts are separate") == true)
    XCTAssertEqual(FoodAllergens.resolve("shellfish").allergens, allergens("crustaceans", "molluscs"))
    let kiwi = FoodAllergens.resolve("kiwi and mustard")
    XCTAssertEqual(kiwi.allergens, allergens("mustard"))
    XCTAssertEqual(kiwi.unknown, ["kiwi"])
  }

  func testIngredientSynonymsAreFound() {
    let cases: [(String, String, String)] = [
      ("milk", "Ingredients: Sugar, whey powder, salt.", "whey powder"),
      ("milk", "Ingredients: Sugar, sodium caseinate, salt.", "sodium caseinate"),
      ("milk", "Ingredients: Glucose, lactose, flavouring.", "lactose"),
      ("milk", "Ingredients: Potatoes, butter (milk), salt.", "butter (milk)"),
      ("gluten", "Ingredients: Wheat flour, water, yeast.", "wheat flour"),
      ("gluten", "Ingredients: Rolled oats, honey.", "rolled oats"),
      ("gluten", "Ingredients: Spelt flour, water.", "spelt flour"),
      ("gluten", "Ingredients: Rice, barley malt extract, salt.", "barley malt extract"),
      ("eggs", "Ingredients: Sugar, pasteurised free range egg, flour.", "pasteurised free range egg"),
      ("sesame", "Ingredients: Chickpeas, tahini, lemon juice.", "tahini"),
      ("soya", "Ingredients: Cocoa mass, emulsifier (soya lecithin).", "emulsifier (soya lecithin)"),
      ("sulphites", "Ingredients: Grape juice, preservative (sodium metabisulphite).", "preservative (sodium metabisulphite)"),
      ("treenuts", "Ingredients: Sugar, roasted hazelnuts (13%), cocoa.", "roasted hazelnuts"),
      ("crustaceans", "Ingredients: King prawns (crustacean), garlic.", "king prawns (crustacean)"),
    ]
    for (id, text, item) in cases {
      let report = FoodCheck.check(sides: [lines(text)], allergens: allergens(id), product: nil)
      XCTAssertEqual(report.contains.first?.evidence.first, item, text)
      XCTAssertEqual(report.contains.first?.place, .ingredients, text)
      assertHonest(report.spoken)
    }
  }

  func testTheAnswerNamesWhatWasFoundAndWhere() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Wheat flour, sugar, whey powder, salt.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.spoken, "Contains milk: it says whey powder in the ingredients.")
  }

  func testLookAlikesAreNotAllergens() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Sugar, cocoa butter, coconut milk, buckwheat flour, nutmeg, cream of tartar, butternut squash.")],
      allergens: allergens("milk", "gluten", "treenuts"), product: nil)
    XCTAssertTrue(report.contains.isEmpty, "\(report.contains)")
    XCTAssertEqual(report.spoken, FoodCheck.nothingFound)
  }

  func testPeanutsAreNotTreeNuts() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Peanuts (98%), salt.")], allergens: allergens("treenuts", "peanuts"), product: nil)
    XCTAssertEqual(report.contains.map(\.allergen.id), ["peanuts"])
  }

  func testMayContainIsAWarningNotContains() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Oats, sugar, salt.", "Allergy advice: May contain peanuts.")],
      allergens: allergens("peanuts", "milk"), product: nil)
    XCTAssertTrue(report.contains.isEmpty)
    XCTAssertEqual(report.mayContain.map(\.allergen.id), ["peanuts"])
    XCTAssertTrue(report.spoken.hasPrefix("May contain peanuts: the pack says, may contain peanuts."), report.spoken)
    XCTAssertTrue(report.spoken.contains("I didn't find milk in the ingredients I could read."), report.spoken)
    XCTAssertFalse(report.spoken.contains("Contains peanuts"))
    assertHonest(report.spoken)
  }

  func testMadeInAFactoryThatHandlesIsAWarning() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice flour, sugar, salt.", "Made in a factory that also handles sesame and nuts.")],
      allergens: allergens("sesame", "treenuts"), product: nil)
    XCTAssertTrue(report.contains.isEmpty)
    XCTAssertEqual(report.mayContain.map(\.allergen.id), ["sesame", "treenuts"])
    XCTAssertTrue(
      report.spoken.hasPrefix("May contain sesame and tree nuts: the pack says, made in a factory that also handles sesame and nuts."),
      report.spoken)
  }

  func testMayContainInsideTheIngredientsSentence() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Oats, sugar, may contain milk.")], allergens: allergens("milk", "gluten"), product: nil)
    XCTAssertEqual(report.contains.map(\.allergen.id), ["gluten"])
    XCTAssertEqual(report.mayContain.map(\.allergen.id), ["milk"])
  }

  func testAllergyAdviceContainsLineCounts() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Flavourings, salt.", "Contains: Milk, Soya.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.contains.first?.place, .allergyAdvice)
    XCTAssertTrue(report.spoken.hasPrefix("Contains milk: the allergy advice says milk."), report.spoken)
  }

  func testBoldIngredientsBoilerplateIsNotAnAllergen() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice, salt.", "Allergy advice: For allergens, including cereals containing gluten, see ingredients in bold.")],
      allergens: allergens("gluten"), product: nil)
    XCTAssertTrue(report.contains.isEmpty)
    XCTAssertEqual(report.spoken, FoodCheck.nothingFound)
  }

  func testFreeFromClaimsAreNotContains() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice, sugar, salt.", "Free from milk and egg. Dairy free.")], allergens: allergens("milk", "eggs"),
      product: nil)
    XCTAssertTrue(report.contains.isEmpty)
  }
}

// MARK: - Partial reads

final class FoodCheckPartialReadTests: XCTestCase {
  func testACompleteListWithNothingFoundSaysExactlyThat() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Rice, water, salt.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .complete)
    XCTAssertEqual(report.spoken, "I didn't find your allergens in the ingredients I could read. Check the pack if you're unsure.")
  }

  func testAListEndingAtTheNextHeadingIsComplete() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Rice, water, salt", "Storage: keep in a cool dry place.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .complete)
  }

  func testAListCutOffAtTheBottomAbstains() {
    let report = FoodCheck.check(sides: [lines("OAT CRUNCH", "Ingredients: Wheat flour, sugar, palm oil,")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .partial(.unfinished))
    XCTAssertFalse(report.spoken.contains("I didn't find"), report.spoken)
    XCTAssertTrue(report.spoken.contains("so I can't check them."), report.spoken)
    XCTAssertTrue(report.spoken.contains("say food check again"), report.spoken)
    assertHonest(report.spoken)
  }

  func testAListWithNoFullStopOnTheLastLineAbstains() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Rice, water, salt")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .partial(.unfinished))
  }

  func testAnOpenBracketAbstains() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Rice, emulsifier (soya lecithin, salt.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .partial(.unfinished))
  }

  func testALineRunningOffTheEdgeAbstains() {
    var side = lines("Ingredients: Rice, water, salt.")
    side[0].touchesEdge = true
    let report = FoodCheck.check(sides: [side], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .partial(.cutOff))
    XCTAssertTrue(report.spoken.hasPrefix("The ingredients run off the edge of the picture"), report.spoken)
  }

  func testABlurredLineAbstains() {
    let side = [LabelLine(text: "Ingredients: Rice, water,", height: 18, confidence: 0.95), LabelLine(text: "salt, mllk powder.", height: 18, confidence: 0.3)]
    let report = FoodCheck.check(sides: [side], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .partial(.unclear))
    XCTAssertFalse(report.spoken.contains("I didn't find"))
  }

  func testNoIngredientsHeadingAbstains() {
    let report = FoodCheck.check(sides: [lines("OAT CRUNCH", "See ingredients in bold on the back.")], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .notFound)
    XCTAssertTrue(report.spoken.contains("Turn the pack until I can see the word Ingredients"), report.spoken)
    XCTAssertFalse(report.spoken.contains("I didn't find your allergens"))
  }

  func testWhatWasFoundIsStillNamedWhenTheListIsCutOff() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Sugar, whey powder, cocoa,")], allergens: allergens("milk", "peanuts"), product: nil)
    XCTAssertEqual(report.state, .partial(.unfinished))
    XCTAssertTrue(report.spoken.hasPrefix("Contains milk: it says whey powder in the ingredients."), report.spoken)
    XCTAssertTrue(report.spoken.contains("so there may be more"), report.spoken)
    XCTAssertFalse(report.spoken.contains("I didn't find peanuts"))
  }

  func testTheNewestSideWithIngredientsIsUsed() {
    let back = lines("Ingredients: Rice, salt.")
    let front = lines("OAT CRUNCH", "High in fibre")
    let report = FoodCheck.check(sides: [front, back], allergens: allergens("milk"), product: nil)
    XCTAssertEqual(report.state, .complete)
  }
}

// MARK: - Open Food Facts never overrides the pack

final class FoodCheckOpenFoodFactsTests: XCTestCase {
  func testAgreementIsMentioned() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Sugar, whey powder.")], allergens: allergens("milk"), product: product(allergens: ["en:milk"]))
    XCTAssertEqual(report.spoken, "Contains milk: it says whey powder in the ingredients. Open Food Facts lists milk too.")
  }

  func testThePackWinsWhenOpenFoodFactsMissesAnAllergen() {
    let report = FoodCheck.check(sides: [lines("Ingredients: Sugar, whey powder.")], allergens: allergens("milk"), product: product())
    XCTAssertEqual(report.contains.map(\.allergen.id), ["milk"])
    XCTAssertTrue(report.spoken.contains("Open Food Facts doesn't list milk, but the pack wins"), report.spoken)
  }

  func testOpenFoodFactsCantAddAnAllergenThePackDoesntShow() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice, salt.")], allergens: allergens("sesame"), product: product(allergens: ["en:sesame-seeds"]))
    XCTAssertTrue(report.contains.isEmpty, "Open Food Facts never overrides the pack")
    XCTAssertFalse(report.spoken.contains("Contains sesame"))
    XCTAssertTrue(report.spoken.contains("Open Food Facts lists sesame, but I didn't find it on the pack. The pack wins"), report.spoken)
    assertHonest(report.spoken)
  }

  func testOpenFoodFactsCantFillInAPartialRead() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice, salt,")], allergens: allergens("sesame"), product: product(allergens: ["en:sesame-seeds"]))
    XCTAssertTrue(report.contains.isEmpty)
    XCTAssertTrue(report.spoken.contains("The pack is what counts"), report.spoken)
    XCTAssertFalse(report.spoken.contains("I didn't find your allergens"))
  }

  func testATraceOnlyInOpenFoodFactsIsMentioned() {
    let report = FoodCheck.check(
      sides: [lines("Ingredients: Rice, salt.")], allergens: allergens("treenuts"), product: product(traces: ["en:nuts"]))
    XCTAssertTrue(report.mayContain.isEmpty)
    XCTAssertTrue(report.spoken.contains("as a possible trace, but I didn't see that on the pack. The pack wins"), report.spoken)
  }
}

// MARK: - Dates against today

final class FoodDatesTests: XCTestCase {
  private let today = CivilDate(2026, 11, 20)

  private func said(_ texts: String...) -> String { FoodDates.answer(texts.map { LabelLine(text: $0, height: 18, confidence: 0.95) }, today: today).spoken }

  func testUseByTomorrow() {
    XCTAssertEqual(said("USE BY 21 NOV"), "Use by 21 November: that's tomorrow. Use by is about safety: don't eat it after that date.")
    XCTAssertEqual(said("Use by: 21/11/2026"), "Use by 21 November: that's tomorrow. Use by is about safety: don't eat it after that date.")
  }

  func testUseByTodayAndPassed() {
    XCTAssertEqual(
      said("USE BY 20.11.26"), "Use by 20 November: that's today. Use by is about safety: eat it, cook it or freeze it by the end of today.")
    XCTAssertEqual(said("USE BY 18/11/2026"), "Use by 18 November: that was 2 days ago. Use by is about safety, so don't eat it.")
    XCTAssertEqual(said("Use by 19/11/2026"), "Use by 19 November: that was yesterday. Use by is about safety, so don't eat it.")
  }

  func testUseBySoon() {
    XCTAssertEqual(said("USE BY 25/11/2026"), "Use by 25 November: that's in 5 days. Use by is about safety: don't eat it after that date.")
  }

  func testBestBefore() {
    XCTAssertEqual(
      said("BEST BEFORE 01/11/2026"),
      "Best before 1 November: that was about 3 weeks ago. Best before is about quality, not safety, so it may just be past its best.")
    XCTAssertEqual(said("BB 12/03/2027"), "Best before 12 March 2027: that's in about 4 months. Best before is about quality, not safety.")
    XCTAssertEqual(said("BBE 03 2027"), "Best before the end of March 2027: that's in about 4 months. Best before is about quality, not safety.")
  }

  func testUseByWinsOverDisplayUntil() {
    XCTAssertEqual(
      said("DISPLAY UNTIL 22/11/2026", "USE BY 24/11/2026"),
      "Use by 24 November: that's in 4 days. Use by is about safety: don't eat it after that date.")
    XCTAssertTrue(said("DISPLAY UNTIL 22/11/2026").contains("That date is for the shop."))
    XCTAssertNil(FoodDates.answer(lines("DISPLAY UNTIL 22/11/2026"), today: today).date)
  }

  func testItAbstainsWhenTheDateIsntFullyRead() {
    let keywordOnly = FoodDates.answer(lines("USE BY"), today: today)
    XCTAssertNil(keywordOnly.date)
    XCTAssertTrue(keywordOnly.spoken.contains("can't make out the date"), keywordOnly.spoken)

    let blurred = FoodDates.answer([LabelLine(text: "USE BY 21/11/2026", height: 18, confidence: 0.3)], today: today)
    XCTAssertNil(blurred.date)
    XCTAssertFalse(blurred.spoken.contains("21"))
    XCTAssertTrue(blurred.spoken.contains("can't read the date clearly"), blurred.spoken)

    let edge = FoodDates.answer([LabelLine(text: "USE BY 21/11/2026", height: 18, confidence: 0.95, touchesEdge: true)], today: today)
    XCTAssertNil(edge.date)
    XCTAssertTrue(edge.spoken.contains("runs off the edge"), edge.spoken)

    XCTAssertEqual(FoodDates.answer(lines("OAT CRUNCH"), today: today).spoken, FoodDates.notFound)
  }

  func testADateOnTheLineBelowItsKeywordIsCheckedToo() {
    let answer = FoodDates.answer(
      [LabelLine(text: "USE BY", height: 18, confidence: 0.95), LabelLine(text: "21/11/2026", height: 18, confidence: 0.2)], today: today)
    XCTAssertNil(answer.date)
  }

  func testReminderPlans() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
    func plan(_ day: Int) -> FoodDates.ReminderPlan {
      FoodDates.reminder(
        for: LabelDate(kind: .useBy, year: 2026, month: 11, day: day), name: "Chicken", key: "123", today: today, now: now, calendar: calendar)
    }
    guard case .request(let request) = plan(25) else { return XCTFail("expected a reminder") }
    XCTAssertEqual(request.fireDate, calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9)))
    XCTAssertEqual(request.title, "Chicken use by")
    XCTAssertEqual(request.spokenText, "Reminder: the Chicken label says use by 25 November, that's tomorrow.")
    XCTAssertEqual(request.source, "labels")
    // The day before at 9 has gone: 9 on the day.
    guard case .request(let tomorrow) = plan(21) else { return XCTFail("expected a reminder") }
    XCTAssertEqual(tomorrow.fireDate, calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9)))
    XCTAssertTrue(tomorrow.spokenText.hasSuffix("that's today."))
    XCTAssertEqual(plan(20), .tooSoon)
    XCTAssertEqual(plan(19), .passed)
  }

  func testReminderResultsAreSpokenHonestly() {
    let date = LabelDate(kind: .useBy, year: 2026, month: 11, day: 25)
    let fire = Date()
    XCTAssertTrue(FoodDates.scheduled(.unavailable, fireDate: fire, date: date, today: today).hasPrefix("Reminders aren't available"))
    XCTAssertTrue(FoodDates.scheduled(.notAllowed, fireDate: fire, date: date, today: today).contains("notifications are off"))
    XCTAssertTrue(FoodDates.scheduled(.inThePast, fireDate: fire, date: date, today: today).contains("too soon"))
  }

  private func lines(_ texts: String...) -> [LabelLine] { texts.map { LabelLine(text: $0, height: 18, confidence: 0.95) } }
}

// MARK: - Cooking steps

final class CookingStepsTests: XCTestCase {
  private let instructions =
    "Cooking instructions: Oven cook: Preheat oven to 200°C / Fan 180°C / Gas Mark 6. Remove film and place on a baking tray. "
    + "Cook for 20-25 mins. Microwave: 800W 4 mins, 900W 3 mins 30 secs. Stir halfway. Leave to stand for 1 min."

  func testMethodsAndSentencesBecomeSteps() {
    let steps = CookingSteps.split(instructions)
    XCTAssertEqual(steps.map(\.method), ["Oven", "Oven", "Oven", "Microwave", "Microwave", "Microwave"])
    XCTAssertEqual(
      steps.map(\.text),
      [
        "Preheat oven to 200°C / Fan 180°C / Gas Mark 6.", "Remove film and place on a baking tray.", "Cook for 20-25 mins.",
        "800W 4 mins, 900W 3 mins 30 secs.", "Stir halfway.", "Leave to stand for 1 min.",
      ])
    XCTAssertEqual(CookingSteps.intro(steps), "Cooking instructions, 6 steps: oven and microwave.")
  }

  func testNumberedStepsAreKept() {
    let steps = CookingSteps.split("1. Preheat the oven. 2. Bake for 20 minutes. 3. Serve.")
    XCTAssertEqual(steps.map(\.text), ["Preheat the oven.", "Bake for 20 minutes.", "Serve."])
    // "Gas Mark 6." isn't a numbered step.
    XCTAssertEqual(CookingSteps.split("Heat to Gas Mark 6. Bake for 1 hour.").count, 2)
  }

  func testTemperaturesAndTimesAreReadAsPrintedNeverConverted() {
    let oven = CookingSteps.spoken("Preheat oven to 200°C / Fan 180°C / Gas Mark 6.")
    XCTAssertEqual(oven, "Preheat oven to 200 degrees Celsius, or Fan 180 degrees Celsius, or Gas Mark 6.")
    XCTAssertFalse(oven.contains("Fahrenheit"))
    XCTAssertFalse(oven.contains("392"))
    XCTAssertEqual(CookingSteps.spoken("Bake at 400°F for 1 hr."), "Bake at 400 degrees Fahrenheit for 1 hour.")
    XCTAssertEqual(CookingSteps.spoken("Cook for 20-25 mins."), "Cook for 20 to 25 minutes.")
    XCTAssertEqual(CookingSteps.spoken("800W 4 mins, 900W 3 mins 30 secs."), "800 watts 4 minutes, 900 watts 3 minutes 30 seconds.")
    XCTAssertEqual(CookingSteps.spoken("Leave to stand for 1 min."), "Leave to stand for 1 minute.")
  }

  func testStepLines() {
    let steps = CookingSteps.split(instructions)
    XCTAssertEqual(
      CookingSteps.line(steps, 0), "Step 1 of 6. Oven: Preheat oven to 200 degrees Celsius, or Fan 180 degrees Celsius, or Gas Mark 6.")
    XCTAssertEqual(CookingSteps.line(steps, 1), "Step 2 of 6. Remove film and place on a baking tray.")
    XCTAssertEqual(CookingSteps.line(steps, 1, alwaysMethod: true), "Step 2 of 6. Oven: Remove film and place on a baking tray.")
    XCTAssertEqual(CookingSteps.line(steps, 3), "Step 4 of 6. Microwave: 800 watts 4 minutes, 900 watts 3 minutes 30 seconds.")
    XCTAssertEqual(CookingSteps.line(steps, 5), "Step 6 of 6. Leave to stand for 1 minute. That's the last step.")
  }
}

// MARK: - Grammar

final class FoodCheckGrammarTests: XCTestCase {
  private func check(_ command: LabelsCommand, _ phrases: String..., file: StaticString = #filePath, line: UInt = #line) {
    for p in phrases { XCTAssertEqual(LabelsGrammar.parse(p), command, p, file: file, line: line) }
  }

  func testMyAllergens() {
    check(.setAllergens("peanuts and milk"), "my allergens are peanuts and milk", "I'm allergic to peanuts and milk")
    check(.addAllergens("sesame"), "add sesame", "add sesame to my allergens", "I'm also allergic to sesame")
    check(.removeAllergens("milk"), "remove milk", "remove milk from my allergens", "I'm not allergic to milk")
    check(.listAllergens, "what are my allergens", "my allergens", "what am I allergic to", "list my allergies")
    check(.clearAllergens, "clear my allergens")
  }

  func testFoodCheck() {
    check(.foodCheck, "Is this OK for me?", "food check", "is it okay for me", "can I eat this", "does it contain my allergens", "check this for me")
  }

  func testRemindersAndSteps() {
    check(.remind, "remind me before it goes off", "remind me before it expires", "set a reminder")
    check(.expiry, "when does it go off", "what's the use by date")
    check(.cooking, "how do I cook it")
    check(.nextStep, "next step", "go to the next step")
    check(.previousStep, "previous step", "go back a step")
    check(.repeatStep, "repeat step", "repeat the step", "say that step again")
    XCTAssertEqual(LabelsGrammar.stepCommand("next"), .nextStep)
    XCTAssertEqual(LabelsGrammar.stepCommand("go back"), .previousStep)
    XCTAssertEqual(LabelsGrammar.stepCommand("repeat"), .repeatStep)
    XCTAssertNil(LabelsGrammar.stepCommand("read the label"))
  }

  func testOldCommandsStillWork() {
    check(.allergens("nuts"), "does it contain nuts")
    check(.allergens(nil), "allergens")
    check(.scan, "next", "scan this")
    check(.dose, "how many should I take")
  }
}

// MARK: - The tool end to end

private struct NoProducts: ProductSource {
  func lookup(_ code: String) async -> ProductLookupResult { .failed("tests don't go online") }
}

@MainActor
private final class FakeReminders: ReminderScheduling {
  var result: ReminderScheduleResult = .scheduled
  var requests: [ReminderRequest] = []
  func schedule(_ request: ReminderRequest) async -> ReminderScheduleResult {
    requests.append(request)
    return result
  }
  func cancel(id: String) {}
  func upcoming(before date: Date) -> [ReminderRequest] { [] }
}

@MainActor
final class FoodCheckToolTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suite = "FoodCheckToolTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func tool(reminders: (any ReminderScheduling)? = nil) -> LabelsTool {
    let store = MyAllergens(defaults: defaults)
    let scheduler: any ReminderScheduling = reminders ?? NoReminders()
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
    let t = LabelsTool(
      productSource: NoProducts(), today: { CivilDate(2026, 11, 20) }, myAllergens: store, reminders: { scheduler }, now: { now })
    t.recentText = RecentText(defaults: nil)
    return t
  }

  func testMyAllergensAreKeptOnThePhone() {
    let store = MyAllergens(defaults: defaults)
    XCTAssertTrue(store.isEmpty)
    store.set(allergens("peanuts", "milk"))
    XCTAssertEqual(store.add(allergens("sesame", "milk")), allergens("sesame"))
    XCTAssertEqual(store.remove(allergens("milk", "eggs")), allergens("milk"))
    let again = MyAllergens(defaults: defaults)
    XCTAssertEqual(again.allergens, allergens("peanuts", "sesame"))
  }

  func testSettingAddingListingAndRemovingAllergensByVoice() {
    let t = tool()
    XCTAssertTrue(t.handle(transcript: "My allergens are peanuts and milk"))
    XCTAssertTrue(t.lastLine.hasPrefix("Your allergens are milk and peanuts."), t.lastLine)
    XCTAssertTrue(t.handle(transcript: "add sesame"))
    XCTAssertEqual(t.lastLine, "Added sesame. Your allergens are milk, peanuts and sesame.")
    XCTAssertTrue(t.handle(transcript: "what are my allergens"))
    XCTAssertEqual(t.lastLine, "Your allergens are milk, peanuts and sesame.")
    XCTAssertTrue(t.handle(transcript: "remove milk"))
    XCTAssertEqual(t.lastLine, "Removed milk. Your allergens are peanuts and sesame.")
    XCTAssertTrue(t.handle(transcript: "add kiwi"))
    XCTAssertTrue(t.lastLine.hasPrefix("I didn't recognise kiwi."), t.lastLine)
    XCTAssertEqual(t.myAllergens.allergens, allergens("peanuts", "sesame"))
  }

  func testFoodCheckNeedsAList() {
    let t = tool()
    t.addViewForTesting(lines("Ingredients: Sugar, whey powder."))
    t.perform(.foodCheck)
    XCTAssertEqual(t.lastLine, LabelsSpeech.noAllergensSet)
  }

  func testFoodCheckOnTheTool() {
    let t = tool()
    _ = t.handle(transcript: "my allergens are milk")
    t.addViewForTesting(lines("OAT CRUNCH", "Ingredients: Oats, sugar, whey powder, salt."))
    XCTAssertTrue(t.handle(transcript: "is this OK for me"))
    XCTAssertEqual(t.lastLine, "Contains milk: it says whey powder in the ingredients.")
  }

  func testMedicineLabelsAreUnchanged() {
    let t = tool()
    _ = t.handle(transcript: "my allergens are milk")
    t.addViewForTesting([
      LabelLine(text: "PARACETAMOL", height: 60, confidence: 0.95), LabelLine(text: "500 mg Tablets", height: 30, confidence: 0.95),
      LabelLine(text: "Ingredients: lactose, maize starch.", height: 16, confidence: 0.95),
    ])
    XCTAssertTrue(t.isMedicine)
    for command in [LabelsCommand.foodCheck, .cooking, .remind] {
      t.perform(command)
      XCTAssertTrue(t.lastLine.hasPrefix("This looks like medicine: PARACETAMOL."), "\(command): \(t.lastLine)")
      XCTAssertFalse(t.lastLine.contains("lactose"))
    }
  }

  func testCookingStepsOnTheTool() {
    let t = tool()
    t.addViewForTesting(
      lines(
        "COOKING INSTRUCTIONS", "Oven cook: Preheat oven to 200°C / Gas Mark 6.", "Place on a baking tray.", "Cook for 20-25 mins.",
        "Storage: keep frozen."))
    XCTAssertTrue(t.handle(transcript: "how do I cook it"))
    XCTAssertEqual(t.stepIndex, 0)
    XCTAssertEqual(t.cookingSteps.count, 3)
    XCTAssertEqual(t.lastLine, "Step 1 of 3. Oven: Preheat oven to 200 degrees Celsius, or Gas Mark 6.")
    XCTAssertTrue(t.handle(transcript: "next step"))
    XCTAssertEqual(t.lastLine, "Step 2 of 3. Place on a baking tray.")
    XCTAssertTrue(t.handle(transcript: "repeat step"))
    XCTAssertEqual(t.lastLine, "Step 2 of 3. Oven: Place on a baking tray.")
    XCTAssertTrue(t.handle(transcript: "next"))
    XCTAssertEqual(t.lastLine, "Step 3 of 3. Cook for 20 to 25 minutes. That's the last step.")
    XCTAssertTrue(t.handle(transcript: "next"))
    XCTAssertEqual(t.lastLine, LabelsSpeech.lastStepAlready)
    XCTAssertTrue(t.handle(transcript: "previous step"))
    XCTAssertEqual(t.stepIndex, 1)
  }

  func testNoCookingInstructionsIsSpoken() {
    let t = tool()
    t.addViewForTesting(lines("Ingredients: Rice, salt."))
    t.perform(.cooking)
    XCTAssertEqual(t.lastLine, LabelsSpeech.noCooking)
    XCTAssertNil(t.stepIndex)
  }

  func testNoReminderOfferWithoutAReminderFeature() {
    let t = tool()
    t.addViewForTesting(lines("USE BY 25/11/2026"))
    XCTAssertFalse(t.canRemind)
    t.perform(.expiry)
    XCTAssertEqual(t.lastLine, "Use by 25 November: that's in 5 days. Use by is about safety: don't eat it after that date.")
  }

  func testRemindMeBeforeItGoesOff() async throws {
    let reminders = FakeReminders()
    let t = tool(reminders: reminders)
    t.addViewForTesting(lines("CHICKEN BREASTS", "USE BY 25/11/2026"))
    XCTAssertTrue(t.canRemind)
    t.perform(.expiry)
    XCTAssertTrue(t.lastLine.hasSuffix(FoodDates.offer), t.lastLine)
    XCTAssertTrue(t.handle(transcript: "remind me before it goes off"))
    for _ in 0..<50 where reminders.requests.isEmpty || !t.lastLine.hasPrefix("Done") {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(reminders.requests.count, 1)
    XCTAssertEqual(reminders.requests.first?.source, "labels")
    XCTAssertEqual(t.lastLine, "Done. I'll remind you on the morning before the use by date, 25 November.")
  }

  func testAReminderFailureIsSpoken() async throws {
    let reminders = FakeReminders()
    reminders.result = .notAllowed
    let t = tool(reminders: reminders)
    t.addViewForTesting(lines("USE BY 25/11/2026"))
    t.perform(.expiry)
    t.perform(.remind)
    for _ in 0..<50 where !t.lastLine.contains("notifications are off") {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(t.lastLine.contains("notifications are off"), t.lastLine)
  }

  func testRemindWithoutADate() {
    let t = tool(reminders: FakeReminders())
    t.addViewForTesting(lines("Ingredients: Rice, salt."))
    t.perform(.remind)
    XCTAssertEqual(t.lastLine, LabelsSpeech.noDateForReminder)
  }
}
