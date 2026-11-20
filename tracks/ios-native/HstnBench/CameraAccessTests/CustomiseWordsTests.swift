/*
 * CustomiseWordsTests - "Your words" and "Your buttons" (notes/customisation-ios-words.md): alias
 * rewrite, macros built by voice, read back and run in order, conflict refusals, the tools menu,
 * the address word, the glasses button map, snapshot/restore, differences from defaults, undo
 * recording and the settings lock.
 */

import XCTest

@testable import CameraAccess

@MainActor
private final class WordsHarness {
  var said: [String] = []
  var injected: [String] = []
  var busyPolls = 0
  var now = Date(timeIntervalSince1970: 5000)

  func environment() -> WordsEngine.Environment {
    WordsEngine.Environment(
      say: { [unowned self] in said.append($0) },
      now: { [unowned self] in now },
      injectStep: { [unowned self] in injected.append($0) },
      isBusy: { [unowned self] in
        // Busy for two polls after each step.
        guard busyPolls > 0 else { return false }
        busyPolls -= 1
        return true
      },
      sleep: { _ in await Task.yield() })
  }
}

@MainActor
class CustomiseTestCase: XCTestCase {
  var defaults = UserDefaults()
  private var suiteName = ""
  private var savedHandler: ((String, Data, String) -> Void)?
  private var savedLock: (() -> Bool)!
  var recorded: [(area: String, before: Data, description: String)] = []

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "CustomiseWordsTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    savedHandler = SettingsChanges.handler
    savedLock = SettingsChanges.isLocked
    recorded = []
    SettingsChanges.handler = { [unowned self] area, before, description in
      recorded.append((area, before, description))
    }
    SettingsChanges.isLocked = { false }
    AddressWord.current = AddressWord.defaultWord
  }

  override func tearDown() async throws {
    SettingsChanges.handler = savedHandler
    SettingsChanges.isLocked = savedLock
    AddressWord.current = WordsArea.shared.addressWord
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  static let idle = VoiceContext(screen: .camera)
  static let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "Mail reader. Hold the phone flat.")
}

// MARK: - Your words

@MainActor
final class CustomiseWordsTests: CustomiseTestCase {
  private var area: WordsArea!
  private var harness: WordsHarness!
  private var engine: WordsEngine!

  override func setUp() async throws {
    try await super.setUp()
    area = WordsArea(defaults: defaults, mirrorsAddressWord: false)
    harness = WordsHarness()
    engine = WordsEngine(area: area, environment: harness.environment())
  }

  private func say(_ words: String, _ context: VoiceContext = CustomiseTestCase.idle) -> UtteranceRewrite {
    engine.rewrite(words, context: context)
  }

  // MARK: Aliases

  func testAnAliasIsDefinedAndRewrittenBeforeParsing() {
    XCTAssertEqual(say("When I say post, open the mail reader."), .handled)
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsAliasSaved("post", "open the mail reader"))
    XCTAssertEqual(area.aliases, [WordAlias(name: "post", phrase: "open the mail reader")])

