/*
 * PhoneReadingTests - reading with an iPhone (notes/phone-reading-ios.md): the step splitter on
 * recipe and manual texts, step navigation and voice, haptic cues from framing verdicts and their
 * pacing, the dark warning's hysteresis and its path through TextReader, and the big-text mirror's
 * model.
 */

import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Texts

/// Recipe and manual texts laid out as OCR gives them: one printed line per line.
private enum Texts {
  static let pancakes = """
    Easy pancakes
    Ingredients
    • 100g plain flour
    • 2 large eggs
    • 300ml milk
    • 1 tbsp sunflower oil
    Method
    1. Put the flour, eggs, milk, 1 tbsp oil and a pinch of salt into a bowl, then whisk to a smooth batter.
    2. Set aside for 30 mins to rest if you have time, or start cooking straight away.
    3. Set a medium frying pan over a medium heat and carefully wipe it with some oiled kitchen
    paper.
    4. When hot, cook your pancakes for 1 min on each side until golden.
    Notes
    Keep them warm in a low oven.
    """

  static let tomatoSoup = """
    Tomato soup
    Serves 4
    Ingredients:
    - 1kg ripe tomatoes
    - 1 onion
    - 2 tbsp olive oil
    1) Chop the onion and fry gently in the oil for 10 minutes.
    2) Add the tomatoes and simmer for 20 minutes.
    3) Blend until smooth and season to taste.
    """

  static let kettleManual = """
    Quick start guide
    Step 1
    Unpack the kettle and remove all stickers.
    Step 2: Fill with water to the MAX line.
    Step 3
    Place the kettle on its base and press the switch.
    Warranty
    Keep your receipt.
    """

  static let filterManual = """
    Fitting the filter
    a) Turn the machine off at the wall.
    b) Open the front cover.
    c) Slide the new filter in until it clicks.
    """

  static let breadInline = """
    Simple bread
    Method
    1. Mix the flour and water. 2. Knead for ten minutes. 3. Leave to rise.
    """

  static let brownieParagraphs = """
    Brownies
    Directions
    Heat the oven to 200C. Grease a tin.

    Mix everything in a bowl and pour into the tin.

    Bake for 25 minutes.
    """

  static let oneParagraph = """
    Directions
    Heat the oven to 200C. Grease a tin. Bake for 25 minutes.
    """

  static let numbersAlone = """
    Method
    1
    Preheat the oven.
    2
    Bake for 20 minutes.
    """

  static let sprayBullets = """
    Glass cleaner
    How to use
    • Shake well.
    • Spray onto a dry cloth, not onto the glass.
    • Wipe and buff dry.
    Warnings
    Keep out of reach of children.
    """

  static let prose = """
    The quick brown fox jumps over the lazy dog.
    Printed text is read word for word, in order.
    """

  static let shoppingList = """
    Ingredients
    1.5 cups sugar
    2 eggs
    10:30 delivery
    """
}

// MARK: - Step splitter

final class StepSplitterTests: XCTestCase {
  func testARecipeGivesItsMethodStepsNotItsIngredientsOrNotes() {
    let steps = StepSplitter.steps(in: Texts.pancakes)
    XCTAssertEqual(steps.count, 4, "\(steps)")
    XCTAssertEqual(
      steps.first, "1. Put the flour, eggs, milk, 1 tbsp oil and a pinch of salt into a bowl, then whisk to a smooth batter.")
    XCTAssertEqual(
      steps[2], "3. Set a medium frying pan over a medium heat and carefully wipe it with some oiled kitchen paper.",
      "a wrapped line carries on its step")
    XCTAssertEqual(steps.last, "4. When hot, cook your pancakes for 1 min on each side until golden.")
    XCTAssertFalse(steps.joined().contains("low oven"), "notes aren't steps")
    XCTAssertFalse(steps.joined().contains("plain flour"), "ingredients aren't steps")
  }

