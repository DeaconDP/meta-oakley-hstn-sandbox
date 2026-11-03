/*
 * EarconPlayer - plays earcons and the "still working" tick
 *
 * Main-actor front for A11yAudioSession, which renders and plays the tones on its own queue so a
 * call here never blocks the UI. Respects the user's "earcons on" preference. Earcons mix with
 * other audio and with VoiceOver: they never interrupt speech, VoiceOver's or ours.
 */

import Foundation

@MainActor
final class EarconPlayer {
  static let shared = EarconPlayer()

  /// True while at least one owner wants the working tick.
  var isTicking: Bool { !tickOwners.isEmpty }

  /// Who asked for the tick ("camera", "registration", ...). One owner's stop doesn't silence
  /// another's wait.
  private(set) var tickOwners: Set<String> = []

  private let audio = A11yAudioSession.shared
  private let preferences = A11yPreferences.shared

  private init() {
    prepare()
  }

  /// Renders the tones and builds the engine ahead of the first earcon. Called on first use of
  /// `shared`; call it again at launch to move that work off the first tap.
  func prepare() {
    let audio = audio
    audio.queue.async { audio.prepareEngine() }
  }

  func play(_ earcon: Earcon) {
    guard preferences.earconsEnabled else { return }
    let audio = audio
    audio.queue.async { audio.playEarcon(earcon) }
  }

  /// A soft tick about every second while any owner is waiting, so a wait is never silent.
  /// Starting again for an owner that is already ticking does nothing.
  func startWorkingTick(owner: String = "default") {
    guard preferences.earconsEnabled else { return }
    let wasTicking = isTicking
    tickOwners.insert(owner)
    guard !wasTicking else { return }
    let audio = audio
    audio.queue.async { audio.startTick() }
  }

  /// Removes `owner`; the tick stops once no owner is left. Works even if earcons were turned off
  /// while ticking.
  func stopWorkingTick(owner: String = "default") {
    guard tickOwners.remove(owner) != nil, !isTicking else { return }
    let audio = audio
    audio.queue.async { audio.stopTick() }
  }

  /// Stops the tick for every owner, e.g. when earcons are turned off.
  func stopAllWorkingTicks() {
    guard isTicking else { return }
    tickOwners.removeAll()
    let audio = audio
    audio.queue.async { audio.stopTick() }
  }
}