    guard case .rewritten(let words) = say("Post") else { return XCTFail("not rewritten") }
    XCTAssertEqual(words, "reader open the mail reader")
    XCTAssertEqual(VoiceCommandParser.parse(words, context: Self.idle), .command(.openMail))
  }

  func testAnAliasWithoutACommaFindsWhereTheNameEnds() {
    _ = say("when I say morning light open light and colour")
    XCTAssertEqual(area.aliases, [WordAlias(name: "morning light", phrase: "open light and colour")])
  }

  func testAnAliasCanStandForAToolPhrase() {
    // "everything" itself is a Labels phrase, so it would be refused.
    XCTAssertEqual(area.addAlias(name: "everything", phrase: "read it all"), SpokenMessage.wordsNameInTool("everything", tool: .labels))
    _ = say("when I say the works, read it all")
    XCTAssertEqual(area.aliases.first?.phrase, "read it all")
    XCTAssertEqual(say("please the works"), .rewritten("reader read it all"))
  }

  func testAliasesFollowTheWakeWordRulesAndPoliteWords() {
    _ = say("when I say post, open mail reader")
    // While the app talks, a bare word is ignored; with the address word it counts.
    XCTAssertEqual(say("post", Self.speaking), .unchanged)
    XCTAssertEqual(say("reader, post", Self.speaking), .rewritten("reader open mail reader"))
    XCTAssertEqual(say("post please"), .rewritten("reader open mail reader"))
    XCTAssertEqual(say("postman"), .unchanged)
  }

  func testForgetAndWhatAreMyWords() {
    XCTAssertEqual(engine.reply(to: "what are my words"), SpokenMessage.wordsNone)
    _ = say("when I say post, open mail reader")
    XCTAssertEqual(engine.reply(to: "what are my words"), "Your words: post means open mail reader.")
    XCTAssertEqual(engine.reply(to: "what does post do"), "Post will open mail reader.")
    XCTAssertEqual(engine.reply(to: "forget post"), SpokenMessage.wordsForgotten("post"))
    XCTAssertTrue(area.aliases.isEmpty)
    XCTAssertEqual(engine.reply(to: "forget post"), SpokenMessage.wordsNotFound("post"))
    XCTAssertEqual(say("post"), .unchanged)
  }

  func testAStepNobodyUnderstandsIsRefused() {
    _ = say("when I say post, open the mailbox")
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsStepNotUnderstood("open the mailbox"))
    XCTAssertTrue(area.aliases.isEmpty)
    XCTAssertNil(engine.draft)
  }

  // MARK: Conflicts

  func testNamesThatClashAreRefusedWithAReason() {
    XCTAssertEqual(area.addAlias(name: "stop", phrase: "repeat"), SpokenMessage.wordsNameBuiltIn("stop"))
    XCTAssertEqual(area.addAlias(name: "open labels", phrase: "repeat"), SpokenMessage.wordsNameBuiltIn("open labels"))
    XCTAssertEqual(area.addAlias(name: "undo", phrase: "repeat"), SpokenMessage.wordsNameSettings("undo"))
    XCTAssertEqual(area.addAlias(name: "reset speech", phrase: "repeat"), SpokenMessage.wordsNameSettings("reset speech"))
    XCTAssertEqual(area.addAlias(name: "earcons quieter", phrase: "repeat"), SpokenMessage.wordsNameSettings("earcons quieter"))
    XCTAssertEqual(area.addAlias(name: "how much", phrase: "repeat"), SpokenMessage.wordsNameInTool("how much", tool: .mail))
    XCTAssertEqual(area.addAlias(name: "reader post", phrase: "repeat"), SpokenMessage.wordsNameIsAddressWord("reader post"))
    XCTAssertEqual(area.addAlias(name: "one two three four five", phrase: "repeat"), SpokenMessage.wordsNameTooLong("one two three four five"))
    XCTAssertTrue(area.aliases.isEmpty)
    XCTAssertTrue(recorded.isEmpty)

    _ = area.addAlias(name: "post", phrase: "open mail reader")
    XCTAssertEqual(area.addAlias(name: "post", phrase: "repeat"), SpokenMessage.wordsNameTaken("post", meaning: "open mail reader"))
    XCTAssertEqual(
      area.addMacro(WordMacro(name: "post", steps: ["repeat", "stop"])), SpokenMessage.wordsNameTaken("post", meaning: "open mail reader"))
    XCTAssertEqual(area.aliases.count, 1)
  }

  func testAMacroNameIsCheckedBeforeBuildingStarts() {
    XCTAssertEqual(say("when I say stop"), .handled)
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsNameBuiltIn("stop"))
    XCTAssertNil(engine.draft)
  }

  // MARK: Macros

  func testAOneLineMacroIsReadBackThenSavedOnYes() {
    _ = say("When I say morning post, open mail and read it all.")
    XCTAssertEqual(engine.draft?.steps, ["open mail", "read it all"])
    XCTAssertEqual(harness.said.last, "Morning post will open mail, then read it all. Shall I save it? Say yes, or no to drop it.")
    XCTAssertTrue(area.macros.isEmpty, "nothing is saved before the yes")

    // "yes" goes to the draft, not the app's question handling.
    XCTAssertEqual(say("yes"), .handled)
    XCTAssertEqual(area.macros, [WordMacro(name: "morning post", steps: ["open mail", "read it all"])])
    XCTAssertEqual(harness.said.last, "Saved. Say morning post to open mail, then read it all.")
    XCTAssertNil(engine.draft)
    XCTAssertEqual(recorded.map(\.area), ["words"])
  }

  func testAMacroIsBuiltStepByStepAndCanBeDropped() {
    _ = say("when I say evening")
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsMacroStarted("evening"))
    XCTAssertEqual(say("that's all"), .handled)
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsMacroNeedsAStep)
    _ = say("open labels")
    _ = say("then torch on")
    _ = say("and then say the status")
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsStepNotUnderstood("say the status"))
    _ = say("and then status")
    _ = say("scratch that")
    _ = say("then repeat")
    XCTAssertEqual(engine.draft?.steps, ["open labels", "torch on", "repeat"])
    _ = say("that's all")
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsMacroReadBack(WordMacro(name: "evening", steps: ["open labels", "torch on", "repeat"])))
    _ = say("no")
    XCTAssertEqual(harness.said.last, SpokenMessage.wordsMacroDropped("evening"))
    XCTAssertTrue(area.macros.isEmpty)
    XCTAssertTrue(recorded.isEmpty)
  }

  func testAnAbandonedDraftTimesOut() {
    _ = say("when I say evening")
    harness.now += WordsEngine.draftTimeout + 1
    XCTAssertEqual(say("stop"), .unchanged)
    XCTAssertNil(engine.draft)
  }

  func testAMacroRunsItsStepsInOrderWaitingForEachToFinish() async {
    _ = area.addMacro(WordMacro(name: "morning post", steps: ["open mail", "read it all", "torch off"]))
    harness.busyPolls = 2
    XCTAssertEqual(say("morning post"), .handled)
    await engine.runner.wait()
    XCTAssertEqual(harness.injected, ["reader open mail", "reader read it all", "reader torch off"])
    XCTAssertEqual(harness.busyPolls, 0, "the runner waited while SpeakUp was busy")
  }

  func testSpeakingDuringAMacroCancelsTheRest() async {
    _ = area.addMacro(WordMacro(name: "morning post", steps: ["open mail", "read it all"]))
    harness.busyPolls = 1000
    _ = say("morning post")
    for _ in 0..<100 where harness.injected.isEmpty { await Task.yield() }
    _ = say("stop")
    await engine.runner.wait()
    XCTAssertEqual(harness.injected, ["reader open mail"])
    XCTAssertFalse(engine.runner.isRunning)
  }

  func testStepsSplitOnThenAndAndButKeepToolNamesWhole() {
    XCTAssertEqual(WordsEngine.steps(["open", "light", "and", "colour", "and", "repeat"]), ["open light and colour", "repeat"])
    XCTAssertEqual(WordsEngine.steps(["open", "mail", "then", "read", "it", "all"]), ["open mail", "read it all"])
    XCTAssertNil(WordsEngine.steps(["open", "the", "mailbox"]))
  }

  // MARK: Tools menu

  func testTheMenuOrderIsChangedByVoiceAndPersists() {
    XCTAssertEqual(engine.reply(to: "put labels first"), SpokenMessage.homeMoved(.labels, position: 0, count: 6))
    XCTAssertEqual(area.orderedTools.first, .labels)
    XCTAssertEqual(engine.reply(to: "move mail up"), SpokenMessage.homeMoved(.mail, position: 1, count: 6))
    XCTAssertEqual(engine.reply(to: "put read text last"), SpokenMessage.homeMoved(.read, position: 5, count: 6))
    XCTAssertEqual(engine.reply(to: "hide light and colour"), SpokenMessage.homeHidden([.light]))
    XCTAssertEqual(area.visibleTools, [.labels, .mail, .watch, .ask, .read])

    let reloaded = WordsArea(defaults: defaults, mirrorsAddressWord: false)
    XCTAssertEqual(reloaded.orderedTools, [.labels, .mail, .watch, .ask, .light, .read])
    XCTAssertEqual(reloaded.visibleTools, [.labels, .mail, .watch, .ask, .read])

    XCTAssertEqual(engine.reply(to: "show all tools"), SpokenMessage.homeAllShown)
    XCTAssertEqual(area.visibleTools.count, 6)
    XCTAssertEqual(engine.reply(to: "show all tools"), SpokenMessage.homeNothingHidden)
  }

  func testHidingSeveralShowingOneAndNeverHidingAll() {
    XCTAssertEqual(engine.reply(to: "hide ask, watch and light"), SpokenMessage.homeHidden([.ask, .watch, .light]))
    XCTAssertEqual(engine.reply(to: "show watch"), SpokenMessage.homeShown([.watch]))
    XCTAssertEqual(area.visibleTools, [.read, .mail, .labels, .watch])
    XCTAssertEqual(engine.reply(to: "hide read text and mail and labels and watch"), SpokenMessage.homeCantHideAll)
    XCTAssertEqual(area.visibleTools.count, 4)
    XCTAssertEqual(engine.reply(to: "hide the kettle"), SpokenMessage.homeUnknownTool("the kettle"))
  }

  func testMenuPhrasesLeaveOtherOwnersAlone() {
    // The settings core's "put it back", the app's "show settings".
    XCTAssertNil(engine.reply(to: "put it back"))
    XCTAssertNil(engine.reply(to: "move it left"))
    XCTAssertEqual(say("show settings"), .unchanged)
    XCTAssertEqual(say("list tools"), .unchanged)
  }

  func testTheToolsListFollowsTheMenu() {
    let wasHidden = WordsArea.shared.orderedTools.filter(WordsArea.shared.isHidden)
    XCTAssertTrue(SpokenMessage.toolsList.hasPrefix(wasHidden.isEmpty ? "SpeakUp has six tools." : "Your menu has"))
    let shared = WordsArea.shared
    let before = shared.snapshot()
    defer { try? shared.restore(before) }
    _ = shared.hide([.light, .ask])
    let list = SpokenMessage.toolsList
    XCTAssertTrue(list.hasPrefix("Your menu has four tools."), list)
    XCTAssertFalse(list.contains(ToolID.light.title))
    XCTAssertTrue(list.contains("show all tools"))
  }

  // MARK: Address word

  func testTheAddressWordCanBeChangedAndTheParserFollows() {
    let mirrored = WordsArea(defaults: defaults, mirrorsAddressWord: true)
    XCTAssertEqual(mirrored.setAddressWord("Robin"), SpokenMessage.addressWordSet("robin"))
    XCTAssertEqual(AddressWord.current, "robin")
    XCTAssertEqual(VoiceCommandParser.parse("Robin, stop", context: Self.speaking), .command(.stop))
    XCTAssertEqual(VoiceCommandParser.parse("robins stop", context: Self.speaking), .command(.stop))
    XCTAssertEqual(VoiceCommandParser.parse("reader stop", context: Self.speaking), .ignored(.needsWakeWord))
    XCTAssertTrue(VoiceCommandParser.helpLine(context: Self.speaking).hasPrefix("Say robin first"))
    XCTAssertEqual(VoiceCoachLines.Words(wakeWord: true).say("help"), "say robin, help")

    XCTAssertEqual(mirrored.setAddressWord("hey sam"), SpokenMessage.addressWordIsCommand("hey sam"))
    XCTAssertEqual(mirrored.setAddressWord("aunt sally"), SpokenMessage.addressWordSet("aunt sally"))
    XCTAssertEqual(VoiceCommandParser.parse("aunt sally repeat", context: Self.speaking), .command(.repeatLast))
    _ = mirrored.setAddressWord("reader")
    XCTAssertEqual(VoiceCommandParser.parse("readers stop", context: Self.speaking), .command(.stop))
  }

  func testAddressWordConflicts() {
    XCTAssertEqual(area.setAddressWord("stop"), SpokenMessage.addressWordIsCommand("stop"))
    XCTAssertEqual(area.setAddressWord("open"), SpokenMessage.addressWordIsCommand("open"))
    XCTAssertEqual(area.setAddressWord("the"), SpokenMessage.addressWordIsCommand("the"))
    XCTAssertEqual(area.setAddressWord("yo"), SpokenMessage.addressWordTooShort)
    XCTAssertEqual(area.setAddressWord("my lovely helper bot"), SpokenMessage.addressWordTooLong)
    _ = area.addAlias(name: "jeeves", phrase: "repeat")
    XCTAssertEqual(area.setAddressWord("jeeves"), SpokenMessage.addressWordIsYourWord("jeeves"))
    XCTAssertEqual(area.addressWord, "reader")
  }

  func testTheAddressWordByVoice() {
    XCTAssertEqual(engine.reply(to: "what's your name"), SpokenMessage.addressWordIs("reader"))
    XCTAssertEqual(engine.reply(to: "call you Robin"), SpokenMessage.addressWordSet("robin"))
    XCTAssertEqual(area.addressWord, "robin")
    XCTAssertEqual(engine.reply(to: "call you reader again"), SpokenMessage.addressWordSet("reader"))
  }

  // MARK: Settings contract

  func testSnapshotRestoreAndDifferences() throws {
    XCTAssertEqual(area.differencesFromDefaults(), [])
    let clean = area.snapshot()
    _ = area.addAlias(name: "post", phrase: "open mail reader")
    _ = area.addMacro(WordMacro(name: "morning post", steps: ["open mail", "read it all"]))
    _ = area.move(.labels, to: 0)
    _ = area.hide([.light])
    _ = area.setAddressWord("robin")
    XCTAssertEqual(
      area.differencesFromDefaults(),
      [
        "post means open mail reader", "morning post will open mail, then read it all",
        "tools menu order: labels and barcodes, read text, mail reader, watch for text, ask about the text, and light and colour",
        "hidden tools: light and colour", "you call me robin",
      ])
    let changed = area.snapshot()
    area.resetToDefaults()
    XCTAssertEqual(area.differencesFromDefaults(), [])
    try area.restore(changed)
    XCTAssertEqual(area.macros.count, 1)
    XCTAssertEqual(area.addressWord, "robin")
    try area.restore(clean)
    XCTAssertEqual(area.settings, WordsSettings())
  }

  func testRestoreKeepsDefaultsForMissingOrUnknownFields() throws {
    let old = #"{"aliases":[{"name":"post","phrase":"repeat"}],"homeOrder":["light","kettle"],"hiddenTools":["kettle"],"extra":1}"#
    try area.restore(Data(old.utf8))
    XCTAssertEqual(area.aliases.count, 1)
    XCTAssertEqual(area.orderedTools, [.light, .read, .mail, .labels, .watch, .ask])
    XCTAssertEqual(area.visibleTools.count, 6)
    XCTAssertEqual(area.addressWord, "reader")
    XCTAssertTrue(area.macros.isEmpty)
  }

  func testEveryChangeIsRecordedWithTheSnapshotFromBefore() throws {
    let before = area.snapshot()
    _ = area.addAlias(name: "post", phrase: "open mail reader")
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded[0].area, WordsArea.areaID)
    XCTAssertEqual(recorded[0].before, before)
    XCTAssertEqual(recorded[0].description, "your word post")
    // Undo, as the settings core does it.
    try area.restore(recorded[0].before)
    XCTAssertTrue(area.aliases.isEmpty)
    // No change, no record.
    _ = area.showAll()
    XCTAssertEqual(recorded.count, 1)
  }

  func testLockedSettingsRefuseEveryChange() {
    SettingsChanges.isLocked = { true }
    XCTAssertEqual(say("when I say post, open mail reader"), .handled)
    XCTAssertEqual(harness.said.last, SpokenMessage.customiseLocked)
    XCTAssertEqual(area.addMacro(WordMacro(name: "m", steps: ["stop"])), SpokenMessage.customiseLocked)
    XCTAssertEqual(engine.reply(to: "put labels first"), SpokenMessage.customiseLocked)
    XCTAssertEqual(engine.reply(to: "hide light"), SpokenMessage.customiseLocked)
    XCTAssertEqual(engine.reply(to: "call you robin"), SpokenMessage.customiseLocked)
    // Reading them back still works.
    XCTAssertEqual(engine.reply(to: "what are my words"), SpokenMessage.wordsNone)
    XCTAssertEqual(area.settings, WordsSettings())
    XCTAssertTrue(recorded.isEmpty)
  }

  func testLockingWhileAMacroIsBeingBuiltRefusesTheSave() {
    _ = say("when I say morning post, open mail and read it all")
    SettingsChanges.isLocked = { true }
    _ = say("yes")
    XCTAssertEqual(harness.said.last, SpokenMessage.customiseLocked)
    XCTAssertTrue(area.macros.isEmpty)
  }

  // MARK: VoiceControl's hook

  func testVoiceControlRewritesBeforeParsingThroughTheHook() {
    _ = area.addAlias(name: "post", phrase: "open mail reader")
    _ = area.addMacro(WordMacro(name: "night", steps: ["torch off"]))
    var performed: [VoiceCommand] = []
    let defaults = self.defaults
    let preferences = A11yPreferences(defaults: defaults)
    let control = VoiceControl(environment: Self.quietVoiceEnvironment(), preferences: preferences)
    control.setScreen(.camera) { command in
      performed.append(command)
      return true
    }
    let saved = UtteranceHook.rewrite
    defer { UtteranceHook.rewrite = saved }
    let engine = self.engine!
    UtteranceHook.rewrite = { engine.rewrite($0, context: $1) }

    control.inject(transcript: "post")
    XCTAssertEqual(performed, [.openMail])
    control.inject(transcript: "night")
    XCTAssertEqual(performed, [.openMail], "a macro is the engine's, not the screen's")
    control.inject(transcript: "stop")
    XCTAssertEqual(performed, [.openMail, .stop])
  }

  static func quietVoiceEnvironment() -> VoiceControl.Environment {
    VoiceControl.Environment(
      isInert: true, makePhoneListener: { _ in nil }, phoneLocale: { nil }, phoneMicPermission: { .granted },
      speechPermission: { .granted }, requestPermissions: {}, say: { _, _, _, _ in }, playEarcon: { _ in },
      isSpeaking: { false }, textBeingSpoken: { "" }, stopSpeech: {}, repeatLast: {}, hasReadSentences: { false },
      micHearsVoiceOver: { _ in false }, followsVoiceOverRate: { false }, setIdleTimerDisabled: { _ in },
      glassesSpeechEnabled: { false }, now: { Date() })
  }
}

