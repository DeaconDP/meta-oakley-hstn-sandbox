/*
 * A11yAudioSession - the audio session and earcon engine shared by EarconPlayer and Announcer
 *
 * Playback category, so audio follows the system route to the glasses over A2DP and isn't silenced by the Ring/Silent switch; released with
 * notifyOthersOnDeactivation when idle, so ducked music comes back. Earcons alone mix with other
 * audio; while the app's own voice is speaking, other audio is ducked.
 *
 * Session calls block, so everything here runs on one serial queue. The queue also confines the
 * AVAudioEngine and its buffers, which is what makes the `@unchecked Sendable` below sound.
 *
 * The engine is the latency-critical part. Buffers are rendered once and nodes stay attached, so
 * a play is "schedule buffer, play". After use, the session and engine stay up for `idleDelay`,
 * so a burst of earcons and speech doesn't pay activation each time; then both are released.
 *
 * Phone voice commands (PhoneSpeechListener) need the phone mic, which the playback category
 * doesn't give. While that listener holds the input (beginInput/endInput), the session is
 * play-and-record with A2DP allowed and HFP not: the mic is the phone's and output stays on the
 * glasses' high-quality route. Opening HFP for commands would drop output to mono, and the DAT docs
 * want an HFP route settled before a stream starts. Earcons and speech play into that session, and
 * the session stays up until endInput. Ducking can only be dropped by deactivating, which a running
 * mic refuses, so once speech has been idle for `idleDelay` the mic is paused for a moment to let
 * ducked music come back.
 */

import AVFoundation
import os

final class A11yAudioSession: @unchecked Sendable {
  static let shared = A11yAudioSession()

  /// Serial, so activations and deactivations apply in the order they were requested.
  let queue = DispatchQueue(label: "com.deaco.hstnbench.a11y-audio", qos: .userInteractive)

  /// How long the session and engine stay up after the last sound. Long enough to cover the gap
  /// between an earcon and the speech after it; short enough that ducked music returns promptly.
  private let idleDelay: TimeInterval = 2

  // MARK: Queue-confined state

  /// The phone mic's owner. Queue-confined, and its closures run on the queue.
  struct InputHold {
    /// Stop the engine so the session can be cycled; the tap may stay installed.
    var pause: () -> Void
    /// Start it again afterwards.
    var resume: () -> Void
  }

  private var inputHold: InputHold?
  private var isActive = false
  private var isDucking = false
  /// Own-TTS speech in progress (Announcer and CloudVoicePlayer hold at most one each).
  private var speechHolds = 0
  private var isTicking = false
  /// Bumped on every use, so a pending idle check only fires if nothing happened since.
  private var idleGeneration = 0

