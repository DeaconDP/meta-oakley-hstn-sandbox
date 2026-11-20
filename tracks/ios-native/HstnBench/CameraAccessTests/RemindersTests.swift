/*
 * RemindersTests - the seventh tool (notes/reminders-ios.md): time phrases on a fixed clock and
 * time zone, the store and its file, upcoming(before:) order, dose refusals, the medicine log's
 * answers, reminders going off, "what was I doing?", and the ToolID wiring.
 *
 * The clock is Friday 20 November 2026, 2 pm in London (GMT).
 */

import SwiftUI
import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Fakes and helpers

@MainActor
private final class FakeNotifications: ReminderNotifying {
  var allowed: Bool? = true
  var asked = 0
  private(set) var added: [ReminderNotification] = []
  private(set) var removed: [String] = []

  func requestPermission() async -> Bool {
    asked += 1
    return allowed ?? false
  }
  func permission() async -> Bool? { allowed }
  func add(_ notification: ReminderNotification) async -> Bool {
    added.removeAll { $0.id == notification.id }
    added.append(notification)
    return true
  }
  func remove(ids: [String]) {
    removed += ids
    added.removeAll { ids.contains($0.id) }
  }
}

@MainActor
private final class NoCamera: ReadFrameSource {
  var latestReadFrame: ReadFrame?
  var cameraKind: CameraKind { .phone }
  func prepareStreamForReading() -> ReadStreamReadiness { .ready }
  func captureStillForReading() async -> UIImage? { nil }
}

@MainActor
private final class BlankTool: SpeakUpTool {
  let toolID: ToolID
  init(_ id: ToolID) { toolID = id }
  func start(source: ReadFrameSource) {}
  func stop() {}
  func handle(transcript: String) -> Bool { false }
  var helpLine: String { "" }
  func makePanel() -> AnyView { AnyView(EmptyView()) }
}

private enum Fixed {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()

  static func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  /// Friday 20 November 2026, 2 pm.
  static let now = date(11, 20, 14)
  static let clock = ReminderClock(now: { Fixed.now }, calendar: calendar)
  static var format: ReminderFormat { ReminderFormat(calendar: calendar, now: now) }
}

private func parse(_ text: String, known: [String] = []) -> ReminderIntent? {
  ReminderGrammar.parse(text, now: Fixed.now, calendar: Fixed.calendar, knownMedicines: known)
}

private func tempFile() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "reminders-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    .appending(path: "reminders.json")
}

// MARK: - Time phrases

final class ReminderTimeTests: XCTestCase {
  private func added(_ text: String) -> (String, ReminderWhen)? {
    guard case .add(let task, let when) = parse(text) else { return nil }
    return (task, when)
  }

  func testInSoManyMinutes() {
    XCTAssertEqual(added("remind me in 20 minutes to take the bins out")?.0, "take the bins out")
    XCTAssertEqual(added("remind me in 20 minutes to take the bins out")?.1, .once(Fixed.now.addingTimeInterval(20 * 60)))
    XCTAssertEqual(added("Remind me in twenty five minutes to check the oven")?.1, .once(Fixed.now.addingTimeInterval(25 * 60)))
    XCTAssertEqual(added("remind me in an hour and a half to stretch")?.1, .once(Fixed.now.addingTimeInterval(90 * 60)))
    XCTAssertEqual(added("remind me in half an hour to stretch")?.1, .once(Fixed.now.addingTimeInterval(30 * 60)))
    XCTAssertEqual(added("remind me in 2 hours to call Sam")?.1, .once(Fixed.now.addingTimeInterval(120 * 60)))
  }

  func testABareHourIsTheNextOneToCome() {
    XCTAssertEqual(added("remind me at 6 to take the bins out")?.1, .once(Fixed.date(11, 20, 18)))
    XCTAssertEqual(added("remind me at 9 to lock up")?.1, .once(Fixed.date(11, 20, 21)), "9 am has gone, so 9 pm")
    XCTAssertEqual(added("remind me at 6 am to feed the cat")?.1, .once(Fixed.date(11, 21, 6)), "6 am has gone today")
    XCTAssertEqual(added("remind me at 6:30 pm to cook")?.1, .once(Fixed.date(11, 20, 18, 30)))
    XCTAssertEqual(added("remind me at 6.30 to cook")?.1, .once(Fixed.date(11, 20, 18, 30)))
    XCTAssertEqual(added("remind me at 18:45 to cook")?.1, .once(Fixed.date(11, 20, 18, 45)))
    XCTAssertEqual(added("remind me at 7pm to call Mum")?.1, .once(Fixed.date(11, 20, 19)))
    XCTAssertEqual(added("remind me at 7 p.m. to call Mum")?.1, .once(Fixed.date(11, 20, 19)))
    XCTAssertEqual(added("remind me at half past 7 tonight to lock the door")?.1, .once(Fixed.date(11, 20, 19, 30)))
    XCTAssertEqual(added("remind me at quarter to 5 to leave")?.1, .once(Fixed.date(11, 20, 16, 45)))
    XCTAssertEqual(added("remind me at midday to eat")?.1, .once(Fixed.date(11, 21, 12)), "midday has gone today")
  }

