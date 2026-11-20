/*
 * MakeItYourOwn - start-up for the customisation core (notes/customisation-ios-core.md)
 *
 * Called once from CameraAccessApp.init, before any screen. Order matters:
 * 1. register the areas (speech, tips, descriptions; other areas register in their own start-up);
 * 2. the store takes over SettingsChanges' handler and lock;
 * 3. voice changes from last session that weren't kept go back (the keep rule);
 * 4. profiles are seeded (Home is the setup as it is now, the first time);
 * 5. the grammars register: speech first, so a voice trial's "go back" and "keep this one" win.
 */

import Foundation

@MainActor
enum MakeItYourOwn {
  private(set) static var speech: SpeechSettings?
  private(set) static var tips: TipsSettings?
  private(set) static var descriptions: DescriptionSettings?
  private(set) static var voiceTrial: SpeechVoiceTrial?
  /// Areas whose unkept voice changes were put back at this launch, for "what's my setup".
  private(set) static var revertedAtLaunch: [String] = []

  static func start() {
    guard speech == nil else { return }
    let preferences = A11yPreferences.shared
    preferences.currentToolID = { ToolHub.shared.openTool?.rawValue }

    let speech = SpeechSettings(preferences: preferences)
    let tips = TipsSettings(preferences: preferences)
    let descriptions = DescriptionSettings()
    SettingsAreas.register(speech)
    SettingsAreas.register(tips)
    SettingsAreas.register(descriptions)
    self.speech = speech
    self.tips = tips
    self.descriptions = descriptions

    let store = SettingsStore.shared
    store.install()
    revertedAtLaunch = store.revertUnkeptChanges()
    store.seedProfilesIfNeeded()

    let trial = SpeechVoiceTrial(area: speech)
    voiceTrial = trial
    SettingsVoice.register(SpeechGrammar(area: speech, trial: trial, currentTool: { ToolHub.shared.openTool }))
    SettingsVoice.register(TipsGrammar(area: tips))
    SettingsVoice.register(DescriptionsGrammar(area: descriptions))
    SettingsVoice.register(SettingsCoreGrammar(store: store))

    SettingsVoiceGate.isCaptureActive = {
      guard ToolHub.shared.openTool == .watch, let watch = ToolHub.shared.current as? WatchTool else { return false }
      return watch.phase == .asking
    }
  }
}
