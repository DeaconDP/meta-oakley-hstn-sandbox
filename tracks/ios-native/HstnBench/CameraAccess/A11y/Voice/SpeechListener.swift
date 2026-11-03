/*
 * SpeechListener - the protocol both speech listeners share, and the pure rules around them
 *
 * GlassesSpeechListener (DAT Speech on the glasses, experimental) is preferred during a session;
 * PhoneSpeechListener (SFSpeechRecognizer on the phone) is used otherwise. VoiceListenerPolicy
 * decides, RestartBackoff paces recovery, PhoneLocaleChoice picks a recognition language. All pure,
 * so all unit-tested. VoiceControl does the acting.
 */

import Foundation

enum VoiceListenerKind: String, Sendable {
  case phone
  case glasses
}

enum SpeechListenerEvent: Equatable, Sendable {
  case started
  /// A finished utterance. Never a partial; never logged or stored.
  case transcript(String)
  /// Listening stopped by itself. `transient` failures are retried on the same listener kind.
  case failed(reason: String, transient: Bool)
  /// Ended without an error (glasses Speech stops after inactivity). Start it again.
  case finished
}

@MainActor
protocol SpeechListener: AnyObject {
  var kind: VoiceListenerKind { get }
  var onEvent: (@MainActor (SpeechListenerEvent) -> Void)? { get set }
  func start()
  /// Synchronous about giving back the mic: on return the session is free for a recording.
  func stop()
}

/// The ROADMAP's "experimental APIs go behind a flag in dev/beta builds". DAT Speech can't ship to
/// a production channel, so a Release build uses it only if a beta turns this key on.
enum VoiceFeatureFlags {
  static let glassesSpeechKey = "a11y.experimental.glassesSpeech"

  static func glassesSpeechEnabled(defaults: UserDefaults = .standard, isDebugBuild: Bool = isDebugBuild) -> Bool {
    defaults.object(forKey: glassesSpeechKey) as? Bool ?? isDebugBuild
  }

  private static var isDebugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }
}

enum VoicePermission: Equatable, Sendable {
  case notDetermined
  case granted
  case denied
}

enum VoicePauseReason: String, Equatable, Sendable {
  case recording
  case background
  case interrupted

  var text: String {
    switch self {
    case .recording: "Paused while recording."
    case .background: "Paused while the app is in the background."
    case .interrupted: "Paused by a call or another app."
    }
  }
}

enum VoiceListenerDecision: Equatable, Sendable {
  case off
  case paused(VoicePauseReason)
  /// Permissions haven't been asked yet.
  case needsPermission
  case denied
  case noOnDeviceRecognition
  case glasses
  case phone
}

enum VoiceListenerPolicy {
  struct Inputs: Equatable, Sendable {
    var enabled = true
    var inBackground = false
    var recording = false
    var interrupted = false
    /// A device session is STARTED and Speech is allowed by the feature flag.
    var glassesAvailable = false
    /// The wearable MICROPHONE permission (a Meta AI grant, separate from the phone's).
    var glassesMicGranted = false
    /// Speech failed recently, so use the phone until the cool-off ends.
    var glassesCoolingOff = false
    var phoneMic = VoicePermission.notDetermined
    var speechRecognition = VoicePermission.notDetermined
    /// An on-device recogniser exists for one of the candidate languages.
    var onDeviceRecognizerAvailable = true
  }

  static func decide(_ inputs: Inputs) -> VoiceListenerDecision {
    guard inputs.enabled else { return .off }
    if inputs.inBackground { return .paused(.background) }
    if inputs.recording { return .paused(.recording) }
    if inputs.interrupted { return .paused(.interrupted) }
    if inputs.glassesAvailable, inputs.glassesMicGranted, !inputs.glassesCoolingOff { return .glasses }
    if inputs.phoneMic == .denied || inputs.speechRecognition == .denied { return .denied }
    if inputs.phoneMic == .notDetermined || inputs.speechRecognition == .notDetermined { return .needsPermission }
    return inputs.onDeviceRecognizerAvailable ? .phone : .noOnDeviceRecognition
  }
}

/// Doubling delays with a ceiling, reset once listening has stayed up for a while.
struct RestartBackoff: Equatable, Sendable {
  static let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30]
  /// Running this long counts as recovered.
  static let stableAfter: TimeInterval = 30

  private(set) var attempts = 0

  mutating func next() -> TimeInterval {
    defer { attempts += 1 }
    return Self.delays[min(attempts, Self.delays.count - 1)]
  }

  mutating func noteRanFor(_ seconds: TimeInterval) {
    if seconds >= Self.stableAfter { attempts = 0 }
  }

  mutating func reset() { attempts = 0 }
}

enum PhoneLocaleChoice {
  /// The device's locale if it's English and on-device recognition supports it (this app's commands
  /// are English), then en-GB, then en-US. nil if none is. `en-ZA` stays first on an en-ZA phone.
  static func choose(deviceLocale: String, supportsOnDevice: (String) -> Bool) -> String? {
    candidates(deviceLocale: deviceLocale).first(where: supportsOnDevice)
  }

  static func candidates(deviceLocale: String) -> [String] {
    // "en_ZA@rg=gbzzzz" is en-ZA.
    let base = deviceLocale.split(separator: "@").first.map(String.init) ?? deviceLocale
    let device = VoiceSelection.normalizedLanguage(base)
    var list = device.hasPrefix("en") ? [device] : []
    for fallback in ["en-GB", "en-US"] where !list.contains(fallback) { list.append(fallback) }
    return list
  }
}