  func testNumberedStepsAfterABulletedIngredientListWithoutAMethodHeading() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.tomatoSoup),
      [
        "1) Chop the onion and fry gently in the oil for 10 minutes.",
        "2) Add the tomatoes and simmer for 20 minutes.",
        "3) Blend until smooth and season to taste.",
      ])
  }

  func testAManualWithStepWordsAndStepsOnTheirOwnLines() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.kettleManual),
      [
        "Step 1 Unpack the kettle and remove all stickers.",
        "Step 2: Fill with water to the MAX line.",
        "Step 3 Place the kettle on its base and press the switch.",
      ])
  }

  func testLetteredSteps() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.filterManual),
      ["a) Turn the machine off at the wall.", "b) Open the front cover.", "c) Slide the new filter in until it clicks."])
  }

  func testNumberedStepsRunTogetherOnOneLineAreSplit() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.breadInline),
      ["1. Mix the flour and water.", "2. Knead for ten minutes.", "3. Leave to rise."])
  }

  func testParagraphsUnderAMethodHeadingAreSteps() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.brownieParagraphs),
      ["Heat the oven to 200C. Grease a tin.", "Mix everything in a bowl and pour into the tin.", "Bake for 25 minutes."])
  }

  func testOneParagraphUnderAMethodHeadingIsSplitIntoSentences() {
    XCTAssertEqual(
      StepSplitter.steps(in: Texts.oneParagraph), ["Heat the oven to 200C.", "Grease a tin.", "Bake for 25 minutes."])
  }

  func testANumberAloneOnItsLineTakesTheNextLine() {
    XCTAssertEqual(StepSplitter.steps(in: Texts.numbersAlone), ["1 Preheat the oven.", "2 Bake for 20 minutes."])
  }

  func testBulletedInstructionsStopAtTheNextHeading() {
    let steps = StepSplitter.steps(in: Texts.sprayBullets)
    XCTAssertEqual(steps, ["• Shake well.", "• Spray onto a dry cloth, not onto the glass.", "• Wipe and buff dry."])
    XCTAssertEqual(StepSplitter.spokenText(steps[0]), "Shake well.", "the bullet isn't said")
    XCTAssertFalse(StepSplitter.isNumberedInPrint(steps[0]))
    XCTAssertTrue(StepSplitter.isNumberedInPrint("Step 2: Fill with water."))
  }

  func testProseAndAShoppingListHaveNoSteps() {
    XCTAssertEqual(StepSplitter.steps(in: Texts.prose), [])
    XCTAssertEqual(StepSplitter.steps(in: Texts.shoppingList), [])
    XCTAssertNil(StepSplitter.marker("1.5 cups sugar"))
    XCTAssertNil(StepSplitter.marker("10:30 delivery"))
    XCTAssertNil(StepSplitter.marker("A. Smith"))
    XCTAssertEqual(StepSplitter.marker("STEP 4 - Close the lid"), .number(4))
    XCTAssertEqual(StepSplitter.marker("(b) Lift"), .letter)
  }

  func testAWordHyphenatedAcrossLinesIsJoined() {
    XCTAssertEqual(StepSplitter.steps(in: "1. Stir the mix-\nture well.\n2. Serve."), ["1. Stir the mixture well.", "2. Serve."])
  }

  func testStepWordsKeepTheirConfidenceSoADoseIsStillWithheld() {
    let page = [
      ReadWord(text: "1.", confidence: 0.95), ReadWord(text: "Take", confidence: 0.95), ReadWord(text: "2", confidence: 0.6),
      ReadWord(text: "tablets.", confidence: 0.95), ReadWord(text: "2.", confidence: 0.95), ReadWord(text: "Rest.", confidence: 0.95),
    ]
    var cursor = 0
    let first = StepPageText.words(of: "1. Take 2 tablets.", in: page, cursor: &cursor)
    XCTAssertEqual(first.map(\.confidence), [0.95, 0.95, 0.6, 0.95])
    let rendered = ReadSpeech.render(first, verbosity: .normal, earconsEnabled: true)
    XCTAssertEqual(rendered.withheld, .dose)
    let second = StepPageText.words(of: "2. Rest.", in: page, cursor: &cursor)
    XCTAssertEqual(second.map(\.text), ["2.", "Rest."])
    XCTAssertEqual(cursor, 6)
  }

  func testThePageTextKeepsLinesAndBlocks() {
    let blocks = [[line("Method", y: 0)], [line("1. Mix.", y: 100), line("2. Bake.", y: 140)]]
    let page = StepPageText.make(blocks: blocks)
    XCTAssertEqual(page.text, "Method\n\n1. Mix.\n2. Bake.")
    XCTAssertEqual(page.words.count, 5)
  }

  /// Splitting stays cheap: the longest real page is a few hundred lines.
  func testSplittingALongPageIsFast() {
    let long = Array(repeating: Texts.pancakes, count: 20).joined(separator: "\n")
    let started = Date()
    _ = StepSplitter.steps(in: long)
    let ms = Date().timeIntervalSince(started) * 1000
    print("[measure] StepSplitter 20 recipes (\(long.count) chars): \(Int(ms)) ms")
    XCTAssertLessThan(ms, 500)
  }
}

