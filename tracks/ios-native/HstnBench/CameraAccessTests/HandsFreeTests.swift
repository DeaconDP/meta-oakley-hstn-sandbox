/*
 * HandsFreeTests - hands-free mode's pure parts (grammar, first-run rule, launch URL, the card and
 * its throttle), GlassesDisplaySink with a fake display, and DATGlassesDisplay against
 * MockDeviceKit's Meta Ray-Ban Display (notes/hands-free-mode.md)
 *
 * VoiceControl's toolbox, push to talk and hands-free commands are in VoiceTests.swift
 * (HandsFreeVoiceControlTests), next to its fakes.
 */

@testable import CameraAccess
import Foundation
import MWDATCore
import MWDATMockDevice
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class HandsFreeGrammarTests: XCTestCase {
  private func parse(_ text: String, _ context: VoiceContext = VoiceContext(screen: .camera)) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context)
  }

  func testNewPhrasesOnEveryScreen() {
    let expected: [(String, VoiceCommand)] = [
      ("main menu", .mainMenu), ("go home", .mainMenu),
      ("what tools are there", .listTools), ("list tools", .listTools), ("list features", .listTools),
      ("where am I", .whereAmI), ("what screen is this", .whereAmI),
      ("close the app", .closeApp), ("quit", .closeApp), ("goodbye", .closeApp), ("bye", .closeApp),
      ("end session", .closeApp), ("end the session", .closeApp), ("exit the app", .closeApp), ("quit speak up", .closeApp),
      ("short answers", .shortAnswers), ("normal answers", .normalAnswers), ("detailed answers", .detailedAnswers),
      ("glasses display on", .glassesDisplayOn), ("glasses display off", .glassesDisplayOff),
      ("hands-free on", .handsFreeOn), ("start hands free", .handsFreeOn), ("voice mode", .handsFreeOn),
      ("hands-free off", .handsFreeOff), ("touch mode", .handsFreeOff), ("stop listening for good", .handsFreeOff),
    ]
    for screen in [VoiceScreen.welcome, .home, .camera] {
      for (text, command) in expected {
        XCTAssertEqual(parse(text, VoiceContext(screen: screen)), .command(command), "\(text) on \(screen)")
      }
    }
  }

  /// Bare "exit" stays free: Watch looks for it ("what should I watch for?" "exit").
  func testBareExitDoesNotEndTheSession() {
    XCTAssertNotEqual(parse("exit"), .command(.closeApp))
    XCTAssertNotEqual(parse("watch for exit"), .command(.closeApp))
  }

  func testScreenPhrases() {
    XCTAssertEqual(parse("open settings"), .command(.openSettings))
    XCTAssertEqual(parse("close settings"), .command(.close))
    XCTAssertEqual(parse("open the reader"), .command(.openReader))
    XCTAssertEqual(parse("disconnect my glasses"), .command(.disconnect))
    XCTAssertEqual(parse("back"), .command(.back), "back works without a page: it leaves settings or names the menu")
    XCTAssertEqual(parse("disconnect", VoiceContext(screen: .home)), .command(.disconnect))
    XCTAssertEqual(parse("open settings", VoiceContext(screen: .welcome)), .ignored(.unavailableHere))
  }

  /// "stop listening for good" must not be heard as plain "stop".
  func testStopListeningForGoodIsNotStop() {
    XCTAssertEqual(parse("stop listening for good"), .command(.handsFreeOff))
    XCTAssertEqual(parse("stop"), .command(.stop))
  }

  /// The wake word alone is still "reader, ..." with nothing after it.
  func testReaderAloneIsStillTheWakeWord() {
    XCTAssertEqual(parse("reader"), .notUnderstood)
    XCTAssertEqual(parse("reader, main menu"), .command(.mainMenu))
  }

  func testPushToTalkCountsAsTheWakeWord() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, requiresWakeWord: true, addressed: true)
    XCTAssertEqual(parse("read", speaking), .command(.read))
    XCTAssertEqual(parse("make me a sandwich", VoiceContext(screen: .camera, addressed: true)), .notUnderstood)
  }

  func testQuestionsOpenYesAndNoAnywhere() {
    XCTAssertEqual(parse("yes"), .ignored(.unavailableHere))
    let asking = VoiceContext(screen: .camera, awaitingAnswer: true)
    XCTAssertEqual(parse("yes", asking), .command(.yes))
    XCTAssertEqual(parse("no thanks", asking), .command(.no))
    XCTAssertEqual(parse("yes", VoiceContext(screen: .home, awaitingAnswer: true)), .command(.yes))
  }

  func testEveryCommandHasAPhraseThatParsesBackToIt() {
    for command in VoiceCommand.allCases {
      let context = VoiceContext(screen: command == .no || command == .yes ? .welcome : .camera, hasReadSentences: true)
      XCTAssertEqual(parse(command.phrase, context), .command(command), command.rawValue)
    }
  }

  func testHelpIsInShortGroups() {
    let line = VoiceCommandParser.helpLine(context: VoiceContext(screen: .home))
    XCTAssertTrue(line.hasPrefix("You can say these. Here: connect, use the phone, status."), line)
    XCTAssertTrue(line.contains("Anywhere: main menu, list tools, where am I."))
    XCTAssertTrue(line.contains("hands-free on"), "the toolbox is offered hands-free on")
  }
}

