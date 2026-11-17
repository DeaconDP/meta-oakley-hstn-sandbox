/*
 * CloudVoicePlayer - plays the natural (OpenAI) reading voice as it streams in
 *
 * CloudSpeechClip fetches one sentence's audio and keeps it: TextReader asks for the next
 * sentence's clip while the current one plays (so there's no gap between sentences), and keeps
 * clips for previous/repeat. CloudVoicePlayer plays a clip from its first chunk, scheduling each
 * chunk on an AVAudioPlayerNode as it arrives.
 *
 * It plays nice with the rest of the app's audio:
 * - The session: it takes A11yAudioSession's speech hold (beginSpeech/endSpeech) exactly as the
 *   Announcer does, so the session is active in our category and on the glasses' route, other
 *   audio is ducked, and the session idles out after. Its own AVAudioEngine runs on that session
 *   and is stopped a second after the last sentence, before the session's idle check, because a
 *   session with running I/O won't deactivate (and ducked music wouldn't come back).
 * - One voice at a time: playback registers with Announcer (externalSpeechStarted), so
 *   Announcer.isSpeaking and textBeingSpoken include it for voice control's echo and barge-in
 *   rules, and Announcer.stop() or an interrupting line stops it. Callers wait for the Announcer
 *   to be idle before playing.
 * - Route changes (glasses connecting) stop the engine: the sentence starts again on the new
 *   route from the audio already received. An interruption (a call) cancels it.
 *
 * Start is reported with the uptime when the node starts (BenchClock's clock), for the
 * trigger_to_first_word metric; finish as finished, cancelled or failed.
 */

import AVFoundation
import os

/// One sentence of cloud speech: fetched once, played as it arrives, kept for repeats.
@MainActor
final class CloudSpeechClip {
  let text: String
  /// The `speed` it was fetched at (OpenAIClient.speechSpeed), so a rate change fetches it again.
  let speed: Double
  private(set) var chunks: [[Float]] = []
  private(set) var sampleCount = 0
  private(set) var isComplete = false
  private(set) var failure: OpenAIError?
  /// Set by the player while this clip is playing; called on every new chunk and at the end.
  var onChange: (@MainActor () -> Void)?

  private var decoder = PCM16Decoder()
  private var task: Task<Void, Never>?

  init(text: String, client: OpenAIClient, speed: Double = 1) {
    self.text = text
    self.speed = speed
    let stream = client.speechPCM(text: text, speed: speed)
    task = Task { [weak self] in
      do {
        for try await data in stream {
          self?.receive(data)
        }
        self?.complete(failure: Task.isCancelled ? .network : nil)
      } catch {
        self?.complete(failure: (error as? OpenAIError) ?? .network)
      }
    }
  }

  /// Stops the download. A cancelled clip counts as failed, so it is never played half-fetched.
  func cancel() {
    task?.cancel()
    task = nil
    if !isComplete { complete(failure: .network) }
  }

  private func receive(_ data: Data) {
    guard !isComplete else { return }
    let samples = decoder.samples(from: data)
    guard !samples.isEmpty else { return }
    chunks.append(samples)
    sampleCount += samples.count
    onChange?()
  }

  private func complete(failure: OpenAIError?) {
    guard !isComplete else { return }
    isComplete = true
    self.failure = failure
    onChange?()
  }
}

@MainActor
final class CloudVoicePlayer {
  static let shared = CloudVoicePlayer()

  enum End: Equatable, Sendable {
    case finished
    /// Stopped: stop(), Announcer.stop(), another play(), an interruption.
    case cancelled
    /// The audio didn't arrive (network, service) or the engine wouldn't start.
    case failed
  }

  typealias StartHandler = @MainActor (_ startedAt: UInt64) -> Void
  typealias Completion = @MainActor (_ end: End) -> Void

  /// Audio buffered before the node starts, so a slow first second doesn't stutter: 0.2 s.
  static let startBufferSamples = Int(OpenAIClient.speechSampleRate * 0.2)
  /// Below A11yAudioSession's 2 s idle delay, so the engine is stopped before the session tries
  /// to deactivate.
  static let engineIdleStop: Duration = .seconds(1)