private func line(_ text: String, y: CGFloat, x: CGFloat = 40, confidence: Float = 0.95) -> ReadLine {
  let words = text.split(separator: " ").map { ReadWord(text: String($0), confidence: confidence) }
  return ReadLine(words: words, box: CGRect(x: x, y: y, width: CGFloat(text.count) * 14, height: 30))
}

// MARK: - Step navigation

final class StepNavigatorTests: XCTestCase {
  func testNextPreviousRepeatAndTheEnds() {
    var navigator = StepNavigator(count: 3)
    XCTAssertNil(navigator.index)
    XCTAssertEqual(navigator.remaining, 3)
    XCTAssertEqual(navigator.repeatStep(), .step(0), "repeat before starting says step 1")
    XCTAssertEqual(navigator.next(), .step(1))
    XCTAssertEqual(navigator.next(), .step(2))
    XCTAssertEqual(navigator.next(), .pastLast)
    XCTAssertEqual(navigator.index, 2, "stays on the last")
    XCTAssertEqual(navigator.remaining, 0)
    XCTAssertEqual(navigator.previous(), .step(1))
    XCTAssertEqual(navigator.previous(), .step(0))
    XCTAssertEqual(navigator.previous(), .atFirst)
    XCTAssertEqual(navigator.go(to: 9), .step(2))
    XCTAssertEqual(navigator.go(to: 0), .step(0))
  }

  func testNextFromTheStartIsStepOne() {
    var navigator = StepNavigator(count: 2)
    XCTAssertEqual(navigator.next(), .step(0))
    var empty = StepNavigator(count: 0)
    XCTAssertEqual(empty.next(), .noSteps)
    XCTAssertEqual(empty.previous(), .noSteps)
  }
}

@MainActor
final class ReadStepsTests: XCTestCase {
  private var reader: TextReader!

  override func setUp() async throws {
    reader = TextReader()
    reader.recentText = RecentText(defaults: nil)
  }

  override func tearDown() async throws {
    reader.stop()
    Announcer.shared.stop()
    reader = nil
  }