  func testTomorrowAndADay() {
    XCTAssertEqual(added("remind me tomorrow at 9 to call Mum")?.0, "call Mum", "the words keep their capitals")
    XCTAssertEqual(added("remind me tomorrow at 9 to call Mum")?.1, .once(Fixed.date(11, 21, 9)))
    XCTAssertEqual(added("remind me tomorrow at 4 to call Mum")?.1, .once(Fixed.date(11, 21, 16)), "a day makes 4 daytime")
    XCTAssertEqual(added("remind me tomorrow to ring the bank")?.1, .once(Fixed.date(11, 21, 9)))
    XCTAssertEqual(added("remind me tomorrow evening to ring the bank")?.1, .once(Fixed.date(11, 21, 18)))
    XCTAssertEqual(added("remind me tomorrow to call Mum at 4")?.1, .once(Fixed.date(11, 21, 16)))
    XCTAssertEqual(added("remind me tomorrow to call Mum at 4")?.0, "call Mum")
    XCTAssertEqual(added("remind me tonight to lock the shed")?.1, .once(Fixed.date(11, 20, 20)))
  }

  func testTheTimeCanComeLast() {
    XCTAssertEqual(added("remind me to take the bins out at 6 p.m.")?.0, "take the bins out")
    XCTAssertEqual(added("remind me to take the bins out at 6 p.m.")?.1, .once(Fixed.date(11, 20, 18)))
    XCTAssertEqual(added("set a reminder for 5 pm to water the plants")?.0, "water the plants")
    XCTAssertEqual(added("set a reminder for 5 pm to water the plants")?.1, .once(Fixed.date(11, 20, 17)))
  }

  func testEveryDay() {
    XCTAssertEqual(added("remind me every day at 8 pm to take my evening pill")?.0, "take my evening pill")
    XCTAssertEqual(added("remind me every day at 8 pm to take my evening pill")?.1, .daily(hour: 20, minute: 0))
    XCTAssertEqual(added("remind me to take my evening pill at 8 pm every day")?.1, .daily(hour: 20, minute: 0))
    XCTAssertEqual(added("remind me daily at 8 to water the plants")?.1, .daily(hour: 8, minute: 0), "daytime for a bare 8")
  }

  func testAMedicineReminderKeepsNoQuantity() {
    XCTAssertEqual(added("remind me to take 2 pills every day at 8 am")?.0, "take pills")
    XCTAssertEqual(added("remind me at 9 pm to take 500 mg of metformin")?.0, "take metformin")
  }

  func testANumberInTheTaskIsNotATime() {
    XCTAssertEqual(parse("remind me to call 3 people"), .needsTime(text: "call 3 people"))
    XCTAssertEqual(parse("remind me to book a table for 6"), .needsTime(text: "book a table for 6"))
    XCTAssertEqual(parse("remind me to put the cake in the oven"), .needsTime(text: "put the cake in the oven"))
  }

  func testMissingPieces() {
    XCTAssertEqual(parse("remind me at 6"), .needsText)
    XCTAssertEqual(parse("remind me to call Mum"), .needsTime(text: "call Mum"))
  }

  func testATimeThatHasGoneIsKeptSoItCanBeSaid() {
    guard case .add(_, .once(let date)) = parse("remind me at 1 pm today to eat") else { return XCTFail() }
    XCTAssertLessThan(date, Fixed.now)
  }

  func testDataDetectorCoversOtherDates() {
    // NSDataDetector reads the phone's own clock, so only check that something is found and the
    // task survives.
    guard case .add(let text, .once) = parse("remind me to renew the passport on 3 December 2030 at 10 am") else {
      return XCTFail("NSDataDetector should find the date")
    }
    XCTAssertEqual(text, "renew the passport")
  }