  private(set) var isPlaying = false

  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: OpenAIClient.speechSampleRate, channels: 1)
  private let audio = A11yAudioSession.shared
  private var isConfigured = false
  private var clip: CloudSpeechClip?
  private var onStart: StartHandler?
  private var onFinish: Completion?
  private var scheduled = 0
  private var outstanding = 0
  private var started = false
  /// Bumped whenever playback starts, restarts or ends, so late buffer callbacks do nothing.
  private var token = 0
  private var holdsSession = false
  private var observers: [NSObjectProtocol] = []

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "CloudVoice")

  private init() {}

  /// Plays `clip` from its first chunk, cutting anything this player was playing. `onFinish` is
  /// called exactly once.
  func play(_ clip: CloudSpeechClip, onStart: StartHandler? = nil, onFinish: @escaping Completion) {
    end(.cancelled)
    token += 1
    let myToken = token
    self.clip = clip
    self.onStart = onStart
    self.onFinish = onFinish
    scheduled = 0
    outstanding = 0
    started = false
    isPlaying = true
    Announcer.shared.externalSpeechStarted(clip.text) { [weak self] in self?.stop() }
    if !holdsSession {
      holdsSession = true
      let audio = audio
      audio.queue.async { audio.beginSpeech() }
    }
    Task { await begin(myToken) }
  }

  func stop() {
    end(.cancelled)
  }

  // MARK: Playback

  private func begin(_ myToken: Int) async {
    // The session queue is serial: once this runs, beginSpeech has activated the session.
    let audio = audio
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      audio.queue.async { continuation.resume() }
    }
    guard token == myToken, let clip else { return }
    guard startEngine() else { return end(.failed) }
    clip.onChange = { [weak self] in self?.pump(myToken) }
    pump(myToken)
  }

  /// Schedules every chunk that has arrived, starts the node once enough is buffered, and ends
  /// when the clip is complete and all of it has been heard.
  private func pump(_ myToken: Int) {
    guard token == myToken, let clip, let format else { return }
    if clip.failure != nil { return end(.failed) }
    while scheduled < clip.chunks.count {
      let samples = clip.chunks[scheduled]
      scheduled += 1
      guard let buffer = Self.buffer(samples, format: format) else { continue }
      outstanding += 1
      node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
        Task { @MainActor in CloudVoicePlayer.shared.bufferPlayed(myToken) }
      }
    }
    if !started, outstanding > 0, clip.isComplete || clip.sampleCount >= Self.startBufferSamples {
      started = true
      node.play()
      let startedAt = BenchClock.uptimeNanoseconds()
      let handler = onStart
      onStart = nil
      handler?(startedAt)
    }
    if clip.isComplete, outstanding == 0 {
      end(.finished)
    }
  }

  private func bufferPlayed(_ myToken: Int) {
    guard token == myToken else { return }
    outstanding = max(0, outstanding - 1)
    pump(myToken)
  }

  private func end(_ result: End) {
    guard clip != nil || onFinish != nil else { return }
    token += 1
    clip?.onChange = nil
    clip = nil
    if isConfigured { node.stop() }
    started = false
    scheduled = 0
    outstanding = 0
    onStart = nil
    isPlaying = false
    if holdsSession {
      holdsSession = false
      let audio = audio
      audio.queue.async { audio.endSpeech() }
    }
    Announcer.shared.externalSpeechEnded()
    scheduleEngineIdleStop()
    let completion = onFinish
    onFinish = nil
    completion?(result)
  }

  // MARK: Engine

  private func configureIfNeeded() {
    guard !isConfigured, let format else { return }
    isConfigured = true
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
        MainActor.assumeIsolated { CloudVoicePlayer.shared.configurationChanged() }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) {
        notification in
        let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
        guard began else { return }
        MainActor.assumeIsolated { CloudVoicePlayer.shared.stop() }
      })
  }

  private func startEngine() -> Bool {
    configureIfNeeded()
    guard isConfigured else { return false }
    if engine.isRunning { return true }
    do {
      engine.prepare()
      try engine.start()
      return true
    } catch {
      Self.logger.error("Cloud voice engine failed to start: \(error.localizedDescription)")
      return false
    }
  }

  private func scheduleEngineIdleStop() {
    let myToken = token
    Task {
      try? await Task.sleep(for: Self.engineIdleStop)
      guard token == myToken, clip == nil, engine.isRunning else { return }
      engine.stop()
    }
  }

  /// The engine stopped under us (route change). Start the sentence again on the new route.
  private func configurationChanged() {
    guard isPlaying, let clip else { return }
    token += 1
    let myToken = token
    node.stop()
    scheduled = 0
    outstanding = 0
    started = false
    guard startEngine() else { return end(.failed) }
    clip.onChange = { [weak self] in self?.pump(myToken) }
    pump(myToken)
  }

  private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return nil }
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      channel.update(from: base, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    return buffer
  }
}