  private func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
    // Counted in polls, not wall time: the first speech of a test run can block the main actor
    // for a minute in the Simulator (TextToSpeech voice lookup), which mustn't use up the wait.
    var polls = Int(seconds * 50)
    while !condition(), polls > 0 {
      polls -= 1
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// A recipe card as OCR lines: title, method heading, three numbered steps, one wrapped.
  private func recipePage() -> ReadPage {
    let lines = [
      line("Flapjacks", y: 20),
      line("Method", y: 100),
      line("1. Melt the butter and syrup in a pan.", y: 160),
      line("2. Stir in the oats and press into a tin.", y: 200),
      line("3. Bake for 20 minutes, then leave to", y: 240),
      line("cool before cutting.", y: 280),
    ]
    return ReadPage(lines: lines, imageSize: CGSize(width: 1000, height: 1400))
  }

  func testAReadPageGivesStepsThatWorkWithoutTheCamera() async throws {
    reader.read(pages: [ReadTextPage(page: recipePage())], source: ReadTextSource(title: "A photo"))
    try await waitFor { reader.steps.hasPage }
    let steps = reader.steps
    XCTAssertEqual(steps.steps.map(\.printed), [
      "1. Melt the butter and syrup in a pan.",
      "2. Stir in the oats and press into a tin.",
      "3. Bake for 20 minutes, then leave to cool before cutting.",
    ])
    XCTAssertEqual(steps.statusText, "3 steps found")
    reader.stop()

    // "next step" from the start is step 1, and stops the sentences.
    XCTAssertTrue(ReadTextVoice.handle("read me the next step", reader: reader))
    XCTAssertEqual(steps.navigator.index, 0)
    XCTAssertTrue(steps.isActive)
    XCTAssertEqual(steps.currentStep?.printed, "1. Melt the butter and syrup in a pan.")
    XCTAssertEqual(steps.statusText, "Step 1 of 3")
    XCTAssertTrue(ReadTextVoice.handle("next step", reader: reader))
    XCTAssertEqual(steps.navigator.index, 1)
    // In step mode, plain "next" and "back" move through the steps.
    XCTAssertTrue(ReadTextVoice.handle("next", reader: reader))
    XCTAssertEqual(steps.navigator.index, 2)
    XCTAssertTrue(ReadTextVoice.handle("next step", reader: reader), "past the last: says so, stays")
    XCTAssertEqual(steps.navigator.index, 2)
    XCTAssertTrue(ReadTextVoice.handle("back", reader: reader))
    XCTAssertEqual(steps.navigator.index, 1)
    XCTAssertTrue(ReadTextVoice.handle("repeat step", reader: reader))
    XCTAssertEqual(steps.navigator.index, 1)
    XCTAssertTrue(ReadTextVoice.handle("what step am I on", reader: reader))
    XCTAssertTrue(ReadTextVoice.handle("how many steps", reader: reader))
    XCTAssertTrue(ReadTextVoice.handle("go to step three", reader: reader))
    XCTAssertEqual(steps.navigator.index, 2)
  }

  func testTheSameStepsReadAgainKeepThePlace() async throws {
    reader.read(pages: [ReadTextPage(page: recipePage())], source: ReadTextSource(title: "A photo"))
    try await waitFor { reader.steps.hasPage }
    reader.steps.perform(.number(2))
    reader.read(pages: [ReadTextPage(page: recipePage())], source: ReadTextSource(title: "A photo"))
    XCTAssertFalse(reader.steps.isActive, "a new read means sentences again")
    try await waitFor { reader.phase == .reading }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(reader.steps.navigator.index, 1, "the place is kept")
    XCTAssertEqual(reader.steps.steps.count, 3)
  }

  func testWithNoPageOrNoStepsItSaysSoAndDoesntMove() async throws {
    XCTAssertTrue(ReadTextVoice.handle("next step", reader: reader), "said: nothing read yet")
    XCTAssertFalse(reader.steps.isActive)
    let prose = ReadPage(lines: [line("The bus leaves at nine.", y: 20)], imageSize: CGSize(width: 1000, height: 600))
    reader.read(pages: [ReadTextPage(page: prose)], source: ReadTextSource(title: "A photo"))
    try await waitFor { reader.steps.hasPage }
    XCTAssertTrue(reader.steps.steps.isEmpty)
    XCTAssertTrue(ReadTextVoice.handle("next step", reader: reader), "said: no steps found")
    XCTAssertFalse(reader.steps.isActive)
    XCTAssertFalse(ReadTextVoice.handle("next", reader: reader), "plain next stays the app's when not stepping")
  }
}

// MARK: - Read text's phrases

final class ReadTextPhraseTests: XCTestCase {
  func testStepAndBigTextPhrases() {
    XCTAssertEqual(ReadTextPhrases.command(for: "Next step."), .step(.next))
    XCTAssertEqual(ReadTextPhrases.command(for: "read me the next step please"), .step(.next))
    XCTAssertEqual(ReadTextPhrases.command(for: "previous step"), .step(.previous))
    XCTAssertEqual(ReadTextPhrases.command(for: "repeat step"), .step(.repeatStep))
    XCTAssertEqual(ReadTextPhrases.command(for: "What step am I on?"), .step(.whichStep))
    XCTAssertEqual(ReadTextPhrases.command(for: "how many steps"), .step(.howMany))
    XCTAssertEqual(ReadTextPhrases.command(for: "how many steps are left"), .step(.howManyLeft))
    XCTAssertEqual(ReadTextPhrases.command(for: "go to step 4"), .step(.number(4)))
    XCTAssertEqual(ReadTextPhrases.command(for: "step two"), .step(.number(2)))
    XCTAssertEqual(ReadTextPhrases.command(for: "big text"), .bigTextOn)
    XCTAssertEqual(ReadTextPhrases.command(for: "Big text off"), .bigTextOff)
    XCTAssertEqual(ReadTextPhrases.command(for: "yes please"), .yes)
    XCTAssertNil(ReadTextPhrases.command(for: "read"))
    XCTAssertNil(ReadTextPhrases.command(for: "next"))
    XCTAssertEqual(ReadTextPhrases.stepModeCommand(for: "next"), .next)
    XCTAssertEqual(ReadTextPhrases.stepModeCommand(for: "go back"), .previous)
    XCTAssertEqual(ReadTextPhrases.stepModeCommand(for: "again"), .repeatStep)
  }

