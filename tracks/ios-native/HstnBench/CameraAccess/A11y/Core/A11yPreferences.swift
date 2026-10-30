/*
 * A11yPreferences - the user's accessibility choices, persisted in UserDefaults
 *
 * Observable so settings and onboarding screens update live. Defaults follow
 * notes/a11y-onboarding.md: follow VoiceOver's voice unless the user picks the app's own, earcons
 * on, normal verbosity, and the system default speech rate.
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
    static let useAppVoice = "a11y.useAppVoice"
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

  /// False (default): with VoiceOver running, status goes through VoiceOver and replies use
  /// VoiceOver's voice and rate. True: always the app's voice at `speechRate`.
  var useAppVoice: Bool {
    didSet { defaults.set(useAppVoice, forKey: Key.useAppVoice) }
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
    useAppVoice = defaults.object(forKey: Key.useAppVoice) as? Bool ?? false
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
