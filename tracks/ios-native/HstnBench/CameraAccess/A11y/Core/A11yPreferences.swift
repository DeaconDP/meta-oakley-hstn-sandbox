/*
 * A11yPreferences - the user's accessibility choices, persisted in UserDefaults
 *
 * Observable so settings and onboarding screens update live. Defaults: the app's own British
 * voice (AppVoice), including with VoiceOver running, unless the user opts to follow VoiceOver's;
 * hands-free off (the app is a touch toolbox, notes/hands-free-mode.md), except on a first run with
 * VoiceOver (HandsFreeMode); the glasses display on where there is one; spoken tips on; earcons on;
 * normal verbosity; the system default speech rate; and the natural (OpenAI) reading voice whenever
 * a key is set (CloudReading).
 */

import AVFoundation
import Observation

enum Verbosity: String, CaseIterable, Identifiable, Sendable {
  case short
  case normal
  case detailed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .short: "Short"
    case .normal: "Normal"
    case .detailed: "Detailed"
    }
  }
}

@MainActor
@Observable
final class A11yPreferences {
  static let shared = A11yPreferences()

  private enum Key {
    static let verbosity = "a11y.verbosity"
    static let speechRate = "a11y.speechRate"
    /// Written only when the user changes the setting, so its presence is a real choice.
    static let useVoiceOverVoice = "a11y.useVoiceOverVoice"
    /// The old "useAppVoice" flag, default false. No build ever wrote it from the UI (only tests
    /// set it), so a stored value can't be a user's choice. Dropped on load; see init.
    static let legacyUseAppVoice = "a11y.useAppVoice"
    /// The old always-listening switch (default on). Hands-free replaces it; dropped on load.
    static let legacyVoiceControlEnabled = "a11y.voiceControlEnabled"
    /// Written on the first run and on every switch, so its presence means the first-run choice has
    /// been made (HandsFreeMode.firstRunDefault).
    static let handsFree = "a11y.handsFree"
    static let glassesDisplayEnabled = "a11y.glassesDisplayEnabled"
    static let voiceControlIntroHeard = "a11y.voiceControlIntroHeard"
    static let voiceDownloadNoticeHeard = "a11y.voiceDownloadNoticeHeard"
    static let earconsEnabled = "a11y.earconsEnabled"
    static let onboardingCompleted = "a11y.onboardingCompleted"
    static let onboardingStep = "a11y.onboardingStep"
    static let disclaimerHeard = "a11y.disclaimerHeard"
    static let voiceTipsEnabled = "a11y.voiceTipsEnabled"
    static let voiceTipsHeard = "a11y.voiceTipsHeard"
    static let useNaturalVoice = "a11y.useNaturalVoice"
  }

  @ObservationIgnored private let defaults: UserDefaults

  var verbosity: Verbosity {
    didSet { defaults.set(verbosity.rawValue, forKey: Key.verbosity) }
  }

  /// AVSpeechUtterance rate for the app's own voice. Ignored while VoiceOver's settings are used.
  var speechRate: Float {
    didSet {
      let clamped = Self.clampRate(speechRate)
      if clamped != speechRate {
        speechRate = clamped
        return
      }
      defaults.set(speechRate, forKey: Key.speechRate)
    }
  }

  /// False (default): always the app's British voice at `speechRate`, VoiceOver or not. True: with
  /// VoiceOver running, status goes through VoiceOver and replies use VoiceOver's voice and rate.
  var useVoiceOverVoice: Bool {
    didSet { defaults.set(useVoiceOverVoice, forKey: Key.useVoiceOverVoice) }
  }

  /// Hands-free mode (notes/hands-free-mode.md): always listening, narrated, no dialogs, no screen
  /// needed. Off by default: the app is a touch toolbox with a push-to-talk mic button. Every voice
  /// auto-start and narration path checks this.
  var handsFree: Bool {
    didSet { defaults.set(handsFree, forKey: Key.handsFree) }
  }

  /// False until hands-free has been set once, by the first-run rule or by the user.
  var hasHandsFreeChoice: Bool { defaults.object(forKey: Key.handsFree) != nil }