  /// Read text's phrases never take one of the app's always-on commands (stop, help, torch...).
  @MainActor
  func testNoPhraseIsAnAlwaysOnCommand() {
    for (phrase, command) in ReadTextPhrases.phrases where command != .yes && command != .no {
      if case .command(let global) = VoiceCommandParser.parse(phrase, context: VoiceContext(screen: .camera)) {
        XCTAssertFalse(ToolHub.alwaysGlobal.contains(global), "\(phrase) is the app's \(global)")
      }
    }
  }
}

// MARK: - Haptics

final class HapticCueTests: XCTestCase {
  func testCuesMatchTheSpokenGuidance() {
    XCTAssertEqual(HapticCueMapper.cue(for: .good, previous: nil), .locked)
    XCTAssertEqual(HapticCueMapper.cue(for: .cutOff([.left]), previous: nil), .pageFound, "text first appears")
    XCTAssertEqual(HapticCueMapper.cue(for: .cutOff([.left]), previous: .good), .edgeCut)
    XCTAssertEqual(HapticCueMapper.cue(for: .cutOff([.left, .right]), previous: .good), .tooClose)
    XCTAssertEqual(HapticCueMapper.cue(for: .cutOff([.top, .bottom]), previous: nil), .tooClose)
    XCTAssertEqual(HapticCueMapper.cue(for: .tooSmall, previous: .good), .tooFar)
    XCTAssertEqual(HapticCueMapper.cue(for: .tooSmall, previous: .noText), .pageFound)
    XCTAssertEqual(HapticCueMapper.cue(for: .noText, previous: .good), .lost)
    XCTAssertNil(HapticCueMapper.cue(for: .noText, previous: .noText))
    XCTAssertNil(HapticCueMapper.cue(for: .noText, previous: nil))
    XCTAssertEqual(HapticCueMapper.cue(for: .tooDark, previous: nil), .dark)
    XCTAssertNil(HapticCueMapper.cue(for: .tooBlurry, previous: .good), "blur is the voice's job")
  }

  func testThePacerNeverBuzzes() {
    var pacer = HapticPacer()
    XCTAssertEqual(pacer.allow(.locked, at: 0), .locked)
    // Checked every 0.7 s while it stays framed: one tap every 2 s, not every check.
    var taps = 0
    for tick in 1...14 where pacer.allow(.locked, at: Double(tick) * 0.7) != nil { taps += 1 }
    XCTAssertEqual(taps, 4, "one tap per 2 s or more over 9.8 s, not 14")
    // A different cue straight after is held back for the minimum gap.
    XCTAssertNil(pacer.allow(.edgeCut, at: pacer.lastAt + 0.1))
    XCTAssertEqual(pacer.allow(.edgeCut, at: pacer.lastAt + 0.5), .edgeCut)
    XCTAssertNil(pacer.allow(.edgeCut, at: pacer.lastAt + 1.0), "the same cue waits 3 s")
    XCTAssertNil(pacer.allow(nil, at: 100))
    XCTAssertEqual(pacer.allow(.dark, at: 100), .dark)
    XCTAssertNil(pacer.allow(.dark, at: 105), "dark repeats at most every 10 s")
  }

  @MainActor
  func testTheSettingTurnsCuesOff() {
    let haptics = ReadHaptics.shared
    let saved = haptics.isEnabled
    defer { haptics.isEnabled = saved }
    let before = haptics.played.count
    haptics.isEnabled = { false }
    haptics.play(.locked)
    XCTAssertEqual(haptics.played.count, before)
    haptics.isEnabled = { true }
    haptics.play(.locked)
    XCTAssertEqual(haptics.played.last, .locked)
  }

  @MainActor
  func testTheHapticsSettingIsSavedAndOnByDefault() {
    let suite = "PhoneReadingSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = PhoneReadingSettings(defaults: defaults)
    XCTAssertTrue(settings.hapticsEnabled)
    XCTAssertEqual(settings.mirrorContrast, .yellowOnBlack)
    settings.hapticsEnabled = false
    settings.mirrorScaleStep = 99
    XCTAssertFalse(PhoneReadingSettings(defaults: defaults).hapticsEnabled)
    XCTAssertEqual(PhoneReadingSettings(defaults: defaults).mirrorScaleStep, MirrorTextScale.steps.count - 1)
  }
}

// MARK: - Dark warning

final class DarkWatchTests: XCTestCase {
  func testExposureValue() throws {
    // f/1.8, 1/30 s, ISO 800: a dim room.
    let ev = try XCTUnwrap(SceneLight.ev100(aperture: 1.8, exposureSeconds: 1.0 / 30, iso: 800))
    XCTAssertEqual(ev, 3.6, accuracy: 0.05)
    // f/1.8, 1/120 s, ISO 100: a bright kitchen.
    XCTAssertEqual(try XCTUnwrap(SceneLight.ev100(aperture: 1.8, exposureSeconds: 1.0 / 120, iso: 100)), 8.6, accuracy: 0.05)
    XCTAssertNil(SceneLight.ev100(aperture: 0, exposureSeconds: 0.01, iso: 100))
  }