  func testFormat() {
    let format = Fixed.format
    XCTAssertEqual(ReminderFormat.clock(hour: 18, minute: 0), "6 pm")
    XCTAssertEqual(ReminderFormat.clock(hour: 18, minute: 5), "6:05 pm")
    XCTAssertEqual(ReminderFormat.clock(hour: 9, minute: 30), "9:30 am")
    XCTAssertEqual(ReminderFormat.clock(hour: 12, minute: 0), "midday")
    XCTAssertEqual(ReminderFormat.clock(hour: 0, minute: 0), "midnight")
    XCTAssertEqual(format.when(Fixed.date(11, 20, 18)), "6 pm today")
    XCTAssertEqual(format.when(Fixed.date(11, 21, 9)), "9 am tomorrow")
    XCTAssertEqual(format.day(Fixed.date(11, 19, 9)), "yesterday")
    XCTAssertEqual(format.day(Fixed.date(11, 24, 9)), "on Tuesday")
    XCTAssertEqual(format.day(Fixed.date(12, 3, 9)), "on 3 December")
    XCTAssertEqual(
      RemindersWording.added("take the bins out", when: format.when(Fixed.date(11, 20, 18))),
      "Reminder at 6 pm today: take the bins out. Say undo to cancel.")
  }
}

// MARK: - Grammar

final class ReminderGrammarTests: XCTestCase {
  func testCommands() {
    XCTAssertEqual(parse("What reminders do I have?"), .list)
    XCTAssertEqual(parse("what's due this week"), .due(.week))
    XCTAssertEqual(parse("what's due today"), .due(.today))
    XCTAssertEqual(parse("cancel the bins reminder"), .cancel(query: "bins"))
    XCTAssertEqual(parse("cancel the reminder to call Mum"), .cancel(query: "call mum"))
    XCTAssertEqual(parse("cancel all my reminders"), .cancelAll)
    XCTAssertEqual(parse("snooze"), .snooze(minutes: 10))
    XCTAssertEqual(parse("snooze for 20 minutes"), .snooze(minutes: 20))
    XCTAssertEqual(parse("remind me again in 5 minutes"), .snooze(minutes: 5))
    XCTAssertEqual(parse("done"), .done)
    XCTAssertEqual(parse("I've done it"), .done)
    XCTAssertEqual(parse("undo"), .undo)
    XCTAssertEqual(parse("cancel that"), .undo)
    XCTAssertEqual(parse("what was I doing?"), .whatWasIDoing)
    XCTAssertNil(parse("stop"), "the app's stop")
    XCTAssertNil(parse("read this letter"))
    XCTAssertNil(parse("what colour is this"))
  }

  func testMedicinePhrases() {
    XCTAssertEqual(parse("I took my evening pill"), .tookMedicine(name: "evening pill", at: nil))
    XCTAssertEqual(parse("I've just taken my metformin"), .tookMedicine(name: "metformin", at: nil))
    XCTAssertEqual(parse("I took 2 paracetamol"), .tookMedicine(name: "paracetamol", at: nil), "no number in the log")
    XCTAssertEqual(parse("I took my evening pill at 7:12 am"), .tookMedicine(name: "evening pill", at: Fixed.date(11, 20, 7, 12)))
    XCTAssertEqual(parse("I took my evening pill at 7"), .tookMedicine(name: "evening pill", at: Fixed.date(11, 20, 7)))
    XCTAssertEqual(parse("did I take my evening pill?"), .didTake(name: "evening pill"))
    XCTAssertEqual(parse("have I taken my metformin today"), .didTake(name: "metformin"))
    XCTAssertEqual(parse("when did I last take metformin"), .lastTook(name: "metformin"))
    XCTAssertNil(parse("I took the bins out"), "not a medicine")
    XCTAssertNil(parse("I took my dog out"), "not a medicine")
    XCTAssertNil(parse("I had lunch"))
  }

  func testDoseQuestionsAreSpotted() {
    let questions = [
      "how many paracetamol can I take", "should I take another evening pill", "what's the dose of ibuprofen",
      "can I take two tablets now", "is it safe to take my pills with wine", "how often can I use my inhaler",
      "how much insulin should I have", "did I take too many pills",
    ]
    for question in questions {
      XCTAssertEqual(parse(question), .doseQuestion, question)
    }
    XCTAssertEqual(parse("can I double up on my metformin", known: ["metformin"]), .doseQuestion)
    XCTAssertNotEqual(parse("did I take my evening pill"), .doseQuestion)
    XCTAssertNotEqual(parse("remind me to take my pill at 8 pm"), .doseQuestion, "a reminder isn't a dose question")
  }

