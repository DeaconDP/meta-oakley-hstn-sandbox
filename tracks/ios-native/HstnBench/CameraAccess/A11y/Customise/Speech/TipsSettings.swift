/*
 * TipsSettings - the "tips" area: how often spoken tips and nudges come (VoiceCoach)
 *
 * Fewer, Normal or Off, never raw seconds (notes/customisation-roadmap.md C3 "Your timing").
 * Normal is VoiceCoach's own schedule; Fewer waits a minute and gives two tips at most
 * (VoiceCoachSchedule.fewerGaps); Off is A11yPreferences.voiceTipsEnabled false, the same switch
 * as the "Turn spoken tips off" button. Tips only ever play in hands-free.
 */

import Foundation

enum TipPacing: String, CaseIterable, Identifiable, Sendable {
  case fewer
  case normal
  case off

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fewer: "Fewer"
    case .normal: "Normal"
    case .off: "Off"
    }
  }
}

@MainActor
final class TipsSettings: SettingsArea {
  static let areaID = "tips"
  var spokenName: String { "tips" }

  private struct Values: Codable {
    var pacing: String?
  }

  let preferences: A11yPreferences
  var record: @MainActor (_ areaID: String, _ before: Data, _ description: String) -> Void = {
    SettingsChanges.record($0, before: $1, description: $2)
  }
  var isLocked: @MainActor () -> Bool = { SettingsChanges.isLocked() }

  init(preferences: A11yPreferences = .shared) {
    self.preferences = preferences
  }

  var pacing: TipPacing {
    if !preferences.voiceTipsEnabled { return .off }
    return preferences.tipsFewer ? .fewer : .normal
  }

  private func apply(_ pacing: TipPacing) {
    preferences.voiceTipsEnabled = pacing != .off
    preferences.tipsFewer = pacing == .fewer
  }

  func snapshot() -> Data { SettingsWords.encode(Values(pacing: pacing.rawValue)) }

  func restore(_ data: Data) throws {
    let values = try JSONDecoder().decode(Values.self, from: data)
    apply(values.pacing.flatMap(TipPacing.init(rawValue:)) ?? .normal)
  }

  func resetToDefaults() { apply(.normal) }

  func differencesFromDefaults() -> [String] {
    switch pacing {
    case .normal: []
    case .fewer: ["fewer tips"]
    case .off: ["tips off"]
    }
  }

  /// Returns the line to speak, which says what the user will now hear.
  func setPacing(_ new: TipPacing) -> String {
    if isLocked() { return SettingsLines.locked }
    let before = snapshot()
    apply(new)
    let description: String =
      switch new {
      case .fewer: "fewer tips"
      case .normal: "tips at the normal pace"
      case .off: "tips off"
      }
    record(Self.areaID, before, description)
    let line: String =
      switch new {
      case .fewer: "Fewer tips. I'll wait a minute before a tip, and give two at most."
      case .normal: SpokenMessage.voiceTipsOn
      case .off: SpokenMessage.voiceTipsOff
      }
    return preferences.handsFree || new == .off ? line : line + " Tips play in hands-free."
  }
}