  private var engine: AVAudioEngine?
  private let earconNode = AVAudioPlayerNode()
  private let tickNode = AVAudioPlayerNode()
  private var buffers: [Earcon: AVAudioPCMBuffer] = [:]
  private var tickBuffer: AVAudioPCMBuffer?
  private var observers: [NSObjectProtocol] = []

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "A11yAudio")

  private init() {}

  // MARK: Earcons

  /// Builds the engine and renders every earcon. Idempotent; called ahead of the first play so
  /// that play only schedules a buffer.
  func prepareEngine() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard engine == nil else { return }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
    let engine = AVAudioEngine()
    engine.attach(earconNode)
    engine.attach(tickNode)
    engine.connect(earconNode, to: engine.mainMixerNode, format: format)
    engine.connect(tickNode, to: engine.mainMixerNode, format: format)
    earconNode.volume = 0.7
    tickNode.volume = 0.7
    for earcon in Earcon.allCases {
      buffers[earcon] = EarconSynth.render(earcon.notes, timbre: earcon.timbre, format: format)
    }
    tickBuffer = EarconSynth.renderTick(format: format)
    // The app's own voice joins the earcons here when the user's ears settings need it (AudioBus).
    AudioBus.shared.install(on: engine, earconNode: earconNode, tickNode: tickNode) { [self] in startEngine() }
    engine.prepare()
    self.engine = engine
    observeSession(engine: engine)
  }

  /// `requestedAt`: the uptime of the main-actor call, for the 100 ms earcon budget (AudioBusMetrics).
  func playEarcon(_ earcon: Earcon, requestedAt: UInt64? = nil) {
    dispatchPrecondition(condition: .onQueue(queue))
    prepareEngine()
    // Pan and volume from the Ears and Sounds settings, and any one-off side cue.
    let buffer = AudioBus.shared.earconBuffer(for: earcon, standard: buffers[earcon])
    guard let buffer, startEngine() else { return }
    // .interrupts: a newer state replaces an older tone instead of queueing behind it.
    earconNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
    earconNode.play()
    if let requestedAt { AudioBus.recordEarcon(requestedAt: requestedAt) }
    scheduleIdleCheck(after: earcon.duration)
  }

  func startTick() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isTicking else { return }
    prepareEngine()
    isTicking = true
    resumeTick()
  }

  func stopTick() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard isTicking else { return }
    isTicking = false
    tickNode.stop()
    scheduleIdleCheck(after: 0)
  }

  /// Loops the one-second tick buffer, so the period is sample-accurate with no timer.
  private func resumeTick() {
    guard isTicking, let tickBuffer, startEngine() else { return }
    tickNode.scheduleBuffer(tickBuffer, at: nil, options: [.loops, .interrupts])
    tickNode.play()
  }

  /// Activates the session if needed and starts the engine. Retries once with a fresh activation,
  /// since an interruption or another component can deactivate the session behind our back.
  private func startEngine() -> Bool {
    guard let engine else { return false }
    if engine.isRunning, isActive { return true }
    for attempt in 0..<2 {
      if attempt > 0 { isActive = false }
      activate(ducking: false)
      do {
        if !engine.isRunning { try engine.start() }
        return true
      } catch {
        Self.logger.error("Earcon engine failed to start: \(error.localizedDescription)")
      }
    }
    return false
  }

  // MARK: Speech

  /// Called before the Announcer's synthesizer or CloudVoicePlayer speaks. Ducks other audio until `endSpeech()`.
  func beginSpeech() {
    dispatchPrecondition(condition: .onQueue(queue))
    speechHolds += 1
    activate(ducking: true)
    idleGeneration += 1
  }

  func endSpeech() {
    dispatchPrecondition(condition: .onQueue(queue))
    speechHolds = max(0, speechHolds - 1)
    scheduleIdleCheck(after: 0)
  }

  // MARK: Phone mic

  /// Takes the phone mic's hold and activates play-and-record. False if activating failed.
  func beginInput(_ hold: InputHold) -> Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    inputHold = hold
    idleGeneration += 1
    // Something else may have deactivated the session behind our back, in a category that matches.
    isActive = false
    activate(ducking: speechHolds > 0)
    guard isActive else {
      inputHold = nil
      return false
    }
    return true
  }

  /// Hands the mic back. The caller has already stopped its engine.
  func endInput() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard inputHold != nil else { return }
    inputHold = nil
    scheduleIdleCheck(after: 0)
  }

  /// What the session should be set to. Pure, so the "no HFP for commands" rule is unit-testable.
  static func sessionConfiguration(
    phoneMic: Bool, ducking: Bool
  ) -> (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
    let mixing: AVAudioSession.CategoryOptions = ducking ? .duckOthers : .mixWithOthers
    guard phoneMic else { return (.playback, .spokenAudio, mixing) }
    // A2DP keeps output on the glasses at full quality. Without .defaultToSpeaker, output with no
    // Bluetooth would drop to the earpiece, and the speaker test's "phone speaker" would be wrong.
    return (.playAndRecord, .default, mixing.union([.allowBluetoothA2DP, .defaultToSpeaker]))
  }

  // MARK: Session

  /// Sets our category every time it isn't already set, because another component may have changed
  /// it. Ducking is only ever added while active, never removed: removing it
  /// takes a deactivation, which the idle check does.
  private func activate(ducking: Bool) {
    let session = AVAudioSession.sharedInstance()
    let wantsDucking = ducking || (isActive && isDucking)
    let configuration = Self.sessionConfiguration(phoneMic: inputHold != nil, ducking: wantsDucking)
    let needsCategory = !isActive || session.category != configuration.category || wantsDucking != isDucking
    guard needsCategory else { return }
    do {
      try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
      try session.setActive(true)
      isActive = true
      isDucking = wantsDucking
    } catch {
      Self.logger.error("A11y audio session activation failed: \(error.localizedDescription)")
    }
  }

  private func scheduleIdleCheck(after delay: TimeInterval) {
    idleGeneration += 1
    let generation = idleGeneration
    queue.asyncAfter(deadline: .now() + delay + idleDelay) { [self] in
      deactivateIfIdle(generation: generation)
    }
  }

  /// Stops the engine first: a session with running I/O refuses to deactivate. Leaves the session
  /// alone if it isn't one of ours any more (something else took it over).
  private func deactivateIfIdle(generation: Int) {
    guard generation == idleGeneration, speechHolds == 0, !isTicking else { return }
    if inputHold != nil {
      releaseDuckingKeepingInput()
      return
    }
    if let engine, engine.isRunning {
      earconNode.stop()
      engine.stop()
    }
    guard isActive else { return }
    isActive = false
    isDucking = false
    let session = AVAudioSession.sharedInstance()
    // A category or mode that isn't ours means something else took the session over.
    guard session.category == .playback || (session.category == .playAndRecord && session.mode == .default) else { return }
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      Self.logger.error("A11y audio session deactivation failed: \(error.localizedDescription)")
    }
  }

  /// Speech is over and the phone mic is still listening. Ducked audio only returns on a
  /// deactivation, which running I/O refuses, so pause the mic, cycle the session, and carry on.
  /// Without ducking to release, the earcon engine is left running while listening, so accepting
  /// a command doesn't wait for an engine start.
  private func releaseDuckingKeepingInput() {
    guard let inputHold, isDucking else { return }
    inputHold.pause()
    if let engine, engine.isRunning {
      earconNode.stop()
      engine.stop()
    }
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      Self.logger.error("A11y audio session deactivation failed: \(error.localizedDescription)")
    }
    isActive = false
    isDucking = false
    activate(ducking: false)
    inputHold.resume()
  }

  /// A route change (glasses connecting) or an interruption (a call) stops the engine and may
  /// deactivate the session. Forget the active state so the next sound re-activates, and bring the
  /// working tick back if it was running.
  private func observeSession(engine: AVAudioEngine) {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [self] _ in
        queue.async { [self] in
          // A category that isn't ours means something else took the session. Don't switch it back
          // from under it just to keep ticking; the next earcon restarts things.
          AudioBus.shared.engineStopped()
          let category = AVAudioSession.sharedInstance().category
          guard category == .playback || inputHold != nil else { return }
          resumeTick()
        }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) {
        [self] notification in
        let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
        queue.async { [self] in
          if began {
            isActive = false
            isDucking = false
            AudioBus.shared.engineStopped()
          } else {
            resumeTick()
          }
        }
      })
  }

  // MARK: Route

  /// "glasses" when a Bluetooth output is the route, "headphones" for wired or USB, otherwise
  /// "phone speaker". Bluetooth is assumed to be the glasses: the app is built around them, and
  /// the route doesn't say which Bluetooth device it is beyond its user-set name.
  static func outputDescription() -> String {
    let ports = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
    if ports.contains(where: { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0) }) { return "glasses" }
    if ports.contains(where: { [.headphones, .usbAudio].contains($0) }) { return "headphones" }
    return "phone speaker"
  }
}
