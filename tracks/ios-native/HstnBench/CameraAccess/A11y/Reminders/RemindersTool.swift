/*
 * RemindersTool - the seventh tool: time reminders, what's due this week, the medicine log and
 * "what was I doing?" (ROADMAP.md U1 and V2, notes/reminders-ios.md)
 *
 * No camera: start(source:) ignores the source. Everything is said with an earcon and shown in the
 * panel. "Remind me ...", "what's due", "I took ..." and "what was I doing" also work from any
 * screen (ToolHub.route calls handleFromAnywhere); they open this tool first, except "what was I
 * doing", which answers in place. "Done" and "snooze" after a reminder goes off are ReminderAlerts'.
 *
 * Medicine: the log is what the user says they took. It never states, suggests or changes a dose,
 * and a dose question gets one line pointing to the label or the pharmacist.
 */

import Observation
import SwiftUI

@MainActor
@Observable
final class RemindersTool: SpeakUpTool {
  let toolID: ToolID = .reminders

  /// The last thing said, shown large on the panel.
  private(set) var lastLine: String?
  /// The next start says nothing: whoever opened it is about to answer something.
  @ObservationIgnored var quietStart = false

  struct Reply: Equatable {
    var line: String
    var earcon: Earcon
  }

  private enum Undo {
    case reminder(id: String, text: String)
    case daily(id: String, text: String)
    case log(id: UUID, name: String)
  }

  @ObservationIgnored private let storeProvider: @MainActor () -> ReminderStore?
  @ObservationIgnored private let alerts: ReminderAlerts
  @ObservationIgnored private let activity: ActivityLog
  @ObservationIgnored private let speak: @MainActor (String, Earcon) -> Void
  /// What "undo" takes back. Noted in VoiceQuestions: "Say undo to cancel" is a question too, and
  /// "undo" reaches it from any tool while it is the newest one.
  @ObservationIgnored private var undo: Undo? {
    didSet { if undo != nil { questions.ask(.reminderAdded) } else { questions.settle(.reminderAdded) } }
  }
  @ObservationIgnored var questions: VoiceQuestions = .shared

  init(
    store: ReminderStore? = nil, alerts: ReminderAlerts = .shared, activity: ActivityLog = .shared,
    speak: (@MainActor (String, Earcon) -> Void)? = nil
  ) {
    if let store {
      storeProvider = { store }
    } else {
      storeProvider = { Reminders.shared as? ReminderStore }
    }
    self.alerts = alerts
    self.activity = activity
    self.speak = speak ?? { line, earcon in Announcer.shared.announce(line, earcon: earcon, kind: .reply) }
  }

  var store: ReminderStore? { storeProvider() }

  // MARK: SpeakUpTool

  var helpLine: String { RemindersWording.help }

  func start(source: ReadFrameSource) {
    if let store { Task { await store.refreshPermission() } }
    if quietStart {
      quietStart = false
      return
    }
    say(Reply(line: "Reminders. \(nextLine()) \(RemindersWording.start)", earcon: .ready))
  }

  func stop() {}

  func handle(transcript: String) -> Bool {
    guard let intent = parse(transcript) else { return false }
    Task { await self.respond(to: intent, openTool: .reminders) }
    return true
  }

  func makePanel() -> AnyView { AnyView(RemindersPanel(tool: self)) }

  /// From ToolHub with any screen showing. On the tools home it opens Reminders first (except
  /// "what was I doing?"). With another tool open it answers in place, so "remind me at 6 to call
  /// the bank" from the mail reader keeps the letter on screen.
  func handleFromAnywhere(_ text: String, hub: ToolHub) -> Bool {
    guard let intent = parse(text) else { return false }
    // "Undo" right after a reminder was added from another tool: takes it back, in place.
    if intent == .undo {
      guard undo != nil, questions.isNewest(.reminderAdded) else { return false }
    } else if !intent.worksFromAnywhere {
      return false
    }
    let openTool = hub.openTool
    if intent != .whatWasIDoing, intent != .undo, openTool == nil {
      quietStart = true
      hub.open(.reminders)
    }
    Task { await self.respond(to: intent, openTool: openTool) }
    return true
  }

