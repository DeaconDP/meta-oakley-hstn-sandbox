/*
 * RealtimeAudio - the phone mic in and the assistant's voice out for a Realtime conversation
 *
 * Mic: AVAudioEngine's input node with Apple's voice processing on (echo cancellation), so the
 * mic doesn't hear the assistant through the glasses' open-ear speakers or the phone speaker and
 * the user can talk over it (barge-in). Each tap buffer is converted to 24 kHz mono PCM16 and
 * handed to `onMicChunk`.
 *
 * Out: an AVAudioPlayerNode on the same engine, fed 24 kHz PCM16 converted to float. Every
 * scheduled buffer's completion lowers `unplayedBytes`, which tells a barge-in how much of the
 * reply was really heard.
 *
 * The session: the phone mic is taken through A11yAudioSession.beginInput, the same hold the
 * command listener uses (play-and-record, A2DP allowed, HFP not, so output stays on the glasses at
 * full quality). VoiceControl pauses its listener first, so there is one owner at a time.
 *
 * All engine work runs on A11yAudioSession's queue, which also confines the state below.
 */

import AVFoundation
import os

final class RealtimeAudio: @unchecked Sendable {
  /// 24 kHz mono PCM16 chunks, on the audio queue.
  var onMicChunk: (@Sendable (Data) -> Void)?

  private let session = A11yAudioSession.shared
  private var engine: AVAudioEngine?
  private let player = AVAudioPlayerNode()
  private var converter: AVAudioConverter?
  private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RealtimeConfig.sampleRate), channels: 1, interleaved: true)!
  private let floatFormat = AVAudioFormat(standardFormatWithSampleRate: Double(RealtimeConfig.sampleRate), channels: 1)!
  private var pending = 0

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "Realtime")

  /// Bytes of reply audio scheduled but not yet played.
  var unplayedBytes: Int { session.queue.sync { pending } }

  /// Starts mic and output. False if the session or engine wouldn't start (no mic permission,
  /// another app holding the mic).
  func start() async -> Bool {
    await withCheckedContinuation { continuation in
      session.queue.async { [self] in
        let hold = A11yAudioSession.InputHold(
          pause: { [weak self] in self?.engine?.pause() },
          resume: { [weak self] in try? self?.engine?.start() })
        guard session.beginInput(hold) else {
          continuation.resume(returning: false)
          return
        }
        session.beginSpeech()
        continuation.resume(returning: startEngine())
      }
    }
  }

  func stop() {
    session.queue.async { [self] in
      guard let engine else { return }
      engine.inputNode.removeTap(onBus: 0)
      player.stop()
      engine.stop()
      self.engine = nil
      converter = nil
      pending = 0
      session.endSpeech()
      session.endInput()
    }
  }

  /// Queues reply audio (24 kHz mono PCM16).
  func play(_ pcm16: Data) {
    session.queue.async { [self] in
      guard engine != nil, let buffer = floatBuffer(from: pcm16) else { return }
      pending += pcm16.count
      let bytes = pcm16.count
      player.scheduleBuffer(buffer) { [weak self] in
        guard let self else { return }
        session.queue.async { self.pending = max(0, self.pending - bytes) }
      }
      if !player.isPlaying { player.play() }
    }
  }

  /// Drops everything queued (barge-in, or leaving). Returns the bytes that were never heard.
  @discardableResult
  func flush() -> Int {
    session.queue.sync {
      let unheard = pending
      player.stop()
      pending = 0
      return unheard
    }
  }

  // MARK: - Engine

  private func startEngine() -> Bool {
    dispatchPrecondition(condition: .onQueue(session.queue))
    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
      // Echo cancellation. Has to be set before the engine starts; it also applies to output.
      try input.setVoiceProcessingEnabled(true)
    } catch {
      Self.logger.error("voice processing unavailable: \(error.localizedDescription)")
    }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: floatFormat)

    let micFormat = input.outputFormat(forBus: 0)
    guard micFormat.sampleRate > 0, let converter = AVAudioConverter(from: micFormat, to: pcmFormat) else {
      Self.logger.error("no usable mic format")
      return false
    }
    self.converter = converter
    input.installTap(onBus: 0, bufferSize: 2_400, format: micFormat) { [weak self] buffer, _ in
      self?.convertAndSend(buffer)
    }
    do {
      try engine.start()
    } catch {
      Self.logger.error("engine start failed: \(error.localizedDescription)")
      input.removeTap(onBus: 0)
      return false
    }
    self.engine = engine
    return true
  }

  /// Runs on the tap's thread; the converter is only used here once set.
  private func convertAndSend(_ buffer: AVAudioPCMBuffer) {
    guard let converter, let onMicChunk else { return }
    let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
    var supplied = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
    onMicChunk(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
  }

  private func floatBuffer(from pcm16: Data) -> AVAudioPCMBuffer? {
    let frames = pcm16.count / 2
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frames)),
      let channel = buffer.floatChannelData?[0]
    else { return nil }
    pcm16.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for index in 0..<frames { channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768 }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
  }
}