// MARK: - Your buttons

@MainActor
final class CustomiseControlsTests: CustomiseTestCase {
  private var area: ControlsArea!
  private var performed: [VoiceCommand] = []
  private var macrosRun: [String] = []
  private var said: [String] = []
  private var openTool: ToolID?
  private var controls: GlassesControls!
  private var grammar: ControlsGrammar!
  private var favouritesOpened: [ToolID] = []

  override func setUp() async throws {
    try await super.setUp()
    area = ControlsArea(defaults: defaults)
    performed = []
    macrosRun = []
    said = []
    openTool = nil
    favouritesOpened = []
    controls = GlassesControls(
      area: area,
      environment: GlassesControls.Environment(
        perform: { [unowned self] in performed.append($0) }, openTool: { [unowned self] in openTool },
        runMacro: { [unowned self] in macrosRun.append($0) }, say: { [unowned self] in said.append($0) },
        sleep: { seconds in try? await Task.sleep(for: .seconds(seconds / 10)) }))
    grammar = ControlsGrammar(
      area: area, macroNames: { ["morning post"] }, openFavourite: { [unowned self] in favouritesOpened.append($0) },
      glassesSupported: true)
  }

  func testTheDefaultMap() {
    XCTAssertEqual(area.action(for: .captureShort), .look)
    XCTAssertEqual(area.action(for: .captureHold), .read)
    XCTAssertEqual(area.action(for: .captureDouble), .stop)
    XCTAssertEqual(area.action(for: .doubleTap), .repeatLast)
    XCTAssertEqual(area.action(for: .swipeRight), .next)
    XCTAssertEqual(area.action(for: .swipeUp), .nothing)
    XCTAssertEqual(area.differencesFromDefaults(), [])
  }