  /// Typed on the panel: the same as saying it.
  func submit(_ text: String) {
    guard let intent = parse(text) else {
      say(Reply(line: RemindersWording.notUnderstood, earcon: .uncertain))
      return
    }
    Task { await self.respond(to: intent, openTool: .reminders) }
  }

  // MARK: Answering

  private var clock: ReminderClock { store?.clock ?? ReminderClock() }

  func parse(_ text: String) -> ReminderIntent? {
    let clock = clock
    return ReminderGrammar.parse(text, now: clock.now(), calendar: clock.calendar, knownMedicines: store?.knownMedicines ?? [])
  }

  /// Says the answer to `text` and returns it. Nil when it isn't for Reminders, or when the answer
  /// is spoken by ReminderAlerts (done, snooze). The tests' seam.
  @discardableResult
  func perform(_ text: String) async -> Reply? {
    guard let intent = parse(text) else { return nil }
    return await respond(to: intent, openTool: .reminders)
  }

  @discardableResult
  private func respond(to intent: ReminderIntent, openTool: ToolID?) async -> Reply? {
    let reply: Reply?
    switch intent {
    case .done:
      alerts.done()
      reply = nil
    case .snooze(let minutes):
      alerts.snooze(minutes: minutes)
      reply = nil
    case .doseQuestion:
      reply = Reply(line: RemindersWording.doseRefusal, earcon: .attention)
    case .whatWasIDoing:
      reply = Reply(line: activity.whatWasIDoing(openTool: openTool), earcon: .ready)
    default:
      guard let store else {
        reply = Reply(line: RemindersWording.unavailable, earcon: .error)
        break
      }
      reply = await answer(intent, store: store)
    }
    if let reply { say(reply) }
    return reply
  }

  private func answer(_ intent: ReminderIntent, store: ReminderStore) async -> Reply {
    let format = store.clock.format
    let now = store.clock.now()
    switch intent {
    case .add(let text, .once(let date)):
      guard date > now else { return Reply(line: RemindersWording.inThePast(format.when(date)), earcon: .error) }
      let request = ReminderRequest(
        id: "user-\(UUID().uuidString)", title: ReminderStore.title(for: text), spokenText: RemindersWording.fired(text),
        fireDate: date, dueDate: nil, source: ToolID.reminders.rawValue)
      let result = await store.schedule(request)
      guard result == .scheduled else { return Reply(line: RemindersWording.failed(result), earcon: .error) }
      undo = .reminder(id: request.id, text: text)
      return Reply(line: RemindersWording.added(text, when: format.when(date)), earcon: .done)
    case .add(let text, .daily(let hour, let minute)):
      let (result, daily) = await store.addDaily(text: text, hour: hour, minute: minute)
      guard result == .scheduled, let daily else { return Reply(line: RemindersWording.failed(result), earcon: .error) }
      undo = .daily(id: daily.id, text: text)
      return Reply(line: RemindersWording.addedDaily(text, clock: ReminderFormat.clock(hour: hour, minute: minute)), earcon: .done)
    case .needsTime(let text):
      return Reply(line: RemindersWording.needsTime(text), earcon: .uncertain)
    case .needsText:
      return Reply(line: RemindersWording.needsText, earcon: .uncertain)
    case .list:
      return Reply(line: listLine(store), earcon: .ready)
    case .due(let range):
      return Reply(line: dueLine(range, store: store), earcon: .ready)
    case .cancel(let query):
      return cancel(query, store: store)
    case .cancelAll:
      return Reply(line: RemindersWording.cancelAll, earcon: .uncertain)
    case .undo:
      return undoLast(store)
    case .tookMedicine(let name, let date):
      guard let entry = store.logMedicine(name, at: date) else {
        return Reply(line: RemindersWording.couldNotSave, earcon: .error)
      }
      undo = .log(id: entry.id, name: entry.name)
      return Reply(
        line: RemindersWording.logged(entry.name, at: format.time(entry.takenAt), day: format.day(entry.takenAt)), earcon: .done)
    case .didTake(let name):
      guard let entry = store.lastTaken(name) else {
        return Reply(line: RemindersWording.notToday(name, last: nil), earcon: .ready)
      }
      if store.clock.calendar.isDate(entry.takenAt, inSameDayAs: now) {
        return Reply(line: RemindersWording.takenToday(entry.name, at: format.time(entry.takenAt)), earcon: .ready)
      }
      return Reply(line: RemindersWording.notToday(entry.name, last: Self.past(entry.takenAt, format)), earcon: .ready)
    case .lastTook(let name):
      let entry = store.lastTaken(name)
      return Reply(
        line: RemindersWording.lastTaken(entry?.name ?? name, when: entry.map { Self.past($0.takenAt, format) }), earcon: .ready)
    case .medicineLog:
      return Reply(line: logLine(store), earcon: .ready)
    case .done, .snooze, .doseQuestion, .whatWasIDoing:
      return Reply(line: RemindersWording.notUnderstood, earcon: .uncertain)
    }
  }

