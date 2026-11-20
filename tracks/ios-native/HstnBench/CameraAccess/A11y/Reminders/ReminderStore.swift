/*
 * ReminderStore - the real ReminderScheduling: local notifications plus a small JSON file on the
 * phone (notes/reminders-ios.md)
 *
 * What it keeps, all in one file in Application Support/Reminders, written with complete file
 * protection and kept out of backups, so it stays on this phone:
 * - one-off reminders (ReminderRequest), from the user ("remind me at 6 to ...") or from another
 *   tool (a letter's deadline);
 * - daily reminders ("every day at 8 am: evening pill");
 * - the medicine log: a name and when the user said they took it. Never a dose.
 *
 * Notifications go through ReminderNotifying, so tests use a fake and UI tests never see the
 * permission prompt. The prompt comes the first time something is scheduled.
 */

import Foundation
import Observation

/// "Every day at 8 am: evening pill."
struct DailyReminder: Equatable, Sendable, Identifiable, Codable {
  var id: String
  var text: String
  var hour: Int
  var minute: Int
}

/// "Evening pill, taken (as the user said) at 7:12 pm."
struct MedicineLogEntry: Equatable, Sendable, Identifiable, Codable {
  var id: UUID
  var name: String
  var takenAt: Date
}

/// What a local notification needs.
struct ReminderNotification: Equatable, Sendable {
  enum Trigger: Equatable, Sendable {
    case at(Date)
    case daily(hour: Int, minute: Int)
  }

  var id: String
  var title: String
  var body: String
  var trigger: Trigger
}

/// The system's notification centre, or a fake.
@MainActor
protocol ReminderNotifying: AnyObject {
  /// Asks the first time; afterwards answers from the setting. True if notifications may be shown.
  func requestPermission() async -> Bool
  /// The current setting without asking: nil when the user hasn't been asked yet.
  func permission() async -> Bool?
  func add(_ notification: ReminderNotification) async -> Bool
  func remove(ids: [String])
}

/// The phone's clock and calendar, fixed in tests.
struct ReminderClock: Sendable {
  var now: @Sendable () -> Date = { Date() }
  var calendar: Calendar = .current

  var format: ReminderFormat { ReminderFormat(calendar: calendar, now: now()) }
}

@MainActor
@Observable
final class ReminderStore: ReminderScheduling {
  private(set) var reminders: [ReminderRequest] = []
  private(set) var daily: [DailyReminder] = []
  private(set) var medicineLog: [MedicineLogEntry] = []
  /// nil until known. False: the user said no, so the panel says how to turn them on.
  private(set) var notificationsAllowed: Bool?

  @ObservationIgnored let clock: ReminderClock
  @ObservationIgnored private let fileURL: URL?
  @ObservationIgnored private let notifier: any ReminderNotifying
  /// The file couldn't be read (the phone is locked, say), so nothing is written over it.
  @ObservationIgnored private var loaded = false

  /// How long a fired reminder stays for "snooze" and "done", and the log's length.
  static let keepFiredFor: TimeInterval = 24 * 60 * 60
  static let logLimit = 500

  init(fileURL: URL?, notifier: any ReminderNotifying, clock: ReminderClock = ReminderClock()) {
    self.fileURL = fileURL
    self.notifier = notifier
    self.clock = clock
    load()
  }

  /// The app's store: Application Support/Reminders/reminders.json and the system's notifications.
  /// Under automated tests: a fresh file in the temporary folder, and notifications that never ask.
  static func live() -> ReminderStore {
    if LaunchOptions.isAutomatedTest {
      let url = FileManager.default.temporaryDirectory.appending(path: "speakup-reminders-test-\(UUID().uuidString).json")
      return ReminderStore(fileURL: url, notifier: QuietNotifications())
    }
    let folder = URL.applicationSupportDirectory.appending(path: "Reminders", directoryHint: .isDirectory)
    return ReminderStore(fileURL: folder.appending(path: "reminders.json"), notifier: SystemNotifications())
  }

