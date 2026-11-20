/*
 * AudioCustomisation - wires the Ears and Sounds areas into the app
 *
 * install() runs once at launch: registers both areas and their grammars with the shared
 * customisation machinery (SettingsAreas, SettingsVoice), starts following iOS's mono setting, and
 * pushes the current AudioShape to every audio path. refreshShape() rebuilds the shape after any
 * change; AudioShape.build is the pure part.
 */

import Foundation

@MainActor
enum AudioCustomisation {
  static let lockedMessage = "Settings are locked. Say unlock settings to change them."

  /// Sorted keys, so the same values always give the same snapshot bytes (undo, profiles, export).
  nonisolated static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
  }

  /// While the listening check plays its A and B, the treble it is comparing.
  static var previewTrebleGainDB: Float? {
    didSet { refreshShape() }
  }

  private static var isInstalled = false

  static func install() {
    guard !isInstalled else { return }
    isInstalled = true
    SettingsAreas.register(EarsArea.shared)
    SettingsAreas.register(SoundsArea.shared)
    SettingsVoice.register(SoundsGrammar())
    SettingsVoice.register(EarsGrammar())
    EarsArea.shared.observeSystemMono()
    refreshShape()
  }

  static func refreshShape() {
    let shape = AudioShape.build(
      ears: EarsArea.shared.values, sounds: SoundsArea.shared.values, systemMono: EarsArea.shared.systemMono,
      previewTrebleGainDB: previewTrebleGainDB)
    AudioShapeStore.current = shape
    AudioBus.shared.apply(shape)
    CloudVoicePlayer.shared.applyShape(shape)
    if shape.speechNeedsBus, !LaunchOptions.isAutomatedTest {
      // After AppVoice's launch lookup, so asking for the voice here doesn't start a second one.
      Task {
        try? await Task.sleep(for: .seconds(2))
        SpeechBusSpeaker.shared.prewarm(voice: AppVoice.shared.voice)
      }
    }
  }
}

extension AudioShape {
  static func build(
    ears: EarsArea.Values, sounds: SoundsArea.Values, systemMono: Bool, previewTrebleGainDB: Float? = nil
  ) -> AudioShape {
    var shape = AudioShape()
    shape.balance = ears.balance
    shape.speechRoute = ears.speechRoute
    shape.earconRoute = ears.earconRoute
    shape.alertRoute = ears.alertRoute
    shape.mono = systemMono || ears.userMono
    shape.speechVolume = sounds.speechVolume
    shape.earconVolume = sounds.earconVolume
    if let previewTrebleGainDB {
      shape.clearSpeech = ClearSpeech(trebleGainDB: previewTrebleGainDB)
    } else if ears.clearSpeech {
      shape.clearSpeech = ClearSpeech(trebleGainDB: ears.trebleGainDB)
    }
    return shape
  }
}

/// Words of an utterance for the settings grammars: lowercased, punctuation and apostrophes gone
/// (VoiceCommandParser.normalize), the wake word and polite filler taken off.
enum AudioPhrases {
  private static let leading: [[String]] = [
    ["hey", "reader"], ["ok", "reader"], ["okay", "reader"], ["reader"], ["please"], ["can", "you"], ["could", "you"],
    ["would", "you"], ["i", "want", "to"], ["id", "like", "to"], ["lets"],
  ]
  private static let trailing: [[String]] = [["please"], ["thanks"], ["thank", "you"], ["for", "me"]]

  static func words(_ utterance: String) -> String {
    var tokens = VoiceCommandParser.normalize(utterance)
    var changed = true
    while changed {
      changed = false
      for filler in leading where tokens.count > filler.count && Array(tokens.prefix(filler.count)) == filler {
        tokens.removeFirst(filler.count)
        changed = true
      }
      for filler in trailing where tokens.count > filler.count && Array(tokens.suffix(filler.count)) == filler {
        tokens.removeLast(filler.count)
        changed = true
      }
    }
    return tokens.joined(separator: " ")
  }
}