  /// "yesterday at 7:05 pm", "on Tuesday at 8 am".
  static func past(_ date: Date, _ format: ReminderFormat) -> String { "\(format.day(date)) at \(format.time(date))" }

  // MARK: Lines

  /// One reminder as a list line: "6 pm today: take the bins out", or for a deadline from another
  /// tool, "Northside Energy bill, due on Thursday".
  func describe(_ request: ReminderRequest) -> String {
    guard let store else { return request.title }
    let format = store.clock.format
    if let due = request.dueDate, due >= store.clock.now() {
      return "\(request.title), due \(format.day(due))"
    }
    return "\(format.when(request.fireDate)): \(displayText(request))"
  }

  /// The user's own words for their reminders; another tool's title as it gave it.
  func displayText(_ request: ReminderRequest) -> String {
    guard request.source == ToolID.reminders.rawValue else { return request.title }
    return RemindersWording.yours(request.title.prefix(1).lowercased() + request.title.dropFirst())
  }

  func describe(_ daily: DailyReminder) -> String {
    "Every day at \(ReminderFormat.clock(hour: daily.hour, minute: daily.minute)): \(RemindersWording.yours(daily.text))"
  }

  private func nextLine() -> String {
    guard let store else { return "" }
    let upcoming = store.upcoming(before: .distantFuture)
    guard let first = upcoming.first else {
      return store.daily.isEmpty ? "Nothing coming up." : "\(RemindersWording.count(store.daily.count, "daily reminder"))."
    }
    return "Next: \(describe(first))."
  }

  private static let spokenLimit = 5

  private func listLine(_ store: ReminderStore) -> String {
    let items = store.upcoming(before: .distantFuture).map(describe) + store.dailyByNext.map(describe)
    guard !items.isEmpty else { return RemindersWording.nothingComingUp }
    return "You have \(RemindersWording.count(items.count, "reminder")). " + spoken(items)
  }

  private func dueLine(_ range: ReminderIntent.DueRange, store: ReminderStore) -> String {
    let calendar = store.clock.calendar
    let now = store.clock.now()
    let today = calendar.startOfDay(for: now)
    let start: Date
    let end: Date
    let label: String
    switch range {
    case .today:
      start = now
      end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
      label = "Today"
    case .tomorrow:
      start = calendar.date(byAdding: .day, value: 1, to: today) ?? now
      end = calendar.date(byAdding: .day, value: 2, to: today) ?? now
      label = "Tomorrow"
    case .week:
      start = now
      end = now.addingTimeInterval(7 * 24 * 60 * 60)
      label = "This week"
    }
    let items = store.upcoming(before: end).filter { request in
      [request.fireDate, request.dueDate].compactMap { $0 }.contains { $0 >= start && $0 < end }
    }
    var line =
      items.isEmpty
      ? RemindersWording.nothingDue(range)
      : "\(label): \(RemindersWording.count(items.count, "thing")). " + spoken(items.map(describe))
    if !store.daily.isEmpty { line += " Plus \(RemindersWording.count(store.daily.count, "daily reminder"))." }
    return line
  }

