/*
 * SpeechBusSpeaker - speaks an AVSpeechUtterance through the shared engine (AudioBus) instead of
 * straight to the output
 *
 * Its own AVSpeechSynthesizer renders with write(_:toBufferCallback:), and the buffers go to
 * AudioBus on the audio queue. Announcer decides per line whether to use it (shouldRoute), so the
 * old path stays the default:
 *
 * - routing .whenShaped (default): only when the user's settings need it, that is a speech pan
 *   (balance or a speech ear) or Clear speech. Volume alone works on the old path.
 * - .always / .off: for testing and as a kill switch ("ears.speechBus" in UserDefaults).
 *
 * VoiceOver announcements never come here: they belong to VoiceOver and can't be routed.
 *
 * If the bus fails before any audio (engine won't start, nothing synthesized within
 * `firstAudioTimeout`), the line is handed back through `fallback` to be spoken the old way, and the
 * bus is not used again this run, so a broken bus costs one delayed line, not every line.
 */

import AVFoundation
import os

@MainActor
final class SpeechBusSpeaker {
  static let shared = SpeechBusSpeaker()

  enum Routing: String, Sendable {
    case off
    case whenShaped
    case always
  }

  static let routingKey = "ears.speechBus"
  static let firstAudioTimeout: Duration = .milliseconds(2500)

  var routing: Routing
  /// Set after a failure; the old path is used for the rest of the run.
  private(set) var isBroken = false
  var isSpeaking: Bool { current != nil }

  private let synthesizer = AVSpeechSynthesizer()
  private var current: Handlers?
  private var nextID = 0

  private struct Handlers {
    let id: Int
    let onStart: @MainActor (UInt64) -> Void
    let onEnd: @MainActor (Bool) -> Void
    let fallback: @MainActor () -> Void
    var heard = false
  }

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "SpeechBus")

  init(defaults: UserDefaults = .standard) {
    routing = defaults.string(forKey: Self.routingKey).flatMap(Routing.init(rawValue:)) ?? .whenShaped
  }

  /// Whether the app's own voice should go through the bus for the next line.
  func shouldRoute(shape: AudioShape = AudioShapeStore.current) -> Bool {
    Self.shouldRoute(routing: routing, broken: isBroken, shape: shape)
  }

  nonisolated static func shouldRoute(routing: Routing, broken: Bool, shape: AudioShape) -> Bool {
    guard !broken else { return false }
    switch routing {
    case .off: return false
    case .always: return true
    case .whenShaped: return shape.speechNeedsBus
    }
  }

  /// Speaks `utterance` through the bus. Exactly one of onEnd or fallback is called, unless stop()
  /// is called first.
  func speak(
    _ utterance: AVSpeechUtterance, onStart: @escaping @MainActor (UInt64) -> Void,
    onEnd: @escaping @MainActor (Bool) -> Void, fallback: @escaping @MainActor () -> Void
  ) {
    stop()
    nextID += 1
    let id = nextID
    current = Handlers(id: id, onStart: onStart, onEnd: onEnd, fallback: fallback)
    let requestedAt = DispatchTime.now().uptimeNanoseconds
    let bus = AudioBus.shared
    bus.queue.async {
      bus.beginStream(
        id: id, requestedAt: requestedAt,
        onStart: { startedAt in Task { @MainActor in SpeechBusSpeaker.shared.started(id: id, at: startedAt) } },
        onEnd: { end in Task { @MainActor in SpeechBusSpeaker.shared.ended(id: id, end) } })
    }
    synthesizer.write(utterance, toBufferCallback: Self.bufferCallback(id: id, bus: bus))
    Task {
      try? await Task.sleep(for: Self.firstAudioTimeout)
      if let current, current.id == id, !current.heard {
        Self.logger.error("speech bus: no audio within the timeout, falling back")
        ended(id: id, .failedBeforeAudio)
      }
    }
  }

  /// The first write on a new synthesizer loads the voice and took about 600 ms on the iOS 27
  /// simulator, against about 4 ms once warm. Renders one silent word and throws it away, once, so the
  /// user's first bus line doesn't pay that. Called when the settings first need the bus.
  func prewarm(voice: AVSpeechSynthesisVoice?) {
    guard !isWarm, current == nil, routing != .off else { return }
    isWarm = true
    let utterance = AVSpeechUtterance(string: "ok")
    utterance.voice = voice
    utterance.volume = 0
    synthesizer.write(utterance, toBufferCallback: Self.discard)
  }

  private var isWarm = false

  nonisolated private static let discard: @Sendable (AVAudioBuffer) -> Void = { _ in }

  /// Cuts the line now playing, without calling its handlers.
  func stop() {
    guard let current else { return }
    self.current = nil
    synthesizer.stopSpeaking(at: .immediate)
    let bus = AudioBus.shared
    let id = current.id
    bus.queue.async { bus.cancelStream(id: id) }
  }

  /// Built outside the main actor: the synthesizer calls it on its own thread, and a closure formed
  /// on the main actor would be main-actor isolated and trap there.
  nonisolated private static func bufferCallback(id: Int, bus: AudioBus) -> @Sendable (AVAudioBuffer) -> Void {
    { buffer in
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      nonisolated(unsafe) let sendable = pcm
      bus.queue.async {
        if sendable.frameLength == 0 {
          bus.finishSynthesis(id: id)
        } else {
          bus.append(sendable, id: id)
        }
      }
    }
  }

  private func started(id: Int, at startedAt: UInt64) {
    guard var current, current.id == id else { return }
    current.heard = true
    self.current = current
    current.onStart(startedAt)
  }

  private func ended(id: Int, _ end: BusSpeechEnd) {
    guard let current, current.id == id else { return }
    self.current = nil
    switch end {
    case .finished: current.onEnd(true)
    case .cut: current.onEnd(false)
    case .failedBeforeAudio:
      isBroken = true
      synthesizer.stopSpeaking(at: .immediate)
      let bus = AudioBus.shared
      bus.queue.async { bus.cancelStream(id: id) }
      current.fallback()
    }
  }
}
