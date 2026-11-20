/*
 * VoiceClashTests - the short words that several features want at once, after letters, reminders,
 * food check and phone reading were merged (ToolHub's routing order, VoiceQuestions):
 * - "yes" / "no": the app's own question, the torch offer, and a reminder added since.
 * - "done" / "snooze": a reminder that just went off, against the app's close.
 * - "next step" / "previous step" / "repeat step": Read text's steps and Labels' cooking steps, each
 *   for the open tool only.
 * - "big text" and "remind me ..." from inside other tools.
 * - No new phrase is one of the app's always-on commands, and help stays short (no glasses in the
 *   App Store build).
 * The mail reader's own clashes are in LettersTests (LetterVoiceClashTests), next to its fixtures.
 */

import SwiftUI
import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Fakes

@MainActor
private final class ClashCamera: ReadFrameSource {
  var latestReadFrame: ReadFrame?
  var cameraKind: CameraKind { .phone }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
}

@MainActor
private final class ClashNotifications: ReminderNotifying {
  func requestPermission() async -> Bool { true }
  func permission() async -> Bool? { true }
  func add(_ notification: ReminderNotification) async -> Bool { true }
  func remove(ids: [String]) {}
}

/// A tool that takes only the phrases it is given.
@MainActor
private final class ClashTool: SpeakUpTool {
  let toolID: ToolID
  var takes: Set<String> = []
  var heard: [String] = []
  init(_ id: ToolID) { toolID = id }
  func start(source: ReadFrameSource) {}
  func stop() {}
  func handle(transcript: String) -> Bool {
    heard.append(transcript)
    return takes.contains(transcript.lowercased())
  }
  var helpLine: String { "" }
  func makePanel() -> AnyView { AnyView(EmptyView()) }
}

/// The real Labels voice (grammar, cooking steps), without the camera work its start does.
@MainActor
private final class LabelsVoiceOnly: SpeakUpTool {
  let labels: LabelsTool
  let toolID: ToolID = .labels
  init(_ labels: LabelsTool) { self.labels = labels }
  func start(source: ReadFrameSource) {}
  func stop() {}
  func handle(transcript: String) -> Bool { labels.handle(transcript: transcript) }
  var helpLine: String { labels.helpLine }
  func makePanel() -> AnyView { AnyView(EmptyView()) }
}

/// Stands in for ToolHub under VoiceControl: takes "yes" only while its own question is newest.
@MainActor
private final class AskingRouter: VoiceToolRouting {
  let questions: VoiceQuestions
  var heard: [String] = []
  init(_ questions: VoiceQuestions) { self.questions = questions }
  func route(_ text: String, command: VoiceCommand?) -> Bool {
    heard.append(text)
    guard command == .yes || command == .no, questions.isNewest(.mail) else { return false }
    questions.settle(.mail)
    return true
  }
}

/// The phone camera seeing a dark frame, with a torch.
@MainActor
private final class DarkPhone: ReadFrameSource, ReadLightSource {
  let image: UIImage = {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 640), format: format).image { context in
      UIColor(white: 0.03, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 480, height: 640))
    }
  }()
  var torchOn = false
  var sceneEV: Double? { nil }
  var cameraKind: CameraKind { .phone }
  var latestReadFrame: ReadFrame? { ReadFrame(image: image, arrivedAt: BenchClock.uptimeNanoseconds()) }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
  var canOfferTorch: Bool { !torchOn }
  func turnTorchOn() { torchOn = true }
}

private enum ClashClock {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()
  /// Friday 20 November 2026, 2 pm.
  static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 14))!
  static let clock = ReminderClock(now: { ClashClock.now }, calendar: calendar)
}

@MainActor
private func waitUntil(_ polls: Int = 250, _ condition: () -> Bool) async {
  // Counted in polls, not wall time: the Simulator's first speech can stall the main actor.
  var left = polls
  while !condition(), left > 0 {
    left -= 1
    try? await Task.sleep(for: .milliseconds(20))
  }
}

private func readLine(_ text: String, y: CGFloat) -> ReadLine {
  ReadLine(
    words: text.split(separator: " ").map { ReadWord(text: String($0), confidence: 0.95) },
    box: CGRect(x: 40, y: y, width: CGFloat(text.count) * 14, height: 30))
}