  func testWhatWorksFromAnywhere() {
    for text in ["remind me at 6 to take the bins out", "what reminders do I have", "what's due this week", "I took my evening pill",
      "did I take my evening pill", "how many pills can I take", "what was I doing"]
    {
      XCTAssertTrue(ReminderGrammar.worksFromAnywhere(text), text)
    }
    for text in ["done", "snooze", "undo", "cancel the bins reminder", "read", "open mail reader", "how much is it"] {
      XCTAssertFalse(ReminderGrammar.worksFromAnywhere(text), text)
    }
  }
}

// MARK: - The store

@MainActor
final class ReminderStoreTests: XCTestCase {
  private var notes: FakeNotifications!
  private var file: URL!
  private var store: ReminderStore!

  override func setUp() async throws {
    try await super.setUp()
    notes = FakeNotifications()
    file = tempFile()
    store = ReminderStore(fileURL: file, notifier: notes, clock: Fixed.clock)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    try await super.tearDown()
  }

  private func request(_ id: String, fire: Date, due: Date? = nil, source: String = "reminders") -> ReminderRequest {
    ReminderRequest(id: id, title: id, spokenText: "Reminder: \(id).", fireDate: fire, dueDate: due, source: source)
  }

  func testScheduleSavesOnThePhoneAndAddsANotification() async throws {
    let result = await store.schedule(request("bins", fire: Fixed.date(11, 20, 18)))
    XCTAssertEqual(result, .scheduled)
    XCTAssertEqual(notes.added.map(\.id), ["speakup.reminder.bins"])
    XCTAssertEqual(notes.added.first?.trigger, .at(Fixed.date(11, 20, 18)))
    XCTAssertEqual(notes.added.first?.body, "Reminder: bins.")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let folder = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(folder.isExcludedFromBackup, true, "kept out of backups: it stays on this phone")

    let reopened = ReminderStore(fileURL: file, notifier: notes, clock: Fixed.clock)
    XCTAssertEqual(reopened.reminders.map(\.id), ["bins"])
  }

  func testTheSameIdReplacesTheFirst() async {
    _ = await store.schedule(request("letter-1", fire: Fixed.date(11, 21, 9)))
    _ = await store.schedule(request("letter-1", fire: Fixed.date(11, 22, 9)))
    XCTAssertEqual(store.reminders.count, 1)
    XCTAssertEqual(store.reminders.first?.fireDate, Fixed.date(11, 22, 9))
    XCTAssertEqual(notes.added.count, 1)
  }

  func testRefusedAndPastTimesAreNotKept() async {
    let past = await store.schedule(request("late", fire: Fixed.date(11, 20, 13)))
    XCTAssertEqual(past, .inThePast)
    notes.allowed = false
    let refused = await store.schedule(request("bins", fire: Fixed.date(11, 20, 18)))
    XCTAssertEqual(refused, .notAllowed)
    XCTAssertEqual(store.notificationsAllowed, false)
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertTrue(notes.added.isEmpty)
  }

  func testCancelRemovesTheNotificationToo() async {
    _ = await store.schedule(request("bins", fire: Fixed.date(11, 20, 18)))
    store.cancel(id: "bins")
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertEqual(notes.removed, ["speakup.reminder.bins"])
    XCTAssertTrue(ReminderStore(fileURL: file, notifier: notes, clock: Fixed.clock).reminders.isEmpty)
  }

  func testUpcomingIsSoonestFirstAndKeepsDeadlinesStillAhead() async {
    // A fires in 2 days; B in an hour; C (a letter) fired yesterday but is due in 3 days; D is
    // beyond the week; E is over.
    _ = await store.schedule(request("A", fire: Fixed.date(11, 22, 14)))
    _ = await store.schedule(request("B", fire: Fixed.date(11, 20, 15)))
    _ = await store.schedule(request("C", fire: Fixed.date(11, 21, 9), due: Fixed.date(11, 23, 14), source: "mail"))
    _ = await store.schedule(request("D", fire: Fixed.date(12, 5, 9)))
    let week = Fixed.now.addingTimeInterval(7 * 24 * 3600)
    XCTAssertEqual(store.upcoming(before: week).map(\.id), ["B", "C", "A"], "C fires tomorrow, before A")

    // Later, C has gone off and only its deadline is ahead.
    let later = ReminderStore(
      fileURL: file, notifier: notes, clock: ReminderClock(now: { Fixed.date(11, 21, 12) }, calendar: Fixed.calendar))
    XCTAssertEqual(later.upcoming(before: week).map(\.id), ["A", "C"], "C stays in until its due date")
    XCTAssertEqual(later.upcoming(before: Fixed.date(11, 21, 13)).map(\.id), [], "nothing before 1 pm")
  }

