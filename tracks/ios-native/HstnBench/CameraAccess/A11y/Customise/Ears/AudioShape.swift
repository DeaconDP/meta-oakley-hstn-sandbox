/*
 * AudioShape - how every sound the app makes is placed and coloured (notes/customisation-ios-ears.md)
 *
 * One value, built from the Ears and Sounds areas, that the audio code reads: balance, which ear
 * each kind of sound goes to, volumes, mono, and Clear speech. The maths is pure and lives here so
 * it can be unit-tested without audio:
 *
 * - pan(for:): ear routing wins over balance (speech "in my left ear" is hard left whatever the
 *   balance); "both ears" uses the balance; with mono on everything is centred, because the OS
 *   sums the channels and a hard-panned sound would only lose level.
 * - sideCue(for:): Watch for text's left/right cue. With stereo it pans the alert towards the side;
 *   with mono, or with alerts routed to one ear (so panning can't carry a side), it changes pitch
 *   instead: lower for left, higher for right. The spoken "on your left" is always said as well.
 *
 * AudioShapeStore holds the current shape behind a lock, because the earcon engine reads it on
 * A11yAudioSession's queue and the speech path on the main actor.
 */

import Foundation
import os

enum EarRoute: String, Codable, CaseIterable, Sendable {
  case both
  case left
  case right

  var spoken: String {
    switch self {
    case .both: "both ears"
    case .left: "your left ear"
    case .right: "your right ear"
    }
  }

  var title: String {
    switch self {
    case .both: "Both"
    case .left: "Left"
    case .right: "Right"
    }
  }
}

/// The three kinds of sound that can be sent to an ear of their own.
enum SoundKind: String, CaseIterable, Sendable {
  case speech
  case earcon
  case alert

  var spoken: String {
    switch self {
    case .speech: "speech"
    case .earcon: "sounds"
    case .alert: "alerts"
    }
  }
}

extension Earcon {
  /// Alerts are the earcons that mean "something needs you": errors, warnings, a lost link.
  var soundKind: SoundKind {
    switch self {
    case .error, .attention, .uncertain, .disconnected: .alert
    default: .earcon
    }
  }
}

/// Clear speech: SpeakUp's own voice, slower, compressed and with the treble lifted.
/// "Speech clarity for SpeakUp's voice", never anything to do with hearing.
struct ClearSpeech: Equatable, Sendable {
  /// High-shelf lift above `shelfHz`, set by the listening check.
  var trebleGainDB: Float

  static let shelfHz: Float = 2_500
  /// Takes out boom below the voice, which masks consonants on small speakers.
  static let lowCutHz: Float = 140
  /// Make-up gain after compression, so Clear speech is also a little louder.
  static let makeUpGainDB: Float = 6
  /// The "slower" part: AVSpeech rate times this.
  static let rateFactor: Float = 0.88
  static let trebleSteps: [Float] = [0, 3, 6, 9, 12]
  static let defaultTrebleGainDB: Float = 6
}

struct AudioShape: Equatable, Sendable {
  /// -1 (all left) ... 0 (centre) ... 1 (all right).
  var balance: Float = 0
  var speechRoute: EarRoute = .both
  var earconRoute: EarRoute = .both
  var alertRoute: EarRoute = .both
  /// Mono in effect: the iOS setting, or the user's "I use mono".
  var mono = false
  /// 0.1 ... 1. Applied to the app's own voice and the natural voice.
  var speechVolume: Float = 1
  /// 0.1 ... 1, on top of the earcon engine's base level.
  var earconVolume: Float = 1
  /// nil when Clear speech is off.
  var clearSpeech: ClearSpeech?

  static let standard = AudioShape()

  func route(for kind: SoundKind) -> EarRoute {
    switch kind {
    case .speech: speechRoute
    case .earcon: earconRoute
    case .alert: alertRoute
    }
  }

  func pan(for kind: SoundKind) -> Float {
    Self.pan(route: route(for: kind), balance: balance, mono: mono)
  }

  static func pan(route: EarRoute, balance: Float, mono: Bool) -> Float {
    if mono { return 0 }
    switch route {
    case .left: return -1
    case .right: return 1
    case .both: return min(max(balance, -1), 1)
    }
  }

  func volume(for kind: SoundKind) -> Float {
    kind == .speech ? speechVolume : earconVolume
  }

  /// The app's own voice only needs the shared engine when something there changes it: a pan or
  /// Clear speech. Volume alone works on the old path through the utterance's volume.
  var speechNeedsBus: Bool { pan(for: .speech) != 0 || clearSpeech != nil }

  /// AVSpeech rate with Clear speech's slower hint.
  func speechRate(_ base: Float) -> Float {
    clearSpeech == nil ? base : base * ClearSpeech.rateFactor
  }

  /// How Watch for text marks a side with its alert tone. Pure; see the file comment.
  func sideCue(for side: WatchSide) -> SideCue {
    let canPan = !mono && alertRoute == .both
    switch side {
    case .ahead: return .plain
    case .left: return canPan ? .pan(-SideCue.panAmount) : .pitch(SideCue.leftPitch)
    case .right: return canPan ? .pan(SideCue.panAmount) : .pitch(SideCue.rightPitch)
    }
  }
}

/// A one-off change to an alert tone that says which side something is on.
enum SideCue: Equatable, Sendable {
  case plain
  case pan(Float)
  /// Frequency factor: below 1 is lower.
  case pitch(Double)

  static let panAmount: Float = 0.85
  static let leftPitch = 0.8
  static let rightPitch = 1.25
}

/// The shape every audio path reads. Written by the Ears and Sounds areas on the main actor.
enum AudioShapeStore {
  private static let lock = OSAllocatedUnfairLock(initialState: AudioShape.standard)

  static var current: AudioShape {
    get { lock.withLock { $0 } }
    set { lock.withLock { $0 = newValue } }
  }
}