// MARK: - Who asked last

@MainActor
final class VoiceQuestionsTests: XCTestCase {
  func testTheNewestQuestionWins() {
    let questions = VoiceQuestions()
    questions.ask(.app)
    questions.ask(.mail)
    XCTAssertTrue(questions.isNewest(.mail))
    XCTAssertFalse(questions.isNewest(.app, among: VoiceAsker.yesOrNo))
    XCTAssertEqual(questions.newest, .mail)
    questions.settle(.mail)
    XCTAssertTrue(questions.isNewest(.app, among: VoiceAsker.yesOrNo))
    // Asking again makes it newest again.
    questions.ask(.torch)
    questions.ask(.app)
    XCTAssertTrue(questions.isNewest(.app))
    XCTAssertFalse(questions.isNewest(.torch))
  }

  func testOnlyTheRivalsNamedCount() {
    let questions = VoiceQuestions()
    questions.ask(.app)
    questions.ask(.reminderAlert)
    XCTAssertTrue(questions.isNewest(.app, among: VoiceAsker.yesOrNo), "a reminder going off isn't a yes-or-no question")
    XCTAssertFalse(questions.isNewest(.app))
  }

  func testMovingOnDropsOnlyTheReminderReplies() {
    let questions = VoiceQuestions()
    questions.ask(.torch)
    questions.ask(.reminderAdded)
    questions.ask(.reminderAlert)
    questions.movedOn()
    XCTAssertTrue(questions.isWaiting(.torch))
    XCTAssertFalse(questions.isWaiting(.reminderAlert))
    XCTAssertFalse(questions.isWaiting(.reminderAdded))
  }
}

// MARK: - "yes" and "no"

@MainActor
final class YesNoClashTests: XCTestCase {
  private func inertEnvironment() -> VoiceControl.Environment {
    VoiceControl.Environment(
      isInert: true, makePhoneListener: { _ in nil }, phoneLocale: { "en-GB" }, phoneMicPermission: { .granted },
      speechPermission: { .granted }, requestPermissions: {}, say: { _, _, _, finish in finish?(true) }, playEarcon: { _ in },
      isSpeaking: { false }, textBeingSpoken: { "" }, stopSpeech: {}, repeatLast: {}, hasReadSentences: { false },
      micHearsVoiceOver: { _ in false }, followsVoiceOverRate: { false }, setIdleTimerDisabled: { _ in }, glassesSpeechEnabled: { false },
      now: { Date() })
  }

  /// The app's yes-or-no (camera access, glasses registration) gets "yes" first, unless a tool
  /// asked its own question since. Then the tool hears it first, and the app's waits.
  func testTheAppsQuestionTakesYesUnlessAToolAskedSince() {
    let suite = "YesNoClashTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let questions = VoiceQuestions()
    let control = VoiceControl(environment: inertEnvironment(), preferences: A11yPreferences(defaults: defaults))
    control.questions = questions
    let router = AskingRouter(questions)
    control.tools = router
    control.setScreen(.camera) { _ in true }
    var answers: [String] = []

    control.ask(yes: { answers.append("app yes") }, no: { answers.append("app no") })
    control.inject(transcript: "yes")
    XCTAssertEqual(answers, ["app yes"])
    XCTAssertEqual(router.heard, [], "the app asked last, so the tools never saw it")

    control.ask(yes: { answers.append("app yes") }, no: { answers.append("app no") })
    questions.ask(.mail)  // The mail reader offers a reminder after the app asked.
    control.inject(transcript: "yes")
    XCTAssertEqual(router.heard, ["yes"], "the newer question hears yes first")
    XCTAssertEqual(answers, ["app yes"])
    XCTAssertTrue(control.isAwaitingAnswer, "the app's question still waits")

    control.inject(transcript: "no")
    XCTAssertEqual(answers, ["app yes", "app no"], "with the tool's question answered, the app's is next")
    XCTAssertFalse(control.isAwaitingAnswer)
    XCTAssertFalse(questions.isWaiting(.app))
    withExtendedLifetime(router) {}
  }

