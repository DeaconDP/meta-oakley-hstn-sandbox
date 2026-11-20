/*
 * ConversationMode - "someone's talking to me": SpeakUp goes quiet until "carry on"
 *
 * For talking to someone, including while Meta's own conversation feature is running on the
 * glasses: speech stops at once, and until the user ends it nothing is spoken; lines that come with
 * an earcon play just the earcon (SoundsPolicy). Both ways are announced. If anything was held back,
 * the end line says how to hear it ("repeat" speaks the last line, which was kept).
 *
 * Not a setting: it isn't saved, isn't part of a profile, and works while settings are locked.
 */

import Foundation
import Observation

@MainActor
@Observable
final class ConversationMode {
  static let shared = ConversationMode()

  nonisolated static let startLine = "Conversation mode. I'll stay quiet and only use sounds. Say carry on when you're done."
  nonisolated static let endLine = "Carrying on. I'm talking again."
  nonisolated static let endLineMissed = "Carrying on. I held something back. Say repeat to hear it."
  nonisolated static let alreadyOn = "Conversation mode is already on. Say carry on when you're done."
  nonisolated static let alreadyOff = "I'm already talking."

  private(set) var isActive = false
  private(set) var heldBack = false

  /// Lines conversation mode itself speaks, which its own quiet rule lets through.
  nonisolated static func isOwnLine(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return [startLine, endLine, endLineMissed, alreadyOn].contains(trimmed)
  }

  /// Stops speech and goes quiet. The returned line is spoken by whoever routed the command.
  func start(stopSpeech: Bool = true) -> String {
    guard !isActive else { return Self.alreadyOn }
    if stopSpeech { Announcer.shared.stop() }
    isActive = true
    heldBack = false
    return Self.startLine
  }

  func end() -> String {
    guard isActive else { return Self.alreadyOff }
    isActive = false
    defer { heldBack = false }
    return heldBack ? Self.endLineMissed : Self.endLine
  }

  func noteHeldBack() { heldBack = true }
}