  func testDailyRemindersRepeatAndSayOnlyTheirWords() async throws {
    let (result, daily) = await store.addDaily(text: "evening pill", hour: 20, minute: 0)
    XCTAssertEqual(result, .scheduled)
    XCTAssertEqual(notes.added.first?.trigger, .daily(hour: 20, minute: 0))
    XCTAssertEqual(notes.added.first?.body, "Reminder: evening pill.")
    XCTAssertEqual(store.nextDate(of: try XCTUnwrap(daily)), Fixed.date(11, 20, 20))
    store.cancelDaily(id: try XCTUnwrap(daily).id)
    XCTAssertTrue(store.daily.isEmpty)
  }

  func testTheMedicineLogIsKept() {
    store.logMedicine("evening pill", at: Fixed.date(11, 19, 19, 5))
    store.logMedicine("metformin", at: Fixed.date(11, 20, 8))
    let reopened = ReminderStore(fileURL: file, notifier: notes, clock: Fixed.clock)
    XCTAssertEqual(reopened.medicineLog.map(\.name), ["evening pill", "metformin"])
    XCTAssertEqual(reopened.lastTaken("evening pills")?.takenAt, Fixed.date(11, 19, 19, 5))
    XCTAssertEqual(reopened.knownMedicines, ["metformin", "evening pill"])
  }
}

// MARK: - The tool

@MainActor
final class RemindersToolTests: XCTestCase {
  private var notes: FakeNotifications!
  private var store: ReminderStore!
  private var alerts: ReminderAlerts!
  private var spoken: [(String, Earcon)] = []
  private var tool: RemindersTool!

  override func setUp() async throws {
    try await super.setUp()
    notes = FakeNotifications()
    store = ReminderStore(fileURL: nil, notifier: notes, clock: Fixed.clock)
    alerts = ReminderAlerts()
    let store = store!
    alerts.store = { store }
    alerts.now = { Fixed.now }
    spoken = []
    alerts.speak = { [weak self] line, earcon in self?.spoken.append((line, earcon)) }
    tool = RemindersTool(store: store, alerts: alerts, activity: ActivityLog(now: { Fixed.now })) { [weak self] line, earcon in
      self?.spoken.append((line, earcon))
    }
  }

  private func say(_ text: String) async -> String? {
    await tool.perform(text)?.line
  }

  func testAddConfirmsBackAndUndoCancels() async {
    let line = await say("remind me at 6 to take the bins out")
    XCTAssertEqual(line, "Reminder at 6 pm today: take the bins out. Say undo to cancel.")
    XCTAssertEqual(spoken.last?.1, .done, "an earcon with every action")
    XCTAssertEqual(store.reminders.count, 1)
    XCTAssertEqual(store.reminders.first?.spokenText, "Reminder: take the bins out.")
    let undone = await say("undo")
    XCTAssertEqual(undone, "Undone. No reminder for take the bins out.")
    XCTAssertTrue(store.reminders.isEmpty)
    let again = await say("undo")
    XCTAssertEqual(again, RemindersWording.nothingToUndo)
  }

  func testMyIsSaidBackAsYour() async {
    let line = await say("remind me tomorrow at 9 to call my sister")
    XCTAssertEqual(line, "Reminder at 9 am tomorrow: call your sister. Say undo to cancel.")
  }

  func testWhatsDueIncludesOtherToolsDeadlines() async {
    _ = await say("remind me at 6 to take the bins out")
    let letter = ReminderRequest(
      id: "letter-1", title: "Northside Energy bill", spokenText: "The letter from Northside Energy says pay by Tuesday.",
      fireDate: Fixed.date(11, 21, 9), dueDate: Fixed.date(11, 24, 9), source: ToolID.mail.rawValue)
    let result = await store.schedule(letter)
    XCTAssertEqual(result, .scheduled)
    let due = await say("what's due this week")
    XCTAssertEqual(due, "This week: 2 things. 6 pm today: take the bins out. Northside Energy bill, due on Tuesday.")
    let list = await say("what reminders do I have")
    XCTAssertEqual(list, "You have 2 reminders. 6 pm today: take the bins out. Northside Energy bill, due on Tuesday.")
    let tomorrow = await say("what's due tomorrow")
    XCTAssertEqual(tomorrow, "Tomorrow: 1 thing. Northside Energy bill, due on Tuesday.")
  }