  /// "Shall I turn the torch on?" takes yes only while it is the newest question, and it goes when
  /// Read text closes.
  func testTheTorchOfferTakesYesOnlyWhileNewestAndLapsesOnClose() async {
    let questions = VoiceQuestions()
    let reader = TextReader()
    reader.recentText = RecentText(defaults: nil)
    reader.questions = questions
    let phone = DarkPhone()
    reader.source = phone
    defer {
      reader.stop()
      Announcer.shared.stop()
    }
    reader.read()
    await waitUntil { reader.phase == .guided }
    XCTAssertTrue(reader.torchOfferPending)
    XCTAssertTrue(questions.isWaiting(.torch))

    // "Remind me at 6 to ..." was answered after the offer: "yes" isn't for the torch now.
    questions.ask(.reminderAdded)
    XCTAssertFalse(ReadTextVoice.handle("yes", reader: reader))
    XCTAssertFalse(ReadTextVoice.handle("no", reader: reader))
    XCTAssertFalse(phone.torchOn)
    XCTAssertTrue(reader.torchOfferPending, "the button is still there to tap")

    questions.settle(.reminderAdded)  // Undone.
    XCTAssertTrue(reader.torchOfferTakesAnswer)

    // Closing Read text (or switching tools) drops the offer.
    ReadTextTool(reader: reader).stop()
    XCTAssertFalse(reader.torchOfferPending)
    XCTAssertFalse(questions.isWaiting(.torch))
    XCTAssertFalse(ReadTextVoice.handle("yes", reader: reader))
    XCTAssertFalse(phone.torchOn)
  }
}

// MARK: - Reminders against the app's words

@MainActor
final class ReminderReplyClashTests: XCTestCase {
  private var fakes: [ToolID: ClashTool] = [:]
  private var store: ReminderStore!
  private var alerts: ReminderAlerts!
  private var reminders: RemindersTool!
  private var hub: ToolHub!
  private var lines: [String] = []

  override func setUp() async throws {
    try await super.setUp()
    VoiceQuestions.shared.reset()
    store = ReminderStore(fileURL: nil, notifier: ClashNotifications(), clock: ClashClock.clock)
    alerts = ReminderAlerts()
    let store = store!
    alerts.store = { store }
    alerts.now = { ClashClock.now }
    lines = []
    alerts.speak = { [weak self] line, _ in self?.lines.append(line) }
    reminders = RemindersTool(store: store, alerts: alerts, activity: ActivityLog(now: { ClashClock.now })) { [weak self] line, _ in
      self?.lines.append(line)
    }
    fakes = [:]
    for id in ToolID.allCases where id != .reminders { fakes[id] = ClashTool(id) }
    let fakes = fakes
    let reminders = reminders!
    hub = ToolHub(source: ClashCamera()) { id -> any SpeakUpTool in
      if id == .reminders { return reminders }
      return fakes[id]!
    }
    hub.alerts = alerts
  }

  override func tearDown() async throws {
    hub.close(announce: false)
    Announcer.shared.stop()
    VoiceQuestions.shared.reset()
    try await super.tearDown()
  }

  private func goOff() async throws {
    _ = await reminders.perform("remind me at 6 to take the bins out")
    let id = try XCTUnwrap(store.reminders.first?.id)
    XCTAssertTrue(alerts.went(off: ReminderStore.notificationID(reminder: id), speakIt: true))
  }

  /// "done" just after a reminder goes off answers it, from inside any tool. Once answered, "done"
  /// is the app's close again.
  func testDoneAnswersAReminderThatJustWentOffThenMeansCloseAgain() async throws {
    hub.open(.mail)
    try await goOff()
    XCTAssertTrue(hub.route("done", command: .close))
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertEqual(lines.last, "Done: take the bins out.")
    XCTAssertEqual(hub.openTool, .mail, "the mail reader stays open")
    XCTAssertFalse(hub.route("done", command: .close), "close is the app's again")
  }

