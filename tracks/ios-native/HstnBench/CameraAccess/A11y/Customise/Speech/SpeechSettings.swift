/*
 * SpeechSettings - the "speech" area of Make it your own (notes/customisation-roadmap.md C1)
 *
 * A11yPreferences stays the source of truth: Announcer, AppVoice, TextReader and the rest keep
 * reading it. This area is the user-facing layer over it: snapshots for undo, profiles and share
 * codes, the spoken description of each change, presets, and the lock.
 *
 * What it covers:
 * - rate, on the one portable scale, 0.5 to 3 times (SpeechRateScale maps it to AVSpeech's);
 * - pitch, 0.75 to 1.5; the pause after each line, 0 to 1 second;
 * - verbosity (short, normal, detailed), and per-tool overrides shown as overrides of it (rule 6);
 * - the voice (AppVoice's choice unless the user kept another: SpeechVoiceTrial);
 * - VoiceOver's voice with VoiceOver on, and the natural (OpenAI) reading voice;
 * - presets Brisk, Normal, Gentle and Clear speech rate, over rate, pitch and pause. Described as
 *   the nearest preset plus the difference: "Normal, but faster".
 *
 * Every user-change method checks the lock, records the snapshot from before, and returns the
 * line to speak, which says the new value ("Faster, 1.2 times.").
 */

import Foundation

enum SpeechPreset: String, CaseIterable, Identifiable, Sendable {
  case brisk
  case normal
  case gentle
  case clearRate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .brisk: "Brisk"
    case .normal: "Normal"
    case .gentle: "Gentle"
    case .clearRate: "Clear speech rate"
    }
  }

  /// How a change to it is said: "Brisk speech, 1.4 times."
  var spokenName: String {
    switch self {
    case .clearRate: "Clear speech rate"
    default: "\(title) speech"
    }
  }

  var rate: Double {
    switch self {
    case .brisk: 1.4
    case .normal: 1
    case .gentle: 0.85
    case .clearRate: 0.75
    }
  }

  var pitch: Double {
    switch self {
    case .gentle: 0.95
    default: 1
    }
  }

  var pause: Double {
    switch self {
    case .brisk, .normal: 0
    case .gentle: 0.3
    case .clearRate: 0.5
    }
  }
}

@MainActor
final class SpeechSettings: SettingsArea {
  static let areaID = "speech"
  var spokenName: String { "speech" }

  /// The snapshot's shape. Every field optional when read, so a missing one keeps its default.
  struct Values: Codable, Equatable {
    var rate: Double?
    var pitch: Double?
    var pause: Double?
    var verbosity: String?
    var tools: [String: String]?
    var voice: String?
    var voiceOverVoice: Bool?
    var naturalVoice: Bool?
  }

  let preferences: A11yPreferences
  /// Seams for tests; the app's area reports to SettingsChanges (the store).
  var record: @MainActor (_ areaID: String, _ before: Data, _ description: String) -> Void = {
    SettingsChanges.record($0, before: $1, description: $2)
  }
  var isLocked: @MainActor () -> Bool = { SettingsChanges.isLocked() }
  var noteTweak: @MainActor (_ key: String, _ suggestion: String) -> Void = { SettingsStore.shared.noteTweak($0, suggestion: $1) }
  /// A voice's display name from its identifier ("Kate"), for spoken lines.
  var voiceName: @MainActor (_ identifier: String) -> String? = { SpeechVoiceTrial.liveName(for: $0) }

  init(preferences: A11yPreferences = .shared) {
    self.preferences = preferences
  }

  // MARK: SettingsArea

  func snapshot() -> Data {
    SettingsWords.encode(
      Values(
        rate: preferences.speechRateMultiplier, pitch: Self.round(Double(preferences.speechPitch)), pause: preferences.sentencePause,
        verbosity: preferences.verbosity.rawValue, tools: preferences.toolVerbosity.mapValues(\.rawValue),
        voice: preferences.appVoiceIdentifier, voiceOverVoice: preferences.useVoiceOverVoice, naturalVoice: preferences.useNaturalVoice))
  }

  func restore(_ data: Data) throws {
    let values = try JSONDecoder().decode(Values.self, from: data)
    preferences.speechRateMultiplier = values.rate ?? 1
    preferences.speechPitch = Float(values.pitch ?? 1)
    preferences.sentencePause = values.pause ?? 0
    preferences.verbosity = values.verbosity.flatMap(Verbosity.init(rawValue:)) ?? .normal
    preferences.toolVerbosity = (values.tools ?? [:]).compactMapValues(Verbosity.init(rawValue:))
    preferences.appVoiceIdentifier = values.voice
    preferences.useVoiceOverVoice = values.voiceOverVoice ?? false
    preferences.useNaturalVoice = values.naturalVoice ?? true
  }

  func resetToDefaults() {
    try? restore(Data("{}".utf8))
  }

