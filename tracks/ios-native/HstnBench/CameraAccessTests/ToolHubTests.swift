/*
 * ToolHubTests - the tools home's plumbing (notes/tools-home-ios.md): opening, closing and
 * switching tools, the routing order for transcripts, the new voice phrases and their no-clash
 * rules, help and tips in the App Store build, and the tools publishing to RecentText for Ask.
 */

import SwiftUI
import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Fakes

@MainActor
private final class FakeToolCamera: ReadFrameSource {
  var latestReadFrame: ReadFrame?
  var cameraKind: CameraKind { .phone }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
}

@MainActor
private final class FakeTool: SpeakUpTool {
  let toolID: ToolID
  var starts = 0
  var stops = 0
  var pauses = 0
  var heard: [String] = []
  /// Phrases it uses; anything else is left to the app.
  var takes: Set<String> = []
  weak var startedWith: (any ReadFrameSource)?

  init(_ id: ToolID) { toolID = id }

  func start(source: ReadFrameSource) {
    starts += 1
    startedWith = source
  }
  func stop() { stops += 1 }
  func handle(transcript: String) -> Bool {
    heard.append(transcript)
    return takes.contains(transcript.lowercased())
  }
  func pauseForStop() { pauses += 1 }
  var helpLine: String { "\(toolID.title) help." }
  func makePanel() -> AnyView { AnyView(EmptyView()) }
}

private struct NoProductLookups: ProductSource {
  func lookup(_ code: String) async -> ProductLookupResult { .failed("tests don't go online") }
}

// MARK: - The hub