  /// Mirror the hands-free card on a glasses display (Ray-Ban Display) when there is one. On by
  /// default; "glasses display off" turns it off. Glasses without a display ignore it.
  var glassesDisplayEnabled: Bool {
    didSet { defaults.set(glassesDisplayEnabled, forKey: Key.glassesDisplayEnabled) }
  }

  /// "Voice control is on. Say help at any time." has been spoken to the end.
  var voiceControlIntroHeard: Bool {
    didSet { defaults.set(voiceControlIntroHeard, forKey: Key.voiceControlIntroHeard) }
  }

  /// The one-time "how to download a British voice" notice has been given.
  var voiceDownloadNoticeHeard: Bool {
    didSet { defaults.set(voiceDownloadNoticeHeard, forKey: Key.voiceDownloadNoticeHeard) }
  }

  var earconsEnabled: Bool {
    didSet { defaults.set(earconsEnabled, forKey: Key.earconsEnabled) }
  }

  var onboardingCompleted: Bool {
    didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
  }

  /// The onboarding step to resume at, if onboarding was left part way. Its values belong to the
  /// onboarding flow; nothing here interprets them.
  var onboardingStep: String? {
    didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
  }

  /// The one-time disclaimer has been spoken, so it isn't repeated on every launch.
  var disclaimerHeard: Bool {
    didSet { defaults.set(disclaimerHeard, forKey: Key.disclaimerHeard) }
  }

  /// VoiceCoach: say what can be said next after a quiet spell. On by default; needs hands-free.
  var voiceTipsEnabled: Bool {
    didSet { defaults.set(voiceTipsEnabled, forKey: Key.voiceTipsEnabled) }
  }

  /// How many times each of VoiceCoach's first tips was heard to the end, by situation. A tip heard
  /// a few times comes later, since the user has learned it.
  var voiceTipsHeard: [String: Int] {
    didSet { defaults.set(voiceTipsHeard, forKey: Key.voiceTipsHeard) }
  }

  /// Read with the cloud path (OpenAI transcription and voice) when a key is set. On by default;
  /// off forces on-phone recognition and the app's own voice.
  var useNaturalVoice: Bool {
    didSet { defaults.set(useNaturalVoice, forKey: Key.useNaturalVoice) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    verbosity = defaults.string(forKey: Key.verbosity).flatMap(Verbosity.init(rawValue:)) ?? .normal
    speechRate = Self.clampRate((defaults.object(forKey: Key.speechRate) as? NSNumber)?.floatValue ?? AVSpeechUtteranceDefaultSpeechRate)
    defaults.removeObject(forKey: Key.legacyUseAppVoice)
    useVoiceOverVoice = defaults.bool(forKey: Key.useVoiceOverVoice)
    defaults.removeObject(forKey: Key.legacyVoiceControlEnabled)
    handsFree = defaults.object(forKey: Key.handsFree) as? Bool ?? false
    glassesDisplayEnabled = defaults.object(forKey: Key.glassesDisplayEnabled) as? Bool ?? true
    voiceControlIntroHeard = defaults.bool(forKey: Key.voiceControlIntroHeard)
    voiceDownloadNoticeHeard = defaults.bool(forKey: Key.voiceDownloadNoticeHeard)
    earconsEnabled = defaults.object(forKey: Key.earconsEnabled) as? Bool ?? true
    onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    onboardingStep = defaults.string(forKey: Key.onboardingStep)
    disclaimerHeard = defaults.bool(forKey: Key.disclaimerHeard)
    voiceTipsEnabled = defaults.object(forKey: Key.voiceTipsEnabled) as? Bool ?? true
    voiceTipsHeard = defaults.dictionary(forKey: Key.voiceTipsHeard) as? [String: Int] ?? [:]
    useNaturalVoice = defaults.object(forKey: Key.useNaturalVoice) as? Bool ?? true
  }

  /// Starts onboarding over, e.g. "replay setup" in Settings. The disclaimer is part of
  /// onboarding, so it is heard again too, and spoken tips come back early as for a new user.
  /// Voice, rate, verbosity, earcon, tips, hands-free and glasses display choices are kept.
  func resetOnboarding() {
    onboardingCompleted = false
    onboardingStep = nil
    disclaimerHeard = false
    voiceTipsHeard = [:]
  }

  private static func clampRate(_ rate: Float) -> Float {
    min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
  }
}