  private func logLine(_ store: ReminderStore) -> String {
    let entries = store.medicineLog.suffix(Self.spokenLimit).reversed()
    guard !entries.isEmpty else { return RemindersWording.emptyLog }
    let format = store.clock.format
    let items = entries.map { "\($0.name), \(Self.past($0.takenAt, format))" }
    return "Your log, latest first: \(items.joined(separator: "; "))."
  }

  private func spoken(_ items: [String]) -> String {
    let said = items.prefix(Self.spokenLimit).map { $0 + "." }.joined(separator: " ")
    let more = items.count - Self.spokenLimit
    return more > 0 ? said + " And \(more) more on the screen." : said
  }

  // MARK: Cancel and undo

  private func cancel(_ query: String, store: ReminderStore) -> Reply {
    let wanted = Set(MedicineName.key(query))
    func score(_ text: String) -> Int { Set(MedicineName.key(text)).intersection(wanted).count }
    let now = store.clock.now()
    let oneOffs = store.reminders.filter { max($0.fireDate, $0.dueDate ?? $0.fireDate) >= now }
    let scored: [(id: String, text: String, daily: Bool, score: Int)] =
      oneOffs.map { ($0.id, displayText($0), false, score($0.title)) } + store.daily.map { ($0.id, $0.text, true, score($0.text)) }
    let best = scored.map(\.score).max() ?? 0
    guard best > 0 else { return Reply(line: RemindersWording.noMatch(query), earcon: .uncertain) }
    let top = scored.filter { $0.score == best }
    guard top.count == 1, let match = top.first else {
      return Reply(line: RemindersWording.which(top.prefix(3).map(\.text)), earcon: .uncertain)
    }
    if match.daily { store.cancelDaily(id: match.id) } else { store.cancel(id: match.id) }
    undo = nil
    return Reply(line: RemindersWording.cancelled(match.text), earcon: .done)
  }

  /// From the panel's Cancel buttons.
  func cancelReminder(id: String) {
    guard let store, let request = store.reminder(id: id) else { return }
    store.cancel(id: id)
    say(Reply(line: RemindersWording.cancelled(displayText(request)), earcon: .done))
  }

  func cancelDaily(id: String) {
    guard let store, let daily = store.daily.first(where: { $0.id == id }) else { return }
    store.cancelDaily(id: id)
    say(Reply(line: RemindersWording.cancelled(daily.text), earcon: .done))
  }

  /// From the panel's "I took ..." buttons.
  func logTaken(_ name: String) {
    Task { await self.respond(to: .tookMedicine(name: name, at: nil), openTool: .reminders) }
  }

  private func undoLast(_ store: ReminderStore) -> Reply {
    guard let last = undo else { return Reply(line: RemindersWording.nothingToUndo, earcon: .uncertain) }
    undo = nil
    switch last {
    case .reminder(let id, let text):
      store.cancel(id: id)
      return Reply(line: RemindersWording.undoneReminder(text), earcon: .done)
    case .daily(let id, let text):
      store.cancelDaily(id: id)
      return Reply(line: RemindersWording.undoneReminder(text), earcon: .done)
    case .log(let id, let name):
      store.removeLogEntry(id: id)
      return Reply(line: RemindersWording.undoneLog(name), earcon: .done)
    }
  }

  private func say(_ reply: Reply) {
    lastLine = reply.line
    speak(reply.line, reply.earcon)
  }
}