  /// Opening or closing a tool after it went off means the user moved on: "done" closes again.
  /// "Snooze" means nothing else, so it still works for the 30 minutes.
  func testDoneMeansCloseOnceTheUserMovedOnButSnoozeStillWorks() async throws {
    try await goOff()
    hub.open(.labels)
    XCTAssertFalse(hub.route("done", command: .close), "done closes Labels")
    XCTAssertEqual(store.reminders.count, 1)
    XCTAssertTrue(hub.route("snooze", command: nil))
    await waitUntil { store.reminders.first?.fireDate == ClashClock.now.addingTimeInterval(10 * 60) }
    XCTAssertEqual(store.reminders.first?.fireDate, ClashClock.now.addingTimeInterval(10 * 60))
  }

  /// A question asked after the reminder went off is the newer one: "done" isn't the reminder's.
  func testANewerQuestionTakesDoneAway() async throws {
    try await goOff()
    VoiceQuestions.shared.ask(.mail)
    XCTAssertFalse(alerts.takesReply("done"))
    VoiceQuestions.shared.settle(.mail)
    XCTAssertTrue(alerts.takesReply("done"))
  }

  /// "Remind me ..." inside another tool answers in place; "undo" right after takes it back from
  /// that tool. From the home it opens Reminders.
  func testRemindMeInsideAToolAnswersInPlaceAndUndoWorksThere() async {
    hub.open(.mail)
    XCTAssertTrue(hub.route("remind me at 6 pm to call the bank", command: nil))
    XCTAssertEqual(hub.openTool, .mail, "the letter stays on screen")
    await waitUntil { lines.last?.hasPrefix("Reminder at") == true }
    XCTAssertEqual(store.reminders.count, 1)
    XCTAssertEqual(lines.last, "Reminder at 6 pm today: call the bank. Say undo to cancel.")
    XCTAssertTrue(hub.route("undo", command: nil))
    await waitUntil { store.reminders.isEmpty }
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertFalse(hub.route("undo", command: nil), "nothing left to undo outside Reminders")

    hub.close(announce: false)
    XCTAssertTrue(hub.route("remind me in 20 minutes to read the letter", command: nil))
    XCTAssertEqual(hub.openTool, .reminders)
  }

  /// Switching tools after adding a reminder means "undo" is no longer an answer outside Reminders.
  func testUndoLapsesWhenTheUserMovesOn() async {
    hub.open(.mail)
    XCTAssertTrue(hub.route("remind me at 6 pm to call the bank", command: nil))
    await waitUntil { lines.last?.hasPrefix("Reminder at") == true }
    hub.open(.labels)
    XCTAssertFalse(hub.route("undo", command: nil))
    XCTAssertEqual(store.reminders.count, 1)
  }
}

// MARK: - Steps, big text and reminders inside other tools

@MainActor
final class ToolWordsClashTests: XCTestCase {
  private var fakes: [ToolID: ClashTool] = [:]
  private var reader: TextReader!
  private var labels: LabelsTool!
  private var store: ReminderStore!
  private var hub: ToolHub!
  private var suite = ""

  override func setUp() async throws {
    try await super.setUp()
    VoiceQuestions.shared.reset()
    suite = "ToolWordsClashTests.\(UUID().uuidString)"
    reader = TextReader()
    reader.recentText = RecentText(defaults: nil)
    let now = ClashClock.now
    labels = LabelsTool(
      productSource: NoClashProducts(), today: { CivilDate(2026, 11, 20) }, myAllergens: MyAllergens(defaults: UserDefaults(suiteName: suite)!),
      reminders: { NoReminders() }, now: { now })
    labels.recentText = RecentText(defaults: nil)
    store = ReminderStore(fileURL: nil, notifier: ClashNotifications(), clock: ClashClock.clock)
    let reminders = RemindersTool(store: store, alerts: ReminderAlerts(), activity: ActivityLog(now: { ClashClock.now })) { _, _ in }
    fakes = [:]
    for id in [ToolID.mail, .watch, .ask, .light] { fakes[id] = ClashTool(id) }
    let fakes = fakes
    let readTool = ReadTextTool(reader: reader)
    let labelsVoice = LabelsVoiceOnly(labels)
    hub = ToolHub(source: ClashCamera()) { id -> any SpeakUpTool in
      switch id {
      case .read: return readTool
      case .labels: return labelsVoice
      case .reminders: return reminders
      default: return fakes[id]!
      }
    }
  }

