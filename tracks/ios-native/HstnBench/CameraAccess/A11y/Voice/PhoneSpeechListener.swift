/*
 * PhoneSpeechListener - voice commands through the phone's mic and on-device recognition
 *
 * SFSpeechRecognizer with requiresOnDeviceRecognition, so audio never leaves the phone, fed by an
 * AVAudioEngine tap. Used during setup, with no session, and whenever glasses Speech fails.
 *
 * Audio belongs to A11yAudioSession: the session goes to play-and-record with A2DP (no HFP) while
 * this holds the input, and PhoneMicTap's engine lives on that session's serial queue.
 *
 * A partial result is never acted on as such. A recognition task doesn't report "final" until its
 * audio ends, so an utterance is taken as finished after `endpointSilence` without a new partial;
 * that text goes out as the transcript and a new task starts on the same running engine. Tasks are
 * also rotated while idle, since a long-lived one grows and may be ended by the system. Nothing is
 * stored or logged except failure reasons.
 */

import AVFoundation
import Speech
import os

enum SpeechRecognitionFailure: Equatable {
  /// Try the next utterance straight away.
  case routine
  /// Retrying won't help until the user changes something: speak the fix.
  case recognizerUnavailable
  /// Back off and try again.
  case transient

  /// On-device recognition reports through kLSRErrorDomain (102 assets not installed, 201 dictation
  /// or Siri off, 301 cancelled), the older path through kAFAssistantErrorDomain (203 retry, 209
  /// and 1110 no speech, 216 and 301 cancelled). Everything else, such as 300 (recogniser failed
  /// to start), counts as transient. The codes are undocumented, so re-check them on hardware.
  static func classify(domain: String, code: Int) -> SpeechRecognitionFailure {
    switch domain {
    case "kAFAssistantErrorDomain" where [203, 209, 216, 301, 1110].contains(code): .routine
    case "kLSRErrorDomain" where code == 301: .routine
    case "kLSRErrorDomain" where [102, 201].contains(code): .recognizerUnavailable
    default: .transient
    }
  }
}

@MainActor
final class PhoneSpeechListener: SpeechListener {
  let kind = VoiceListenerKind.phone
  var onEvent: (@MainActor (SpeechListenerEvent) -> Void)?

  static let endpointSilence: Duration = .milliseconds(700)
  static let taskLifetime: Duration = .seconds(50)
  /// Biases recognition towards the app's words. Stays on the device like everything else.
  private static let hints = ["reader", "read this", "read aloud", "take a photo", "test the speaker", "what can I say"]

