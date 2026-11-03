/*
 * GlassesSpeechListener - voice commands through DAT's on-glasses recogniser (MWDATSpeech)
 *
 * Experimental in DAT (dev and beta channels only), so it sits behind VoiceFeatureFlags. It hears
 * through the glasses mic and keeps output on A2DP, which is why it's preferred once a session is
 * STARTED and the wearable microphone permission is granted. The app touches no audio session for
 * it, and the docs don't say whether it contends with a running camera stream.
 *
 * Only final results count. Confidence -1 means "no score", not low confidence (DAT speech docs).
 */

import Foundation
import MWDATCore
import MWDATSpeech
import os

enum GlassesTranscriptFilter {
  /// Below this a real score is too unsure to act on. A guess [est]; tune on hardware.
  static let minimumConfidence: Float = 0.3

  /// The text to act on, or nil.
  static func accepted(text: String, isFinal: Bool, confidence: Float) -> String? {
    guard isFinal, !text.isEmpty else { return nil }
    // Negative is "unavailable" (documented as -1): don't discard for the lack of a score.
    if confidence >= 0, confidence < minimumConfidence { return nil }
    return text
  }
}

@MainActor
final class GlassesSpeechListener: SpeechListener {
  let kind = VoiceListenerKind.glasses
  var onEvent: (@MainActor (SpeechListenerEvent) -> Void)?

  private let session: DeviceSession
  private var speech: MWDATSpeech.Speech?
  private var tokens: [any AnyListenerToken] = []
  private var isRunning = false
  /// Speech reported .started, so a later .stopped means it ended by itself.
  private var hasStarted = false

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "VoiceControl")

  init(session: DeviceSession) {
    self.session = session
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    do throws(DeviceSessionError) {
      guard let speech = try session.addSpeech() else {
        fail("session has no Speech", transient: false)
        return
      }
      self.speech = speech
      // Listeners before start(), so no initial state, error or result is missed.
      tokens = [
        speech.statePublisher.listen { [weak self] state in
          Task { @MainActor in self?.stateChanged(state) }
        },
        speech.transcriptionPublisher.listen { [weak self] result in
          guard let text = GlassesTranscriptFilter.accepted(text: result.text, isFinal: result.isFinal, confidence: result.confidence)
          else { return }
          Task { @MainActor in
            guard let self, self.isRunning else { return }
            self.onEvent?(.transcript(text))
          }
        },
        speech.errorPublisher.listen { [weak self] error in
          Task { @MainActor in self?.errorReported(error) }
        },
      ]
      speech.start()
    } catch {
      fail("addSpeech: \(error.localizedDescription)", transient: false)
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    release()
  }

  /// Stop, cancel the listeners, then remove: that order, per the DAT skill. Removing is terminal
  /// for this Speech; the next start() adds a new one.
  private func release() {
    let speech = speech
    let tokens = tokens
    let session = session
    self.speech = nil
    self.tokens = []
    hasStarted = false
    speech?.stop()
    Task {
      for token in tokens { await token.cancel() }
      if speech != nil { try? session.removeSpeech() }
    }
  }

  private func stateChanged(_ state: SpeechState) {
    guard isRunning else { return }
    switch state {
    case .started:
      hasStarted = true
      onEvent?(.started)
    case .stopped:
      guard hasStarted else { return }
      // Documented: it can stop after inactivity, a timeout or a performance limit.
      isRunning = false
      release()
      onEvent?(.finished)
    case .starting, .stopping:
      break
    }
  }

  private func errorReported(_ error: SpeechError) {
    guard isRunning else { return }
    if error == .alreadyListening { return }
    fail(error.description, transient: false)
  }

  private func fail(_ reason: String, transient: Bool) {
    Self.logger.error("glasses listener: \(reason, privacy: .public)")
    isRunning = false
    release()
    onEvent?(.failed(reason: reason, transient: transient))
  }
}