  func differencesFromDefaults() -> [String] {
    var differences: [String] = []
    let preset = presetDescription()
    if preset != SpeechPreset.normal.title {
      let rate = abs(preferences.speechRateMultiplier - 1) > 0.001 ? ", \(SettingsWords.rate(preferences.speechRateMultiplier))" : ""
      differences.append("speech \(preset)\(rate)")
    }
    if preferences.verbosity != .normal { differences.append("\(preferences.verbosity.title.lowercased()) answers") }
    for tool in ToolID.allCases {
      guard let override = preferences.toolVerbosity[tool.rawValue] else { continue }
      differences.append("\(override.title.lowercased()) answers in \(tool.title)")
    }
    if let voice = preferences.appVoiceIdentifier { differences.append("voice \(voiceName(voice) ?? "chosen by you")") }
    if preferences.useVoiceOverVoice { differences.append("VoiceOver's voice when VoiceOver is on") }
    if !preferences.useNaturalVoice { differences.append("natural reading voice off") }
    return differences
  }

  // MARK: Presets

  /// "Brisk", or the nearest preset and how this differs: "Normal, but faster and longer pauses".
  func presetDescription() -> String {
    let rate = preferences.speechRateMultiplier
    let pitch = Self.round(Double(preferences.speechPitch))
    let pause = preferences.sentencePause
    // A tie goes to Normal: 1.2 times is "Normal, but faster", not "Brisk, but slower".
    func distance(_ preset: SpeechPreset) -> Double {
      abs(preset.rate - rate) + abs(preset.pitch - pitch) * 2 + abs(preset.pause - pause) + (preset == .normal ? 0 : 0.001)
    }
    let nearest = SpeechPreset.allCases.min { distance($0) < distance($1) } ?? .normal
    var buts: [String] = []
    if abs(rate - nearest.rate) > 0.001 { buts.append(rate > nearest.rate ? "faster" : "slower") }
    if abs(pitch - nearest.pitch) > 0.001 { buts.append(pitch > nearest.pitch ? "higher" : "lower") }
    if abs(pause - nearest.pause) > 0.001 { buts.append(pause > nearest.pause ? "longer pauses" : "shorter pauses") }
    return buts.isEmpty ? nearest.title : "\(nearest.title), but \(SettingsWords.list(buts))"
  }

  /// The preset these values are exactly, if any.
  var currentPreset: SpeechPreset? {
    SpeechPreset.allCases.first {
      abs($0.rate - preferences.speechRateMultiplier) < 0.001 && abs($0.pitch - Double(preferences.speechPitch)) < 0.001
        && abs($0.pause - preferences.sentencePause) < 0.001
    }
  }

  func applyPreset(_ preset: SpeechPreset) -> String {
    change("\(preset.spokenName), \(SettingsWords.rate(preset.rate))") {
      preferences.speechRateMultiplier = preset.rate
      preferences.speechPitch = Float(preset.pitch)
      preferences.sentencePause = preset.pause
    }
  }

  // MARK: Rate

  /// The next rate up or down: 0.1 steps below normal speed, 0.2 above, on a 0.05 grid.
  static func step(_ rate: Double, up: Bool) -> Double {
    let delta = up ? (rate < 0.999 ? 0.1 : 0.2) : (rate > 1.001 ? -0.2 : -0.1)
    return SpeechRateScale.clamp(((rate + delta) * 20).rounded() / 20)
  }

  /// "faster" and "slower". At the end of the scale it says so and changes nothing.
  func stepRate(faster: Bool) -> String {
    let current = preferences.speechRateMultiplier
    let next = Self.step(current, up: faster)
    if abs(next - current) < 0.001 { return faster ? SpokenMessage.voiceFastest : SpokenMessage.voiceSlowest }
    let line = change("\(faster ? "faster" : "slower"), \(SettingsWords.rate(next))") { preferences.speechRateMultiplier = next }
    if !isLocked() { noteTweak("speech.rate.\(faster ? "up" : "down")", SettingsWords.rate(next)) }
    return line
  }

  func setRate(_ multiplier: Double) -> String {
    let rate = SpeechRateScale.clamp((multiplier * 20).rounded() / 20)
    return change("speech at \(SettingsWords.rate(rate))") { preferences.speechRateMultiplier = rate }
  }

  // MARK: Pitch and pauses

  func stepPitch(higher: Bool) -> String {
    let current = Self.round(Double(preferences.speechPitch))
    let next = min(max(Self.round(current + (higher ? 0.1 : -0.1)), 0.75), 1.5)
    if abs(next - current) < 0.001 { return higher ? "That's the highest." : "That's the lowest." }
    return change("\(higher ? "higher" : "lower") voice, pitch \(SettingsWords.decimal(next))") { preferences.speechPitch = Float(next) }
  }

  func setPitch(_ pitch: Double) -> String {
    let value = min(max(Self.round(pitch), 0.75), 1.5)
    return change(abs(value - 1) < 0.001 ? "normal pitch" : "pitch \(SettingsWords.decimal(value))") {
      preferences.speechPitch = Float(value)
    }
  }

