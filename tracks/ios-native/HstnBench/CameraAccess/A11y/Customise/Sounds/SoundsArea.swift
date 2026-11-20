/*
 * SoundsArea - "Sounds" in Make it your own (customisation roadmap C1)
 *
 * - earcons on/off: the one place it is changed now. The value still lives in
 *   A11yPreferences.earconsEnabled ("a11y.earconsEnabled"), which every player and the reading
 *   code read, so nothing else had to move and an existing choice carries over.
 * - earcon volume and speech volume (the app's own voice and the natural voice), in steps of 20 %.
 *   Speech never goes below 40 %, so the voice that tells you how to turn it up stays audible.
 * - earcons only: a short status line that comes with an earcon plays just the earcon. Answers,
 *   descriptions and reading are always spoken.
 * - say it instead of beeping: while learning, an earcon's meaning is spoken in its place
 *   ("Finished", "Problem"). Tones that would talk over the microphone (listening, heard,
 *   capturing, working) stay tones.
 *
 * Everything else is stored as this area's snapshot JSON under "customise.sounds".
 */

import Foundation
import Observation

@MainActor
@Observable
final class SoundsArea: SettingsArea {
  static let shared = SoundsArea(live: true)

  static let areaID = "sounds"
  static let storageKey = "customise.sounds"
  nonisolated static let volumeStep: Float = 0.2
  nonisolated static let minimumSpeechVolume: Float = 0.4
  nonisolated static let minimumEarconVolume: Float = 0.2

  struct Values: Codable, Equatable, Sendable {
    var earconsOn = true
    var earconVolume: Float = 1
    var speechVolume: Float = 1
    var earconsOnly = false
    var sayInsteadOfBeeping = false

    init() {}

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let standard = Values()
      earconsOn = try container.decodeIfPresent(Bool.self, forKey: .earconsOn) ?? standard.earconsOn
      earconVolume = try container.decodeIfPresent(Float.self, forKey: .earconVolume) ?? standard.earconVolume
      speechVolume = try container.decodeIfPresent(Float.self, forKey: .speechVolume) ?? standard.speechVolume
      earconsOnly = try container.decodeIfPresent(Bool.self, forKey: .earconsOnly) ?? standard.earconsOnly
      sayInsteadOfBeeping = try container.decodeIfPresent(Bool.self, forKey: .sayInsteadOfBeeping) ?? standard.sayInsteadOfBeeping
    }