@MainActor
final class ToolHubTests: XCTestCase {
  private var camera: FakeToolCamera!
  private var fakes: [ToolID: FakeTool] = [:]
  private var hub: ToolHub!
  private var watchDefaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    camera = FakeToolCamera()
    watchDefaults = UserDefaults(suiteName: "ToolHubTests.\(UUID().uuidString)")
    fakes = [:]
    for id in ToolID.allCases where id != .watch { fakes[id] = FakeTool(id) }
    let fakes = fakes
    let defaults = watchDefaults!
    hub = ToolHub(source: camera) { id in
      if id == .watch { return WatchTool(defaults: defaults, haptic: {}) }
      return fakes[id]!
    }
  }

  override func tearDown() async throws {
    hub.close(announce: false)
    Announcer.shared.stop()
    hub = nil
    try await super.tearDown()
  }

  func testOpeningStartsTheToolWithTheCamera() {
    hub.open(.mail)
    XCTAssertEqual(hub.openTool, .mail)
    XCTAssertEqual(fakes[.mail]?.starts, 1)
    XCTAssertTrue(fakes[.mail]?.startedWith === camera)
  }

  func testSwitchingStopsTheOldToolAndStartsTheNew() {
    hub.open(.mail)
    hub.open(.labels)
    XCTAssertEqual(fakes[.mail]?.stops, 1)
    XCTAssertEqual(fakes[.labels]?.starts, 1)
    XCTAssertEqual(hub.openTool, .labels)
    XCTAssertTrue(hub.tool(.labels) === fakes[.labels], "one instance per tool")
  }

  func testCloseStopsTheToolAndGoesHome() {
    hub.open(.ask)
    hub.close(announce: false)
    XCTAssertNil(hub.openTool)
    XCTAssertEqual(fakes[.ask]?.stops, 1)
    hub.close(announce: false)
    XCTAssertEqual(fakes[.ask]?.stops, 1, "closing twice stops once")
  }

  func testTheOpenToolHearsItsOwnPhrasesBeforeTheAppsGrammar() {
    hub.open(.mail)
    fakes[.mail]?.takes = ["read", "repeat", "back"]
    XCTAssertTrue(hub.route("read", command: .read))
    XCTAssertTrue(hub.route("repeat", command: .repeatLast))
    XCTAssertTrue(hub.route("back", command: .back))
    XCTAssertEqual(fakes[.mail]?.heard, ["read", "repeat", "back"])
    // Not the tool's: the app carries on ("next" reads on in Read text, say).
    XCTAssertFalse(hub.route("next", command: .continueOn))
  }

  func testStopCloseAndHelpStayTheApps() {
    hub.open(.light)
    fakes[.light]?.takes = ["stop", "close", "help", "main menu"]
    for (text, command) in [("stop", VoiceCommand.stop), ("close", .close), ("help", .help), ("main menu", .mainMenu)] {
      XCTAssertFalse(hub.route(text, command: command), text)
    }
    XCTAssertEqual(fakes[.light]?.heard, [], "the tool never saw them")
    hub.stopForGlobal()
    XCTAssertEqual(fakes[.light]?.pauses, 1, "global stop quiets the open tool too")
    XCTAssertEqual(hub.openTool, .light, "and leaves it open")
  }

  func testAnotherToolsNameSwitchesTools() {
    hub.open(.mail)
    XCTAssertTrue(hub.route("open labels", command: .openLabels))
    XCTAssertEqual(hub.openTool, .labels)
    XCTAssertEqual(fakes[.mail]?.stops, 1)
  }

  func testTheOpenToolsOwnNamePhraseGoesToItFirst() {
    hub.open(.labels)
    fakes[.labels]?.takes = ["read the label"]
    XCTAssertTrue(hub.route("read the label", command: .openLabels))
    XCTAssertEqual(fakes[.labels]?.starts, 1, "not restarted")
    XCTAssertEqual(fakes[.labels]?.heard, ["read the label"])
  }

  func testReadOnTheHomeIsLeftToTheScreen() {
    XCTAssertFalse(hub.route("read", command: .read), "the screen opens Read text and reads")
    XCTAssertNil(hub.openTool)
    XCTAssertFalse(hub.route("hello there", command: nil), "chatter is nobody's")
  }

  func testWatchForAFreeTargetOpensWatchWatchingForIt() throws {
    XCTAssertTrue(hub.route("tell me when you see 42", command: nil))
    XCTAssertEqual(hub.openTool, .watch)
    let watch = try XCTUnwrap(hub.tool(.watch) as? WatchTool)
    XCTAssertEqual(watch.target?.display, "42")
    XCTAssertEqual(watch.phase, .watching)
    // From another tool too, and a new target replaces the old one.
    hub.open(.mail)
    XCTAssertTrue(hub.route("watch for platform 4", command: nil))
    XCTAssertEqual(hub.openTool, .watch)
    XCTAssertEqual(watch.target?.display, "platform 4")
  }

  func testWatchForTextOpensWatchAsking() throws {
    XCTAssertTrue(hub.route("watch for text", command: .openWatch))
    let watch = try XCTUnwrap(hub.tool(.watch) as? WatchTool)
    XCTAssertEqual(hub.openTool, .watch)
    XCTAssertEqual(watch.phase, .asking)
    XCTAssertNil(watch.target)
  }

  func testGlobalStopPausesWatching() throws {
    XCTAssertTrue(hub.route("watch for 42", command: nil))
    let watch = try XCTUnwrap(hub.tool(.watch) as? WatchTool)
    hub.stopForGlobal()
    XCTAssertEqual(watch.phase, .stopped)
    XCTAssertEqual(hub.openTool, .watch)
  }

  func testLightOpensInColourModeFromItsPhrase() {
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "what colour is this"), .colour)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "is the light on"), .probe)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "light and colour"), .probe)
  }
}

// MARK: - The phrases

