/*
 * TtsReply - spoken reply through the glasses speakers
 *
 * DAT has no audio-output API of its own. Glasses speakers are a normal Bluetooth A2DP sink, so
 * playback audio follows the system route to them once they're connected (see the DAT
 * "Microphones and speakers" guide). This wraps AVSpeechSynthesizer and logs which output the
 * reply played on, so a benchmark run shows whether it reached the glasses. In the Simulator
 * there is no Bluetooth sink, so the reply plays on the Mac's output.
 *
 * Audio-session calls block, so they run on a serial queue instead of the main thread. Each reply
 * ducks other audio and releases the session when it finishes, so music on the glasses resumes.
 */

import AVFoundation

@MainActor
final class TtsReply: NSObject, AVSpeechSynthesizerDelegate {
  /// Serial, so activations and deactivations apply in the order they were requested.
  nonisolated private static let sessionQueue = DispatchQueue(label: "com.deaco.hstnbench.tts-session", qos: .userInitiated)

  private let synthesizer = AVSpeechSynthesizer()
  // Looked up once; the lookup is slow enough to show up in tts_to_audio_start.
  private let voice = AVSpeechSynthesisVoice(language: "en-US")
  private let clock = BenchClock.shared
  /// The reply waiting on the audio session, if any. A newer reply cancels it.
  private var pendingReply: Task<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Speaks `text`, interrupting any reply still playing. While `isRecording`, the recorder owns
  /// the audio session (play-and-record for the glasses mic), so the reply uses it as it is.
  func speak(_ text: String, isRecording: Bool) {
    clock.start("tts_to_audio_start")
    clock.start("tts_total")
    pendingReply?.cancel()
    synthesizer.stopSpeaking(at: .immediate)
    pendingReply = Task {
      if !isRecording {
        await Self.runOnSessionQueue(Self.activatePlayback)
      }
      guard !Task.isCancelled else { return }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      synthesizer.speak(utterance)
      pendingReply = nil
    }
  }

  nonisolated private static func runOnSessionQueue(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      sessionQueue.async {
        work()
        continuation.resume()
      }
    }
  }

  /// Switches to a playback session, which routes to the glasses over A2DP. The category is set
  /// every time because a finished recording leaves it at play-and-record (HFP).
  nonisolated private static func activatePlayback() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
      try session.setActive(true)
    } catch {
      BenchClock.shared.note("tts_session_error=\(error.localizedDescription)")
    }
  }

  /// Releases the playback session so ducked audio comes back. Leaves play-and-record alone,
  /// since a recording that started mid-reply owns it.
  nonisolated private static func deactivatePlayback() {
    let session = AVAudioSession.sharedInstance()
    guard session.category == .playback else { return }
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      BenchClock.shared.note("tts_session_error=\(error.localizedDescription)")
    }
  }

  /// Deactivates once nothing is speaking or about to speak.
  private func releaseSessionIfIdle() {
    guard pendingReply == nil, !synthesizer.isSpeaking else { return }
    Self.sessionQueue.async(execute: Self.deactivatePlayback)
  }

  /// "a2dp" when a Bluetooth A2DP sink (the glasses) is the output, "hfp" for Bluetooth hands-free,
  /// otherwise "phone".
  nonisolated private static func outputRoute() -> String {
    let ports = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
    if ports.contains(.bluetoothA2DP) { return "a2dp" }
    if ports.contains(.bluetoothHFP) { return "hfp" }
    return "phone"
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    BenchClock.shared.end("tts_to_audio_start", detail: "route=\(Self.outputRoute())")
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    BenchClock.shared.end("tts_total")
    Task { @MainActor in self.releaseSessionIfIdle() }
  }
}