  func testHysteresisOnExposure() {
    var watch = DarkWatch()
    XCTAssertEqual(watch.check(ev: 5, brightness: nil), .read)
    XCTAssertEqual(watch.check(ev: 3.5, brightness: nil), .read, "between the thresholds: stays light")
    XCTAssertEqual(watch.check(ev: 2.5, brightness: nil), .warn, "below enter: dark, warned")
    XCTAssertTrue(watch.isDark)
    XCTAssertEqual(watch.check(ev: 3.5, brightness: nil), .read, "warned once; reading again tries anyway")
    XCTAssertTrue(watch.isDark, "between the thresholds: stays dark")
    XCTAssertEqual(watch.check(ev: 4.5, brightness: nil), .read, "above exit: light again")
    XCTAssertFalse(watch.isDark)
    XCTAssertEqual(watch.check(ev: 2.0, brightness: nil), .warn, "a new dark spell warns again")
  }

  func testWithoutExposureTheFrameBrightnessCounts() {
    var watch = DarkWatch()
    XCTAssertEqual(watch.check(ev: nil, brightness: 0.12), .read)
    XCTAssertEqual(watch.check(ev: nil, brightness: 0.05), .warn)
    XCTAssertEqual(watch.check(ev: nil, brightness: 0.14), .read)
    XCTAssertTrue(watch.isDark)
    XCTAssertEqual(watch.check(ev: nil, brightness: 0.2), .read)
    XCTAssertFalse(watch.isDark)
    // Exposure wins: a dark frame (light text on black) in a bright room isn't dark.
    XCTAssertEqual(watch.check(ev: 7, brightness: 0.03), .read)
    XCTAssertFalse(watch.isDark)
    // Nothing measured: no change.
    XCTAssertEqual(watch.check(ev: nil, brightness: nil), .read)
  }
}

/// The phone camera, with a frame of a given brightness and a torch.
@MainActor
private final class DimPhone: ReadFrameSource, ReadLightSource {
  var frameImage: UIImage
  var sceneEV: Double?
  var torchOn = false
  var cameraKind: CameraKind { .phone }

  init(gray: CGFloat, ev: Double? = nil) {
    frameImage = Self.page(gray: gray)
    sceneEV = ev
  }

  var latestReadFrame: ReadFrame? { ReadFrame(image: frameImage, arrivedAt: BenchClock.uptimeNanoseconds()) }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
  var canOfferTorch: Bool { !torchOn }
  func turnTorchOn() { torchOn = true }

  static func page(gray: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 640), format: format).image { context in
      UIColor(white: gray, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 480, height: 640))
    }
  }
}

/// The glasses, seeing a dark frame. They have no exposure to report.
@MainActor
private final class DimGlasses: ReadFrameSource {
  let image = DimPhone.page(gray: 0.03)
  var latestReadFrame: ReadFrame? { ReadFrame(image: image, arrivedAt: BenchClock.uptimeNanoseconds()) }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
}

@MainActor
final class DarkReadTests: XCTestCase {
  private var reader: TextReader!

  override func setUp() async throws {
    reader = TextReader()
    reader.recentText = RecentText(defaults: nil)
  }

  override func tearDown() async throws {
    reader.stop()
    Announcer.shared.stop()
    reader = nil
  }