final class ToolPhraseTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera)

  private func parse(_ text: String, _ context: VoiceContext? = nil) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context ?? camera)
  }

  func testEveryOpenPhraseOpensItsTool() {
    for tool in ToolID.allCases {
      for phrase in tool.openPhrases {
        guard case .command(let command) = parse(phrase) else {
          XCTFail("\(phrase) isn't a command")
          continue
        }
        XCTAssertEqual(command.tool, tool, phrase)
      }
    }
  }

  func testOpenAndANameOpensEachTool() {
    let expected: [(String, VoiceCommand)] = [
      ("open read text", .openReader), ("open mail reader", .openMail), ("open labels", .openLabels),
      ("open watch for text", .openWatch), ("open ask", .openAsk), ("open light and colour", .openLight), ("open reminders", .openReminders),
      ("please open the mail reader", .openMail), ("what color is this", .openLight), ("scan a barcode", .openLabels),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  func testOldPhrasesKeepTheirMeaning() {
    let expected: [(String, VoiceCommand)] = [
      ("read", .read), ("read text", .read), ("read this", .read), ("light on", .torchOn), ("turn on the light", .torchOn),
      ("light off", .torchOff), ("stop", .stop), ("repeat", .repeatLast), ("list tools", .listTools), ("open reader", .openReader),
      ("close", .close), ("main menu", .mainMenu),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  func testToolsOpenOnlyFromTheMainScreen() {
    XCTAssertEqual(parse("open mail reader", VoiceContext(screen: .welcome)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("open mail reader", VoiceContext(screen: .home)), .ignored(.unavailableHere))
  }

  func testHelpNamesTheTools() {
    let help = VoiceCommandParser.helpLine(context: camera)
    XCTAssertTrue(help.hasPrefix("You can say these. Here: read"), help)
    XCTAssertTrue(help.contains("Tools: say open, then read text, mail reader, labels, watch for text, ask, light and colour, or reminders."), help)
    XCTAssertFalse(help.contains("open mail reader,"), "the tools are one group, not six phrases in Here")
    XCTAssertFalse(VoiceCommandParser.helpLine(context: VoiceContext(screen: .home)).contains("Tools:"))
  }

  func testListToolsNamesAllSeven() {
    for tool in ToolID.allCases {
      XCTAssertTrue(SpokenMessage.toolsList.contains(tool.title), tool.title)
    }
    XCTAssertTrue(SpokenMessage.toolsList.hasPrefix("SpeakUp has seven tools."))
  }

  func testHandsFreeListsTheToolsWithTheirCommands() {
    XCTAssertEqual(
      HandsFreeTool.allCases.map(\.command),
      [.read, .openMail, .openLabels, .openWatch, .openAsk, .openLight, .openReminders, .status, .openSettings])
    for tool in ToolID.allCases {
      XCTAssertEqual(HandsFreeTool(tool).tool, tool)
    }
  }

  func testAddressedTextFollowsTheWakeWordRules() {
    XCTAssertEqual(VoiceCommandParser.addressedText("how much", context: camera), "how much")
    XCTAssertEqual(VoiceCommandParser.addressedText("reader, how much", context: camera), "how much")
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "A bill from Northgate Energy.")
    XCTAssertNil(VoiceCommandParser.addressedText("how much", context: speaking), "needs the wake word while speaking")
    XCTAssertEqual(VoiceCommandParser.addressedText("reader how much", context: speaking), "how much")
    let book = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "Reader, how much is it, she asked.")
    XCTAssertNil(VoiceCommandParser.addressedText("reader how much", context: book), "that's the app's own voice")
    XCTAssertNil(VoiceCommandParser.addressedText("reader", context: camera))
  }

  // MARK: The App Store build (no glasses)

  func testStoreBuildHelpDoesNotOfferTheGlasses() {
    for screen in [VoiceScreen.welcome, .camera] {
      var context = VoiceContext(screen: screen)
      context.glassesSupported = false
      let help = VoiceCommandParser.helpLine(context: context)
      for glasses in ["connect", "use the glasses", "glasses display", "disconnect"] {
        XCTAssertFalse(help.contains(glasses), "\(glasses) in \(help)")
      }
    }
    XCTAssertTrue(VoiceCommandParser.helpLine(context: VoiceContext(screen: .welcome)).contains("connect"), "the Beta still offers it")
  }

  func testStoreBuildTipsDoNotOfferTheGlasses() {
    let situations: [CoachSituation] = [
      .welcome, .welcomeRetry, .welcomeConnected, .notLinked, .noGlasses, .glassesNotReady, .ready, .afterReading, .paused,
      .readyWithPhone, .phoneCameraBlocked,
    ]
    for situation in situations {
      for verbosity in [Verbosity.short, .normal] {
        let line = VoiceCoachLines.line(
          for: situation, tip: 0, isLast: false, wakeWord: false, verbosity: verbosity, glassesSupported: false)
        XCTAssertFalse(line.lowercased().contains("connect"), "\(situation): \(line)")
        XCTAssertFalse(line.lowercased().contains("meta ai"), "\(situation): \(line)")
      }
    }
  }
}

// MARK: - Text for Ask

@MainActor
final class ToolsPublishTextTests: XCTestCase {
  func testALabelsTextIsPublishedButNeverAMedicines() {
    let store = RecentText(defaults: nil)
    let labels = LabelsTool(productSource: NoProductLookups(), today: { CivilDate(2026, 11, 7) })
    labels.recentText = store
    labels.addViewForTesting([LabelLine(text: "OAT CRUNCH", height: 60), LabelLine(text: "Ingredients: oats, honey.", height: 18)])
    XCTAssertEqual(store.snapshot(source: .labels)?.fullText, "OAT CRUNCH\nIngredients: oats, honey.")
    labels.addViewForTesting([
      LabelLine(text: "PARACETAMOL", height: 60, confidence: 0.95), LabelLine(text: "500 mg Tablets", height: 30, confidence: 0.95),
      LabelLine(text: "Dosage: adults take 2 tablets every 4 hours.", height: 16, confidence: 0.9),
    ])
    XCTAssertTrue(labels.isMedicine)
    XCTAssertNil(store.snapshot(source: .labels), "a medicine label takes back what the pack published")
  }

  func testAReadPageIsPublishedForAsk() async throws {
    let store = RecentText(defaults: nil)
    let reader = TextReader()
    reader.recentText = store
    let camera = FakeToolCamera()
    camera.latestReadFrame = ReadFrame(image: Self.page(), arrivedAt: BenchClock.uptimeNanoseconds())
    reader.source = camera
    reader.read()
    for _ in 0..<300 where store.snapshot(source: .read) == nil { try await Task.sleep(for: .milliseconds(20)) }
    reader.stop()
    Announcer.shared.stop()
    let text = try XCTUnwrap(store.snapshot(source: .read)?.fullText)
    XCTAssertTrue(text.lowercased().contains("library"), text)
    withExtendedLifetime(camera) {}
  }

  /// A clean page of big black print, which Vision reads in the Simulator.
  private static func page() -> UIImage {
    let size = CGSize(width: 1200, height: 900)
    return UIGraphicsImageRenderer(size: size).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let text = "The library opens at nine o'clock.\nBooks are due back in two weeks.\nPlease return them on time."
      let style = NSMutableParagraphStyle()
      style.lineSpacing = 24
      (text as NSString).draw(
        in: CGRect(x: 80, y: 160, width: 1040, height: 640),
        withAttributes: [.font: UIFont.systemFont(ofSize: 56, weight: .regular), .foregroundColor: UIColor.black, .paragraphStyle: style])
    }
  }
}

// MARK: - J2: "switch to <tool>" and import by voice

@MainActor
final class SwitchAndImportPhraseTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera)

  private func parse(_ text: String, _ context: VoiceContext? = nil) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context ?? camera)
  }

  func testSwitchToOpensEachTool() {
    let expected: [(String, VoiceCommand)] = [
      ("switch to read text", .openReader), ("switch to the reader", .openReader), ("go to read text", .openReader),
      ("switch to mail reader", .openMail), ("go to the mail reader", .openMail), ("switch to labels", .openLabels),
      ("switch to watch for text", .openWatch), ("switch to ask", .openAsk), ("switch to light and colour", .openLight),
      ("switch to light and color", .openLight), ("switch to reminders", .openReminders), ("go to labels", .openLabels),
      ("can you switch to labels please", .openLabels), ("lets go to reminders", .openReminders),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  /// "switch to" is never a filler: it doesn't turn "read text" into reading, or take the camera.
  func testSwitchToKeepsItsNeighbours() {
    XCTAssertEqual(parse("switch to read text"), .command(.openReader), "opens Read text, doesn't read")
    XCTAssertEqual(parse("read text"), .command(.read))
    XCTAssertEqual(parse("switch to the phone"), .command(.usePhone))
    XCTAssertEqual(parse("switch to the phone camera"), .command(.usePhone))
    XCTAssertEqual(parse("switch to the glasses"), .command(.useGlasses))
    XCTAssertEqual(parse("go to the main menu"), .command(.mainMenu))
    XCTAssertEqual(parse("go back"), .command(.back))
    XCTAssertEqual(parse("go to step 3"), .ignored(.unrecognized), "Read text's step phrase, not the app's")
    XCTAssertEqual(parse("switch to"), .ignored(.unrecognized))
    XCTAssertEqual(parse("switch to settings"), .ignored(.unrecognized))
  }

  func testImportPhrases() {
    let expected: [(String, VoiceCommand)] = [
      ("read a photo", .readPhoto), ("read a picture", .readPhoto), ("read a photo from my library", .readPhoto),
      ("please read a screenshot", .readPhoto), ("read a file", .readFile), ("read a PDF", .readFile),
      ("read a document", .readFile), ("import", .readPhotoOrFile), ("read a photo or PDF", .readPhotoOrFile),
      ("read what I shared", .readShared),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  /// "read" stays reading, and the tools' own "read the ..." stay theirs.
  func testImportDoesNotTakeOtherReads() {
    XCTAssertEqual(parse("read"), .command(.read))
    XCTAssertEqual(parse("read this"), .command(.read))
    XCTAssertEqual(parse("read the text"), .command(.read))
    XCTAssertEqual(parse("read the letter"), .command(.openMail))
    XCTAssertEqual(parse("read a letter"), .command(.openMail))
    XCTAssertEqual(parse("read the label"), .command(.openLabels))
    XCTAssertEqual(parse("read my mail"), .command(.openMail))
    for phrase in ["read a photo", "read a file", "read a pdf", "import"] {
      XCTAssertNil(ReadTextPhrases.command(for: phrase), phrase)
      XCTAssertNil(LabelsGrammar.parse(phrase), phrase)
      XCTAssertNil(LetterGrammar.parse(phrase), phrase)
      XCTAssertNil(ToolHub.globalLetterCommand(phrase), phrase)
    }
  }

  func testImportOnlyFromTheMainScreen() {
    XCTAssertEqual(parse("read a photo", VoiceContext(screen: .welcome)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("read a file", VoiceContext(screen: .home)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("reader, read a photo", VoiceContext(screen: .camera, isSpeaking: true)), .command(.readPhoto))
    XCTAssertEqual(parse("read a photo", VoiceContext(screen: .camera, addressed: true)), .command(.readPhoto), "push to talk")
  }

  func testHelpOffersReadAPhotoOnce() {
    let help = VoiceCommandParser.helpLine(context: camera)
    XCTAssertTrue(help.contains("read a photo"), help)
    XCTAssertFalse(help.contains("import"), help)
    XCTAssertTrue(SpokenMessage.toolsList.contains("say read a photo, or read a file."))
  }

  func testEachImportCommandAsksForItsPicker() {
    XCTAssertEqual(ImportPicker.request(for: .readPhoto), .photo)
    XCTAssertEqual(ImportPicker.request(for: .readFile), .file)
    XCTAssertEqual(ImportPicker.request(for: .readPhotoOrFile), .choice)
    XCTAssertEqual(ImportPicker.request(for: .readShared), .choice)
    XCTAssertNil(ImportPicker.request(for: .read))
    for request in [ImportPicker.Request.photo, .file, .choice] {
      let line = SpokenMessage.importOpening(request)
      XCTAssertTrue(line.contains("VoiceOver or Voice Control"), line)
      XCTAssertLessThanOrEqual(line.split(separator: " ").count, 25, line)
    }
  }

  func testAPickerRequestIsTakenOnceAndExpires() {
    var now = Date(timeIntervalSince1970: 1000)
    let picker = ImportPicker(maxAge: 15) { now }
    XCTAssertNil(picker.consume())
    picker.request(.photo)
    picker.request(.file)
    XCTAssertEqual(picker.consume(), .file, "latest wins")
    XCTAssertNil(picker.consume(), "once")
    picker.request(.choice)
    now += 16
    XCTAssertNil(picker.consume(), "too old")
    XCTAssertNil(picker.pending)
  }
}

@MainActor
final class SwitchAndImportRoutingTests: XCTestCase {
  private var fakes: [ToolID: FakeTool] = [:]
  private var hub: ToolHub!

  override func setUp() async throws {
    try await super.setUp()
    fakes = [:]
    for id in ToolID.allCases { fakes[id] = FakeTool(id) }
    let fakes = fakes
    hub = ToolHub(source: FakeToolCamera()) { fakes[$0]! }
  }

  override func tearDown() async throws {
    hub.close(announce: false)
    Announcer.shared.stop()
    hub = nil
    try await super.tearDown()
  }

  private func route(_ text: String) -> Bool {
    guard case .command(let command) = VoiceCommandParser.parse(text, context: VoiceContext(screen: .camera)) else {
      return hub.route(text, command: nil)
    }
    return hub.route(text, command: command)
  }

  /// "switch to ..." opens the tool with another tool open, even one that would take the words.
  func testSwitchToOpensTheToolFromInsideAnother() {
    hub.open(.mail)
    fakes[.mail]?.takes = ["switch to labels", "switch to read text", "go to the mail reader"]
    XCTAssertTrue(route("switch to labels"))
    XCTAssertEqual(hub.openTool, .labels)
    XCTAssertTrue(route("switch to read text"))
    XCTAssertEqual(hub.openTool, .read)
    XCTAssertTrue(route("go to the mail reader"))
    XCTAssertEqual(hub.openTool, .mail)
    XCTAssertEqual(fakes[.mail]?.heard, [], "the mail reader never saw them")
  }

  /// The import phrases go to the screen (which closes the tool), never to the open tool.
  func testImportGoesToTheScreenWithAToolOpen() {
    for tool in ToolID.allCases {
      hub.open(tool)
      fakes[tool]?.takes = ["read a photo", "read a file", "import", "read what i shared"]
      for phrase in ["read a photo", "read a file", "import", "read what I shared"] {
        XCTAssertFalse(route(phrase), "\(phrase) in \(tool)")
      }
      XCTAssertEqual(fakes[tool]?.heard, [], "\(tool) heard an import phrase")
      XCTAssertEqual(hub.openTool, tool, "the screen closes it, not the hub")
    }
  }

  func testImportFromTheHomeGoesToTheScreen() {
    XCTAssertNil(hub.openTool)
    XCTAssertFalse(route("read a photo"))
    XCTAssertNil(hub.openTool)
  }
}

/// Review fix: "switch to colour" must open colour mode, not the light tone.
@MainActor
final class SwitchToColourTests: XCTestCase {
  func testSwitchToColourOpensColourMode() {
    for phrase in ["switch to colour", "switch to color", "go to colour", "go to color"] {
      XCTAssertEqual(LightTool.mode(forOpeningPhrase: phrase), .colour, phrase)
    }
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "switch to light"), .probe)
    XCTAssertEqual(LightTool.mode(forOpeningPhrase: "switch to light and colour"), .probe)
  }
}
