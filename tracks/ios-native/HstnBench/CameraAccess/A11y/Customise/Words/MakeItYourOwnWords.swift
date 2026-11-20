/*
 * MakeItYourOwnWords - start-up for "Your words" and "Your buttons": registers both areas and
 * grammars with the shared settings machinery (SettingsArea.swift) and sets the utterance hook
 * VoiceControl calls before parsing. Called once from the app's init; idempotent.
 */

import Foundation

@MainActor
enum MakeItYourOwnWords {
  private static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    let words = WordsArea.shared
    let controls = ControlsArea.shared
    SettingsAreas.register(words)
    SettingsAreas.register(controls)
    let engine = WordsEngine.shared
    let controlsGrammar = ControlsGrammar(area: controls)
    engine.moreGrammars = [controlsGrammar]
    SettingsVoice.register(WordsGrammar(engine: engine))
    SettingsVoice.register(controlsGrammar)
    UtteranceHook.rewrite = { transcript, context in engine.rewrite(transcript, context: context) }
  }
}

/// Runs a macro asked for from outside the app (Shortcuts, Siri, Back Tap) once the main screen is
/// up to hear its steps. Gives up quietly after `maxWait`, as LaunchActionRouter does.
@MainActor
enum WordsLaunch {
  static let maxWait: Double = 60

  static func runWhenReady(_ name: String) {
    Task {
      var waited = 0.0
      while VoiceControl.shared.screen != .camera, waited < maxWait {
        try? await Task.sleep(for: .milliseconds(250))
        waited += 0.25
      }
      guard VoiceControl.shared.screen == .camera else { return }
      // A moment for the screen's own first line.
      try? await Task.sleep(for: .milliseconds(600))
      WordsEngine.shared.runMacro(named: name)
    }
  }
}
