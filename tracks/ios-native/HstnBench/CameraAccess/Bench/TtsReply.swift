/*
 * TtsReply - spoken reply through the glasses speakers
 *
 * DAT has no audio-output API of its own. Glasses speakers are a normal Bluetooth A2DP sink, so
 * playback audio follows the system route to them once they're connected (see the DAT
 * "Microphones and speakers" guide). This wraps AVSpeechSynthesizer and logs which output the
 * reply played on, so a benchmark run shows whether it reached the glasses. In the Simulator
 * there is no Bluetooth sink, so the reply plays on the Mac's output.
 *
 * The audio session belongs to A11yAudioSession, which the earcons and the Announcer also use.
 * Each reply takes a speech hold there (playback, ducking other audio) and gives it back when it
 * finishes or is cut. The session is released once nothing holds it, so music on the glasses
 * resumes. Releasing it here instead would cut off an earcon or Announcer line that started
 * while the reply was playing.
 */

import AVFoundation

@MainActor
final class TtsReply: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  // Looked up once; the lookup is slow enough to show up in tts_to_audio_start.
  private let voice = AVSpeechSynthesisVoice(language: "en-US")
  private let clock = BenchClock.shared
  /// The reply waiting on the audio session, if any. A newer reply cancels it.
  private var pendingReply: Task<Void, Never>?
  /// Utterances holding a speech hold on A11yAudioSession, released when each ends.
  private var heldUtterances: Set<ObjectIdentifier> = []

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
      // While recording, the recorder owns the session (play-and-record), so take no hold.
      if !isRecording {
        await Self.onSessionQueue { A11yAudioSession.shared.beginSpeech() }
      }
      guard !Task.isCancelled else {
        if !isRecording { Self.releaseHold() }
        return
      }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      if !isRecording { heldUtterances.insert(ObjectIdentifier(utterance)) }
      synthesizer.speak(utterance)
      pendingReply = nil
    }
  }

  nonisolated private static func onSessionQueue(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      A11yAudioSession.shared.queue.async {
        work()
        continuation.resume()
      }
    }
  }

  nonisolated private static func releaseHold() {
    A11yAudioSession.shared.queue.async { A11yAudioSession.shared.endSpeech() }
  }

  /// Gives back the hold the utterance took, if it took one. Called once per utterance, on
  /// finish or cancel.
  private func utteranceEnded(_ id: ObjectIdentifier) {
    guard heldUtterances.remove(id) != nil else { return }
    Self.releaseHold()
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
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceEnded(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.utteranceEnded(id) }
  }
}