  func testCancelByName() async {
    _ = await say("remind me at 6 to take the bins out")
    _ = await say("remind me tomorrow at 9 to call Mum")
    let cancelled = await say("cancel the bins reminder")
    XCTAssertEqual(cancelled, "Cancelled the reminder: take the bins out.")
    XCTAssertEqual(store.reminders.map(\.title), ["Call Mum"])
    let missing = await say("cancel the dentist reminder")
    XCTAssertEqual(missing, RemindersWording.noMatch("dentist"))
  }

  func testNotificationsRefusedSaysHowToTurnThemOn() async {
    notes.allowed = false
    let line = await say("remind me in 20 minutes to take the bins out")
    XCTAssertEqual(line, RemindersWording.notificationsOff)
    XCTAssertTrue(line?.contains("Settings") ?? false)
    XCTAssertEqual(spoken.last?.1, .error)
  }

  func testATimeThatHasGoneIsSaid() async {
    let line = await say("remind me at 1 pm today to eat")
    XCTAssertEqual(line, "1 pm today has already gone. Say a later time.")
  }

  func testMissingTimeOrWordsAreAskedFor() async {
    let noTime = await say("remind me to call Mum")
    XCTAssertEqual(noTime, "When should I remind you? Say, for example, remind me at 6 to call Mum.")
    let noText = await say("remind me at 6")
    XCTAssertEqual(noText, RemindersWording.needsText)
  }

  // MARK: Medicine

  func testDoseQuestionsAreRefused() async {
    store.logMedicine("metformin", at: Fixed.date(11, 20, 8))
    for question in [
      "how many paracetamol can I take", "should I take another evening pill", "can I take more metformin",
      "what dose of ibuprofen should I take", "is it safe to take my pills with wine",
    ] {
      let line = await say(question)
      XCTAssertEqual(line, RemindersWording.doseRefusal, question)
      XCTAssertEqual(spoken.last?.1, .attention)
    }
    XCTAssertEqual(store.medicineLog.count, 1, "a dose question never writes to the log")
    XCTAssertTrue(RemindersWording.doseRefusal.contains("pharmacist"))
    XCTAssertTrue(RemindersWording.doseRefusal.contains("label"))
  }

  func testTheLogAnswers() async {
    let empty = await say("did I take my evening pill?")
    XCTAssertEqual(empty, "There's nothing in your log for evening pill.")

    let logged = await say("I took my evening pill at 7:12 am")
    XCTAssertEqual(logged, "Logged: evening pill, at 7:12 am. Say undo if that's wrong.")
    let today = await say("did I take my evening pill?")
    XCTAssertEqual(today, "You logged evening pill today at 7:12 am.")
    let plural = await say("have I taken my evening pills")
    XCTAssertEqual(plural, "You logged evening pill today at 7:12 am.")

    store.logMedicine("metformin", at: Fixed.date(11, 19, 19, 5))
    let last = await say("when did I last take metformin")
    XCTAssertEqual(last, "You last logged metformin yesterday at 7:05 pm.")
    let notToday = await say("did I take my metformin")
    XCTAssertEqual(notToday, "You haven't logged metformin today. The last time was yesterday at 7:05 pm.")
    let never = await say("when did I last take aspirin")
    XCTAssertEqual(never, "There's nothing in your log for aspirin.")
  }

  func testTheLogNeverSaysANumberBack() async {
    let line = await say("I took 2 paracetamol")
    XCTAssertEqual(line, "Logged: paracetamol, at 2 pm. Say undo if that's wrong.")
    XCTAssertEqual(store.medicineLog.map(\.name), ["paracetamol"])
    let undone = await say("undo")
    XCTAssertEqual(undone, "Undone. Paracetamol is off your log.")
    XCTAssertTrue(store.medicineLog.isEmpty)
  }