final class HandsFreeModeRuleTests: XCTestCase {
  func testFirstRunFollowsVoiceOverOnce() {
    XCTAssertEqual(HandsFreeMode.firstRunChoice(hasChoice: false, voiceOverRunning: true), true)
    XCTAssertEqual(HandsFreeMode.firstRunChoice(hasChoice: false, voiceOverRunning: false), false)
    XCTAssertNil(HandsFreeMode.firstRunChoice(hasChoice: true, voiceOverRunning: true))
  }

  func testLaunchURL() throws {
    for text in ["speakup://handsfree", "SpeakUp://HandsFree", "speakup://handsfree/", "speakup://hands-free"] {
      XCTAssertTrue(HandsFreeMode.isHandsFreeURL(try XCTUnwrap(URL(string: text))), text)
    }
    for text in ["hstnbench://handsfree", "speakup://read", "https://worldbuild.io/handsfree"] {
      XCTAssertFalse(HandsFreeMode.isHandsFreeURL(try XCTUnwrap(URL(string: text))), text)
    }
  }

  func testToolsMatchTheirCommands() {
    XCTAssertEqual(
      HandsFreeTool.allCases.map(\.command),
      [.read, .openMail, .openLabels, .openWatch, .openAsk, .openLight, .status, .openSettings])
  }
}

final class HandsFreeCardTests: XCTestCase {
  func testShortensAtAWordAndCapsHints() {
    let card = HandsFreeCard(
      title: "Reader", state: "Reading sentence 3 of 10 on a very long page of tiny print",
      hints: [.read, .status, .help, .mainMenu])
    XCTAssertLessThanOrEqual(card.state.count, HandsFreeCard.maxLineLength)
    XCTAssertTrue(card.state.hasSuffix("\u{2026}"))
    XCTAssertEqual(card.hints, [.read, .status, .help])
    XCTAssertEqual(card.hintLine, "Say: read · status · help")
  }

  func testThrottleSendsOnlyChangesAtMostTwiceASecond() {
    var throttle = CardThrottle()
    let start = Date(timeIntervalSince1970: 100)
    let a = HandsFreeCard(title: "Reader", state: "Ready")
    let b = HandsFreeCard(title: "Reader", state: "Reading")
    XCTAssertEqual(throttle.decide(a, now: start), .sendNow)
    throttle.sent(a, at: start)
    XCTAssertEqual(throttle.decide(a, now: start.addingTimeInterval(5)), .skip)
    XCTAssertEqual(throttle.decide(b, now: start.addingTimeInterval(0.1)), .sendAt(start.addingTimeInterval(0.5)))
    XCTAssertEqual(throttle.decide(b, now: start.addingTimeInterval(0.6)), .sendNow)
    throttle.reset()
    XCTAssertEqual(throttle.decide(a, now: start.addingTimeInterval(0.1)), .sendAt(start.addingTimeInterval(0.5)))
  }
}

// MARK: - GlassesDisplaySink with a fake display

@MainActor
private final class FakeDisplay: GlassesDisplayTarget {
  var sent: [HandsFreeCard] = []
  var clears = 0
  var detached = false
  var failing = false

  struct Broken: Error {}