  private let recognizer: SFSpeechRecognizer
  private let mic = PhoneMicTap()
  private var task: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  /// Bumped for each task, so late results from an old one do nothing.
  private var generation = 0
  private var isRunning = false
  private var pendingText: String?
  private var endpointTimer: Task<Void, Never>?
  private var rotationTimer: Task<Void, Never>?

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "VoiceControl")

  /// nil if iOS has no recogniser for the locale.
  init?(localeIdentifier: String) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return nil }
    self.recognizer = recognizer
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    mic.onFailure = { [weak self] reason in
      Task { @MainActor in self?.fail(reason, transient: true) }
    }
    mic.start { [weak self] failure in
      Task { @MainActor in self?.micStarted(failure: failure) }
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    endTask()
    mic.stop()
  }

  private func micStarted(failure: String?) {
    guard isRunning else { return }
    if let failure {
      fail(failure, transient: true)
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      fail("no on-device recognition", transient: false)
      return
    }
    startTask()
    onEvent?(.started)
  }

  private func fail(_ reason: String, transient: Bool) {
    guard isRunning else { return }
    Self.logger.error("phone listener: \(reason, privacy: .public)")
    stop()
    onEvent?(.failed(reason: reason, transient: transient))
  }

  // MARK: Recognition tasks

  private func startTask() {
    endTask()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = false
    request.taskHint = .confirmation
    request.contextualStrings = Self.hints
    self.request = request
    mic.feed(request)
    generation += 1
    task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self, generation: generation))
    rotationTimer = Task { [weak self] in
      try? await Task.sleep(for: Self.taskLifetime)
      guard !Task.isCancelled, let self, self.pendingText == nil else { return }
      self.startTask()
    }
  }

  private func endTask() {
    generation += 1
    endpointTimer?.cancel()
    endpointTimer = nil
    rotationTimer?.cancel()
    rotationTimer = nil
    pendingText = nil
    mic.feed(nil)
    request?.endAudio()
    request = nil
    task?.cancel()
    task = nil
  }

  /// nonisolated, so the closure doesn't inherit main-actor isolation it might not run under.
  nonisolated private static func resultHandler(
    owner: PhoneSpeechListener, generation: Int
  ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    { [weak owner] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failure = error.map { $0 as NSError }
      let domain = failure?.domain
      let code = failure?.code
      Task { @MainActor in
        owner?.handleResult(text: text, isFinal: isFinal, errorDomain: domain, errorCode: code, generation: generation)
      }
    }
  }

  private func handleResult(text: String?, isFinal: Bool, errorDomain: String?, errorCode: Int?, generation resultGeneration: Int) {
    guard isRunning, resultGeneration == generation else { return }
    if let errorDomain, let errorCode {
      if let pendingText { deliver(pendingText) }
      switch SpeechRecognitionFailure.classify(domain: errorDomain, code: errorCode) {
      case .routine: startTask()
      case .recognizerUnavailable: fail("recognition error \(errorDomain) \(errorCode)", transient: false)
      case .transient: fail("recognition error \(errorDomain) \(errorCode)", transient: true)
      }
      return
    }
    guard let text, !text.isEmpty else { return }
    if isFinal {
      deliver(text)
      startTask()
      return
    }
    pendingText = text
    endpointTimer?.cancel()
    endpointTimer = Task { [weak self] in
      try? await Task.sleep(for: Self.endpointSilence)
      guard !Task.isCancelled, let self, self.generation == resultGeneration else { return }
      self.utteranceEnded()
    }
  }

  private func utteranceEnded() {
    guard let pendingText else { return }
    deliver(pendingText)
    startTask()
  }

  private func deliver(_ text: String) {
    pendingText = nil
    onEvent?(.transcript(text))
  }
}

/// The mic engine, confined to A11yAudioSession's queue. Rebuilds its tap when the engine's
/// configuration changes (a route change, or the session's category changing under it).
final class PhoneMicTap: @unchecked Sendable {
  /// Called from the session queue when the mic can't be kept running.
  var onFailure: (@Sendable (String) -> Void)?

  private let audio = A11yAudioSession.shared
  private let engine = AVAudioEngine()
  private var observer: NSObjectProtocol?
  private var isOn = false
  private let sink = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)

  private static let bufferSize: AVAudioFrameCount = 1024

  /// The request tapped audio goes to. Swapped without touching the engine, so a new recognition
  /// task doesn't restart the mic. nil drops audio on the floor.
  func feed(_ request: SFSpeechAudioBufferRecognitionRequest?) {
    sink.withLockUnchecked { $0 = request }
  }

  /// `completion` gets nil on success, or why not, on the session queue.
  func start(completion: @escaping @Sendable (String?) -> Void) {
    audio.queue.async { [self] in
      let hold = A11yAudioSession.InputHold(
        pause: { [self] in if engine.isRunning { engine.stop() } },
        resume: { [self] in
          if let failure = startEngine() { onFailure?(failure) }
        })
      guard audio.beginInput(hold) else {
        completion("audio session unavailable")
        return
      }
      isOn = true
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [self] _ in
        audio.queue.async { [self] in configurationChanged() }
      }
      let failure = startEngine()
      if failure != nil { shutDown() }
      completion(failure)
    }
  }

  /// Blocks until the mic is off and the session is handed back, so a recording that starts next
  /// finds them free. Only reached while running, so it can't stall a call with no mic in use.
  func stop() {
    feed(nil)
    audio.queue.sync { shutDown() }
  }

  private func shutDown() {
    guard isOn else { return }
    isOn = false
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    audio.endInput()
  }

  private func configurationChanged() {
    guard isOn else { return }
    if let failure = startEngine() { onFailure?(failure) }
  }

  /// Installs a tap in the input's current format and starts. The format can change with the route,
  /// and a zero format means no usable mic: installTap would throw an uncatchable exception.
  private func startEngine() -> String? {
    if engine.isRunning { engine.stop() }
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return "no usable microphone" }
    input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: format) { [sink] buffer, _ in
      sink.withLockUnchecked { $0 }?.append(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
      return nil
    } catch {
      input.removeTap(onBus: 0)
      return "microphone engine: \(error.localizedDescription)"
    }
  }
}