  func testDailyMedicineReminderSaysOnlyTheName() async {
    let line = await say("remind me every day at 8 pm to take my evening pill")
    XCTAssertEqual(line, "Reminder every day at 8 pm: take your evening pill. Say undo to cancel.")
    XCTAssertEqual(notes.added.first?.body, "Reminder: take your evening pill.")
    let list = await say("what reminders do I have")
    XCTAssertEqual(list, "You have 1 reminder. Every day at 8 pm: take your evening pill.")
  }

  // MARK: Going off

  func testAReminderGoingOffIsSpokenThenDoneTakesItOff() async {
    _ = await say("remind me at 6 to take the bins out")
    let id = try? XCTUnwrap(store.reminders.first?.id)
    spoken = []
    XCTAssertTrue(alerts.went(off: ReminderStore.notificationID(reminder: id ?? ""), speakIt: true))
    XCTAssertEqual(spoken.last?.0, "Reminder: take the bins out. Say done, or snooze.")
    XCTAssertEqual(spoken.last?.1, .attention)
    XCTAssertTrue(alerts.takesReply("done"))
    XCTAssertEqual(spoken.last?.0, "Done: take the bins out.")
    XCTAssertTrue(store.reminders.isEmpty)
    XCTAssertFalse(alerts.takesReply("done"), "nothing left to answer, so done is the app's again")
    XCTAssertFalse(alerts.went(off: "someone.else", speakIt: true))
  }

  func testSnoozeMovesItOn() async throws {
    _ = await say("remind me at 6 to take the bins out")
    let id = try XCTUnwrap(store.reminders.first?.id)
    alerts.went(off: ReminderStore.notificationID(reminder: id), speakIt: false)
    XCTAssertTrue(alerts.takesReply("snooze for 20 minutes"))
    for _ in 0..<50 where store.reminders.first?.fireDate != Fixed.now.addingTimeInterval(20 * 60) {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(store.reminders.first?.fireDate, Fixed.now.addingTimeInterval(20 * 60))
    XCTAssertEqual(spoken.last?.0, "Snoozed for 20 minutes. I'll remind you at 2:20 pm.")
  }

  func testDoneWithNothingGoingOff() {
    XCTAssertFalse(alerts.takesReply("done"))
    alerts.done()
    XCTAssertEqual(spoken.last?.0, RemindersWording.nothingToAnswer)
  }
}

// MARK: - What was I doing?

@MainActor
final class ActivityLogTests: XCTestCase {
  func testItSaysTheLastSteps() {
    var now = Fixed.now
    let log = ActivityLog(now: { now })
    XCTAssertEqual(log.whatWasIDoing(openTool: nil), "Nothing yet. You haven't used a tool since SpeakUp opened.")
    log.note("Opened Mail reader", tool: .mail)
    now += 60
    log.note("Closed Mail reader", tool: .mail)
    now += 60
    log.note("Opened Reminders", tool: .reminders)
    log.note("Opened Labels and barcodes", tool: .labels)
    now += 60
    XCTAssertEqual(
      log.whatWasIDoing(openTool: .labels),
      "You're in Labels and barcodes now. 2 minutes ago, you closed Mail reader. Before that, you opened Mail reader.")
    XCTAssertEqual(
      log.whatWasIDoing(openTool: nil),
      "A minute ago, you opened Labels and barcodes. Before that, you closed Mail reader, then before that, opened Mail reader.")
  }

  func testItKeepsOnlyAShortList() {
    let log = ActivityLog()
    for index in 0..<50 { log.note("Step \(index)", tool: nil) }
    XCTAssertEqual(log.entries.count, ActivityLog.limit)
    XCTAssertEqual(log.entries.last?.text, "Step 49")
  }

  func testTheHubNotesOpenAndClose() {
    ActivityLog.shared.clear()
    let hub = ToolHub(source: NoCamera()) { BlankTool($0) }
    hub.open(.mail)
    hub.close(announce: false)
    XCTAssertEqual(ActivityLog.shared.entries.map(\.text), ["Opened Mail reader", "Closed Mail reader"])
    XCTAssertEqual(ActivityLog.shared.entries.map(\.tool), [.mail, .mail])
    ActivityLog.shared.clear()
  }
}

// MARK: - Wiring

@MainActor
final class RemindersWiringTests: XCTestCase {
  func testRemindersIsTheSeventhTool() {
    XCTAssertEqual(ToolID.allCases.count, 7)
    XCTAssertEqual(ToolID.allCases.last, .reminders)
    XCTAssertEqual(ToolID.reminders.title, "Reminders")
    XCTAssertEqual(ToolID.reminders.summary, "Reminders, your medicine log and what's due this week.")
    XCTAssertNotNil(UIImage(systemName: ToolID.reminders.systemImage))
    XCTAssertTrue(ToolHub.liveTool(.reminders) is RemindersTool)
  }