  func testEventsRunTheirActions() async {
    controls.receive(.captureHold)
    controls.receive(.doubleTap)
    controls.receive(.swipeLeft)
    XCTAssertEqual(performed, [.read, .repeatLast, .back])
    // Look: Read text reads; another open tool looks again.
    controls.receive(.captureShort)
    await controls.settle()
    openTool = .light
    controls.receive(.captureShort)
    await controls.settle()
    XCTAssertEqual(performed.suffix(2), [.read, .openLight])
  }

  func testADoublePressIsNotAlsoAShortPress() async {
    controls.receive(.captureShort)
    controls.receive(.captureDouble)
    await controls.settle()
    try? await Task.sleep(for: .seconds(GlassesControls.doublePressWindow / 5))
    XCTAssertEqual(performed, [.stop])
  }

  func testAShortPressActsAtOnceWhenDoublePressIsFree() {
    _ = area.set(.captureDouble, to: .nothing)
    controls.receive(.captureShort)
    XCTAssertEqual(performed, [.read])
  }

  func testButtonsOffIgnoresEvents() {
    _ = area.setEnabled(false)
    controls.receive(.captureHold)
    XCTAssertEqual(performed, [])
  }

  func testMacrosToolsAndTheFavouriteFromAButton() {
    _ = area.set(.swipeUp, to: .macro("morning post"))
    _ = area.set(.swipeDown, to: .tool(.labels))
    _ = area.set(.actionButton, to: .favouriteTool)
    controls.receive(.swipeUp)
    controls.receive(.swipeDown)
    controls.receive(.actionButton)
    XCTAssertEqual(macrosRun, ["morning post"])
    XCTAssertEqual(performed, [.openLabels])
    XCTAssertEqual(said, [SpokenMessage.favouriteNone])
    _ = area.setFavourite(.mail)
    controls.receive(.actionButton)
    XCTAssertEqual(performed, [.openLabels, .openMail])
  }

