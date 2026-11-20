/*
 * A11yPreferences - the user's accessibility choices, persisted in UserDefaults
 *
 * Observable so settings and onboarding screens update live. Defaults: the app's own British
 * voice (AppVoice), including with VoiceOver running, unless the user opts to follow VoiceOver's;
 * hands-free off (the app is a touch toolbox, notes/hands-free-mode.md), except on a first run with
 * VoiceOver (HandsFreeMode); the glasses display on where there is one; spoken tips on; earcons on;
 * normal verbosity; the system default speech rate; and the natural (OpenAI) reading voice whenever
 * a key is set (CloudReading); and the automatic camera source (CameraSource).
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
    /// The old AVSpeech rate (0...1). Read once to migrate, then written alongside the multiplier
    /// so an older build still finds the user's speed.
    static let speechRate = "a11y.speechRate"
    /// The portable rate, 0.5 to 3 times normal (notes/customisation-ios-core.md).
    static let speechRateMultiplier = "a11y.speech.rate"
    static let speechPitch = "a11y.speech.pitch"
    static let sentencePause = "a11y.speech.pause"
    static let toolVerbosity = "a11y.speech.toolVerbosity"
    static let appVoiceIdentifier = "a11y.speech.voice"
    static let tipsFewer = "a11y.tips.fewer"
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
    static let cameraSource = "a11y.cameraSource"
  }

  /// Which camera reads (CameraSource): auto (default) is the phone until glasses are linked, then
  /// the glasses with the phone as a fallback. "use the phone" / "use the glasses" set it.
  var cameraSource: CameraSourcePreference {
    didSet { defaults.set(cameraSource.rawValue, forKey: Key.cameraSource) }
  }

  @ObservationIgnored private let defaults: UserDefaults

  var verbosity: Verbosity {
    didSet { defaults.set(verbosity.rawValue, forKey: Key.verbosity) }
  }

  /// AVSpeechUtterance rate for the app's own voice. Ignored while VoiceOver's settings are used.
  /// A view of `speechRateMultiplier` on AVSpeech's scale (SpeechRateScale), kept for the readers
  /// that predate the portable scale; setting it sets the multiplier.
  var speechRate: Float {
    get { SpeechRateScale.avRate(forMultiplier: speechRateMultiplier) }
    set { speechRateMultiplier = SpeechRateScale.multiplier(forAVRate: newValue) }
  }

  /// The one portable rate (Android uses the same scale): 1 is the system's normal speed, 0.5 half,
  /// 3 the fastest. Clamped.
  var speechRateMultiplier: Double {
    didSet {
      let clamped = SpeechRateScale.clamp(speechRateMultiplier)
      if clamped != speechRateMultiplier {
        speechRateMultiplier = clamped
        return
      }
      defaults.set(speechRateMultiplier, forKey: Key.speechRateMultiplier)
      defaults.set(speechRate, forKey: Key.speechRate)
    }
  }

  /// AVSpeechUtterance.pitchMultiplier for the app's own voice, 0.75 to 1.5. 1 is the voice's own.
  var speechPitch: Float {
    didSet {
      let clamped = min(max(speechPitch, 0.75), 1.5)
      if clamped != speechPitch {
        speechPitch = clamped
        return
      }
      defaults.set(speechPitch, forKey: Key.speechPitch)
    }
  }

  /// Extra silence after each line the app speaks (sentences when reading), in seconds, 0 to 1.
  var sentencePause: Double {
    didSet {
      let clamped = min(max(sentencePause, 0), 1)
      if clamped != sentencePause {
        sentencePause = clamped
        return
      }
      defaults.set(sentencePause, forKey: Key.sentencePause)
    }
  }

  /// Per-tool overrides of `verbosity`, by ToolID raw value. Missing means "same as the main one".
  var toolVerbosity: [String: Verbosity] {
    didSet { defaults.set(toolVerbosity.mapValues(\.rawValue), forKey: Key.toolVerbosity) }
  }

  /// The voice the user picked ("keep this one"), by AVSpeechSynthesisVoice identifier. nil: the
  /// app's own choice (AppVoice, a British woman's voice when there is one).
  var appVoiceIdentifier: String? {
    didSet { defaults.set(appVoiceIdentifier, forKey: Key.appVoiceIdentifier) }
  }

  /// A voice being tried ("try another voice", SpeechVoiceTrial). Not saved: it lasts until the
  /// trial ends, and wins over `appVoiceIdentifier` meanwhile.
  var trialVoiceIdentifier: String?

  /// Tips pacing "fewer": longer gaps and only two tips (VoiceCoachSchedule). Off is
  /// `voiceTipsEnabled` false.
  var tipsFewer: Bool {
    didSet { defaults.set(tipsFewer, forKey: Key.tipsFewer) }
  }

  /// Which tool is open, for `effectiveVerbosity`. Set at start-up (MakeItYourOwn.start).
  @ObservationIgnored var currentToolID: @MainActor () -> String? = { nil }

  /// The verbosity to use right now: the open tool's override, else the main one.
  var effectiveVerbosity: Verbosity {
    currentToolID().flatMap { toolVerbosity[$0] } ?? verbosity
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
    // The portable multiplier, or the old AVSpeech rate converted (the two scales map one to one,
    // so no user's choice is lost), or normal speed. Both keys are written together, so an old
    // key that no longer matches the new one was changed by an older build since: it wins.
    let stored = (defaults.object(forKey: Key.speechRateMultiplier) as? NSNumber)?.doubleValue
    let legacy = (defaults.object(forKey: Key.speechRate) as? NSNumber)?.floatValue
    if let stored, legacy.map({ abs(SpeechRateScale.avRate(forMultiplier: stored) - $0) < 0.0001 }) ?? true {
      speechRateMultiplier = SpeechRateScale.clamp(stored)
    } else if let legacy {
      let migrated = SpeechRateScale.multiplier(forAVRate: legacy)
      speechRateMultiplier = migrated
      defaults.set(migrated, forKey: Key.speechRateMultiplier)
    } else {
      speechRateMultiplier = 1
    }
    speechPitch = min(max((defaults.object(forKey: Key.speechPitch) as? NSNumber)?.floatValue ?? 1, 0.75), 1.5)
    sentencePause = min(max((defaults.object(forKey: Key.sentencePause) as? NSNumber)?.doubleValue ?? 0, 0), 1)
    toolVerbosity = (defaults.dictionary(forKey: Key.toolVerbosity) as? [String: String] ?? [:]).compactMapValues(Verbosity.init(rawValue:))
    appVoiceIdentifier = defaults.string(forKey: Key.appVoiceIdentifier)
    tipsFewer = defaults.bool(forKey: Key.tipsFewer)
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
    cameraSource = defaults.string(forKey: Key.cameraSource).flatMap(CameraSourcePreference.init(rawValue:)) ?? .auto
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
}

/// The portable rate scale (0.5 to 3 times) and AVSpeech's (0 to 1, default 0.5). Piecewise
/// linear and one to one: 0.5x is AVSpeech's minimum, 1x its default, 3x its maximum. So every
/// rate an older build saved has an exact multiplier, and back.
enum SpeechRateScale {
  static let minimum = 0.5
  static let maximum = 3.0

  static func clamp(_ multiplier: Double) -> Double {
    guard multiplier.isFinite else { return 1 }
    return min(max(multiplier, minimum), maximum)
  }

  static func avRate(forMultiplier multiplier: Double) -> Float {
    let m = clamp(multiplier)
    let low = Double(AVSpeechUtteranceMinimumSpeechRate)
    let mid = Double(AVSpeechUtteranceDefaultSpeechRate)
    let high = Double(AVSpeechUtteranceMaximumSpeechRate)
    if m <= 1 { return Float(low + (m - minimum) / (1 - minimum) * (mid - low)) }
    return Float(mid + (m - 1) / (maximum - 1) * (high - mid))
  }

  static func multiplier(forAVRate rate: Float) -> Double {
    let low = Double(AVSpeechUtteranceMinimumSpeechRate)
    let mid = Double(AVSpeechUtteranceDefaultSpeechRate)
    let high = Double(AVSpeechUtteranceMaximumSpeechRate)
    let r = rate.isFinite ? min(max(Double(rate), low), high) : mid
    if r <= mid { return minimum + (r - low) / (mid - low) * (1 - minimum) }
    return 1 + (r - mid) / (high - mid) * (maximum - 1)
  }
}
