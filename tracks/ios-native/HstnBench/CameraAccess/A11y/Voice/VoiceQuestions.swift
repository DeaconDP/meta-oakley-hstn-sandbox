/*
 * VoiceQuestions - who asked last, so a short answer goes to the most recent question
 *
 * Several parts of the app wait for a short answer at once: the app's own yes or no (camera
 * access, glasses registration), the mail reader's reminder offer and "forget all letters", Read
 * text's torch offer, "Say undo to cancel" after a reminder is added, and "Say done, or snooze"
 * after a reminder goes off. Each one notes here when it asks and when it is settled. A short
 * answer goes to the newest one still waiting (notes/tools-home-ios.md > Routing order).
 *
 * Opening, closing or switching a tool means the user moved on: the reminder replies that clash
 * with app words ("done" is also close) stop counting. "Snooze" clashes with nothing, so it keeps
 * its 30 minutes (ReminderAlerts).
 */

import Foundation

enum VoiceAsker: Hashable, Sendable {
  /// VoiceControl.ask: camera access for the glasses, glasses registration.
  case app
  /// Mail reader: "Do you want a reminder before the deadline?", "Forget all letters?".
  case mail
  /// Read text: "Shall I turn the torch on?".
  case torch
  /// Reminders: "Say undo to cancel."
  case reminderAdded
  /// A reminder went off: "Say done, or snooze."
  case reminderAlert

  /// The ones a "yes" or "no" answers.
  static let yesOrNo: Set<VoiceAsker> = [.app, .mail, .torch]
}

@MainActor
final class VoiceQuestions {
  static let shared = VoiceQuestions()

  private var asked: [VoiceAsker: Int] = [:]
  private var counter = 0

  /// `asker` has just asked (again).
  func ask(_ asker: VoiceAsker) {
    counter += 1
    asked[asker] = counter
  }

  /// `asker`'s question was answered, dropped, or ran out.
  func settle(_ asker: VoiceAsker) {
    asked[asker] = nil
  }

  func isWaiting(_ asker: VoiceAsker) -> Bool { asked[asker] != nil }

  /// `asker` is waiting, and nobody in `among` has asked since. Everyone counts when `among` is nil.
  func isNewest(_ asker: VoiceAsker, among: Set<VoiceAsker>? = nil) -> Bool {
    guard let mine = asked[asker] else { return false }
    return !asked.contains { other, order in other != asker && (among?.contains(other) ?? true) && order > mine }
  }

  /// The newest question still waiting.
  var newest: VoiceAsker? { asked.max { $0.value < $1.value }?.key }

  /// A tool opened or closed: the reminder replies that are also app words stop counting.
  func movedOn() {
    settle(.reminderAlert)
    settle(.reminderAdded)
  }

  /// Tests: forget everything.
  func reset() {
    asked = [:]
  }
}