  func testMappingByVoice() {
    XCTAssertEqual(grammar.handle("when I double tap, stop"), SpokenMessage.controlsSet(.doubleTap, .stop))
    XCTAssertEqual(grammar.handle("make hold open mail reader"), SpokenMessage.controlsSet(.captureHold, .tool(.mail)))
    XCTAssertEqual(grammar.handle("set swipe up to morning post"), SpokenMessage.controlsSet(.swipeUp, .macro("morning post")))
    XCTAssertEqual(grammar.handle("press and hold should read"), SpokenMessage.controlsSet(.captureHold, .read))
    XCTAssertEqual(grammar.handle("make double press juggle"), SpokenMessage.controlsUnknownAction("juggle"))
    XCTAssertEqual(area.action(for: .doubleTap), .stop)
    XCTAssertEqual(area.action(for: .captureHold), .read)
    XCTAssertEqual(area.action(for: .swipeUp), .macro("morning post"))
    XCTAssertEqual(grammar.handle("what does double tap do"), "A double tap will stop.")
    XCTAssertNil(grammar.handle("hold on"))
    XCTAssertNil(grammar.handle("when I say post, open mail"))
  }

  func testWhatDoMyButtonsDoReadsTheMapAndMetasWarning() {
    let line = grammar.handle("what do my buttons do") ?? ""
    XCTAssertTrue(line.hasPrefix("A short press will look. Holding the button will read. A double press will stop."), line)
    XCTAssertTrue(line.hasSuffix(SpokenMessage.controlsWarning))
    XCTAssertFalse(line.contains("swiping up"))
    let store = ControlsGrammar(area: area, glassesSupported: false)
    XCTAssertEqual(store.handle("what do my buttons do"), SpokenMessage.controlsNeedGlassesBuild)
    XCTAssertEqual(store.handle("make hold read"), SpokenMessage.controlsNeedGlassesBuild)
  }

