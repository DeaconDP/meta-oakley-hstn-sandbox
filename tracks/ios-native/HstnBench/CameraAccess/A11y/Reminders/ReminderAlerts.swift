/*
 * ReminderAlerts - a reminder going off: spoken when SpeakUp is in front, a normal notification
 * otherwise; then "done" and "snooze" answer it from any screen for a while
 *
 * SystemNotifications wraps UNUserNotificationCenter for ReminderStore. ReminderAlerts is the
 * centre's delegate (set at launch, CameraAccessApp): with the app in front iOS asks it what to
 * show, and it speaks the reminder with an earcon instead of a banner. A tap on the notification,
 * or its Snooze and Done buttons, come here too.
 */

import Foundation
import UserNotifications

@MainActor
final class SystemNotifications: ReminderNotifying {
  static let categoryID = "speakup.reminder"
  static let snoozeAction = "speakup.reminder.snooze"
  static let doneAction = "speakup.reminder.done"

  private var center: UNUserNotificationCenter { .current() }

  func requestPermission() async -> Bool {
    switch await permission() {
    case .some(let allowed): return allowed
    case .none: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
  }

  func permission() async -> Bool? {
    let status = await center.notificationSettings().authorizationStatus
    switch status {
    case .authorized, .provisional, .ephemeral: return true
    case .denied: return false
    case .notDetermined: return nil
    @unknown default: return false
    }
  }

  func add(_ notification: ReminderNotification) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    content.categoryIdentifier = Self.categoryID
    let trigger: UNNotificationTrigger
    switch notification.trigger {
    case .at(let date):
      let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
      trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
    case .daily(let hour, let minute):
      trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
    }
    let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
    do {
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }

  func remove(ids: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  /// Snooze and Done on the notification itself.
  static func registerCategory() {
    let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze 10 minutes")
    let done = UNNotificationAction(identifier: doneAction, title: "Done")
    let category = UNNotificationCategory(identifier: categoryID, actions: [snooze, done], intentIdentifiers: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }
}

@MainActor
final class ReminderAlerts: NSObject, UNUserNotificationCenterDelegate {
  static let shared = ReminderAlerts()

  /// The reminder that went off last.
  struct Fired: Equatable {
    enum Kind: Equatable {
      case once(id: String)
      case daily(id: String)
    }

    var kind: Kind
    var text: String
    var at: Date
  }

  private(set) var lastFired: Fired?
  /// How long "done" and "snooze" mean the reminder that went off.
  static let replyWindow: TimeInterval = 30 * 60

  /// The store, the voice and the clock; tests replace them.
  var store: () -> ReminderStore? = { Reminders.shared as? ReminderStore }
  var speak: (String, Earcon) -> Void = { line, earcon in
    Announcer.shared.announce(line, earcon: earcon, kind: .reply, interrupt: false)
  }
  var now: () -> Date = Date.init

  /// At launch: be the notification centre's delegate, and add Snooze and Done.
  func install() {
    UNUserNotificationCenter.current().delegate = self
    SystemNotifications.registerCategory()
  }

  // MARK: Delegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let id = notification.request.identifier
    let spoken = await MainActor.run { self.went(off: id, speakIt: true) }
    // Spoken in the app instead of a banner; it stays in Notification Centre.
    return spoken ? [.list] : [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let id = response.notification.request.identifier
    let action = response.actionIdentifier
    await MainActor.run {
      switch action {
      case SystemNotifications.snoozeAction:
        _ = self.went(off: id, speakIt: false)
        self.snooze(minutes: ReminderGrammar.defaultSnoozeMinutes)
      case SystemNotifications.doneAction:
        _ = self.went(off: id, speakIt: false)
        self.done()
      default:
        _ = self.went(off: id, speakIt: true)
      }
    }
  }

  // MARK: Going off

  /// A notification with `identifier` went off. Speaks it if asked. False if it isn't ours.
  @discardableResult
  func went(off identifier: String, speakIt: Bool) -> Bool {
    guard let store = store() else { return false }
    let fired: Fired
    if identifier.hasPrefix(ReminderStore.reminderPrefix) {
      let id = String(identifier.dropFirst(ReminderStore.reminderPrefix.count))
      guard let request = store.reminder(id: id) else { return false }
      // The user's own words start lower case mid-sentence ("Done: take the bins out.").
      let text =
        request.source == ToolID.reminders.rawValue ? request.title.prefix(1).lowercased() + request.title.dropFirst() : request.title
      fired = Fired(kind: .once(id: id), text: text, at: now())
      if speakIt { speak(RemindersWording.firedSpoken(request.spokenText), .attention) }
    } else if identifier.hasPrefix(ReminderStore.dailyPrefix) {
      let id = String(identifier.dropFirst(ReminderStore.dailyPrefix.count))
      guard let daily = store.daily.first(where: { $0.id == id }) else { return false }
      fired = Fired(kind: .daily(id: id), text: daily.text, at: now())
      if speakIt { speak(RemindersWording.firedSpoken(RemindersWording.fired(daily.text)), .attention) }
    } else {
      return false
    }
    lastFired = fired
    return true
  }

  /// The reminder "done" and "snooze" are about, if one went off recently.
  var answerable: Fired? {
    guard let lastFired, now().timeIntervalSince(lastFired.at) <= Self.replyWindow else { return nil }
    return lastFired
  }

  /// From ToolHub before anything else: "done" or "snooze" just after a reminder went off.
  func takesReply(_ text: String) -> Bool {
    guard answerable != nil, let intent = ReminderGrammar.parse(text) else { return false }
    switch intent {
    case .done:
      done()
      return true
    case .snooze(let minutes):
      snooze(minutes: minutes)
      return true
    default:
      return false
    }
  }

  /// Takes the reminder that went off off the list. Spoken.
  func done() {
    guard let fired = answerable, let store = store() else {
      speak(RemindersWording.nothingToAnswer, .uncertain)
      return
    }
    if case .once(let id) = fired.kind { store.cancel(id: id) }
    lastFired = nil
    speak(RemindersWording.done(fired.text), .done)
  }

  /// Again in `minutes`. Spoken once it's set.
  func snooze(minutes: Int) {
    guard let fired = answerable, let store = store() else {
      speak(RemindersWording.nothingToAnswer, .uncertain)
      return
    }
    let date = now().addingTimeInterval(TimeInterval(minutes * 60))
    Task { @MainActor in
      let result: ReminderScheduleResult
      switch fired.kind {
      case .once(let id):
        result = await store.move(id: id, to: date)
      case .daily(let id):
        let text = store.daily.first(where: { $0.id == id })?.text ?? fired.text
        result = await store.schedule(
          ReminderRequest(
            id: "snooze-\(id)", title: ReminderStore.title(for: text), spokenText: RemindersWording.fired(text), fireDate: date,
            dueDate: nil, source: ToolID.reminders.rawValue))
      }
      if result == .scheduled {
        self.lastFired = nil
        self.speak(RemindersWording.snoozed(minutes: minutes, at: store.clock.format.time(date)), .done)
      } else {
        self.speak(RemindersWording.failed(result), .error)
      }
    }
  }
}
