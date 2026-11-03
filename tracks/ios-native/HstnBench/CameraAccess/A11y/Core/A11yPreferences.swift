/*
 * A11yPreferences - the user's accessibility choices, persisted in UserDefaults
 *
 * Observable so settings and onboarding screens update live. Defaults: the app's own British
 * voice (AppVoice), including with VoiceOver running, unless the user opts to follow VoiceOver's;
 * voice control on; earcons on; normal verbosity; and the system default speech rate.
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
    static let voiceControlEnabled = "a11y.voiceControlEnabled"
    static let voiceControlIntroHeard = "a11y.voiceControlIntroHeard"
    static let voiceDownloadNoticeHeard = "a11y.voiceDownloadNoticeHeard"
    static let earconsEnabled = "a11y.earconsEnabled"
    static let onboardingCompleted = "a11y.onboardingCompleted"
    static let onboardingStep = "a11y.onboardingStep"
    static let disclaimerHeard = "a11y.disclaimerHeard"
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

  /// Run the app by speaking. On by default; listening starts once permissions are granted.
  var voiceControlEnabled: Bool {
    didSet { defaults.set(voiceControlEnabled, forKey: Key.voiceControlEnabled) }
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

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    verbosity = defaults.string(forKey: Key.verbosity).flatMap(Verbosity.init(rawValue:)) ?? .normal
    speechRate = Self.clampRate((defaults.object(forKey: Key.speechRate) as? NSNumber)?.floatValue ?? AVSpeechUtteranceDefaultSpeechRate)
    defaults.removeObject(forKey: Key.legacyUseAppVoice)
    useVoiceOverVoice = defaults.bool(forKey: Key.useVoiceOverVoice)
    voiceControlEnabled = defaults.object(forKey: Key.voiceControlEnabled) as? Bool ?? true
    voiceControlIntroHeard = defaults.bool(forKey: Key.voiceControlIntroHeard)
    voiceDownloadNoticeHeard = defaults.bool(forKey: Key.voiceDownloadNoticeHeard)
    earconsEnabled = defaults.object(forKey: Key.earconsEnabled) as? Bool ?? true
    onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    onboardingStep = defaults.string(forKey: Key.onboardingStep)
    disclaimerHeard = defaults.bool(forKey: Key.disclaimerHeard)
  }

  /// Starts onboarding over, e.g. "replay setup" in Settings. The disclaimer is part of
  /// onboarding, so it is heard again too. Voice, rate, verbosity and earcon choices are kept.
  func resetOnboarding() {
    onboardingCompleted = false
    onboardingStep = nil
    disclaimerHeard = false
  }

  private static func clampRate(_ rate: Float) -> Float {
    min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
  }
}
