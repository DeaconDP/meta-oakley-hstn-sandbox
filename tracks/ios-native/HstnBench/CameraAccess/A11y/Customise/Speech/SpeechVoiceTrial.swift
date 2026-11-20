/*
 * SpeechVoiceTrial - choosing the app's voice by ear (notes/customisation-roadmap.md C1)
 *
 * "try another voice" moves to the next installed voice in the user's language and speaks a short
 * sample in it; "go back" (only while trying) steps back, and past the first returns to the voice
 * the user started with; "keep this one" keeps the voice being tried (deliberate, so kept at once,
 * and undoable); anything else ends the trial and the voice goes back to what it was.
 *
 * The voice being tried lives in A11yPreferences.trialVoiceIdentifier, which isn't saved, so a
 * trial cut short by closing the app can't change the voice.
 *
 * Candidates: usable voices (no novelty or Eloquence voices, VoiceSelection.isUsable) whose base
 * language is the current voice's (English for the app's British voice), best quality first,
 * British first, then by name.
 */

import AVFoundation
import Foundation

@MainActor
final class SpeechVoiceTrial {
  let area: SpeechSettings
  /// Where "keep this one" is made deliberate (kept at once).
  var store: SettingsStore = .shared
  /// The installed voices. A seam for tests.
  var installedVoices: @MainActor () -> [VoiceDescriptor] = { AppVoice.installedVoices() }
  /// The language of the voice now heard, e.g. "en-GB".
  var currentLanguage: @MainActor () -> String = { AppVoice.shared.voice?.language ?? "en-GB" }
  /// The voice now heard, to start the list after it.
  var currentIdentifier: @MainActor () -> String? = { AppVoice.shared.voice?.identifier }

  private(set) var isActive = false
  private var candidates: [VoiceDescriptor] = []
  private var index = -1
  private var startIndex = -1

  init(area: SpeechSettings) {
    self.area = area
  }

  private var preferences: A11yPreferences { area.preferences }

  /// The voices that can be tried, in order.
  /// `voices`: an installed list already looked up (the settings screen does it off the main thread).
  func candidateList(from voices: [VoiceDescriptor]? = nil) -> [VoiceDescriptor] {
    let language = VoiceSelection.normalizedLanguage(currentLanguage()).split(separator: "-").first.map(String.init) ?? "en"
    return (voices ?? installedVoices())
      .filter { VoiceSelection.isUsable($0) }
      .filter { VoiceSelection.normalizedLanguage($0.language).split(separator: "-").first.map(String.init) == language }
      .sorted { lhs, rhs in
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        let lhsGB = VoiceSelection.normalizedLanguage(lhs.language) == "en-GB"
        let rhsGB = VoiceSelection.normalizedLanguage(rhs.language) == "en-GB"
        if lhsGB != rhsGB { return lhsGB }
        return lhs.name < rhs.name
      }
  }

  /// "try another voice".
  func next() -> String {
    if area.isLocked() { return SettingsLines.locked }
    if !isActive {
      candidates = candidateList()
      guard candidates.count > 1 else {
        return "There's no other voice to try. Download more in the iPhone's Settings, under Accessibility, Spoken Content, Voices."
      }
      startIndex = candidates.firstIndex { $0.identifier == currentIdentifier() } ?? -1
      index = startIndex
      isActive = true
    }
    index = (index + 1) % candidates.count
    if index == startIndex { index = (index + 1) % candidates.count }
    return sample()
  }

  /// "go back" while trying.
  func previous() -> String {
    guard isActive else { return "You're not trying voices. Say try another voice to start." }
    index -= 1
    if index == startIndex { index -= 1 }
    if index < 0 {
      end()
      return "Back to your voice. Say try another voice to hear more."
    }
    return sample()
  }

  /// "keep this one". Kept at once and undoable.
  func keep() -> String {
    guard isActive, candidates.indices.contains(index) else { return "Say try another voice first." }
    let chosen = candidates[index].identifier
    end()
    return store.deliberately { area.setVoice(chosen) }
  }

  /// Ends the trial without keeping anything.
  func cancel() -> String {
    guard isActive else { return "You're not trying voices." }
    end()
    return "Okay, your voice is back."
  }

  /// Ends quietly (anything said that isn't for the trial).
  func end() {
    isActive = false
    preferences.trialVoiceIdentifier = nil
    candidates = []
    index = -1
  }

  private func sample() -> String {
    let voice = candidates[index]
    preferences.trialVoiceIdentifier = voice.identifier
    let name = VoiceSelection.baseName(voice)
    let accent = VoiceSelection.accentName(language: voice.language)
    return "This is \(name), \(accent). I'll read your pages like this. Say keep this one, try another voice, or go back."
  }

  /// "Kate" for an installed voice's identifier.
  static func liveName(for identifier: String) -> String? {
    AVSpeechSynthesisVoice(identifier: identifier).map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
  }
}