  func send(_ card: HandsFreeCard, onCommand: @escaping @MainActor @Sendable (VoiceCommand) -> Void) async throws {
    if failing { throw Broken() }
    sent.append(card)
  }

  func clear() async { clears += 1 }
  func detach() { detached = true }
}

@MainActor
final class GlassesDisplaySinkTests: XCTestCase {
  private var now = Date(timeIntervalSince1970: 1000)
  private var allowed = true
  private var failures: [Bool] = []
  private var sink: GlassesDisplaySink!
  private var display: FakeDisplay!

  override func setUp() async throws {
    try await super.setUp()
    sink = GlassesDisplaySink(
      environment: GlassesDisplaySink.Environment(
        isAllowed: { [unowned self] in allowed },
        now: { [unowned self] in now },
        // A fake clock: waiting moves time on.
        sleep: { [unowned self] seconds in now = now.addingTimeInterval(seconds) },
        reportFailure: { [unowned self] _, speak in failures.append(speak) },
        perform: { _ in }))
    display = FakeDisplay()
  }

  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  private func card(_ state: String) -> HandsFreeCard { HandsFreeCard(title: "Reader", state: state) }

  func testSendsOnAttachThenOnlyChangesCoalescingFastOnes() async {
    sink.attach(display, showing: card("Ready"))
    await settle()
    XCTAssertEqual(display.sent.map(\.state), ["Ready"])
    sink.show(card("Ready"))
    await settle()
    XCTAssertEqual(display.sent.count, 1, "an unchanged card isn't sent again")
    sink.show(card("Finding text"))
    sink.show(card("Reading"))
    await settle()
    XCTAssertEqual(display.sent.map(\.state), ["Ready", "Reading"], "the in-between card is skipped")
    XCTAssertTrue(sink.isShowing)
  }

  func testNothingWithoutADisplayOrWhenNotAllowed() async {
    sink.show(card("Ready"))
    await settle()
    XCTAssertEqual(display.sent.count, 0)
    sink.attach(display, showing: card("Ready"))
    await settle()
    allowed = false
    sink.show(card("Reading"))
    await settle()
    XCTAssertEqual(display.sent.count, 1)
    XCTAssertEqual(display.clears, 1, "turning it off clears what was shown")
    XCTAssertFalse(sink.isShowing)
  }

  func testFailureIsSpokenOnceAndNeverThrows() async {
    display.failing = true
    sink.attach(display, showing: card("Ready"))
    await settle()
    now = now.addingTimeInterval(1)
    sink.show(card("Reading"))
    await settle()
    XCTAssertEqual(failures, [true, false])
    display.failing = false
    now = now.addingTimeInterval(1)
    sink.show(card("Finished"))
    await settle()
    XCTAssertEqual(display.sent.map(\.state), ["Finished"])
  }

  func testDetachStopsTheDisplay() {
    sink.attach(display, showing: card("Ready"))
    sink.detach()
    XCTAssertTrue(display.detached)
    XCTAssertNil(sink.target)
  }
}

// MARK: - The real Display API against the mock Ray-Ban Display

@MainActor
final class DATGlassesDisplayMockTests: XCTestCase {
  private var selector: AutoDeviceSelector?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
    glasses.powerOn()
    glasses.don()
    try await Task.sleep(for: .seconds(1))
  }

  override func tearDown() async throws {
    await MockDeviceKit.shared.disable()
    try await super.tearDown()
  }

  func testTheCardRendersOnTheMockDisplay() async throws {
    let selector = AutoDeviceSelector(wearables: Wearables.shared, filter: { $0.supportsDisplay() })
    self.selector = selector
    for await device in selector.activeDeviceStream() where device != nil { break }
    let session = try Wearables.shared.createSession(deviceSelector: selector)
    defer { session.stop() }
    try session.start()
    for _ in 0..<100 where session.state != .started {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(session.state, .started)
    XCTAssertEqual(session.device?.supportsDisplay(), true, "the mock reports a display")

    let display = try DATGlassesDisplay.attach(to: session)
    defer { display.detach() }
    let card = HandsFreeCard(title: "Reader", state: "Listening", heard: "Heard: read", hints: [.read, .status, .mainMenu])
    try await display.send(card) { _ in }
    // A second, different card replaces the first.
    try await display.send(HandsFreeCard(title: "Reader", state: "Reading sentence 1 of 3")) { _ in }
  }
}