  private func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
    // Counted in polls, not wall time: the first speech of a test run can block the main actor
    // for a minute in the Simulator (TextToSpeech voice lookup), which mustn't use up the wait.
    var polls = Int(seconds * 50)
    while !condition(), polls > 0 {
      polls -= 1
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testADarkPhoneFrameIsWarnedAboutBeforeOCRAndTheTorchIsOfferedOnce() async throws {
    let phone = DimPhone(gray: 0.03)
    reader.source = phone
    reader.read()
    try await waitFor { reader.phase == .guided }
    XCTAssertEqual(reader.notice, SpokenMessage.readDarkWarning)
    XCTAssertTrue(reader.torchOfferPending)

    // "yes": the torch goes on, and the page is read again.
    XCTAssertTrue(ReadTextVoice.handle("yes", reader: reader))
    XCTAssertTrue(phone.torchOn)
    XCTAssertFalse(reader.torchOfferPending)
    phone.frameImage = DimPhone.page(gray: 0.9)
    try await waitFor { reader.phase != .guided || reader.notice != SpokenMessage.readDarkWarning }
    try await waitFor { reader.phase == .guided }
    XCTAssertNotEqual(reader.notice, SpokenMessage.readDarkWarning, "light now: OCR ran (a blank page has no text)")
  }

  func testReadingAgainInTheDarkTriesOCRAndTheOfferIsntRepeated() async throws {
    let phone = DimPhone(gray: 0.03)
    reader.source = phone
    reader.read()
    try await waitFor { reader.phase == .guided }
    XCTAssertTrue(ReadTextVoice.handle("no", reader: reader))
    XCTAssertFalse(reader.torchOfferPending)
    reader.read()
    try await waitFor { reader.phase == .guided }
    XCTAssertEqual(
      reader.notice, SpokenMessage.readGuidance(.tooDark, verbosity: A11yPreferences.shared.verbosity, camera: .phone),
      "the second read ran OCR, and the framing check named the dark")
    XCTAssertFalse(reader.torchOfferPending)
  }

  func testExposureSaysItsLightEvenWhenTheFrameIsDark() async throws {
    // White text on black in a bright room: EV 8, so no warning.
    reader.source = DimPhone(gray: 0.03, ev: 8)
    reader.read()
    try await waitFor { reader.phase == .guided }
    XCTAssertNotEqual(reader.notice, SpokenMessage.readDarkWarning)
  }

  func testTheGlassesAreNotChecked() async throws {
    let glasses = DimGlasses()
    reader.source = glasses
    reader.read()
    try await waitFor { reader.phase == .guided }
    XCTAssertNotEqual(reader.notice, SpokenMessage.readDarkWarning)
    XCTAssertFalse(reader.torchOfferPending)
  }
}

// MARK: - Simulator measurements (notes/phone-reading-ios.md)

/// Timings on the Simulator's CPU for the work added per read and per framing check. Printed as
/// `[measure]` lines; the assertions are only loose sanity bounds.
final class PhoneReadingTimingTests: XCTestCase {
  private func fixture() throws -> UIImage {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "read_page", withExtension: "png"), "Fixture should be in the app bundle")
    return try XCTUnwrap(UIImage(contentsOfFile: url.path))
  }

  /// The page drawn at a phone frame size (portrait), as the two presets would give it.
  private func scaled(_ image: UIImage, to size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
  }

  private func milliseconds(_ runs: Int = 3, _ work: () throws -> Void) rethrows -> Int {
    var best = Double.infinity
    for _ in 0..<runs {
      let started = Date()
      try work()
      best = min(best, Date().timeIntervalSince(started) * 1000)
    }
    return Int(best)
  }

  func testDarkCheckFastFramingAndAccurateOCRTimes() throws {
    let page = try fixture()
    for (name, size) in [("photo 1080x1440", CGSize(width: 1080, height: 1440)), ("high 1080x1920", CGSize(width: 1080, height: 1920))] {
      let frame = scaled(page, to: size)
      let cgImage = try XCTUnwrap(frame.cgImage)
      let dark = milliseconds { _ = TextRecognizer.measureQuality(cgImage) }
      var fastLines = 0
      var accurateLines = 0
      let fast = try milliseconds { fastLines = try TextRecognizer.recognize(frame, fast: true).page.lines.count }
      let accurate = try milliseconds { accurateLines = try TextRecognizer.recognize(frame).page.lines.count }
      print("[measure] \(name): dark check \(dark) ms, fast framing OCR \(fast) ms (\(fastLines) lines), accurate OCR \(accurate) ms (\(accurateLines) lines)")
      XCTAssertGreaterThan(accurateLines, 0)
      XCTAssertLessThan(dark, 200)
    }
  }
}

// MARK: - Big-text mirror

