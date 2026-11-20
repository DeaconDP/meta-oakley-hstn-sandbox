/*
 * ReminderScheduling - the contract between tools that want a reminder (a letter's deadline, a
 * label's use-by date) and the Reminders feature that owns notifications and "what's due"
 *
 * A tool builds a ReminderRequest and calls Reminders.shared.schedule. The Reminders feature
 * replaces `Reminders.shared` with the real store at launch. Until then NoReminders answers
 * honestly that reminders aren't available, so callers must speak the result, never assume it.
 *
 * Rules (ROADMAP.md > Ground rules, notes/value-strategy.md > 7): reminders stay on the phone, a
 * reminder never states or changes a medicine dose, and a deadline reminder says where the date
 * came from ("the letter from Northside Energy says pay by 3 December").
 */

import Foundation

struct ReminderRequest: Equatable, Sendable, Identifiable, Codable {
  /// Stable per item, so scheduling the same letter twice replaces the first reminder.
  var id: String
  /// Short, for the notification title and the "what's due" list: "Northside Energy bill".
  var title: String
  /// The full spoken line when it fires.
  var spokenText: String
  /// When to remind.
  var fireDate: Date
  /// The date the thing is due, if there is one (a deadline, a use-by date), for "what's due".
  var dueDate: Date?
  /// Which tool asked, by ToolID raw value.
  var source: String
}

enum ReminderScheduleResult: Equatable, Sendable {
  case scheduled
  /// The user said no to notifications; the line says how to turn them on.
  case notAllowed
  /// The date has already passed.
  case inThePast
  /// No reminders feature in this build yet.
  case unavailable
}

@MainActor
protocol ReminderScheduling: AnyObject {
  func schedule(_ request: ReminderRequest) async -> ReminderScheduleResult
  func cancel(id: String)
  /// Everything still to come with a due date or fire date before `date`, soonest first.
  func upcoming(before date: Date) -> [ReminderRequest]
}

@MainActor
enum Reminders {
  /// Replaced by the real store at launch.
  static var shared: any ReminderScheduling = NoReminders()
}

@MainActor
final class NoReminders: ReminderScheduling {
  func schedule(_ request: ReminderRequest) async -> ReminderScheduleResult { .unavailable }
  func cancel(id: String) {}
  func upcoming(before date: Date) -> [ReminderRequest] { [] }
}