  func testButtonsOnOffAndTheFavouriteByVoice() {
    XCTAssertEqual(grammar.handle("glasses buttons off"), SpokenMessage.controlsOff)
    XCTAssertEqual(grammar.handle("glasses buttons off"), SpokenMessage.controlsAlreadyOff)
    XCTAssertEqual(grammar.handle("turn on the glasses buttons"), SpokenMessage.controlsOn)
    XCTAssertEqual(grammar.handle("open my favourite"), SpokenMessage.favouriteNone)
    XCTAssertEqual(grammar.handle("make mail my favourite"), SpokenMessage.favouriteSet(.mail))
    XCTAssertEqual(grammar.handle("what's my favorite tool"), SpokenMessage.favouriteIs(.mail))
    XCTAssertEqual(grammar.handle("my favourite tool is light and colour"), SpokenMessage.favouriteSet(.light))
    XCTAssertEqual(grammar.handle("open my favourite"), "")
    XCTAssertEqual(favouritesOpened, [.light])
  }

  func testSnapshotRestoreDifferencesAndRecording() throws {
    let clean = area.snapshot()
    _ = area.set(.doubleTap, to: .stop)
    _ = area.setFavourite(.labels)
    _ = area.setEnabled(false)
    XCTAssertEqual(area.differencesFromDefaults(), ["glasses buttons off", "a double tap will stop", "favourite tool labels and barcodes"])
    XCTAssertEqual(recorded.map(\.area), ["controls", "controls", "controls"])
    XCTAssertEqual(recorded[0].before, clean)
    let changed = area.snapshot()
    try area.restore(clean)
    XCTAssertEqual(area.settings, ControlsSettings())
    try area.restore(changed)
    XCTAssertEqual(area.action(for: .doubleTap), .stop)
    XCTAssertEqual(area.favouriteTool, .labels)
    let reloaded = ControlsArea(defaults: defaults)
    XCTAssertFalse(reloaded.enabled)
    area.resetToDefaults()
    XCTAssertEqual(area.differencesFromDefaults(), [])
  }

