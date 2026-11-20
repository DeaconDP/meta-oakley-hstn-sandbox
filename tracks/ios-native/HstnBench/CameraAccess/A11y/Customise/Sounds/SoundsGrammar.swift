/*
 * SoundsGrammar - the Sounds area by voice
 *
 * "earcons off", "quieter sounds", "louder voice", "earcons only", "say it instead of beeping",
 * and their opposites. Whole-utterance phrases after AudioPhrases.words, like VoiceCommand, and
 * none of them is a VoiceCommand phrase or one of the settings core's (a unit test checks).
 */

import Foundation

@MainActor
struct SoundsGrammar: SettingsGrammar {
  enum Action: CaseIterable, Sendable {
    case earconsOn
    case earconsOff
    case quieterSounds
    case louderSounds
    case quieterVoice
    case louderVoice
    case earconsOnlyOn
    case earconsOnlyOff
    case sayInsteadOn
    case sayInsteadOff
  }

  nonisolated static let phrases: [Action: [String]] = [
    .earconsOff: [
      "earcons off", "ear cons off", "earcon off", "turn earcons off", "turn off earcons", "turn off the earcons",
      "no earcons", "beeps off", "turn off the beeps", "turn the beeps off", "no beeps", "sounds off",
      "turn off the sounds", "turn the sounds off",
    ],
    .earconsOn: [
      "earcons on", "ear cons on", "earcon on", "turn earcons on", "turn on earcons", "turn on the earcons", "beeps on",
      "turn on the beeps", "turn the beeps on", "sounds on", "turn on the sounds", "turn the sounds on",
    ],
    .quieterSounds: [
      "quieter sounds", "softer sounds", "quieter earcons", "quieter beeps", "turn the sounds down", "turn down the sounds",
      "sounds quieter", "earcons quieter", "beeps quieter",
    ],
    .louderSounds: [
      "louder sounds", "louder earcons", "louder beeps", "turn the sounds up", "turn up the sounds", "sounds louder",
      "earcons louder", "beeps louder",
    ],
    .quieterVoice: [
      "quieter voice", "quieter", "softer", "softer voice", "speak quieter", "speak more quietly", "talk quieter",
      "talk more quietly", "voice quieter", "turn the voice down", "turn down the voice", "turn your voice down",
      "a bit quieter",
    ],
    .louderVoice: [
      "louder voice", "louder", "speak louder", "talk louder", "voice louder", "turn the voice up", "turn up the voice",
      "turn your voice up", "a bit louder",
    ],
    .earconsOnlyOn: [
      "earcons only", "ear cons only", "earcons only on", "sounds only", "just sounds", "just the sounds", "beeps only",
      "just beeps", "just the beeps",
    ],
    .earconsOnlyOff: [
      "earcons only off", "stop earcons only", "words and sounds", "sounds and words", "use words again", "words again",
      "say things again",
    ],
    .sayInsteadOn: [
      "say it instead of beeping", "say instead of beeping", "say it instead of beeps", "speak instead of beeping",
      "speak instead of earcons", "say what the sounds mean", "words instead of beeps", "talk instead of beeping",
      "say the sounds",
    ],
    .sayInsteadOff: [
      "beep again", "beeps again", "back to beeps", "back to beeping", "go back to beeping", "stop saying the sounds",
      "beep instead",
    ],
  ]

  nonisolated static let lookup: [String: Action] = {
    var lookup: [String: Action] = [:]
    for (action, list) in phrases {
      for phrase in list { lookup[phrase] = action }
    }
    return lookup
  }()

  nonisolated static var allPhrases: [String] { phrases.values.flatMap { $0 } }

  let area: SoundsArea

  init(area: SoundsArea = .shared) {
    self.area = area
  }

  nonisolated static func action(for utterance: String) -> Action? {
    lookup[AudioPhrases.words(utterance)]
  }

  func handle(_ utterance: String) -> String? {
    guard let action = Self.action(for: utterance) else { return nil }
    switch action {
    case .earconsOn: return area.setEarcons(on: true)
    case .earconsOff: return area.setEarcons(on: false)
    case .quieterSounds: return area.changeEarconVolume(steps: -1)
    case .louderSounds: return area.changeEarconVolume(steps: 1)
    case .quieterVoice: return area.changeSpeechVolume(steps: -1)
    case .louderVoice: return area.changeSpeechVolume(steps: 1)
    case .earconsOnlyOn: return area.setEarconsOnly(true)
    case .earconsOnlyOff: return area.setEarconsOnly(false)
    case .sayInsteadOn: return area.setSayInsteadOfBeeping(true)
    case .sayInsteadOff: return area.setSayInsteadOfBeeping(false)
    }
  }
}