  override func tearDown() async throws {
    hub.close(announce: false)
    reader.stop()
    Announcer.shared.stop()
    UserDefaults().removePersistentDomain(forName: suite)
    VoiceQuestions.shared.reset()
    try await super.tearDown()
  }

  private func readRecipe() async {
    let page = ReadPage(
      lines: [
        readLine("Flapjacks", y: 20), readLine("Method", y: 100), readLine("1. Melt the butter and syrup in a pan.", y: 160),
        readLine("2. Stir in the oats and press into a tin.", y: 200), readLine("3. Bake for 20 minutes.", y: 240),
      ], imageSize: CGSize(width: 1000, height: 1400))
    reader.read(pages: [ReadTextPage(page: page)], source: ReadTextSource(title: "A photo"))
    await waitUntil { reader.steps.hasPage }
  }

  private func packWithCooking() {
    labels.addViewForTesting(
      ["COOKING INSTRUCTIONS", "Oven cook: Preheat oven to 200°C / Gas Mark 6.", "Place on a baking tray.", "Cook for 20-25 mins."]
        .map { LabelLine(text: $0, height: 18, confidence: 0.95) })
  }

  /// "next step", "previous step" and "repeat step" move the open tool's steps only.
  func testStepWordsGoToTheOpenToolOnly() async {
    hub.open(.read)
    await readRecipe()
    reader.stop()
    XCTAssertTrue(hub.route("next step", command: nil))
    XCTAssertEqual(reader.steps.navigator.index, 0)

    hub.open(.labels)
    packWithCooking()
    XCTAssertTrue(hub.route("how do I cook it", command: nil))
    XCTAssertEqual(labels.stepIndex, 0)
    XCTAssertTrue(hub.route("next step", command: nil))
    XCTAssertTrue(hub.route("next step", command: nil))
    XCTAssertEqual(labels.stepIndex, 2)
    XCTAssertTrue(hub.route("previous step", command: nil))
    XCTAssertTrue(hub.route("repeat step", command: nil))
    XCTAssertEqual(labels.stepIndex, 1)
    XCTAssertEqual(reader.steps.navigator.index, 0, "Read text's place didn't move")

    hub.open(.read)
    XCTAssertTrue(hub.route("next step", command: nil))
    XCTAssertTrue(hub.route("repeat step", command: nil))
    XCTAssertEqual(reader.steps.navigator.index, 1)
    XCTAssertTrue(hub.route("next", command: .continueOn), "plain next moves the steps in step mode")
    XCTAssertEqual(reader.steps.navigator.index, 2)
    XCTAssertTrue(hub.route("previous step", command: nil))
    XCTAssertEqual(reader.steps.navigator.index, 1)
    XCTAssertEqual(labels.stepIndex, 1, "Labels' place didn't move")

    // A tool without steps: nobody takes them.
    hub.open(.mail)
    XCTAssertFalse(hub.route("next step", command: nil))
    XCTAssertFalse(hub.route("repeat step", command: nil))
    XCTAssertEqual(reader.steps.navigator.index, 1)
    XCTAssertEqual(labels.stepIndex, 1)
  }

  /// "big text" in the mail reader or Labels says where big text is; on the home it opens Read
  /// text's big text.
  func testBigTextOutsideReadText() {
    hub.open(.mail)
    XCTAssertTrue(hub.route("big text", command: nil))
    XCTAssertEqual(hub.openTool, .mail)
    hub.open(.labels)
    XCTAssertTrue(hub.route("large print", command: nil))
    XCTAssertEqual(hub.openTool, .labels)
    hub.close(announce: false)
    XCTAssertTrue(hub.route("big text", command: nil), "nothing read yet: Read text opens and says so")
    XCTAssertEqual(hub.openTool, .read)
    BigTextMirror.shared.hide(announce: false)
  }