  func stepPause(longer: Bool) -> String {
    let current = preferences.sentencePause
    let next = min(max(((current + (longer ? 0.2 : -0.2)) * 10).rounded() / 10, 0), 1)
    if abs(next - current) < 0.001 { return longer ? "Those are the longest pauses." : "There are no pauses now." }
    return setPause(next, word: longer ? "longer pauses" : "shorter pauses")
  }

  func setPause(_ seconds: Double, word: String? = nil) -> String {
    let value = min(max((seconds * 10).rounded() / 10, 0), 1)
    let description =
      value < 0.001 ? "no pauses" : "\(word ?? "pauses"), \(SettingsWords.decimal(value)) seconds"
    return change(description) { preferences.sentencePause = value }
  }

  // MARK: Verbosity

  /// The main verbosity, or one tool's override. Says when tools keep their own.
  func setVerbosity(_ verbosity: Verbosity, tool: ToolID? = nil) -> String {
    let word = verbosity.title.lowercased()
    if let tool {
      return change("\(word) answers in \(tool.title)") { preferences.toolVerbosity[tool.rawValue] = verbosity }
    }
    var line = change("\(word) answers") { preferences.verbosity = verbosity }
    guard !isLocked() else { return line }
    noteTweak("speech.verbosity.\(verbosity.rawValue)", "\(word) answers")
    let others = ToolID.allCases.filter { tool in preferences.toolVerbosity[tool.rawValue].map { $0 != verbosity } ?? false }
    if !others.isEmpty {
      line += " \(SettingsWords.list(others.map(\.title))) \(others.count == 1 ? "keeps its" : "keep their") own."
    }
    return line
  }

  /// One tool, or every tool, back to the main verbosity.
  func clearToolVerbosity(_ tool: ToolID?) -> String {
    let main = preferences.verbosity.title.lowercased()
    if let tool {
      guard preferences.toolVerbosity[tool.rawValue] != nil else { return "\(tool.title) already uses your main answers, \(main)." }
      return change("\(tool.title) back to your main answers, \(main)") { preferences.toolVerbosity[tool.rawValue] = nil }
    }
    guard !preferences.toolVerbosity.isEmpty else { return "Every tool already uses your main answers, \(main)." }
    return change("every tool on your main answers, \(main)") { preferences.toolVerbosity = [:] }
  }

  // MARK: Voice

  /// Keeps `identifier` as the app's voice; nil goes back to the app's own choice.
  func setVoice(_ identifier: String?) -> String {
    guard let identifier else { return change("the app's own voice") { preferences.appVoiceIdentifier = nil } }
    return change("voice \(voiceName(identifier) ?? "chosen")") { preferences.appVoiceIdentifier = identifier }
  }

  /// "VoiceOver voice on/off". Says when it has no effect right now.
  func setVoiceOverVoice(_ on: Bool, voiceOverRunning: Bool) -> String {
    var line = change(on ? "VoiceOver's voice when VoiceOver is on" : "the app's own voice, with VoiceOver too") {
      preferences.useVoiceOverVoice = on
    }
    if on, !voiceOverRunning, !isLocked() { line += " VoiceOver isn't running now, so you'll hear the change once it is." }
    return line
  }

  /// "natural voice on/off". Says when there's no key, so nothing changes yet.
  func setNaturalVoice(_ on: Bool, hasKey: Bool) -> String {
    var line = change(on ? "natural reading voice on" : "natural reading voice off") { preferences.useNaturalVoice = on }
    if on, !hasKey, !isLocked() { line += " It needs an OpenAI key, added in Settings, before it's heard." }
    return line
  }

  // MARK: Helpers

  /// Checks the lock, records the snapshot from before, applies, and returns "Description."
  func change(_ description: String, _ apply: () -> Void) -> String {
    if isLocked() { return SettingsLines.locked }
    let before = snapshot()
    apply()
    record(Self.areaID, before, description)
    return SettingsWords.sentence(description) + "."
  }

  static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// VoiceControl's own "faster", "slower" and "short answers" commands come through here, so they
/// are recorded (undo, keep that, lock) when they change the app's settings. A VoiceControl built
/// with other preferences (unit tests) gets the same lines with nothing recorded.
@MainActor
enum SpeechChanges {
  static func stepRate(_ preferences: A11yPreferences, faster: Bool) -> String {
    run(preferences) { $0.stepRate(faster: faster) }
  }

  static func setVerbosity(_ preferences: A11yPreferences, _ verbosity: Verbosity) -> String {
    run(preferences) { $0.setVerbosity(verbosity) }
  }

  private static func run(_ preferences: A11yPreferences, _ body: (SpeechSettings) -> String) -> String {
    if let area = SettingsAreas.area(SpeechSettings.areaID) as? SpeechSettings, area.preferences === preferences {
      let store = SettingsStore.shared
      let line = store.voiceChange { body(area) }
      return [line, store.takeFollowUp()].compactMap { $0 }.joined(separator: " ")
    }
    let detached = SpeechSettings(preferences: preferences)
    detached.record = { _, _, _ in }
    detached.isLocked = { false }
    detached.noteTweak = { _, _ in }
    return body(detached)
  }
}
