/*
 * AudioBus - the app's own voice and the earcons on one AVAudioEngine, so pan, volume and Clear
 * speech apply to both (customisation roadmap C0, "one audio bus")
 *
 * The engine is A11yAudioSession's earcon engine. A11yAudioSession calls install(...) once it has
 * built it, earconBuffer(...) before each earcon, and engineStopped() when a route change or an
 * interruption stops it. Everything here is confined to A11yAudioSession's serial queue, like the
 * engine itself.
 *
 *   earconNode, tickNode ----------------------------------------------> main mixer
 *   speechNode -> SpeechShapingChain (pan mixer, dynamics, EQ) --------> main mixer
 *
 * Speech arrives as a stream from SpeechBusSpeaker: AVSpeechSynthesizer.write hands over PCM
 * buffers, which are converted to the speech node's format and scheduled as they come, so the
 * first syllable plays as soon as the first buffer is ready. The stream ends when synthesis has
 * finished and every buffer has been heard (.dataPlayedBack), which is what keeps Announcer's
 * one-line-at-a-time queue and voice control's echo rules working.
 *
 * Timing (for the 100 ms earcon rule and first-word latency) is kept in AudioBusMetrics.
 */

import AVFoundation
import os

/// How a bus speech stream ended.
enum BusSpeechEnd: Equatable, Sendable {
  case finished
  /// Stopped by the caller, a route change or an interruption.
  case cut
  /// Nothing was heard: the engine wouldn't start or no audio came. The caller can fall back.
  case failedBeforeAudio
}

/// Latest timings, in milliseconds. Written on the audio queue, read anywhere.
struct AudioBusTimings: Equatable, Sendable {
  /// Speech: from the Announcer's speak to the first synthesized buffer reaching the bus.
  var speechToFirstBufferMs: Double?
  /// Speech: from the Announcer's speak to the speech node starting to play.
  var speechToPlayMs: Double?
  /// Earcon: from EarconPlayer.play to the buffer being scheduled.
  var earconToScheduleMs: Double?
  /// The output's own latency (session output latency plus one IO buffer), added to both above.
  var outputLatencyMs: Double?
}

enum AudioBusMetrics {
  private static let lock = OSAllocatedUnfairLock(initialState: AudioBusTimings())
  static var latest: AudioBusTimings {
    get { lock.withLock { $0 } }
    set { lock.withLock { $0 = newValue } }
  }

  static func update(_ change: @Sendable (inout AudioBusTimings) -> Void) {
    lock.withLock { change(&$0) }
  }
}

final class AudioBus: @unchecked Sendable {
  static let shared = AudioBus()

  /// The speech node's format. Most AVSpeech voices synthesize at 22.05 kHz, so usually only the
  /// sample type changes.
  static let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!

  /// Earcon base level, as before the bus. The Sounds area's earcon volume scales it.
  static let earconBaseVolume: Float = 0.7

  let queue: DispatchQueue

  // MARK: Queue-confined

  private weak var engine: AVAudioEngine?
  private weak var earconNode: AVAudioPlayerNode?
  private weak var tickNode: AVAudioPlayerNode?
  private let speechNode = AVAudioPlayerNode()
  private let chain = SpeechShapingChain()
  private var startEngine: (() -> Bool)?
  private var shape = AudioShape.standard
  private var pendingSideCue: (earcon: Earcon, cue: SideCue, expires: UInt64)?
  private var stream: Stream?