  /// "Remind me ..." in Labels is a general reminder, except "remind me before it goes off".
  func testRemindMeInsideLabels() async {
    hub.open(.labels)
    XCTAssertTrue(hub.route("remind me tomorrow at 9 to buy milk", command: nil))
    XCTAssertEqual(hub.openTool, .labels)
    await waitUntil { store.reminders.count == 1 }
    XCTAssertEqual(store.reminders.first?.title.lowercased(), "buy milk")
    XCTAssertEqual(LabelsGrammar.parse("remind me before it goes off"), .remind)
    XCTAssertEqual(LabelsGrammar.parse("set a reminder"), .remind)
    XCTAssertNil(LabelsGrammar.parse("remind me to check the date on the milk"), "not an expiry question")
    XCTAssertNil(LabelsGrammar.parse("remind me at 6 to cook dinner"), "not a cooking question")
  }

  /// "Remind me ..." in the mail reader: its own reminder words stay its own; anything else is a
  /// general reminder answered in place.
  func testRemindMeInsideTheMailReader() async {
    let mail = MailTool(
      letters: LettersStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("clash-\(UUID().uuidString)"), defaults: nil),
      reminders: { NoReminders() }, online: { nil })
    XCTAssertFalse(mail.handle(transcript: "remind me at 6 pm to call the bank"))
    XCTAssertFalse(mail.handle(transcript: "remind me tomorrow at 9 to pay it"))
    XCTAssertEqual(LetterGrammar.parse("remind me three days before"), .remind(.daysBefore(3)))
    XCTAssertEqual(LetterGrammar.parse("remind me on Friday"), .remind(.weekday(6)))
  }
}

private struct NoClashProducts: ProductSource {
  func lookup(_ code: String) async -> ProductLookupResult { .failed("tests don't go online") }
}

// MARK: - No clashes with the app's words

final class NewPhrasesNoClashTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera, hasReadSentences: true)

  private static let newPhrases = [
    // Letters
    "my letters", "what letters do I have", "read the letter from Northgate Energy", "explain this letter", "what does this mean",
    "remind me three days before", "cancel the reminder", "forget all letters", "export my letters", "delete that letter",
    // Reminders
    "remind me at 6 to take the bins out", "remind me every day at 8 pm to take my evening pill", "what's due this week",
    "I took my evening pill", "did I take my evening pill", "when did I last take metformin", "what was I doing", "undo",
    "snooze", "snooze for 20 minutes", "mark it done", "cancel the bins reminder",
    // Food check
    "is this OK for me", "food check", "my allergens are peanuts and milk", "add sesame", "what are my allergens",
    "how do I cook it", "remind me before it goes off",
    // Reading with the phone
    "next step", "previous step", "repeat step", "what step am I on", "how many steps", "go to step 3", "big text", "big text off",
  ]

  /// None of the new phrases is one of the app's always-on commands, so the tools hear them.
  @MainActor
  func testNoNewPhraseIsAnAlwaysOnCommand() {
    for phrase in Self.newPhrases {
      if case .command(let command) = VoiceCommandParser.parse(phrase, context: camera) {
        XCTAssertFalse(ToolHub.alwaysGlobal.contains(command), "\(phrase) is the app's \(command)")
        XCTAssertNil(command.tool, "\(phrase) opens \(command)")
      }
    }
  }

  /// The one shared word: "done" is the app's close, and a reminder's reply only by recency.
  func testDoneIsCloseUnlessAReminderJustWentOff() {
    XCTAssertEqual(VoiceCommandParser.parse("done", context: camera), .command(.close))
    XCTAssertEqual(ReminderGrammar.parse("done"), .done)
    XCTAssertFalse(ReminderGrammar.worksFromAnywhere("done"), "only through ReminderAlerts' window")
  }

  /// The features don't take each other's phrases.
  @MainActor
  func testTheFeaturesDontTakeEachOthersPhrases() {
    for phrase in ["my letters", "what letters do I have", "read the letter from Northgate Energy"] {
      XCTAssertFalse(ReminderGrammar.worksFromAnywhere(phrase), phrase)
      XCTAssertNotNil(ToolHub.globalLetterCommand(phrase), phrase)
      XCTAssertNil(ReadTextPhrases.command(for: phrase), phrase)
    }
    for phrase in ["remind me at 6 to take the bins out", "what's due this week", "I took my evening pill", "what was I doing"] {
      XCTAssertNil(ToolHub.globalLetterCommand(phrase), phrase)
      XCTAssertNil(LabelsGrammar.parse(phrase), phrase)
      XCTAssertNil(LetterGrammar.parse(phrase), phrase)
      XCTAssertNil(ReadTextPhrases.command(for: phrase), phrase)
    }
    XCTAssertNil(ToolHub.globalLetterCommand("read the council letter"), "only ... letter from someone works from anywhere")
    XCTAssertNil(ToolHub.globalLetterCommand("read the letter"))
    XCTAssertTrue(ReminderGrammar.isUndo("undo that"))
    XCTAssertFalse(ReminderGrammar.isUndo("cancel the reminder"), "the mail reader's")
  }

  /// The open phrases for Reminders and the letters log don't collide.
  func testOpenRemindersAndMyLettersAreDifferent() {
    XCTAssertEqual(VoiceCommandParser.parse("my reminders", context: camera), .command(.openReminders))
    XCTAssertNotEqual(VoiceCommandParser.parse("my letters", context: camera), .command(.openReminders))
    XCTAssertNotEqual(VoiceCommandParser.parse("my letters", context: camera), .command(.openMail))
  }
}