final class BigTextMirrorTests: XCTestCase {
  func testTheSpokenWordIsHighlightedAcrossChunks() {
    let chunks = ["Preheat the oven to 200C,", "then grease a tin."]
    // The second chunk is being spoken; "grease" starts at offset 5.
    XCTAssertEqual(BigTextMirrorModel.wordIndex(chunks: chunks, line: "then grease a tin.", range: NSRange(location: 5, length: 6)), 6)
    XCTAssertEqual(BigTextMirrorModel.wordIndex(chunks: chunks, line: "Preheat the oven to 200C,", range: NSRange(location: 0, length: 7)), 0)
    // Part way into a word (the voice splits "200C").
    XCTAssertEqual(BigTextMirrorModel.wordIndex(chunks: chunks, line: "Preheat the oven to 200C,", range: NSRange(location: 23, length: 1)), 4)
    // Another line (a status line, the end line): no highlight.
    XCTAssertNil(BigTextMirrorModel.wordIndex(chunks: chunks, line: "End of text.", range: NSRange(location: 0, length: 3)))
    let model = BigTextMirrorModel(chunks: chunks, spokenLine: nil, spokenRange: nil)
    XCTAssertNil(model.highlightedWord, "the cloud voice gives no words: sentence level")
    XCTAssertEqual(model.words.count, 9)
    XCTAssertEqual(model.text, "Preheat the oven to 200C, then grease a tin.")
  }

  func testEveryContrastChoiceIsAboveSevenToOne() {
    for contrast in MirrorContrast.allCases {
      let colors = contrast.colors
      XCTAssertGreaterThanOrEqual(MirrorContrast.RGB.contrast(colors.text, colors.background), 7, "\(contrast) text")
      XCTAssertGreaterThanOrEqual(MirrorContrast.RGB.contrast(colors.highlightText, colors.highlight), 7, "\(contrast) word")
    }
    XCTAssertEqual(MirrorContrast.yellowOnBlack.next, .darkOnLight)
  }

  func testScaleAndGestures() {
    XCTAssertEqual(MirrorTextScale.clamp(-3), 0)
    XCTAssertEqual(MirrorTextScale.factor(MirrorTextScale.defaultStep), 1)
    XCTAssertEqual(MirrorTextScale.factor(99), 2.5)
    XCTAssertEqual(MirrorGesture.tap(phase: .reading, hasSentences: true), .pause)
    XCTAssertEqual(MirrorGesture.tap(phase: .stopped, hasSentences: true), .resume)
    XCTAssertEqual(MirrorGesture.tap(phase: .finished, hasSentences: true), .resume)
    XCTAssertEqual(MirrorGesture.tap(phase: .guided, hasSentences: false), .none)
    XCTAssertEqual(MirrorGesture.swipe(dx: -120, dy: 10), .next)
    XCTAssertEqual(MirrorGesture.swipe(dx: 120, dy: -20), .previous)
    XCTAssertEqual(MirrorGesture.swipe(dx: 20, dy: 0), .none, "a short drag")
    XCTAssertEqual(MirrorGesture.swipe(dx: 80, dy: 200), .none, "a scroll")
  }

  @MainActor
  func testBigTextByVoiceFollowsTheReader() async throws {
    let reader = TextReader()
    reader.recentText = RecentText(defaults: nil)
    let mirror = BigTextMirror()
    mirror.reader = reader
    defer {
      reader.stop()
      Announcer.shared.stop()
    }
    XCTAssertTrue(ReadTextVoice.handle("big text", reader: reader, mirror: mirror))
    XCTAssertFalse(mirror.isShown, "nothing read yet")
    XCTAssertFalse(ReadTextVoice.handle("big text off", reader: reader, mirror: mirror), "nothing to close")

    let page = ReadPage(lines: [line("One cat sat. Two dogs ran.", y: 20)], imageSize: CGSize(width: 1000, height: 600))
    reader.read(pages: [ReadTextPage(page: page)], source: ReadTextSource(title: "A photo"))
    var polls = 500
    while reader.sentences.count < 2, polls > 0 {
      polls -= 1
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(ReadTextVoice.handle("big text", reader: reader, mirror: mirror))
    XCTAssertTrue(mirror.isShown)
    XCTAssertEqual(mirror.chunks, reader.currentSentence?.chunks.map(\.text))
    mirror.perform(.next)
    XCTAssertEqual(reader.index, 1)
    XCTAssertEqual(mirror.model.text, "Two dogs ran.")
    mirror.perform(.pause)
    XCTAssertEqual(reader.phase, .stopped)
    XCTAssertEqual(MirrorGesture.tap(phase: reader.phase, hasSentences: true), .resume)
    XCTAssertTrue(ReadTextVoice.handle("big text off", reader: reader, mirror: mirror))
    XCTAssertFalse(mirror.isShown)
  }
}
