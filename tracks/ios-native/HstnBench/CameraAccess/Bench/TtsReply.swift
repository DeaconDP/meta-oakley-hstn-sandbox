/*
 * TtsReply - spoken reply through the glasses speakers
 *
 * DAT has no audio-output API of its own. Glasses speakers are a normal Bluetooth A2DP sink, so
 * playback audio follows the system route to them once they're connected (see the DAT
 * "Microphones and speakers" guide). This wraps AVSpeechSynthesizer and logs which output the
 * reply played on, so a benchmark run shows whether it reached the glasses. In the Simulator
 * there is no Bluetooth sink, so the reply plays on the Mac's output.
 */

import AVFoundation

@MainActor
final class TtsReply: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private let clock = BenchClock.shared

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Speaks `text`, interrupting any reply still playing.
  func speak(_ text: String) {
    clock.start("tts_to_audio_start")
    clock.start("tts_total")
    configureAudioSession()
    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  /// Uses a playback session (A2DP) unless the glasses-mic path already holds play-and-record,
  /// which must not be downgraded mid-recording.
  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    guard session.category != .playAndRecord else { return }
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    } catch {
      clock.note("tts_session_error=\(error.localizedDescription)")
    }
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
  }
}