  private var now: Date { clock.now() }

  // MARK: ReminderScheduling

  func schedule(_ request: ReminderRequest) async -> ReminderScheduleResult {
    guard request.fireDate > now else { return .inThePast }
    guard ensureLoaded() else { return .unavailable }
    guard await allowed() else { return .notAllowed }
    let note = ReminderNotification(
      id: Self.notificationID(reminder: request.id), title: request.title, body: request.spokenText, trigger: .at(request.fireDate))
    guard await notifier.add(note) else { return .unavailable }
    reminders.removeAll { $0.id == request.id }
    reminders.append(request)
    guard save() else {
      notifier.remove(ids: [note.id])
      reminders.removeAll { $0.id == request.id }
      return .unavailable
    }
    return .scheduled
  }

  func cancel(id: String) {
    notifier.remove(ids: [Self.notificationID(reminder: id)])
    guard reminders.contains(where: { $0.id == id }) else { return }
    reminders.removeAll { $0.id == id }
    save()
  }

  /// One-off reminders with a fire date or due date still to come and before `date`, soonest first.
  /// A reminder that has fired but whose due date is still ahead (a letter's deadline) stays in.
  /// Daily reminders aren't ReminderRequests, so they're not in it (see `daily`).
  func upcoming(before date: Date) -> [ReminderRequest] {
    let now = now
    return reminders.compactMap { request -> (ReminderRequest, Date)? in
      let dates = [request.fireDate, request.dueDate].compactMap { $0 }
      let ahead = dates.filter { $0 >= now }
      guard let next = ahead.min(), ahead.contains(where: { $0 < date }) else { return nil }
      return (request, next)
    }
    .sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 < $1.1 }
    .map(\.0)
  }

  // MARK: More than the contract

  func reminder(id: String) -> ReminderRequest? { reminders.first { $0.id == id } }

  /// Moves a reminder to `date` (snooze).
  func move(id: String, to date: Date) async -> ReminderScheduleResult {
    guard var request = reminder(id: id) else { return .unavailable }
    request.fireDate = date
    return await schedule(request)
  }

  /// "Every day at 8 am: evening pill."
  func addDaily(text: String, hour: Int, minute: Int) async -> (ReminderScheduleResult, DailyReminder?) {
    guard ensureLoaded() else { return (.unavailable, nil) }
    guard await allowed() else { return (.notAllowed, nil) }
    let reminder = DailyReminder(id: UUID().uuidString, text: text, hour: hour, minute: minute)
    let note = ReminderNotification(
      id: Self.notificationID(daily: reminder.id), title: Self.title(for: text), body: RemindersWording.fired(text),
      trigger: .daily(hour: hour, minute: minute))
    guard await notifier.add(note) else { return (.unavailable, nil) }
    daily.append(reminder)
    guard save() else {
      notifier.remove(ids: [note.id])
      daily.removeAll { $0.id == reminder.id }
      return (.unavailable, nil)
    }
    return (.scheduled, reminder)
  }

  func cancelDaily(id: String) {
    notifier.remove(ids: [Self.notificationID(daily: id)])
    guard daily.contains(where: { $0.id == id }) else { return }
    daily.removeAll { $0.id == id }
    save()
  }

  /// The next time a daily reminder goes off.
  func nextDate(of reminder: DailyReminder) -> Date? {
    clock.calendar.nextDate(
      after: now, matching: DateComponents(hour: reminder.hour, minute: reminder.minute, second: 0), matchingPolicy: .nextTime)
  }

  /// Daily reminders, soonest next first.
  var dailyByNext: [DailyReminder] {
    daily.sorted { (nextDate(of: $0) ?? .distantFuture) < (nextDate(of: $1) ?? .distantFuture) }
  }

  // MARK: Medicine log

  /// Writes "took `name` at `date`" into the log. Nil if it couldn't be saved.
  @discardableResult
  func logMedicine(_ name: String, at date: Date? = nil) -> MedicineLogEntry? {
    guard ensureLoaded() else { return nil }
    let entry = MedicineLogEntry(id: UUID(), name: name, takenAt: date ?? now)
    medicineLog.append(entry)
    medicineLog.sort { $0.takenAt < $1.takenAt }
    if medicineLog.count > Self.logLimit { medicineLog.removeFirst(medicineLog.count - Self.logLimit) }
    guard save() else {
      medicineLog.removeAll { $0.id == entry.id }
      return nil
    }
    return entry
  }

  func removeLogEntry(id: UUID) {
    medicineLog.removeAll { $0.id == id }
    save()
  }

  /// The latest entry for that medicine ("pill" matches "evening pill").
  func lastTaken(_ name: String) -> MedicineLogEntry? {
    medicineLog.last { MedicineName.matches(name, $0.name) }
  }

  /// Names in the log, most recent first, each once.
  var knownMedicines: [String] {
    var seen = Set<[String]>()
    return medicineLog.reversed().compactMap { entry in
      seen.insert(MedicineName.key(entry.name)).inserted ? entry.name : nil
    }
  }

  // MARK: Permission

  /// Reads the setting without asking (for the panel).
  func refreshPermission() async {
    notificationsAllowed = await notifier.permission()
  }

  private func allowed() async -> Bool {
    let allowed = await notifier.requestPermission()
    notificationsAllowed = allowed
    return allowed
  }

  // MARK: Ids

  static let reminderPrefix = "speakup.reminder."
  static let dailyPrefix = "speakup.daily."

  static func notificationID(reminder id: String) -> String { reminderPrefix + id }
  static func notificationID(daily id: String) -> String { dailyPrefix + id }

  /// A notification's title: the words, first letter capital, cut at a word near 60 characters.
  static func title(for text: String) -> String {
    let capital = text.prefix(1).uppercased() + text.dropFirst()
    guard capital.count > 60 else { return capital }
    let cut = capital.prefix(60)
    return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "\u{2026}"
  }

  // MARK: File

  private struct File: Codable {
    var version = 1
    var reminders: [ReminderRequest] = []
    var daily: [DailyReminder] = []
    var medicineLog: [MedicineLogEntry] = []
  }

  private func load() {
    guard let fileURL else {
      loaded = true
      return
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      loaded = true
      return
    }
    guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else {
      // Locked or unreadable: keep it, and try again before the next change.
      loaded = false
      return
    }
    let cutoff = now.addingTimeInterval(-Self.keepFiredFor)
    reminders = file.reminders.filter { max($0.fireDate, $0.dueDate ?? $0.fireDate) > cutoff }
    daily = file.daily
    medicineLog = file.medicineLog.sorted { $0.takenAt < $1.takenAt }
    loaded = true
  }

  private func ensureLoaded() -> Bool {
    if !loaded { load() }
    return loaded
  }

  @discardableResult
  private func save() -> Bool {
    guard let fileURL else { return true }
    guard loaded else { return false }
    do {
      var folder = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? folder.setResourceValues(values)
      let data = try JSONEncoder().encode(File(reminders: reminders, daily: daily, medicineLog: medicineLog))
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
      return true
    } catch {
      return false
    }
  }
}

/// For UI tests and the unit-test host: always allowed, nothing shown.
@MainActor
final class QuietNotifications: ReminderNotifying {
  private(set) var added: [ReminderNotification] = []
  func requestPermission() async -> Bool { true }
  func permission() async -> Bool? { true }
  func add(_ notification: ReminderNotification) async -> Bool {
    added.removeAll { $0.id == notification.id }
    added.append(notification)
    return true
  }
  func remove(ids: [String]) { added.removeAll { ids.contains($0.id) } }
}