  private struct Stream {
    let id: Int
    let requestedAt: UInt64
    let onStart: @Sendable (UInt64) -> Void
    let onEnd: @Sendable (BusSpeechEnd) -> Void
    var converter: AVAudioConverter?
    var converterInput: AVAudioFormat?
    var outstanding = 0
    var synthesisDone = false
    var started = false
  }

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "AudioBus")

  init(queue: DispatchQueue = A11yAudioSession.shared.queue) {
    self.queue = queue
  }

  var isInstalled: Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    return engine != nil
  }

  // MARK: Called by A11yAudioSession

  /// Adds the speech path to the earcon engine. Called once, before the engine is prepared.
  func install(
    on engine: AVAudioEngine, earconNode: AVAudioPlayerNode, tickNode: AVAudioPlayerNode, startEngine: @escaping () -> Bool
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard self.engine == nil else { return }
    self.engine = engine
    self.earconNode = earconNode
    self.tickNode = tickNode
    self.startEngine = startEngine
    engine.attach(speechNode)
    chain.install(on: engine, source: speechNode, sourceFormat: Self.speechFormat, destination: engine.mainMixerNode)
    applyOnQueue(AudioShapeStore.current)
  }

  /// The buffer to play for `earcon`, with the earcon node set to the earcon's ear and volume.
  /// A pending side cue (Watch for text) pans it or changes its pitch once.
  func earconBuffer(for earcon: Earcon, standard: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
    dispatchPrecondition(condition: .onQueue(queue))
    var buffer = standard
    var pan = shape.pan(for: earcon.soundKind)
    if let pending = pendingSideCue, pending.earcon == earcon {
      pendingSideCue = nil
      if DispatchTime.now().uptimeNanoseconds < pending.expires {
        switch pending.cue {
        case .plain: break
        case .pan(let value): pan = value
        case .pitch(let factor):
          if let format = standard?.format {
            buffer = EarconSynth.render(Self.scaled(earcon.notes, by: factor), timbre: earcon.timbre, format: format) ?? standard
          }
        }
      }
    }
    earconNode?.pan = pan
    earconNode?.volume = Self.earconBaseVolume * shape.earconVolume
    return buffer
  }

  /// Called once an earcon is scheduled and playing: the time since EarconPlayer.play, including any
  /// session activation and engine start.
  static func recordEarcon(requestedAt: UInt64) {
    let ms = Double(DispatchTime.now().uptimeNanoseconds &- requestedAt) / 1_000_000
    AudioBusMetrics.update {
      $0.earconToScheduleMs = ms
      $0.outputLatencyMs = outputLatencyMs()
    }
  }

  /// The engine stopped under us (route change, interruption, idle). A stream in progress is cut,
  /// so the Announcer's line ends instead of waiting for buffers that will never play.
  func engineStopped() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let stream else { return }
    self.stream = nil
    speechNode.stop()
    stream.onEnd(stream.started ? .cut : .failedBeforeAudio)
  }

  // MARK: Shape

  /// Applies `shape` to every node. Call from anywhere.
  func apply(_ shape: AudioShape) {
    queue.async { [self] in applyOnQueue(shape) }
  }

  private func applyOnQueue(_ shape: AudioShape) {
    self.shape = shape
    chain.apply(shape, source: speechNode)
    earconNode?.volume = Self.earconBaseVolume * shape.earconVolume
    earconNode?.pan = shape.pan(for: .earcon)
    tickNode?.volume = Self.earconBaseVolume * shape.earconVolume
    tickNode?.pan = shape.pan(for: .earcon)
  }

  /// The next `earcon` (within a second and a half) gets `cue`. Call from anywhere, before the
  /// earcon is played.
  func placeNext(_ earcon: Earcon, cue: SideCue) {
    let expires = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
    queue.async { [self] in pendingSideCue = (earcon, cue, expires) }
  }

  static func scaled(_ notes: [EarconNote], by factor: Double) -> [EarconNote] {
    notes.map { note in
      var copy = note
      copy.from *= factor
      copy.to *= factor
      return copy
    }
  }

  // MARK: Speech stream

  /// Starts stream `id`. Buffers follow with append(_:id:), then finishSynthesis(id:).
  func beginStream(
    id: Int, requestedAt: UInt64, onStart: @escaping @Sendable (UInt64) -> Void,
    onEnd: @escaping @Sendable (BusSpeechEnd) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    if let old = stream {
      stream = nil
      speechNode.stop()
      old.onEnd(.cut)
    }
    guard let startEngine, startEngine() else {
      Self.logger.error("speech bus: the engine wouldn't start")
      onEnd(.failedBeforeAudio)
      return
    }
    stream = Stream(id: id, requestedAt: requestedAt, onStart: onStart, onEnd: onEnd)
  }

  func append(_ buffer: AVAudioPCMBuffer, id: Int) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard var stream, stream.id == id, buffer.frameLength > 0 else { return }
    if stream.outstanding == 0, !stream.started {
      let ms = Double(DispatchTime.now().uptimeNanoseconds &- stream.requestedAt) / 1_000_000
      AudioBusMetrics.update { $0.speechToFirstBufferMs = ms }
    }
    guard let converted = convert(buffer, stream: &stream) else {
      self.stream = stream
      return
    }
    stream.outstanding += 1
    speechNode.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [self] _ in
      queue.async { [self] in bufferPlayed(id: id) }
    }
    if !stream.started {
      guard engine?.isRunning == true || (startEngine?() ?? false) else {
        self.stream = nil
        stream.onEnd(.failedBeforeAudio)
        return
      }
      speechNode.play()
      stream.started = true
      let now = DispatchTime.now().uptimeNanoseconds
      let ms = Double(now &- stream.requestedAt) / 1_000_000
      AudioBusMetrics.update {
        $0.speechToPlayMs = ms
        $0.outputLatencyMs = Self.outputLatencyMs()
      }
      Self.logger.info("speech bus: first audio \(ms, format: .fixed(precision: 1)) ms after speak")
      stream.onStart(now)
    } else if !speechNode.isPlaying {
      speechNode.play()
    }
    self.stream = stream
  }

  func finishSynthesis(id: Int) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard var stream, stream.id == id else { return }
    stream.synthesisDone = true
    self.stream = stream
    endIfDone()
  }

  /// The caller cut the stream (Announcer.stop or an interrupting line). No onEnd: the caller knows.
  func cancelStream(id: Int) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let stream, stream.id == id else { return }
    self.stream = nil
    speechNode.stop()
  }

  private func bufferPlayed(id: Int) {
    guard var stream, stream.id == id else { return }
    stream.outstanding = max(0, stream.outstanding - 1)
    self.stream = stream
    endIfDone()
  }

  private func endIfDone() {
    guard let stream, stream.synthesisDone, stream.outstanding == 0 else { return }
    self.stream = nil
    stream.onEnd(stream.started ? .finished : .failedBeforeAudio)
  }

  private func convert(_ buffer: AVAudioPCMBuffer, stream: inout Stream) -> AVAudioPCMBuffer? {
    let output = Self.speechFormat
    if buffer.format == output { return buffer }
    if stream.converter == nil || stream.converterInput != buffer.format {
      stream.converter = AVAudioConverter(from: buffer.format, to: output)
      stream.converterInput = buffer.format
    }
    guard let converter = stream.converter else { return nil }
    let ratio = output.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
    guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
    let feed = OneShotInput(buffer)
    var error: NSError?
    let status = converter.convert(to: result, error: &error) { _, inputStatus in
      guard let next = feed.take() else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputStatus.pointee = .haveData
      return next
    }
    if status == .error {
      Self.logger.error("speech bus: conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
      return nil
    }
    return result.frameLength > 0 ? result : nil
  }

  static func outputLatencyMs() -> Double {
    let session = AVAudioSession.sharedInstance()
    return (session.outputLatency + session.ioBufferDuration) * 1000
  }
}

/// Hands one buffer to an AVAudioConverter input block, then nothing. The block runs synchronously
/// inside convert(to:error:withInputFrom:), on the audio queue.
private final class OneShotInput: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func take() -> AVAudioPCMBuffer? {
    defer { buffer = nil }
    return buffer
  }
}