  func testEveryToolIsWiredEverywhere() {
    for tool in ToolID.allCases {
      XCTAssertEqual(VoiceCommand.open(tool).tool, tool, tool.rawValue)
      XCTAssertEqual(HandsFreeTool(tool).tool, tool, tool.rawValue)
      if tool != .read { XCTAssertEqual(LaunchAction.open(tool).tool, tool, tool.rawValue) }
      XCTAssertNotNil(ToolID.caseDisplayRepresentations[tool], tool.rawValue)
      XCTAssertFalse(tool.homeIdentifier.isEmpty)
      _ = tool.tone
    }
    XCTAssertEqual(LaunchAction.open(.reminders), .openReminders)
    XCTAssertEqual(VoiceCommand.open(.reminders), .openReminders)
    XCTAssertEqual(HandsFreeTool(.reminders).command, .openReminders)
    XCTAssertEqual(ToolID.reminders.homeIdentifier, "tool_open_reminders")
  }

  func testOpenPhrases() {
    let camera = VoiceContext(screen: .camera)
    for phrase in ["open reminders", "reminders", "my reminders", "medicine log", "open my reminders"] {
      XCTAssertEqual(VoiceCommandParser.parse(phrase, context: camera), .command(.openReminders), phrase)
    }
    XCTAssertTrue(VoiceCommandParser.helpLine(context: camera).contains("light and colour, or reminders."))
    XCTAssertTrue(SpokenMessage.toolsList.contains("Reminders: reminders, your medicine log"))
  }

  func testRemindersHasAnAppShortcutAndTheLimitHolds() {
    XCTAssertEqual(OpenRemindersIntent.tool, .reminders)
    XCTAssertTrue(OpenRemindersIntent.openAppWhenRun)
    XCTAssertLessThanOrEqual(LaunchShortcuts.appShortcuts.count, 10)
    let router = LaunchActionRouter()
    XCTAssertEqual(OpenToolLaunch.park(.reminders, on: router), "Opening Reminders.")
    XCTAssertEqual(router.consume(), .openReminders)
  }

  func testRemindersNeedNoCamera() async {
    let notes = FakeNotifications()
    let store = ReminderStore(fileURL: nil, notifier: notes, clock: Fixed.clock)
    var lines: [String] = []
    let tool = RemindersTool(store: store, alerts: ReminderAlerts()) { line, _ in lines.append(line) }
    tool.start(source: NoCamera())
    XCTAssertEqual(lines.first, "Reminders. Nothing coming up. \(RemindersWording.start)")
  }

  /// From the home, "remind me ..." opens Reminders without its opening line. Inside another tool
  /// it answers in place (VoiceClashTests has the clashes).
  func testRemindMeFromTheHomeOpensRemindersAndInAToolAnswersInPlace() async throws {
    let notes = FakeNotifications()
    let store = ReminderStore(fileURL: nil, notifier: notes, clock: Fixed.clock)
    var lines: [String] = []
    let reminders = RemindersTool(store: store, alerts: ReminderAlerts()) { line, _ in lines.append(line) }
    let hub = ToolHub(source: NoCamera()) { id -> any SpeakUpTool in
      if id == .reminders { return reminders }
      return BlankTool(id)
    }
    XCTAssertTrue(hub.route("remind me in 20 minutes to read the letter", command: nil))
    XCTAssertEqual(hub.openTool, .reminders)
    for _ in 0..<50 where store.reminders.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(store.reminders.count, 1)
    XCTAssertEqual(lines, ["Reminder at 2:20 pm today: read the letter. Say undo to cancel."], "no opening line first")

    hub.open(.mail)
    XCTAssertTrue(hub.route("remind me at 6 to take the bins out", command: nil))
    XCTAssertEqual(hub.openTool, .mail, "answered in place")
    for _ in 0..<50 where store.reminders.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(store.reminders.count, 2)

    hub.open(.labels)
    XCTAssertTrue(hub.route("what was I doing", command: nil))
    XCTAssertEqual(hub.openTool, .labels, "answered in place")
    hub.close(announce: false)
    Announcer.shared.stop()
  }
}