  func testRestoreKeepsDefaultsForUnknownEventsAndActions() throws {
    try area.restore(Data(#"{"map":{"doubleTap":"stop","wink":"read","swipeUp":"juggle"}}"#.utf8))
    XCTAssertEqual(area.action(for: .doubleTap), .stop)
    XCTAssertEqual(area.action(for: .swipeUp), .nothing)
    XCTAssertEqual(area.action(for: .captureShort), .look)
    XCTAssertTrue(area.enabled)
  }

  func testLockedSettingsRefuseButtonChanges() {
    SettingsChanges.isLocked = { true }
    XCTAssertEqual(grammar.handle("make hold stop"), SpokenMessage.customiseLocked)
    XCTAssertEqual(grammar.handle("glasses buttons off"), SpokenMessage.customiseLocked)
    XCTAssertEqual(grammar.handle("make mail my favourite"), SpokenMessage.customiseLocked)
    XCTAssertTrue(grammar.handle("what do my buttons do")?.hasSuffix(SpokenMessage.controlsWarning) == true)
    XCTAssertEqual(area.settings, ControlsSettings())
    XCTAssertTrue(recorded.isEmpty)
  }

  func testActionsRoundTripThroughTheirStoredForm() {
    let all = ControlAction.simple + ToolID.allCases.map(ControlAction.tool) + [.macro("morning post")]
    for action in all {
      XCTAssertEqual(ControlAction(rawValue: action.rawValue), action, action.rawValue)
    }
    XCTAssertNil(ControlAction(rawValue: "tool:kettle"))
    XCTAssertNil(ControlAction(rawValue: "macro:"))
  }

  func testGrammarsAreRegisteredAndDontClaimBuiltInPhrases() {
    XCTAssertNotNil(SettingsAreas.area(WordsArea.areaID))
    XCTAssertNotNil(SettingsAreas.area(ControlsArea.areaID))
    XCTAssertNotNil(UtteranceHook.rewrite)
    let words = WordsEngine(area: WordsArea(defaults: defaults, mirrorsAddressWord: false), environment: WordsHarness().environment())
    for command in VoiceCommand.allCases {
      XCTAssertNil(words.reply(to: command.phrase), command.phrase)
      XCTAssertNil(grammar.handle(command.phrase), command.phrase)
    }
    // The settings core's and the ears' phrases stay theirs.
    for phrase in ["faster", "slower", "undo", "put it back", "keep that", "lock settings", "unlock settings", "what's my setup",
      "reset speech", "switch to reading", "save as profile", "earcons off", "louder", "quieter", "balance", "move it left",
      "clear speech", "I use mono", "someone's talking to me", "carry on"]
    {
      XCTAssertNil(words.reply(to: phrase), phrase)
      XCTAssertNil(grammar.handle(phrase), phrase)
    }
  }
}