    func clamped() -> Values {
      var copy = self
      copy.earconVolume = SoundsArea.level(earconVolume, minimum: SoundsArea.minimumEarconVolume)
      copy.speechVolume = SoundsArea.level(speechVolume, minimum: SoundsArea.minimumSpeechVolume)
      return copy
    }
  }

  var spokenName: String { "sounds" }

  private(set) var values: Values

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let preferences: A11yPreferences
  @ObservationIgnored private let live: Bool

  init(defaults: UserDefaults = .standard, preferences: A11yPreferences? = nil) {
    self.defaults = defaults
    self.preferences = preferences ?? A11yPreferences(defaults: defaults)
    live = false
    values = Self.load(defaults: defaults, earconsOn: self.preferences.earconsEnabled)
  }

  private init(live: Bool) {
    defaults = .standard
    preferences = .shared
    self.live = live
    values = Self.load(defaults: .standard, earconsOn: A11yPreferences.shared.earconsEnabled)
  }

  private static func load(defaults: UserDefaults, earconsOn: Bool) -> Values {
    var values = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
    values.earconsOn = earconsOn
    return values.clamped()
  }

  // MARK: SettingsArea

  func snapshot() -> Data {
    (try? AudioCustomisation.encoder.encode(values)) ?? Data("{}".utf8)
  }

  func restore(_ data: Data) throws {
    set(try JSONDecoder().decode(Values.self, from: data).clamped())
  }

  func resetToDefaults() {
    set(Values())
  }

  func differencesFromDefaults() -> [String] {
    Self.differences(values)
  }

  static func differences(_ values: Values) -> [String] {
    let standard = Values()
    var lines: [String] = []
    if values.earconsOn != standard.earconsOn { lines.append("earcons off") }
    if values.earconsOnly { lines.append("earcons only for familiar actions") }
    if values.sayInsteadOfBeeping { lines.append("saying sounds instead of beeping") }
    if values.earconVolume != standard.earconVolume { lines.append("sounds at \(percent(values.earconVolume))") }
    if values.speechVolume != standard.speechVolume { lines.append("voice at \(percent(values.speechVolume))") }
    return lines
  }

  // MARK: Changes (each returns the line to speak)

  func setEarcons(on: Bool) -> String {
    change(
      unchanged: on ? "Earcons are already on." : "Earcons are already off.",
      { $0.earconsOn = on },
      describe: { _ in on ? "Earcons on." : "Earcons off. I'll say things in words instead." })
  }

  func changeEarconVolume(steps: Int) -> String {
    let target = values.earconVolume + Float(steps) * Self.volumeStep
    return setEarconVolume(target)
  }

  func setEarconVolume(_ volume: Float) -> String {
    let level = Self.level(volume, minimum: Self.minimumEarconVolume)
    let edge = level >= 1 ? "Sounds are already as loud as they go." : "Sounds are already as quiet as they go."
    return change(
      unchanged: edge, { $0.earconVolume = level },
      describe: { "Sounds \(Self.percent($0.earconVolume))." })
  }

  func changeSpeechVolume(steps: Int) -> String {
    setSpeechVolume(values.speechVolume + Float(steps) * Self.volumeStep)
  }

  func setSpeechVolume(_ volume: Float) -> String {
    let level = Self.level(volume, minimum: Self.minimumSpeechVolume)
    let edge =
      level >= 1
      ? "My voice is already as loud as it goes. Clear speech can make it clearer, and the phone's volume buttons go higher."
      : "My voice is already as quiet as I'll go, so you can still hear me."
    return change(
      unchanged: edge, { $0.speechVolume = level },
      describe: { "Voice \(Self.percent($0.speechVolume))." })
  }

  func setEarconsOnly(_ on: Bool) -> String {
    change(
      unchanged: on ? "Earcons only is already on." : "I'm already saying things in words.",
      { $0.earconsOnly = on },
      describe: { values in
        guard on else { return "Words back on. I'll say what happens as well as play the sound." }
        return values.earconsOn
          ? "Earcons only. For familiar things you'll hear just the sound. Answers are still spoken."
          : "Earcons only, but earcons are off. Say earcons on to hear them."
      })
  }

  func setSayInsteadOfBeeping(_ on: Bool) -> String {
    change(
      unchanged: on ? "I'm already saying the sounds." : "I'm already beeping.",
      { $0.sayInsteadOfBeeping = on },
      describe: { _ in
        on ? "I'll say what each sound means instead of beeping. Say beep again when you know them." : "Back to beeps."
      })
  }

  // MARK: Helpers

  private func change(unchanged: String, _ mutate: (inout Values) -> Void, describe: (Values) -> String) -> String {
    if SettingsChanges.isLocked() { return AudioCustomisation.lockedMessage }
    var new = values
    mutate(&new)
    new = new.clamped()
    guard new != values else { return unchanged }
    let description = describe(new)
    SettingsChanges.record(Self.areaID, before: snapshot(), description: description)
    set(new)
    return description
  }

  private func set(_ new: Values) {
    let earconsChanged = new.earconsOn != values.earconsOn
    values = new
    if preferences.earconsEnabled != new.earconsOn { preferences.earconsEnabled = new.earconsOn }
    var stored = new
    stored.earconsOn = true  // lives in A11yPreferences
    if let data = try? AudioCustomisation.encoder.encode(stored) { defaults.set(data, forKey: Self.storageKey) }
    guard live else { return }
    if earconsChanged, !new.earconsOn { EarconPlayer.shared.stopAllWorkingTicks() }
    AudioCustomisation.refreshShape()
  }

  /// Rounded to the 20 % step and kept between `minimum` and 1.
  nonisolated static func level(_ volume: Float, minimum: Float) -> Float {
    let stepped = (volume / volumeStep).rounded() * volumeStep
    return min(1, max(minimum, (stepped * 100).rounded() / 100))
  }

  nonisolated static func percent(_ volume: Float) -> String {
    "\(Int((volume * 100).rounded())) percent"
  }
}