// MARK: - Help

@MainActor
final class ShortHelpTests: XCTestCase {
  private static func words(_ line: String) -> Int { line.split(whereSeparator: \.isWhitespace).count }

  private var tools: [any SpeakUpTool] {
    [
      ReadTextTool(reader: TextReader()), MailTool(online: { nil }),
      LabelsTool(productSource: NoClashProducts(), today: { CivilDate(2026, 11, 20) }), WatchTool(defaults: UserDefaults(suiteName: "ShortHelpTests")!, haptic: {}),
      AskTool(), LightTool(), RemindersTool(store: nil, alerts: ReminderAlerts()) { _, _ in },
    ]
  }

  /// Every tool's help, with how to leave it, is short enough to hear in one go.
  func testEveryToolsHelpIsShort() {
    let tools = tools
    XCTAssertEqual(tools.map(\.toolID), ToolID.allCases)
    for tool in tools {
      let line = SpokenMessage.toolHelp(tool.toolID, tool.helpLine)
      XCTAssertLessThanOrEqual(Self.words(line), 40, line)
      XCTAssertFalse(line.lowercased().contains("glasses"), line)
    }
  }

  func testListToolsCoversSevenInShortLines() {
    XCTAssertTrue(SpokenMessage.toolsList.hasPrefix("SpeakUp has seven tools."))
    for tool in ToolID.allCases {
      XCTAssertTrue(SpokenMessage.toolsList.contains(tool.title), tool.title)
      XCTAssertLessThanOrEqual(Self.words(tool.summary), 14, tool.summary)
    }
    XCTAssertFalse(SpokenMessage.toolsList.lowercased().contains("glasses"))
    XCTAssertTrue(VoiceCommandParser.helpLine(context: VoiceContext(screen: .camera)).contains("light and colour, or reminders."))
  }

  /// The App Store build (SPEAKUP_NO_DAT) never mentions glasses in help or settings.
  func testTheStoreBuildNeverMentionsGlasses() {
    for screen in [VoiceScreen.welcome, .camera] {
      for handsFree in [false, true] {
        var context = VoiceContext(screen: screen, hasReadSentences: true, handsFree: handsFree)
        context.glassesSupported = false
        let help = VoiceCommandParser.helpLine(context: context)
        XCTAssertFalse(help.lowercased().contains("glasses"), help)
      }
    }
    XCTAssertFalse(SpokenMessage.settingsOpenedLine(glassesSupported: false).lowercased().contains("glasses"))
    XCTAssertTrue(SpokenMessage.settingsOpenedLine(glassesSupported: true).contains("glasses display off"), "the Beta still offers it")
    XCTAssertFalse(WatchWording.help(camera: .phone).lowercased().contains("glasses"))
    #if SPEAKUP_NO_DAT
      for line in [
        SpokenMessage.settingsOpened, SpokenMessage.mainMenuHome, SpokenMessage.mainMenuWelcome, SpokenMessage.readerNeedsGlasses,
        SpokenMessage.toolsListNotConnected, HandsFreeTool.settings.summary,
      ] {
        XCTAssertFalse(line.lowercased().contains("glasses"), line)
      }
    #endif
  }
}
